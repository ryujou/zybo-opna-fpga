from pathlib import Path
import gzip
import struct
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from timeline import load_song
from opna import PC98, OpnaTransport, parse_vgm, vgm_mix
from playback import devices
from protocol import ProtocolError, UsbDeviceInfo


class OpnaTests(unittest.TestCase):
    def test_synthetic_ssg_file_and_waveform(self):
        from opna_visual import OpnaVisual
        raw = bytearray(0x100)
        raw[:4] = b"Vgm "
        struct.pack_into("<I", raw, 8, 0x171)
        struct.pack_into("<I", raw, 0x34, 0xcc)
        struct.pack_into("<I", raw, 0x48, 7987200)
        raw.extend(bytes.fromhex("56006456010056073e56080f613a1166"))
        song = load_song(raw, "ssg.vgm", "1")
        self.assertEqual(song.mode, "opna")
        self.assertEqual(song.opna_music[2], (131072, 21845, 8192))
        self.assertEqual(song.opna_music, load_song(gzip.compress(raw), "ssg.vgz", "2").opna_music)
        core = OpnaVisual(raw)
        try:
            core.advance_to(.05)
            frame = core.snapshot([7, 8, 9, 1, 10, 11])
            self.assertGreater(max(map(abs, frame["waves"][0])), .001)
            self.assertTrue(all(max(map(abs, wave)) == 0 for wave in frame["waves"][1:]))
        finally:
            core.close()

    def test_actual_files_preserve_events_samples_mix(self):
        import json
        if not (PC98 / "build/usb_dual/volume-fix/songs.json").exists():
            self.skipTest("Private music/reference fixtures are not distributed")
        paths = json.loads((PC98 / "build/usb_dual/volume-fix/songs.json").read_text(encoding="utf-8"))
        for entry in paths:
            path = Path(entry)
            with self.subTest(song=path.name):
                raw = path.read_bytes()
                song = load_song(raw, path.name, "1")
                events, samples, duration, counts, clock = parse_vgm(raw)
                self.assertEqual(song.mode, "opna")
                self.assertEqual(song.opna_music, (events, samples, vgm_mix.parse_mix(raw)))
                self.assertEqual(song.duration, duration)
                self.assertEqual(len(song.events), len(events) // 8)

    def test_vgz_and_pmd(self):
        if not (PC98 / "build/native_music/CT_maintheme.vgm").exists():
            self.skipTest("Private music/reference fixtures are not distributed")
        path = PC98 / "build/native_music/CT_maintheme.vgm"
        raw = path.read_bytes()
        self.assertEqual(load_song(gzip.compress(raw), "CT.vgz", "1").opna_music,
                         load_song(raw, "CT.vgm", "1").opna_music)
        pmd = PC98 / "build/native_music/touhou_original/th04/th04-10.m"
        song = load_song(pmd.read_bytes(), pmd.name, "2")
        self.assertEqual(song.mode, "opna")
        self.assertEqual(song.opna_music[2], (131072, 21845, 8192))

    def test_usb_identity(self):
        found = [UsbDeviceInfo(str(i), "", 0xcafe, 0x4012, "", "", serial)
                 for i, serial in enumerate(("ZOPL3USB0001", "ZOPNAUSB0001", ""))]
        with patch("playback.list_usb_devices", return_value=found), patch("playback.outputs", return_value=[]):
            self.assertEqual([d["mode"] for d in devices()["items"]], ["vgm", "opna"])
        active = {"id": "2", "name": "Zybo PC98 OPNA", "mode": "opna"}
        with patch("playback.list_usb_devices", return_value=found), patch("playback.outputs", return_value=[]):
            self.assertEqual(devices(active)["items"][-1], active)
        with patch("playback.list_usb_devices", return_value=[]), patch("playback.outputs", return_value=[]):
            self.assertEqual(devices(active)["items"], [])

    def test_old_protocol_rejected_before_enter(self):
        from types import SimpleNamespace
        output = OpnaTransport("test")
        board = SimpleNamespace(serial_number="ZOPNAUSB0001")
        with patch.object(output, "_find_device", return_value=board), \
             patch("opna.usb.usb.util.claim_interface"), \
             patch("opna.usb.request", return_value=b"\x02\x01" + bytes(22)) as request:
            with self.assertRaises(ProtocolError):
                output.open()
            self.assertEqual(request.call_count, 1)
            self.assertFalse(output.entered)


if __name__ == "__main__":
    unittest.main()
