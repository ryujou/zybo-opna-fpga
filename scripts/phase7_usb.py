#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise the running OPNA PS application over its actual USB bulk endpoints."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import struct
import sys
from threading import Event
import time

import usb.backend.libusb1
import usb.core
import usb.util

ROOT = Path(__file__).resolve().parents[1]


def encode_frame(kind, payload=b""):
    length = len(payload)
    return b"OP" + bytes((kind, length & 255, length >> 8)) + payload + bytes(
        ((kind + (length & 255) + (length >> 8) + sum(payload)) & 255,))


def request(device, incoming, kind, payload=b""):
    frame = encode_frame(kind, payload)
    if device.write(0x01, frame, timeout=5000) != len(frame):
        raise RuntimeError("Incomplete USB OUT transfer")
    return receive_response(device, incoming, kind)


def receive_response(device, incoming, kind):
    while True:
        while len(incoming) < 5:
            incoming.extend(device.read(0x81, 1024, timeout=5000))
        if incoming[:2] != b"OP":
            raise RuntimeError("Invalid OPNA response framing")
        response_kind = incoming[2]
        length = incoming[3] | incoming[4] << 8
        while len(incoming) < length + 6:
            incoming.extend(device.read(0x81, 1024, timeout=5000))
        response = bytes(incoming[5:length + 5])
        checksum = (response_kind + incoming[3] + incoming[4] + sum(response)) & 255
        if incoming[length + 5] != checksum:
            raise RuntimeError("OPNA response checksum mismatch")
        del incoming[:length + 6]
        if response_kind == 0x7F:
            raise RuntimeError(f"Device rejected command 0x{kind:02x}: {response.hex()}")
        if response_kind == kind | 0x80:
            return response
        # ENTER/STOP and playback completion also emit an unsolicited STATUS.
        if response_kind != 0x86:
            raise RuntimeError(f"Unexpected response 0x{response_kind:02x}")


def play_with_pending_in(device, incoming):
    # PLAY dispatch follows the completed IN ACK in the actual PS application.
    started = Event()

    def receive_play_ack():
        started.set()
        return receive_response(device, incoming, 11)

    with ThreadPoolExecutor(max_workers=1) as reader:
        response = reader.submit(receive_play_ack)
        started.wait()
        frame = encode_frame(11)
        if device.write(0x01, frame, timeout=5000) != len(frame):
            raise RuntimeError("Incomplete USB PLAY transfer")
        return response.result()


def status(device, incoming):
    # HELLO orders this query after any unsolicited completion/STOP STATUS.
    request(device, incoming, 1)
    payload = request(device, incoming, 6)
    if len(payload) != 29:
        raise RuntimeError("Expected the protocol 2.2 STATUS payload")
    free, queued, flags, hardware, late, max_late, loaded, clip_l, clip_r = struct.unpack("<HHBIIIIII", payload)
    if hardware & 8:
        raise RuntimeError(f"Native DDR fault: STATUS=0x{hardware:08x}")
    return {"free_slots": free, "queued_writes": queued, "flags": flags,
            "hardware_status": hardware, "dispatch_late_writes": late,
            "max_dispatch_lateness_us": max_late, "sample_loaded": loaded, "clip_left": clip_l, "clip_right": clip_r}


def upload_samples(device, incoming, samples, kind, chunk):
    request(device, incoming, 14, struct.pack("<IIB", 0, len(samples), kind))
    for offset in range(0, len(samples), chunk):
        request(device, incoming, 15, samples[offset:offset + chunk])
    request(device, incoming, 16)


def read_samples(device, incoming, length, chunk):
    data = bytearray()
    for offset in range(0, length, chunk):
        count = min(chunk, length - offset)
        part = request(device, incoming, 17, struct.pack("<IH", offset, count))
        if len(part) != count:
            raise RuntimeError(f"Short sample read at {offset}")
        data.extend(part)
    return bytes(data)


def music_payload():
    sys.path.insert(0, str(ROOT / "tools/opna_sim"))
    from acceptance_cases import music_data
    writes, memory, _ = music_data()
    events = bytearray()
    previous = count = 0
    for sample, bank, register, value in writes:
        if sample >= 44100:
            break
        due = sample * 1_000_000 // 44100
        events.extend(struct.pack("<IBBBB", due - previous, 1, bank, register, value))
        previous, count = due, count + 1
    samples = bytes(memory.get(index, 0) for index in range(max(memory) + 1))
    if count != 887 or len(samples) != 34560:
        raise RuntimeError("The frozen Counterattack first-second fixture differs")
    return bytes(events), samples, count


