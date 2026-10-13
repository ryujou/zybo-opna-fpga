"""Desktop PCM and voice state from the fixed libADLMIDI/Nuked core."""
import ctypes as C
import math
from pathlib import Path
import sys

SAMPLE_RATE = 49716
CAPACITY = 4096


class VoiceState(C.Structure):
    _fields_ = [("source", C.c_int), ("pair", C.c_int), ("kind", C.c_int),
                ("key_on", C.c_int), ("frequency", C.c_double)]


class OplVisual:
    def __init__(self, midi_mode: bool):
        root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[1]))
        path = root / "opl_visual.dll" if getattr(sys, "frozen", False) else root / "pc_player/native/bin/opl_visual.dll"
        self.dll = C.CDLL(str(path))
        for name, args, result in (
            ("visual_create", [C.c_int], C.c_void_p),
            ("visual_destroy", [C.c_void_p], None),
            ("visual_midi", [C.c_void_p, C.POINTER(C.c_ubyte), C.c_int], None),
            ("visual_opl", [C.c_void_p, C.c_int, C.c_int, C.c_int], None),
            ("visual_advance", [C.c_void_p, C.c_double, C.c_int], None),
            ("visual_snapshot", [C.c_void_p, C.POINTER(C.c_float), C.POINTER(VoiceState)], None),
        ):
            function = getattr(self.dll, name)
            function.argtypes, function.restype = args, result
        self.handle = self.dll.visual_create(midi_mode)
        if not self.handle:
            raise RuntimeError("OPL 核心初始化失败")
        self.samples = (C.c_float * (20 * CAPACITY))()
        self.states = (VoiceState * 18)()
        self.frame_count = 0
        self.position = 0.0

    def close(self):
        if self.handle:
            self.dll.visual_destroy(self.handle)
            self.handle = None

    def midi(self, data):
        buffer = (C.c_ubyte * len(data))(*data)
        self.dll.visual_midi(self.handle, buffer, len(data))

    def opl(self, bank, reg, value):
        self.dll.visual_opl(self.handle, bank, reg, value)

    def advance_to(self, seconds):
        # Split iterator work at ~1 ms so allocation/release tracks board timing.
        while self.position < seconds:
            target = min(seconds, self.position + 0.001)
            frames = round(target * SAMPLE_RATE) - self.frame_count
            self.dll.visual_advance(self.handle, target - self.position, frames)
            self.frame_count += frames
            self.position = target

    def snapshot(self, voices):
        self.dll.visual_snapshot(self.handle, self.samples, self.states)
        channels = []
        for i, state in enumerate(self.states):
            lane = state.source + 2
            active = state.key_on or any(abs(x) > 0.0001 for x in self.samples[lane * CAPACITY + CAPACITY - 1024:(lane + 1) * CAPACITY])
            note = round(69 + 12 * math.log2(state.frequency / 440)) if state.frequency > 0 else None
            channels.append({"id": i + 1, "pair": state.pair, "kind": state.kind,
                             "active": bool(active), "note": note, "frequency": state.frequency})
        total = [self._window(0), self._window(1)]
        waves = [self._window(self.states[v - 1].source + 2) for v in voices]
        return {"total": total, "waves": waves, "opl": channels}

    def _window(self, lane):
        data = self.samples[lane * CAPACITY:(lane + 1) * CAPACITY]
        # A rising zero crossing gives the first-stage display a stable trigger.
        start = CAPACITY - 1024
        mean = sum(data[start:]) / 1024
        for i in range(start - 512, start):
            if data[i] <= mean < data[i + 1]:
                start = i
        window = data[start:start + 1024]
        # Each pixel bucket keeps both extrema rather than discarding transients.
        return [round(value - mean, 6) for i in range(0, len(window), 4)
                for value in (min(window[i:i + 4]), max(window[i:i + 4]))]
