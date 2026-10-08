#!/usr/bin/env python3
"""
build_opna_test_tone.py — Generate a minimal YM2608 FM test-tone preload binary.

Output format (one event = delay_us + write_count + port/reg/data tuples):

  uint32 delay_us  (little-endian)
  uint8  write_count
  (write_count × 3) bytes of {u8 port, u8 reg, u8 data}

This format is consumed by the PS buffered-song parser in opl_stream.cpp
(parse_buffered_event / validate_buffered_song).

Strategy:
  - FM channel 0 only
  - Operator slot mapping assumed to be OPN2-style (0/1/2/3 = +0/+1/+2/+3)
    with per-slot registers at base offsets {0x30,0x40,0x50,0x60,0x70,0x80}.
    NOTE: This mapping needs validation against the actual mtrberzi/ym2608
    register decoder in fm2608.vhd.
  - If the OPN2 slot interleave is actually +0/+4/+8/+12 (as in some
    YM2612 implementations), the script can be adjusted trivially.
  - Simple algorithm 0 (all serial) with one carrier enabled.
  - Key-on for a sustained tone.

Relevant register addresses (port 0, below 0x100):
  DT1_MUL_BASE    = 0x30
  TL_BASE         = 0x40
  KS_AR_BASE      = 0x50
  AM_DR_BASE      = 0x60  (bit7: AM on/off)
  SR_BASE         = 0x70
  SL_RR_BASE      = 0x80
  SSG_EG_BASE     = 0x90
  FNUM_L_BASE     = 0xA0
  BLOCK_FNUM_H    = 0xA4
  FB_ALG          = 0xB0
  PAN_LFO         = 0xB4
  KEY_ON          = 0x28  (bits 0-3: slot enable, bit4: ch0 key-on)
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

# --- OPNA / YM2608 register helpers (port 0) ---

P0 = 0   # YM2608 port 0
P1 = 1   # YM2608 port 1

# Per-operator register bases
DT1_MUL  = 0x30
TL       = 0x40
KS_AR    = 0x50
AM_DR    = 0x60
SR       = 0x70

SL_RR    = 0x80
SSG_EG   = 0x90  # not used in basic test

# Verified against fm2608.vhd (2026-07-01):
#   fm2608 decodes addr[1:0] to select channels 0-5 on ports 0-1.
#   fm_channel.vhd uses addr(7:2) & "00" as target register,
#   with per-operator interleave mapping:
#     opParam[0] (S1) → offset +0  (0x30)
#     opParam[1] (S2) → offset +8  (0x38)
#     opParam[2] (S3) → offset +4  (0x34)
#     opParam[3] (S4) → offset +12 (0x3C)
OP_OFFSETS = [0, 8, 4, 12]  # OPN2 interleave for opParam[0..3]


def op_reg(base: int, op_idx: int) -> int:
    """Return bus-level register address for operator op_idx (0-3) at base."""
    return base + OP_OFFSETS[op_idx]


def build_events() -> list[bytes]:
    """Return a list of raw event blobs."""
    events: list[bytes] = []
    writes: list[tuple[int, int, int]] = []  # (port, reg, data)

    # ----------------------------------------------------------------
    # Event 0: initialise all registers with a long delay before key-on
    # ----------------------------------------------------------------

    # Operator 0 (carrier — S1, opParam[0], offset +0)
    writes.append((P0, op_reg(DT1_MUL, 0), 0x01))
    writes.append((P0, op_reg(TL,      0), 0x10))
    writes.append((P0, op_reg(KS_AR,   0), 0x1F))
    writes.append((P0, op_reg(AM_DR,   0), 0x00))
    writes.append((P0, op_reg(SR,      0), 0x00))
    writes.append((P0, op_reg(SL_RR,   0), 0x0F))

    # Operator 1 (S2 — opParam[1], offset +8) — muted (TL=0x7F)
    writes.append((P0, op_reg(DT1_MUL, 1), 0x01))
    writes.append((P0, op_reg(TL,      1), 0x7F))
    writes.append((P0, op_reg(KS_AR,   1), 0x1F))
    writes.append((P0, op_reg(AM_DR,   1), 0x00))
    writes.append((P0, op_reg(SR,      1), 0x00))
    writes.append((P0, op_reg(SL_RR,   1), 0x0F))

    # Operator 2 (S3 — opParam[2], offset +4) — muted
    writes.append((P0, op_reg(DT1_MUL, 2), 0x01))
    writes.append((P0, op_reg(TL,      2), 0x7F))
    writes.append((P0, op_reg(KS_AR,   2), 0x1F))
    writes.append((P0, op_reg(AM_DR,   2), 0x00))
    writes.append((P0, op_reg(SR,      2), 0x00))
    writes.append((P0, op_reg(SL_RR,   2), 0x0F))

    # Operator 3 (S4 — opParam[3], offset +12) — muted
    writes.append((P0, op_reg(DT1_MUL, 3), 0x01))
    writes.append((P0, op_reg(TL,      3), 0x7F))
    writes.append((P0, op_reg(KS_AR,   3), 0x1F))
    writes.append((P0, op_reg(AM_DR,   3), 0x00))
    writes.append((P0, op_reg(SR,      3), 0x00))
    writes.append((P0, op_reg(SL_RR,   3), 0x0F))

    # FNUM: approximate 440 Hz with block=4
    writes.append((P0, 0xA0, 0x57))   # FNUM low
    writes.append((P0, 0xA4, 0x24))   # Block=4 | FNUM high bits 8-9

    # Algorithm 0 (all serial), feedback 0
    writes.append((P0, 0xB0, 0x00))   # FB_ALG: fb=0, alg=0

    # Stereo output both channels
    writes.append((P0, 0xB4, 0xC0))   # PAN: L+R for ch0

    # Split into manageable chunks
    while writes:
        chunk = writes[:20]
        writes = writes[20:]
        delay = 1000 if len(events) == 0 else 0
        buf = bytearray()
        buf.extend(struct.pack("<I", delay))   # delay_us u32 LE
        buf.append(len(chunk))                   # write_count u8
        for port, reg, data in chunk:
            buf.extend([port, reg, data])
        events.append(bytes(buf))

    # ----------------------------------------------------------------
    # Event N: key-on after short settling delay
    # ----------------------------------------------------------------
    buf = bytearray()
    buf.extend(struct.pack("<I", 10_000))   # 10 ms settling
    buf.append(1)                             # 1 write
    buf.extend([P0, 0x28, 0xF0])            # KEY_ON: slot 0-3 on ch0
    events.append(bytes(buf))

    return events


def write_output(bin_path: Path, txt_path: Path, events: list[bytes]) -> None:
    """Write the binary preload file and a human-readable dump."""
    all_data = b"".join(events)
    bin_path.write_bytes(all_data)

    lines = []
    for ei, blob in enumerate(events):
        if len(blob) < 5:
            continue
        delay_us = struct.unpack_from("<I", blob, 0)[0]
        count = blob[4]
        lines.append(f"# Event {ei}: delay_us={delay_us}, write_count={count}")
        for wi in range(count):
            base = 5 + wi * 3
            port = blob[base]
            reg = blob[base + 1]
            data = blob[base + 2]
            lines.append(f"  {delay_us:>8} {port} {reg:#04x} {data:#04x}")
        lines.append("")
        # Only the first write has the delay; subsequent within same event = 0
        delay_us = 0

    txt_path.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    repo_root = Path(__file__).resolve().parent.parent
    build_dir = repo_root / "build"
    build_dir.mkdir(parents=True, exist_ok=True)

    bin_path = build_dir / "opna_test_tone.bin"
    txt_path = build_dir / "opna_test_tone.txt"

    events = build_events()
    # Validate format
    offset = 0
    data = b"".join(events)
    while offset < len(data):
        if offset + 5 > len(data):
            print(f"ERROR: truncated at offset {offset}", file=sys.stderr)
            sys.exit(1)
        count = data[offset + 4]
        if count == 0:
            print(f"ERROR: zero write_count at offset {offset}", file=sys.stderr)
            sys.exit(1)
        size = 5 + count * 3
        if offset + size > len(data):
            print(f"ERROR: event truncated at offset {offset}", file=sys.stderr)
            sys.exit(1)
        offset += size

    write_output(bin_path, txt_path, events)
    print(f"Wrote {len(data)} bytes ({len(events)} events) to {bin_path}")
    print(f"Dump written to {txt_path}")


if __name__ == "__main__":
    main()
