"""Software OPNA display samples; independent of the board's audio output."""
import ctypes as C
from pathlib import Path

CAPACITY = 4096


class OpnaVisual:
    def __init__(self, data):
        self.dll = C.CDLL(str(Path(__file__).resolve().parents[1] / "pc_player/native/bin/opna_visual.dll"))
        for name, args, result in (
            ("opna_visual_create", [C.POINTER(C.c_ubyte), C.c_uint], C.c_void_p),
            ("opna_visual_destroy", [C.c_void_p], None),
            ("opna_visual_advance", [C.c_void_p, C.c_uint64], C.c_int),
            ("opna_visual_snapshot", [C.c_void_p, C.POINTER(C.c_float)], None),
        ):
            function = getattr(self.dll, name)
            function.argtypes, function.restype = args, result
        raw = (C.c_ubyte * len(data)).from_buffer_copy(data)
        self.handle = self.dll.opna_visual_create(raw, len(data))
        if not self.handle:
            raise RuntimeError("YM2608 波形核心初始化失败")
        self.samples = (C.c_float * (13 * CAPACITY))()

    def advance_to(self, target):
        if not self.dll.opna_visual_advance(self.handle, round(target * 48000)):
            raise RuntimeError("YM2608 波形渲染失败")

    def snapshot(self, voices):
        self.dll.opna_visual_snapshot(self.handle, self.samples)
        windows = [self._window(lane) for lane in range(13)]
        channels = [{"id": i + 1, "pair": 0, "kind": 0,
                     "active": max(map(abs, windows[i + 2])) > .0001,
                     "note": None, "frequency": 0} for i in range(11)]
        return {"total": windows[:2], "waves": [windows[v + 1] for v in voices], "opl": channels}

    def _window(self, lane):
        data = self.samples[lane * CAPACITY:(lane + 1) * CAPACITY]
        start = CAPACITY - 1024
        mean = sum(data[start:]) / 1024
        for i in range(start - 512, start):
            if data[i] <= mean < data[i + 1]:
                start = i
        window = data[start:start + 1024]
        return [round(value - mean, 6) for i in range(0, len(window), 4)
                for value in (min(window[i:i + 4]), max(window[i:i + 4]))]

    def close(self):
        if self.handle:
            self.dll.opna_visual_destroy(self.handle)
            self.handle = None
