"""File parsing and the static, read-only performance timeline."""
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path
import math
import gzip
import struct
import subprocess

import mido

from vgm_loader import load_vgm_bytes


def note_name(note):
    return ("C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-")[note % 12] + str(note // 12 - 1)


@dataclass
class Event:
    time: float
    data: list[int]
    channel: int = -1


@dataclass
class Song:
    id: str
    name: str
    format: str
    title: str
    duration: float
    metadata: dict
    events: list[Event]
    rows: list[dict]
    opl_song: object = None
    opna_music: object = None
    opna_data: bytes = b""

    @property
    def mode(self):
        return "opna" if self.opna_music is not None else "midi" if self.format == "MIDI" else "vgm"

    def info(self):
        return {"id": self.id, "name": self.name, "format": self.format,
                "title": self.title, "duration": self.duration, "metadata": self.metadata, "mode": self.mode}

    def index(self):
        return {**self.info(), "columns": 16 if self.mode == "midi" else 12 if self.mode == "opna" else 18, "rows": self.rows}


def load_song(raw, name, song_id):
    suffix = Path(name).suffix.lower()
    if suffix in (".mid", ".midi"):
        return _midi(raw, name, song_id)
    if suffix in (".vgm", ".vgz"):
        data = gzip.decompress(raw) if raw[:2] == b"\x1f\x8b" else raw
        if len(data) >= 0x4c and data[:4] == b"Vgm ":
            version = struct.unpack_from("<I", data, 8)[0]
            offset = struct.unpack_from("<I", data, 0x34)[0]
            header_end = 0x34 + offset if version >= 0x150 and offset else 0x40
            if header_end >= 0x4c and struct.unpack_from("<I", data, 0x48)[0]:
                return _opna(data, name, song_id)
        return _vgm(raw, name, song_id)
    if suffix in (".m", ".m2", ".mz", ".mp", ".pmd"):
        from opna import PC98
        result = subprocess.run([str(PC98 / "pc_player/native/bin/pmd_decode.exe")], input=raw,
                                capture_output=True, creationflags=subprocess.CREATE_NO_WINDOW)
        if result.returncode:
            raise ValueError(result.stderr.decode("utf-8", errors="replace").strip())
        return _opna(result.stdout, name, song_id, "PMD")
    raise ValueError("支持 MID、MIDI、VGM、VGZ 和 PC98 PMD（M/M2/MZ/MP/PMD）")


def _opna(data, name, song_id, file_format=None):
    from opna import parse_vgm, vgm_mix
    packed, samples, duration, counts, clock = parse_vgm(data)
    gains = vgm_mix.parse_mix(data)
    events, cells = [], {}
    elapsed = 0
    for delay, count, bank, reg, value in struct.iter_unpack("<IBBBB", packed):
        elapsed += delay
        events.append(Event(elapsed / 1_000_000, [bank, reg, value]))
        # FM 1–6, SSG 7–9, rhythm 10, ADPCM 11, shared controls 12.
        channel = 11
        if bank == 0 and reg < 14:
            channel = 6 + (reg // 2 if reg < 6 else reg - 8 if 8 <= reg <= 10 else 0)
        elif bank == 0 and 0x10 <= reg <= 0x1d:
            channel = 9
        elif bank == 1 and reg <= 0x10:
            channel = 10
        elif bank == 0 and reg == 0x28 and value & 3 != 3:
            channel = (value & 3) + (3 if value & 4 else 0)
        elif 0x30 <= reg <= 0xb6 and reg & 3 != 3:
            channel = bank * 3 + (reg & 3)
        cells.setdefault(elapsed // 50000, {}).setdefault(str(channel), []).append(f"{bank}:{reg:02X}={value:02X}")
    metadata = {"system": "PC98 · YM2608", "clock": str(clock),
                "samples": str(len(samples)), "mix": ", ".join(f"{gain / 65536:.5f}" for gain in gains)}
    tag_offset = struct.unpack_from("<I", data, 0x14)[0]
    tag = tag_offset + 0x14
    if tag_offset and data[tag:tag + 4] == b"Gd3 " and tag + 12 <= len(data):
        length = struct.unpack_from("<I", data, tag + 8)[0]
        fields = data[tag + 12:tag + 12 + length].decode("utf-16-le", errors="replace").split("\0")
        for key, index in (("title", 0), ("game", 2), ("system", 4), ("author", 6)):
            if len(fields) > index + 1:
                metadata[key] = fields[index] or fields[index + 1]
    rows = [{"time": row * .05, "cells": cells.get(row, {})} for row in range(int(duration / .05) + 1)]
    return Song(song_id, name, file_format or Path(name).suffix[1:].upper(), metadata.get("title") or name,
                duration, metadata, events, rows, opna_music=(packed, samples, gains), opna_data=data)


def _midi(raw, name, song_id):
    try:
        midi = mido.MidiFile(file=BytesIO(raw))
    except (EOFError, OSError) as exc:
        raise ValueError("不是有效的 MIDI 文件") from exc
    if midi.type not in (0, 1) or midi.ticks_per_beat <= 0:
        raise ValueError("支持 SMF 0/1 的 PPQN MIDI")
    events, cells = [], {}
    seconds, tick, tempo, title = 0.0, 0, 500000, name
    tempos = [(0, 0.0, tempo)]
    for message in mido.merge_tracks(midi.tracks):
        tick += message.time
        seconds += mido.tick2second(message.time, midi.ticks_per_beat, tempo)
        if message.type == "set_tempo":
            tempo = message.tempo
            tempos.append((tick, seconds, tempo))
        elif message.type == "track_name" and title == name and message.name:
            title = message.name
        if message.is_meta:
            continue
        channel = getattr(message, "channel", -1)
        events.append(Event(seconds, message.bytes(), channel))
        if channel >= 0:
            row = tick * 4 // midi.ticks_per_beat
            cells.setdefault(row, {}).setdefault(str(channel), []).append(_midi_text(message))
    rows, segment = [], 0
    for row in range(tick * 4 // midi.ticks_per_beat + 1):
        row_tick = row * midi.ticks_per_beat / 4
        while segment + 1 < len(tempos) and tempos[segment + 1][0] <= row_tick:
            segment += 1
        anchor, at, tempo = tempos[segment]
        rows.append({"time": at + mido.tick2second(row_tick - anchor, midi.ticks_per_beat, tempo),
                     "cells": cells.get(row, {})})
    return Song(song_id, name, "MIDI", title, seconds, {}, events, rows)


def _midi_text(message):
    if message.type in ("note_on", "note_off"):
        return "OFF " + note_name(message.note) if message.type == "note_off" or not message.velocity else f"{note_name(message.note)} {message.velocity:02X}"
    if message.type == "program_change":
        return f"@{message.program:03d}"
    if message.type == "control_change":
        return f"{message.control:02X}:{message.value:02X}"
    if message.type == "pitchwheel":
        return f"PB {message.pitch:+d}"
    if message.type == "polytouch":
        return f"AT {message.note:02X}"
    return message.type.upper()[:8]


def _vgm(raw, name, song_id):
    loaded = load_vgm_bytes(raw, name)
    events, cells = [], {}
    registers = [[0] * 256 for _ in range(2)]
    elapsed = 0
    slots = {0: 0, 1: 1, 2: 2, 3: 0, 4: 1, 5: 2,
             8: 3, 9: 4, 10: 5, 11: 3, 12: 4, 13: 5,
             16: 6, 17: 7, 18: 8, 19: 6, 20: 7, 21: 8}
    for event in loaded.events:
        elapsed += event.delta_us
        seconds = elapsed / 1000000
        for write in event.writes:
            bank, reg, value = write.bank, write.reg, write.value
            previous = registers[bank][reg]
            registers[bank][reg] = value
            events.append(Event(seconds, [bank, reg, value]))
            channel, text = -1, f"{reg:02X}:{value:02X}"
            if 0xA0 <= reg <= 0xA8 or 0xB0 <= reg <= 0xB8 or 0xC0 <= reg <= 0xC8:
                channel = reg & 15
                if 0xB0 <= reg <= 0xB8:
                    fnum = registers[bank][0xA0 + channel] | ((value & 3) << 8)
                    frequency = math.ldexp(fnum * 49716, ((value >> 2) & 7) - 20)
                    note = round(69 + 12 * math.log2(frequency / 440)) if frequency else 0
                    text = note_name(max(0, note)) if value & 32 else "OFF" if previous & 32 else text
            elif 0x20 <= reg <= 0x95 or 0xE0 <= reg <= 0xF5:
                channel = slots.get(reg & 31, -1)
            elif reg == 0xBD:
                channel = 6
            if channel >= 0:
                cells.setdefault(elapsed // 50000, {}).setdefault(str(channel + bank * 9), []).append(text)
    rows = [{"time": row * 0.05, "cells": cells.get(row, {})}
            for row in range(loaded.total_us // 50000 + 1)]
    return Song(song_id, name, "VGZ" if name.lower().endswith(".vgz") else "VGM",
                loaded.title, loaded.total_us / 1000000, loaded.metadata, events, rows, loaded)
