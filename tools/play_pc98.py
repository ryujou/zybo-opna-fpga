#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Play YM2608 VGM/VGZ music through the Zybo PC98 USB device (SW0 on)."""
import argparse
import collections
import gzip
from pathlib import Path
import struct
import subprocess
import sys
import time

import vgm_mix

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import phase7_usb as usb


def load_vgm(path, seconds=None):
    data = path.read_bytes()
    return parse_vgm(data, seconds)


def music_bytes(path):
    if path.suffix.lower() in (".vgm", ".vgz"):
        return path.read_bytes()
    decoder = (Path(sys._MEIPASS) if getattr(sys, "frozen", False)
               else Path(__file__).resolve().parents[1] / "pc_player/native/bin") / "pmd_decode.exe"
    result = subprocess.run([str(decoder)], input=path.read_bytes(), capture_output=True,
                            creationflags=subprocess.CREATE_NO_WINDOW)
    if result.returncode:
        raise ValueError(result.stderr.decode("utf-8", errors="replace").strip())
    return result.stdout


def load_music(path, seconds=None):
    return parse_vgm(music_bytes(path), seconds)


def load_music_with_mix(path, seconds=None):
    data = music_bytes(path)
    return parse_vgm(data, seconds), vgm_mix.parse_mix(data)


def parse_vgm(data, seconds=None):
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    if len(data) < 0x4c or data[:4] != b"Vgm ":
        raise ValueError("Expected a VGM/VGZ file with a YM2608 header")
    u32 = lambda offset: struct.unpack_from("<I", data, offset)[0]
    clock = u32(0x48)
    if clock not in (7987200, 8000000):
        raise ValueError(f"Unsupported YM2608 clock/chip configuration: {clock}")
    pos = 0x34 + u32(0x34) if u32(0x34) else 0x40
    tick = previous = 0
    events, memory = bytearray(), bytearray()
    counts = collections.Counter()
    while pos < len(data):
        if seconds is not None and tick >= seconds * 44100:
            break
        op = data[pos]
        if op in (0x56, 0x57):
            bank, reg, value = op - 0x56, data[pos + 1], data[pos + 2]
            due = tick * 1000000 // 44100
            events.extend(struct.pack("<IBBBB", due - previous, 1, bank, reg, value))
            previous = due
            group = "SSG" if bank == 0 and reg < 14 else "rhythm" if bank == 0 and 0x10 <= reg <= 0x1d else "ADPCM" if bank == 1 and reg <= 0x10 else "FM/control"
            counts[group] += 1
            pos += 3
        elif op == 0x61:
            tick += struct.unpack_from("<H", data, pos + 1)[0]
            pos += 3
        elif op in (0x62, 0x63) or 0x70 <= op <= 0x7f:
            tick += 735 if op == 0x62 else 882 if op == 0x63 else op - 0x6f
            pos += 1
        elif op == 0x67:
            if data[pos + 1:pos + 3] != b"\x66\x81" or tick != 0:
                raise ValueError("Only initial YM2608 ADPCM RAM blocks are supported")
            length, size, start = u32(pos + 3), u32(pos + 7), u32(pos + 11)
            if length < 8 or pos + 7 + length > len(data):
                raise ValueError("Truncated ADPCM block")
            payload = data[pos + 15:pos + 7 + length]
            if not start + len(payload) <= size <= 262144:
                raise ValueError("ADPCM block exceeds the board's 256 KiB sample memory")
            if len(memory) < start + len(payload):
                memory.extend(bytes(start + len(payload) - len(memory)))
            memory[start:start + len(payload)] = payload
            pos += 7 + length
        elif op == 0x66:
            break
        else:
            raise ValueError(f"Unsupported VGM command 0x{op:02x} at offset 0x{pos:x}")
    if not events:
        raise ValueError("No YM2608 register writes in this file")
    duration = tick / 44100
    if seconds is not None:
        duration = min(duration, seconds)
    return events, memory, duration, dict(counts), clock


def stop_device(device, incoming):
    usb.request(device, incoming, 4)
    # STOP sends ACK followed by STATUS; both must complete before closing USB.
    usb.receive_response(device, incoming, 6)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("songs", type=Path, nargs="+")
    parser.add_argument("--seconds", type=float, help="play only the first N seconds")
    parser.add_argument("--libusb", type=Path, help="path to libusb-1.0.dll when it is not on PATH")
    args = parser.parse_args()
    if args.seconds is not None and args.seconds <= 0:
        parser.error("--seconds must be positive")
    backend = usb.usb.backend.libusb1.get_backend(
        **({"find_library": lambda _: str(args.libusb.resolve())} if args.libusb else {}))
    if backend is None:
        raise RuntimeError("libusb is unavailable; supply --libusb with the library path")
    device = usb.usb.core.find(idVendor=0xcafe, idProduct=0x4012, backend=backend)
    if device is None:
        raise RuntimeError("PC98 USB device is not connected; put SW0 on")
    incoming = bytearray()
    entered = False
    try:
        if not device.serial_number.startswith("ZOPNA"):
            raise RuntimeError("Connected device is not OPNA")
        usb.usb.util.claim_interface(device, 0)
        hello = usb.request(device, incoming, 1)
        if len(hello) != 24 or hello[:2] != vgm_mix.PROTOCOL:
            raise RuntimeError("Expected OPNA USB protocol 2.2")
        capacity = struct.unpack_from("<I", hello, 12)[0]
        entered = True
        for path in args.songs:
            music, gains = load_music_with_mix(path, args.seconds)
            events, memory, duration, counts, clock = music
            if len(events) > capacity:
                raise ValueError(f"Song exceeds the {capacity // 1048576} MiB event buffer")
            usb.request(device, incoming, 2)
            usb.request(device, incoming, 5)
            vgm_mix.set_mix(usb, device, incoming, gains)
            if memory:
                usb.upload_samples(device, incoming, memory, 0, 1024)
            usb.request(device, incoming, 8, struct.pack("<I", len(events)))
            for offset in range(0, len(events), 1024):
                usb.request(device, incoming, 9, events[offset:offset + 1024])
            usb.request(device, incoming, 10)
            print(f"Playing {path.name}: {duration:.2f}s, {clock} Hz, {counts}", flush=True)
            usb.play_with_pending_in(device, incoming)
            time.sleep(duration + 0.1)
            state = usb.status(device, incoming)
            if state["flags"] or state["queued_writes"]:
                raise RuntimeError(f"Playback did not complete: {state}")
            stop_device(device, incoming)
            print(f"Completed {path.name}", flush=True)
    finally:
        try:
            if entered:
                stop_device(device, incoming)
        except usb.usb.core.USBError:
            print("PC98 USB disconnected; playback stops when SW0 changes mode.", file=sys.stderr)
        usb.usb.util.dispose_resources(device)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("Stopped.")
