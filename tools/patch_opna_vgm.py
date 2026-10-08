"""Create an OPNA VGM compatibility/SSG diagnostic copy; preserve source timing."""
import argparse
import gzip
import json
from pathlib import Path
import struct

from play_pc98 import parse_vgm


def patch(source, destination, enable_six_channel=False, ssg_steps=0):
    if source.resolve() == destination.resolve():
        raise ValueError('Use a separate output file')
    data = source.read_bytes()
    if data[:2] == b'\x1f\x8b':
        data = gzip.decompress(data)
    parse_vgm(data)
    patched = bytearray(data)
    u32 = lambda offset: struct.unpack_from('<I', data, offset)[0]
    start = 0x34 + u32(0x34) if u32(0x34) else 0x40
    pos = start
    changed = envelope_writes = mode_writes = 0
    while pos < len(data):
        op = data[pos]
        if op in (0x56, 0x57):
            reg, value = data[pos+1:pos+3]
            if op == 0x56 and reg == 0x29:
                mode_writes += 1
            if op == 0x56 and 8 <= reg <= 10:
                if value & 0x10:
                    # Envelope mode has no independent attenuation register.
                    envelope_writes += 1
                else:
                    new = (value & 0xf0) | max(0, (value & 15) - ssg_steps)
                    patched[pos+2] = new
                    changed += new != value
            pos += 3
        elif op == 0x61:
            pos += 3
        elif op in (0x62, 0x63) or 0x70 <= op <= 0x7f:
            pos += 1
        elif op == 0x67:
            pos += 7 + u32(pos+3)
        elif op == 0x66:
            break
        else:
            raise ValueError(f'Unsupported command at {pos:#x}')
    if enable_six_channel:
        if mode_writes:
            raise ValueError('Source already writes 0x29; inspect its mode before patching')
        patched[start:start] = b'\x56\x29\x83'
        # VGM pointers are relative to their own header fields. Header/data start
        # stay in place; the original stream, loop target and GD3 move three bytes.
        for field in (0x04, 0x14, 0x1c):
            relative = u32(field)
            if relative and field + relative >= start:
                struct.pack_into('<I', patched, field, relative + 3)
    parse_vgm(patched)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(patched)
    return dict(source=str(source.resolve()), output=str(destination.resolve()),
                six_channel_prefix=enable_six_channel, ssg_steps=ssg_steps,
                changed_fixed_ssg_writes=changed,
                unchanged_envelope_writes=envelope_writes)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--enable-six-channel', action='store_true')
    parser.add_argument('--ssg-steps', type=int, choices=range(16), default=0)
    args = parser.parse_args()
    if not args.enable_six_channel and not args.ssg_steps:
        parser.error('Select a patch')
    if args.destination.suffix.lower() != '.vgm':
        parser.error('Output must be an uncompressed .vgm file')
    print(json.dumps(patch(args.source, args.destination,
                           args.enable_six_channel, args.ssg_steps), indent=2))


if __name__ == '__main__':
    main()
