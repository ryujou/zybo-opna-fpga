"""YM2608 file gains in the calibrated libvgm MAME output scale."""
import gzip
import math
import struct

HEADROOM = 1 / 8
PROTOCOL = b'\x02\x02'


def parse_mix(data):
    if data[:2] == b'\x1f\x8b':
        data = gzip.decompress(data)
    if len(data) < 0x4c or data[:4] != b'Vgm ':
        raise ValueError('Expected a YM2608 VGM header')
    u32 = lambda p: struct.unpack_from('<I', data, p)[0]
    version = u32(8)
    start = 0x34 + u32(0x34) if version >= 0x150 and u32(0x34) else 0x40
    if not 0x4c <= start <= len(data):
        raise ValueError('Invalid YM2608 VGM data offset')
    extra = 0xbc + u32(0xbc) if version >= 0x170 and start >= 0xc0 and u32(0xbc) else 0
    header_end = extra or start
    volumes = {7: 128, 0x87: 128}
    if extra:
        if not 0xc0 <= extra <= start - 4:
            raise ValueError('Invalid VGM extra header')
        length = u32(extra)
        if length < 4 or extra + length > start:
            raise ValueError('Truncated VGM extra header')
        if length >= 12 and u32(extra + 8):
            table = extra + 8 + u32(extra + 8)
            if not extra + length <= table < start or table + 1 + data[table] * 4 > start:
                raise ValueError('Truncated VGM chip volume table')
            seen = set()
            for i in range(data[table]):
                chip, flags, value = struct.unpack_from('<BBH', data, table + 1 + i * 4)
                if chip in volumes and not flags & 1 and chip not in seen:
                    volumes[chip] = (128 * (value & 0x7fff) + 128) >> 8 if value & 0x8000 else value
                    seen.add(chip)
    modifier = data[0x7c] if version >= 0x160 and header_end > 0x7c else 0
    modifier = -64 if modifier == 0xc1 else modifier - 256 if modifier > 0xc1 else modifier
    global_gain = 2 ** (modifier / 32)
    # libvgm normalizes device weights, independently of measured song loudness.
    overall = sum(volumes.values())
    factor = 1
    if overall:
        while overall <= 0x180:
            factor *= 2
            overall *= 2
        if factor == 1:
            divisor = 1
            while overall > 0x300:
                divisor *= 2
                overall //= 2
            volumes = {k: v // divisor for k, v in volumes.items()}
        else:
            volumes = {k: v * factor for k, v in volumes.items()}
    gains = (2 * volumes[7] / 256, volumes[0x87] / (3 * 256), HEADROOM * global_gain)
    return tuple(math.floor(value * 65536 + .5) for value in gains)


def set_mix(usb, device, incoming, gains):
    hello = usb.request(device, incoming, 1)
    if len(hello) != 24 or hello[:2] != PROTOCOL:
        raise RuntimeError('VGM mixing requires matching OPNA protocol 2.2 firmware and FPGA')
    payload = struct.pack('<III', *gains)
    if usb.request(device, incoming, 0x12, payload) != payload:
        raise RuntimeError('FPGA mix gain readback differs from request')
