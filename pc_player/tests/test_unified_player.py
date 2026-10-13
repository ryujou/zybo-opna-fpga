"""Focused desktop-core, timeline and HTTP/WebSocket lifecycle checks."""
from io import BytesIO
from pathlib import Path
import sys
import subprocess
import time
from types import ModuleType
import unittest

import mido
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from opl_visual import OplVisual
from playback import MidiState, devices
from server import create_app
from timeline import load_song
from vgm_loader import load_vgm_bytes, load_vgm_file
from song_builder import build_preloaded_song


def midi_file():
    midi = mido.MidiFile()
    track = mido.MidiTrack()
    midi.tracks.append(track)
    track.extend([
        mido.MetaMessage("track_name", name="Single note"),
        mido.Message("program_change", program=0),
        mido.Message("note_on", note=69, velocity=100),
        mido.Message("note_off", note=69, time=1920),
        mido.MetaMessage("end_of_track", time=480),
    ])
    output = BytesIO()
    midi.save(file=output)
    return output.getvalue()


def configure(core, channel=0, pan=0x30):
    slot = (0, 1, 2, 8, 9, 10, 16, 17, 18)[channel]
    for offset in (slot, slot + 3):
        for reg, value in ((0x20, 0x21), (0x40, 0), (0x60, 0xf0), (0x80, 0x04), (0xe0, 0)):
            core.opl(0, reg + offset, value)
    core.opl(0, 0xc0 + channel, pan)
    core.opl(0, 0xa0 + channel, 0x98)
    core.opl(0, 0xb0 + channel, 0x31)


