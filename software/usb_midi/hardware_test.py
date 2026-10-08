"""Test the Windows system MIDI output; MIDI file playback optionally uses mido."""
import argparse
import ctypes as C
from contextlib import contextmanager
import os
from pathlib import Path
import subprocess
import sys
import time


class Caps(C.Structure):
    _fields_ = [("manufacturer", C.c_ushort), ("product", C.c_ushort),
                ("version", C.c_uint32), ("name", C.c_wchar * 32),
                ("technology", C.c_ushort), ("voices", C.c_ushort),
                ("notes", C.c_ushort), ("channels", C.c_ushort), ("support", C.c_uint32)]


class Header(C.Structure):
    _pack_ = 1  # WinMM's mmsyscom.h uses one-byte packing, including MIDIHDR on x64.
    _fields_ = [("data", C.c_void_p), ("length", C.c_uint32), ("recorded", C.c_uint32),
                ("user", C.c_size_t), ("flags", C.c_uint32), ("next", C.c_void_p),
                ("reserved", C.c_size_t), ("offset", C.c_uint32), ("reserved8", C.c_size_t * 8)]


api = C.WinDLL("winmm")
for function, args in {
    "midiOutGetNumDevs": [],
    "midiOutGetDevCapsW": [C.c_size_t, C.POINTER(Caps), C.c_uint],
    "midiOutOpen": [C.POINTER(C.c_void_p), C.c_uint, C.c_size_t, C.c_size_t, C.c_uint32],
    "midiOutShortMsg": [C.c_void_p, C.c_uint32],
    "midiOutReset": [C.c_void_p], "midiOutClose": [C.c_void_p],
    "midiOutPrepareHeader": [C.c_void_p, C.POINTER(Header), C.c_uint],
    "midiOutLongMsg": [C.c_void_p, C.POINTER(Header), C.c_uint],
    "midiOutUnprepareHeader": [C.c_void_p, C.POINTER(Header), C.c_uint],
    "midiOutGetErrorTextW": [C.c_uint, C.c_wchar_p, C.c_uint],
}.items():
    getattr(api, function).argtypes = args
    getattr(api, function).restype = C.c_uint


def check(result, operation):
    if result:
        text = C.create_unicode_buffer(256)
        api.midiOutGetErrorTextW(result, text, len(text))
        raise RuntimeError(f"{operation}: {result} {text.value}")


def outputs():
    ports = []
    for index in range(api.midiOutGetNumDevs()):
        caps = Caps()
        check(api.midiOutGetDevCapsW(index, C.byref(caps), C.sizeof(caps)), "get capabilities")
        ports.append((index, caps.name))
    return ports


@contextmanager
def device(index):
    handle = C.c_void_p()
    check(api.midiOutOpen(C.byref(handle), index, 0, 0, 0), "open MIDI output")
    try:
        yield handle
    finally:
        try:
            check(api.midiOutReset(handle), "reset MIDI output")
        finally:
            check(api.midiOutClose(handle), "close MIDI output")


def short(handle, status, a=0, b=0):
    check(api.midiOutShortMsg(handle, status | (a << 8) | (b << 16)), "send short MIDI")


def sysex(handle, data):
    buffer = C.create_string_buffer(bytes(data))
    header = Header(data=C.addressof(buffer), length=len(data))
    check(api.midiOutPrepareHeader(handle, C.byref(header), C.sizeof(header)), "prepare SysEx")
    try:
        check(api.midiOutLongMsg(handle, C.byref(header), C.sizeof(header)), "send SysEx")
        deadline = time.monotonic() + 5
        while not header.flags & 1:
            if time.monotonic() >= deadline:
                raise TimeoutError("SysEx output did not complete within five seconds")
            time.sleep(0.005)
    finally:
        if not header.flags & 1:
            check(api.midiOutReset(handle), "cancel pending SysEx")
        check(api.midiOutUnprepareHeader(handle, C.byref(header), C.sizeof(header)), "unprepare SysEx")


def exercise(handle):
    sysex(handle, [0xF0, 0x7E, 0x7F, 9, 1, 0xF7])
    for channel in range(16):
        short(handle, 0xC0 | channel, channel * 7)
        for note in range(4):
            short(handle, 0x90 | channel, 36 + note if channel == 9 else 60 + note, 100)
        time.sleep(0.03)
        for note in range(4):
            short(handle, 0x80 | channel, 36 + note if channel == 9 else 60 + note)
    for program in range(128):
        short(handle, 0xC0, program)
        short(handle, 0x90, 60, 100)
        short(handle, 0x90, 60, 0)
        time.sleep(0.003)
    short(handle, 0x90, 69, 100)
    for cc, value in ((7, 70), (11, 60), (10, 0), (10, 127), (64, 127)):
        short(handle, 0xB0, cc, value)
    short(handle, 0xE0, 0, 80)
    short(handle, 0xA0, 69, 90)
    short(handle, 0xD0, 80)
    short(handle, 0x80, 69)
    time.sleep(0.1)
    short(handle, 0xB0, 64, 0)
    short(handle, 0xB0, 123, 0)
    # The first SysEx is intentionally longer than the firmware's 1 KiB buffer.
    sysex(handle, [0xF0, 0x7D] + [1] * 1100 + [0xF7])
    sysex(handle, [0xF0, 0x7E, 0x7F, 9, 1, 0xF7])
    short(handle, 0x90, 72, 100)
    time.sleep(0.1)
    short(handle, 0x80, 72)
    print("Sent 16-channel/drum, 128-program, controller/aftertouch, SysEx and reset cases", flush=True)