def test(args):
    backend = usb.backend.libusb1.get_backend(find_library=lambda _: str(args.libusb.resolve()))
    if backend is None:
        raise RuntimeError("Cannot load the supplied libusb library")
    devices = list(usb.core.find(find_all=True, idVendor=0xCAFE, idProduct=0x4012, backend=backend))
    if len(devices) != 1:
        raise RuntimeError(f"Expected one running OPNA USB device, found {len(devices)}")
    device = devices[0]
    incoming = bytearray()
    checks = []
    try:
        config = device.get_active_configuration()
        interface = config[(0, 0)]
        endpoints = {endpoint.bEndpointAddress: endpoint for endpoint in interface}
        if config.bConfigurationValue != 1 or set(endpoints) != {0x01, 0x81} or any(
                endpoint.wMaxPacketSize != 64 or endpoint.bmAttributes & 3 != 2
                for endpoint in endpoints.values()):
            raise RuntimeError("The active device does not expose the expected EP1 64-byte bulk pair")
        usb.util.claim_interface(device, 0)
        hello = request(device, incoming, 1)
        if len(hello) != 24 or hello[:2] != b"\x02\x02":
            raise RuntimeError("Expected OPNA protocol version 2.2")
        capacity = struct.unpack_from("<I", hello, 12)[0]
        maximum, chunk = struct.unpack_from("<HH", hello, 16)
        if capacity != 8388608 or maximum != 1024 or chunk != 1024:
            raise RuntimeError("Unexpected event buffer or USB payload capability")
        checks.append("actual EP1 bulk descriptors and HELLO 2.2 capabilities")
        request(device, incoming, 2)
        request(device, incoming, 5)
        initial = status(device, incoming)
        if initial["flags"] or initial["queued_writes"] or initial["hardware_status"] & 2:
            raise RuntimeError("IC reset did not leave an idle stream")
        checks.append("actual IC reset and STATUS without DDR fault")
        samples = bytes((index * 37 + (index >> 8)) & 255 for index in range(262144))
        upload_samples(device, incoming, samples, 2, chunk)
        if read_samples(device, incoming, len(samples), maximum) != samples:
            raise RuntimeError("Full 256KiB sample DDR CPU roundtrip differs")
        checks.append("all 262144 sample DDR bytes including the last packed RAM1 bank byte")
        result = {"status": "passed", "hardware_executed": True,
                  "scope": "USB control and sample DDR CPU roundtrip", "checks": checks,
                  "sample_roundtrip_bytes": len(samples), "music_writes_sent": 0}
        if args.music:
            events, samples, count = music_payload()
            upload_samples(device, incoming, samples, 0, chunk)
            if read_samples(device, incoming, len(samples), maximum) != samples:
                raise RuntimeError("Actual Counterattack ADPCM upload/readback differs")
            request(device, incoming, 8, struct.pack("<I", len(events)))
            for offset in range(0, len(events), chunk):
                request(device, incoming, 9, events[offset:offset + chunk])
            request(device, incoming, 10)
            request(device, incoming, 11)
            time.sleep(0.15)
            request(device, incoming, 12)
            paused = status(device, incoming)
            if paused["flags"] & 3 != 3:
                raise RuntimeError("Actual buffered playback was not paused")
            time.sleep(0.05)
            request(device, incoming, 13)
            resumed = status(device, incoming)
            if resumed["flags"] & 3 != 1:
                raise RuntimeError("Actual buffered playback did not resume")
            time.sleep(1.1)
            finished = status(device, incoming)
            if finished["flags"] or finished["queued_writes"]:
                raise RuntimeError("Counterattack first-second stream did not complete")
            checks.append("Counterattack 887 writes/34560 samples and actual USB pause/resume completion")
            result.update(music_writes_sent=count, music_sample_bytes=len(samples),
                          playback_status=finished,
                          scope="USB control, sample DDR CPU roundtrip and buffered playback control")
        request(device, incoming, 4)
        result["final_status"] = status(device, incoming)
        return result
    finally:
        usb.util.dispose_resources(device)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--libusb", type=Path, required=True, help="Existing libusb-1.0 library; the device needs a working USB driver")
    parser.add_argument("--music", action="store_true", help="Upload and play the locally prepared Counterattack first second")
    parser.add_argument("--out", type=Path, default=ROOT / "build/opna_phase7/board/usb-result.json")
    args = parser.parse_args()
    args.out.unlink(missing_ok=True)
    result = test(args)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
