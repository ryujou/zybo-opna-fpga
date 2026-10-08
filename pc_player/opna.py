"""PC98 native playback using the validated parser, mixer and USB 2.2 helpers."""
from pathlib import Path
import struct
import sys
import time
from types import SimpleNamespace

PC98 = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PC98 / "tools"))
from play_pc98 import parse_vgm, stop_device, usb, vgm_mix
from protocol import ZyboTransport, ProtocolError


class OpnaTransport(ZyboTransport):
    def __init__(self, device_key):
        super().__init__(device_key)
        self.incoming = bytearray()
        self.entered = False
        self.last_status = None

    def open(self):
        self.device = self._find_device()
        if self.device is None or not self.device.serial_number.startswith("ZOPNA"):
            raise ProtocolError("请选择 Zybo PC98 OPNA 原曲设备（SW0 = 1）")
        usb.usb.util.claim_interface(self.device, 0)
        hello = usb.request(self.device, self.incoming, 1)
        if len(hello) != 24 or hello[:2] != vgm_mix.PROTOCOL:
            raise ProtocolError("YM2608 播放需要匹配的 USB 2.2 固件与 FPGA")
        self.entered = True
        usb.request(self.device, self.incoming, 2)
        usb.request(self.device, self.incoming, 5)
        return SimpleNamespace(preload_capacity=struct.unpack_from("<I", hello, 12)[0])

    def upload_music(self, music, on_progress):
        events, samples, gains = music
        vgm_mix.set_mix(usb, self.device, self.incoming, gains)
        total = len(events) + len(samples)
        done = 0
        if samples:
            usb.request(self.device, self.incoming, 14, struct.pack("<IIB", 0, len(samples), 0))
            for offset in range(0, len(samples), 1024):
                part = samples[offset:offset + 1024]
                usb.request(self.device, self.incoming, 15, part)
                done += len(part)
                on_progress(done, total)
            usb.request(self.device, self.incoming, 16)
        usb.request(self.device, self.incoming, 8, struct.pack("<I", len(events)))
        for offset in range(0, len(events), 1024):
            part = events[offset:offset + 1024]
            usb.request(self.device, self.incoming, 9, part)
            done += len(part)
            on_progress(done, total)
        usb.request(self.device, self.incoming, 10)

    def play_buffered(self):
        usb.play_with_pending_in(self.device, self.incoming)
        return time.monotonic()

    def pause_buffered(self):
        usb.request(self.device, self.incoming, 12)

    def resume_buffered(self):
        usb.request(self.device, self.incoming, 13)
        return time.monotonic()

    def query_status(self):
        self.last_status = usb.status(self.device, self.incoming)
        return SimpleNamespace(playing=bool(self.last_status["flags"] & 1))

    def close(self):
        if self.device is not None:
            try:
                if self.entered:
                    stop_device(self.device, self.incoming)
            finally:
                usb.usb.util.dispose_resources(self.device)
                self.device = None
                self.entered = False