def play_files(handle, paths, seconds):
    import mido
    files = [(path, list(mido.MidiFile(path))) for path in paths]
    if not any(sum(message.time for message in messages) > 0 for _, messages in files):
        raise ValueError("MIDI playback needs a file with positive duration")
    started = time.monotonic()
    deadline = started + seconds if seconds else float("inf")
    next_log = started + 30
    repeats = messages_sent = 0
    while time.monotonic() < deadline:
        for path, messages in files:
            print(f"Playing {path}", flush=True)
            target = time.monotonic()
            for message in messages:
                target += message.time
                delay = min(target, deadline) - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                if time.monotonic() >= deadline:
                    break
                if not message.is_meta:
                    data = message.bytes()
                    if message.type == "sysex":
                        sysex(handle, data)
                    else:
                        short(handle, data[0], data[1] if len(data) > 1 else 0,
                              data[2] if len(data) > 2 else 0)
                    messages_sent += 1
                if time.monotonic() >= next_log:
                    print(f"MIDI elapsed={time.monotonic()-started:.1f}s messages={messages_sent}", flush=True)
                    next_log += 30
            check(api.midiOutReset(handle), "reset between MIDI files")
            if time.monotonic() >= deadline:
                break
        repeats += 1
        if not seconds:
            break
    print(f"Completed MIDI playback in {time.monotonic()-started:.1f}s, messages={messages_sent}, passes={repeats}", flush=True)


def test_ila(handle):
    import csv
    import json
    root = Path(__file__).resolve().parents[2]
    sys.path.insert(0, str(root / "tools/opna_sim"))
    from phase7_ila_compare import compare_audio
    vivado = Path(os.environ.get("XILINX_VIVADO", "J:/FPGA/2025.2/Vivado")) / "bin/vivado.bat"
    results = {}
    for pan, label in ((0, "left"), (127, "right"), (64, "stereo"), (64, "quiet")):
        sysex(handle, [0xF0, 0x7E, 0x7F, 9, 1, 0xF7])
        if label != "quiet":
            short(handle, 0xC0, 80)
            short(handle, 0xB0, 10, pan)
            short(handle, 0x90, 69, 100)
        time.sleep(0.5)
        out = root / "build/usb_midi/ila" / label
        out.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(vivado), "-mode", "batch", "-source", str(root / "scripts/phase7_capture.tcl"),
                        "-log", str(out / "capture.log"), "-journal", str(out / "capture.jou"),
                        "-tclargs", str(root / "build/opna_phase7/pipeline-board/zybo_opna.ltx"), str(out), "audio"], cwd=out, check=True)
        result = compare_audio(out)
        rows = list(csv.reader((out / "audio.csv").open(encoding="utf-8")))[2:]
        frames = [int(row[3],16) for row in rows]
        left, right = [f >> 16 for f in frames], [f & 65535 for f in frames]
        if label == "left": audible = any(left) and not any(right)
        elif label == "right": audible = any(right) and not any(left)
        elif label == "stereo": audible = any(left) and any(right)
        else: audible = not any(left) and not any(right)
        result["expected_channels_passed"] = audible
        result["passed"] &= audible
        results[label] = result
        check(api.midiOutReset(handle), "reset after ILA tone")
    destination = root / "build/usb_midi/ila-result.json"
    destination.write_text(json.dumps(results, indent=2), encoding="utf-8")
    if not all(r["passed"] for r in results.values()): raise RuntimeError("MIDI I2S validation failed")
    print("PASS actual USB MIDI to I2S: left, right, stereo, reset silence", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--seconds", type=float, default=0, help="duration of a synthetic MIDI load")
    parser.add_argument("--hold", type=float, default=0, help="hold A4 for digital waveform capture")
    parser.add_argument("--pan", type=int, choices=(0, 64, 127), default=64)
    parser.add_argument("--midi", action="append", help="MIDI file to play; repeat for --seconds if supplied (requires mido)")
    parser.add_argument("--ila", action="store_true", help="capture left/right/stereo tones and silence (requires loaded ILA image)")
    args = parser.parse_args()
    ports = outputs()
    for index, name in ports:
        print(f"{index}: {name}", flush=True)
    if args.list:
        return
    index = next((index for index, name in ports if name == "Zybo OPNA MIDI"), None)
    if index is None:
        raise RuntimeError("Zybo OPNA MIDI is not present in the Windows MIDI output list")
    with device(index) as handle:
        if args.ila:
            test_ila(handle)
            return
        if args.hold:
            sysex(handle, [0xF0, 0x7E, 0x7F, 9, 1, 0xF7])
            short(handle, 0xC0, 73)
            short(handle, 0xB0, 10, args.pan)
            short(handle, 0x90, 69, 100)
            print(f"Holding A4, program 73, velocity 100, pan {args.pan}", flush=True)
            time.sleep(args.hold)
            short(handle, 0x80, 69)
            return
        exercise(handle)
        if args.midi:
            play_files(handle, args.midi, args.seconds)
            return
        started = time.monotonic()
        next_log = started + 30
        cycles = 0
        while time.monotonic() - started < args.seconds:
            for channel in range(16):
                note = 36 + cycles % 12 if channel == 9 else 48 + (cycles + channel) % 36
                short(handle, 0x90 | channel, note, 70 + cycles % 50)
                short(handle, 0xE0 | channel, 0, 60 + cycles % 9)
                short(handle, 0x80 | channel, note)
            cycles += 1
            time.sleep(0.04)
            if time.monotonic() >= next_log:
                print(f"Load elapsed={time.monotonic()-started:.1f}s cycles={cycles} short_messages={cycles*48}", flush=True)
                next_log += 30
        print(f"Completed {cycles} synthetic cycles in {time.monotonic()-started:.1f}s", flush=True)


if __name__ == "__main__":
    main()