class DesktopTests(unittest.TestCase):
    def test_raw_pan_and_release(self):
        core = OplVisual(False)
        try:
            configure(core, pan=0x10)
            core.advance_to(0.06)
            frame = core.snapshot([1, 2, 3, 4, 5, 6])
            self.assertGreater(max(map(abs, frame["total"][0])), 0.001)
            self.assertEqual(max(map(abs, frame["total"][1])), 0)
            self.assertGreater(max(map(abs, frame["waves"][0])), 0.001)
            self.assertEqual(max(map(abs, frame["waves"][1])), 0)
            core.opl(0, 0xb0, 0x11)
            core.advance_to(0.07)
            self.assertGreater(max(map(abs, core.snapshot([1] * 6)["waves"][0])), 0.001)
            core.advance_to(4.0)
            self.assertLess(max(map(abs, core.snapshot([1] * 6)["waves"][0])), 0.001)
        finally:
            core.close()

    def test_four_op_mapping(self):
        core = OplVisual(False)
        try:
            core.opl(1, 4, 1)
            configure(core, 3)
            configure(core, 0)
            core.advance_to(0.06)
            frame = core.snapshot([1, 4, 2, 3, 5, 6])
            self.assertEqual(frame["opl"][0]["pair"], 4)
            self.assertEqual(frame["opl"][0]["kind"], 4)
            self.assertEqual(frame["waves"][0], frame["waves"][1])
            self.assertGreater(max(map(abs, frame["waves"][0])), 0.001)
        finally:
            core.close()

    def test_rhythm_contribution(self):
        core = OplVisual(False)
        try:
            for channel in (6, 7, 8):
                configure(core, channel)
                core.opl(0, 0xb0 + channel, 0x11)
            core.opl(0, 0xbd, 0x3f)
            core.advance_to(0.08)
            frame = core.snapshot([7, 8, 9, 1, 2, 3])
            self.assertTrue(all(c["kind"] == 1 for c in frame["opl"][6:9]))
            self.assertTrue(all(max(map(abs, wave)) > 0.001 for wave in frame["waves"][:3]))
        finally:
            core.close()

    def test_midi_native_core(self):
        core = OplVisual(True)
        try:
            core.midi([0xc0, 0])
            core.midi([0x90, 69, 100])
            core.advance_to(0.1)
            core.dll.visual_snapshot(core.handle, core.samples, core.states)
            self.assertGreater(max(map(abs, core.samples)), 0.001)
            self.assertTrue(any(s.key_on for s in core.states))
        finally:
            core.close()

    def test_midi_sustain_restore(self):
        state = MidiState()
        for data in ([0xc0, 5], [0xb0, 64, 127], [0x90, 60, 90], [0x80, 60, 0], [0x90, 64, 100], [0xe0, 1, 70]):
            state.apply(data)
        messages = []
        state.restore(messages.append)
        self.assertIn([0xc0, 5], messages)
        self.assertIn([0xe0, 1, 70], messages)
        self.assertLess(messages.index([0xb0, 64, 127]), messages.index([0x90, 60, 90]))
        self.assertLess(messages.index([0x90, 60, 90]), messages.index([0x80, 60, 0]))
        state.apply([0xb0, 64, 0])
        self.assertEqual(list(state.notes[0]), [64])

    def test_midi_tempo_and_same_tick_order(self):
        midi = mido.MidiFile()
        midi.tracks.extend([
            mido.MidiTrack([mido.Message("program_change", program=3),
                            mido.MetaMessage("set_tempo", tempo=1000000, time=480),
                            mido.MetaMessage("end_of_track", time=480)]),
            mido.MidiTrack([mido.Message("note_on", note=60, velocity=80),
                            mido.Message("note_off", note=60, time=960)]),
        ])
        output = BytesIO()
        midi.save(file=output)
        song = load_song(output.getvalue(), "tempo.mid", "1")
        self.assertEqual([e.data[0] for e in song.events], [0xc0, 0x90, 0x80])
        self.assertAlmostEqual(song.events[-1].time, 1.5)
        self.assertAlmostEqual(song.rows[4]["time"], 0.5)
        self.assertAlmostEqual(song.rows[8]["time"], 1.5)

    def test_vgm_content_matches_path(self):
        import gzip, struct
        raw = bytearray(0x100)
        raw[:4] = b"Vgm "
        struct.pack_into("<I", raw, 8, 0x171)
        struct.pack_into("<I", raw, 0x34, 0xcc)
        struct.pack_into("<I", raw, 0x5c, 14318180)
        raw.extend(bytes.fromhex("5e20915e40ff6178565f201166"))
        plain = load_vgm_bytes(raw, "test.vgm")
        packed = load_vgm_bytes(gzip.compress(raw), "test.vgz")
        self.assertEqual(build_preloaded_song(plain).data, build_preloaded_song(packed).data)
        self.assertEqual(plain.total_us, round(0x5678 * 1000000 / 44100))

    def test_vgm_clock_uses_command_ack(self):
        from unittest.mock import patch
        from protocol import ZyboTransport
        transport = ZyboTransport("test")
        transport._request = lambda _type: b""
        transport._drain_async_frames = lambda: None
        with patch("protocol.time.monotonic", return_value=42.0):
            self.assertEqual(transport.play_buffered(), 42.0)
            self.assertEqual(transport.resume_buffered(), 42.0)

    def test_api_pause_stop_reload_and_websocket(self):
        with TestClient(create_app(visual_test=True)) as client:
            response = client.post("/api/files?name=test.mid", content=midi_file())
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json()["title"], "Single note")
            self.assertEqual(client.get("/api/song?id=1").json()["columns"], 16)
            client.post("/api/control", json={"action": "play"}).raise_for_status()
            time.sleep(0.1)
            paused = client.post("/api/control", json={"action": "pause"}).json()
            self.assertEqual(paused["status"], "paused")
            self.assertGreater(max(map(abs, paused["total"][0])), 0.001)
            with client.websocket_connect("/ws") as socket:
                first = socket.receive_json()
                time.sleep(0.05)
                second = socket.receive_json()
                self.assertEqual(first["position"], second["position"])
                self.assertEqual(first["waves"], second["waves"])
            client.post("/api/control", json={"action": "resume"}).raise_for_status()
            time.sleep(0.05)
            self.assertGreater(client.get("/api/state").json()["position"], paused["position"])
            stopped = client.post("/api/control", json={"action": "stop"}).json()
            self.assertEqual(stopped["position"], 0)
            self.assertEqual(max(map(abs, stopped["total"][0])), 0)
            client.post("/api/control", json={"action": "restart"}).raise_for_status()
            client.post("/api/files?name=second.mid", content=midi_file()).raise_for_status()
            selected = client.post("/api/control", json={"action": "select", "id": "2"}).json()
            self.assertEqual(selected["selected"], "2")
            self.assertEqual(selected["status"], "ready")
            self.assertEqual(selected["cursor"], 0)
            self.assertEqual(max(map(abs, selected["waves"][0])), 0)
            self.assertEqual(client.post("/api/files?name=bad.mid", content=b"bad").status_code, 400)


if __name__ == "__main__":
    unittest.main()
