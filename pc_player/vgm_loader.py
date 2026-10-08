from __future__ import annotations

from dataclasses import dataclass, field
import gzip
from pathlib import Path
from typing import List

from protocol import OplWrite


VGM_SAMPLE_RATE = 44_100


@dataclass
class OplStreamEvent:
    delta_us: int
    writes: List[OplWrite]


@dataclass
class LoadedVgm:
    events: List[OplStreamEvent]
    total_us: int
    title: str
    metadata: dict[str, str] = field(default_factory=dict)


def load_vgm_file(path: str) -> LoadedVgm:
    file_path = Path(path)
    return load_vgm_bytes(file_path.read_bytes(), file_path.name)


def load_vgm_bytes(raw: bytes, name: str) -> LoadedVgm:
    data = gzip.decompress(raw) if Path(name).suffix.lower() == ".vgz" else raw
    if len(data) < 0x40 or data[:4] != b"Vgm ":
        raise ValueError("不是有效的 VGM/VGZ 文件")

    version = _u32(data, 0x08)
    data_offset = _u32(data, 0x34)
    ym3812_clock = _u32(data, 0x50)
    ymf262_clock = _u32(data, 0x5C)

    # Some VGM writers place GD3 metadata after the command stream and expose
    # its offset in the standard header field at 0x14. Stop parsing before the
    # tag instead of treating UTF-16 metadata bytes as opcodes.
    gd3_offset = _u32(data, 0x14)
    command_end = gd3_offset + 0x14 if gd3_offset else len(data)

    # If the file only declares YM3812, force C0-C8 panning bits so an OPL3 core
    # sends OPL2-era channels to both left and right.
    opl2_compat_mode = ym3812_clock != 0 and ymf262_clock == 0

    data_start = 0x34 + data_offset if version >= 0x00000150 and data_offset else 0x40

    events: List[OplStreamEvent] = []
    pending_delay_us = 0
    pending_writes: List[OplWrite] = []
    total_us = 0
    total_samples = 0

    def wait_us(samples: int) -> int:
        nonlocal total_samples, total_us
        previous = total_us
        total_samples += samples
        total_us = (total_samples * 1_000_000 + VGM_SAMPLE_RATE // 2) // VGM_SAMPLE_RATE
        return total_us - previous
    pos = data_start

    while pos < min(len(data), command_end):
        cmd_offset = pos
        cmd = data[pos]
        pos += 1

        if cmd == 0x66:
            break

        if cmd == 0x61:
            wait_samples = _u16_checked(data, pos, cmd_offset, cmd)
            pos += 2
            delay_us = wait_us(wait_samples)
            pending_delay_us = _flush_pending(events, pending_writes, pending_delay_us)
            pending_delay_us += delay_us
            continue

        if cmd == 0x62:
            delay_us = wait_us(735)
            pending_delay_us = _flush_pending(events, pending_writes, pending_delay_us)
            pending_delay_us += delay_us
            continue

        if cmd == 0x63:
            delay_us = wait_us(882)
            pending_delay_us = _flush_pending(events, pending_writes, pending_delay_us)
            pending_delay_us += delay_us
            continue

        if 0x70 <= cmd <= 0x7F:
            delay_us = wait_us((cmd & 0x0F) + 1)
            pending_delay_us = _flush_pending(events, pending_writes, pending_delay_us)
            pending_delay_us += delay_us
            continue

        # YM2612 DAC write + wait n samples. We do not replay the DAC write for
        # an OPL-only player, but the wait must be preserved.
        if 0x80 <= cmd <= 0x8F:
            delay_us = wait_us(cmd & 0x0F)
            pending_delay_us = _flush_pending(events, pending_writes, pending_delay_us)
            pending_delay_us += delay_us
            continue

        # YM3812 / OPL2 first chip.
        if cmd == 0x5A:
            reg, value = _read_reg_value(data, pos, cmd_offset, cmd)
            pos += 2
            if opl2_compat_mode and 0xC0 <= reg <= 0xC8:
                value |= 0x30
            pending_writes.append(OplWrite(0, reg, value))
            continue

        # YMF262 / OPL3 first chip, port 0 / port 1.
        if cmd == 0x5E:
            reg, value = _read_reg_value(data, pos, cmd_offset, cmd)
            pos += 2
            pending_writes.append(OplWrite(0, reg, value))
            continue

        if cmd == 0x5F:
            reg, value = _read_reg_value(data, pos, cmd_offset, cmd)
            pos += 2
            pending_writes.append(OplWrite(1, reg, value))
            continue

        # Second YM3812 / dual OPL2. A single OPL3 can approximate this by
        # mapping chip 0 to bank 0 and chip 1 to bank 1.
        if cmd == 0xAA:
            reg, value = _read_reg_value(data, pos, cmd_offset, cmd)
            pos += 2
            if opl2_compat_mode and 0xC0 <= reg <= 0xC8:
                value |= 0x30
            pending_writes.append(OplWrite(1, reg, value))
            continue

        # Game Gear stereo / SN76489 PSG write. Not relevant for OPL-only output.
        if cmd in (0x4F, 0x50):
            pos = _skip(data, pos, 1, cmd_offset, cmd)
            continue

        # Other common two-byte chip writes. Ignore non-OPL chips so mixed logs
        # can still load, but do not corrupt the stream position.
        if cmd in (
            0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
            0x5B, 0x5C, 0x5D,
        ):
            pos = _skip(data, pos, 2, cmd_offset, cmd)
            continue

        # Second-chip writes for other chips. 0xAE/0xAF are second YMF262 and
        # require a second OPL3 chip; this one-OPL3 player ignores them for now.
        if 0xA0 <= cmd <= 0xBF:
            pos = _skip(data, pos, 2, cmd_offset, cmd)
            continue

        # Data block: 0x67 0x66 tt ss ss ss ss [data...]
        if cmd == 0x67:
            if pos >= len(data) or data[pos] != 0x66:
                raise ValueError(f"VGM 数据块格式错误，offset=0x{cmd_offset:X}")
            block_size = _u32_checked(data, pos + 2, cmd_offset, cmd)
            pos = _skip(data, pos, 6 + block_size, cmd_offset, cmd)
            continue

        # PCM RAM write: 0x68 0x66 cc oo oo oo dd dd dd ss ss ss
        if cmd == 0x68:
            if pos >= len(data) or data[pos] != 0x66:
                raise ValueError(f"VGM PCM RAM 写入格式错误，offset=0x{cmd_offset:X}")
            pos = _skip(data, pos, 11, cmd_offset, cmd)
            continue

        # DAC stream control commands. They are often present in modern VGMs;
        # this OPL-only loader can skip them unless you later add PCM streaming.
        if cmd == 0x90:
            pos = _skip(data, pos, 4, cmd_offset, cmd)
            continue
        if cmd == 0x91:
            pos = _skip(data, pos, 4, cmd_offset, cmd)
            continue
        if cmd == 0x92:
            pos = _skip(data, pos, 5, cmd_offset, cmd)
            continue
        if cmd == 0x93:
            pos = _skip(data, pos, 10, cmd_offset, cmd)
            continue
        if cmd == 0x94:
            pos = _skip(data, pos, 1, cmd_offset, cmd)
            continue
        if cmd == 0x95:
            pos = _skip(data, pos, 4, cmd_offset, cmd)
            continue

        raise ValueError(
            f"暂不支持的 VGM 指令: 0x{cmd:02X}，offset=0x{cmd_offset:X}，near={_near(data, cmd_offset)}"
        )

    if pending_writes:
        events.append(OplStreamEvent(delta_us=pending_delay_us, writes=list(pending_writes)))
    elif pending_delay_us and events:
        # Carry the final wait without changing any audible OPL register.
        events.append(OplStreamEvent(delta_us=pending_delay_us, writes=[OplWrite(0, 0, 0)]))

    metadata = {}
    if gd3_offset:
        tag = gd3_offset + 0x14
        if data[tag:tag + 4] == b"Gd3 ":
            length = _u32(data, tag + 8)
            fields = data[tag + 12:tag + 12 + length].decode("utf-16-le").split("\0")
            for key, primary, alternate in (("title", 0, 1), ("game", 2, 3),
                                            ("system", 4, 5), ("author", 6, 7)):
                if len(fields) > alternate and (fields[primary] or fields[alternate]):
                    metadata[key] = fields[primary] or fields[alternate]
    return LoadedVgm(events=events, total_us=total_us,
                     title=metadata.get("title", name), metadata=metadata)


def _flush_pending(
    events: List[OplStreamEvent],
    pending_writes: List[OplWrite],
    pending_delay_us: int,
) -> int:
    if not pending_writes:
        return pending_delay_us
    events.append(OplStreamEvent(delta_us=pending_delay_us, writes=list(pending_writes)))
    pending_writes.clear()
    return 0


def _samples_to_us(samples: int) -> int:
    return int(round(samples * 1_000_000 / VGM_SAMPLE_RATE))


def _read_reg_value(data: bytes, offset: int, cmd_offset: int, cmd: int) -> tuple[int, int]:
    if offset + 2 > len(data):
        raise ValueError(f"VGM 指令 0x{cmd:02X} 在 offset=0x{cmd_offset:X} 后数据不足")
    return data[offset], data[offset + 1]


def _skip(data: bytes, offset: int, count: int, cmd_offset: int, cmd: int) -> int:
    new_offset = offset + count
    if new_offset > len(data):
        raise ValueError(f"VGM 指令 0x{cmd:02X} 在 offset=0x{cmd_offset:X} 后数据不足，需要跳过 {count} 字节")
    return new_offset


def _near(data: bytes, offset: int, count: int = 16) -> str:
    return data[offset : min(len(data), offset + count)].hex(" ")


def _u16(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset : offset + 2], "little")


def _u16_checked(data: bytes, offset: int, cmd_offset: int, cmd: int) -> int:
    if offset + 2 > len(data):
        raise ValueError(f"VGM 指令 0x{cmd:02X} 在 offset=0x{cmd_offset:X} 后数据不足")
    return _u16(data, offset)


def _u32(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset : offset + 4], "little")


def _u32_checked(data: bytes, offset: int, cmd_offset: int, cmd: int) -> int:
    if offset + 4 > len(data):
        raise ValueError(f"VGM 指令 0x{cmd:02X} 在 offset=0x{cmd_offset:X} 后数据不足")
    return _u32(data, offset)
