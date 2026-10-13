"""One worker owns the song clock, output device and visualization core."""
from concurrent.futures import Future
from queue import Empty, Queue
from threading import Thread
import time

from midi_output import GM_NAMES, MidiOutput, outputs
from opl_visual import OplVisual
from protocol import ProtocolError, ZyboTransport, list_usb_devices
from song_builder import build_preloaded_song
from timeline import load_song


def devices(active=None):
    midi = outputs()
    error = ""
    try:
        usb = []
        for d in list_usb_devices(active["id"] if active else None):
            # WinUSB may deny a second descriptor handle while playback owns it.
            if active and d.key == active["id"]:
                usb.append(active)
            elif d.serial_number.startswith(("ZOPNA", "ZOPL3")):
                opna = d.serial_number.startswith("ZOPNA")
                usb.append({"id": d.key, "name": d.product or ("Zybo PC98 OPNA" if opna else "Zybo OPL3 USB Interface"),
                            "mode": "opna" if opna else "vgm"})
    except (ProtocolError, OSError) as exc:
        usb, error = [], str(exc)
    return {"items": midi + usb, "error": error}


class MidiState:
    def __init__(self):
        self.program = [0] * 16
        self.controls = [{} for _ in range(16)]
        self.pitch = [[0, 64] for _ in range(16)]
        self.pressure = [0] * 16
        self.notes = [{} for _ in range(16)]

    def apply(self, data):
        if data[0] == 0xf0:
            # Universal GM/GS/XG reset messages clear the displayed MIDI state.
            if (len(data) >= 6 and data[1] == 0x7e and data[3:5] == [9, 1]) or (
                len(data) >= 9 and data[1] == 0x41 and data[4:8] == [0x12, 0x40, 0, 0x7f]) or (
                len(data) >= 8 and data[1] == 0x43 and data[3:7] == [0x4c, 0, 0, 0x7e]):
                self.__init__()
            return
        if data[0] >= 0xf0:
            return
        kind, ch = data[0] & 0xf0, data[0] & 15
        a, b = data[1], data[2] if len(data) > 2 else 0
        if kind == 0x90 and b:
            self.notes[ch][a] = {"velocity": b, "pressed": True, "aftertouch": 0}
        elif kind == 0x80 or kind == 0x90:
            if a in self.notes[ch]:
                if self.controls[ch].get(64, 0) >= 64:
                    self.notes[ch][a]["pressed"] = False
                else:
                    del self.notes[ch][a]
        elif kind == 0xb0:
            self.controls[ch][a] = b
            if a == 64 and b < 64:
                self.notes[ch] = {n: v for n, v in self.notes[ch].items() if v["pressed"]}
            elif a == 120:
                self.notes[ch].clear()
            elif a == 123:
                if self.controls[ch].get(64, 0) >= 64:
                    for note in self.notes[ch].values():
                        note["pressed"] = False
                else:
                    self.notes[ch].clear()
            elif a == 121:
                self.controls[ch].clear()
                self.pitch[ch], self.pressure[ch] = [0, 64], 0
                self.notes[ch] = {n: v for n, v in self.notes[ch].items() if v["pressed"]}
        elif kind == 0xc0:
            self.program[ch] = a
        elif kind == 0xe0:
            self.pitch[ch] = [a, b]
        elif kind == 0xd0:
            self.pressure[ch] = a
        elif kind == 0xa0 and a in self.notes[ch]:
            self.notes[ch][a]["aftertouch"] = b

    def restore(self, send):
        for ch in range(16):
            controls = self.controls[ch]
            for cc in (0, 32):
                if cc in controls:
                    send([0xb0 | ch, cc, controls[cc]])
            send([0xc0 | ch, self.program[ch]])
            for cc, value in controls.items():
                if cc not in (0, 32, 120, 121, 123):
                    send([0xb0 | ch, cc, value])
            send([0xe0 | ch, *self.pitch[ch]])
            send([0xd0 | ch, self.pressure[ch]])
            for note, state in self.notes[ch].items():
                send([0x90 | ch, note, state["velocity"]])
                if state["aftertouch"]:
                    send([0xa0 | ch, note, state["aftertouch"]])
                if not state["pressed"]:
                    send([0x80 | ch, note, 0])

    def channels(self):
        return [{"id": i + 1, "program": self.program[i],
                 "name": "Drums" if i == 9 else GM_NAMES[self.program[i]],
                 "active": bool(self.notes[i]), "note": next(reversed(self.notes[i]), None)}
                for i in range(16)]


class Player:
    def __init__(self, visual_test=False):
        self.visual_test = visual_test
        self.commands = Queue()
        self.songs = {}
        self.selected = None
        self.status = "empty"
        self.error = ""
        self.position = 0.0
        self.cursor = 0
        self.voices = [1, 2, 3, 4, 5, 6]
        self.visual = None
        self.output = None
        self.midi = MidiState()
        self.device_info = {"items": [], "error": ""}
        self.device = None
        self.upload = 0
        self.hardware = None
        self.running = True
        self.frame = {"total": [[0] * 512 for _ in range(2)],
                      "waves": [[0] * 512 for _ in range(6)], "opl": []}
        self._publish()
        self.thread = Thread(target=self._run, name="opl3-playback")
        self.thread.start()

    def submit(self, action, **args):
        future = Future()
        self.commands.put((action, args, future))
        return future

    def close(self):
        future = self.submit("close")
        try:
            future.result(timeout=15)
        finally:
            self.thread.join(timeout=15)

    def _publish(self):
        self.state = {"status": self.status, "error": self.error, "test_mode": self.visual_test,
                      "position": self.position, "cursor": self.cursor, "voices": self.voices[:],
                      "selected": self.selected, "playlist": [s.info() for s in self.songs.values()],
                      "devices": self.device_info, "device": self.device, "upload": self.upload,
                      "channels": self.midi.channels(), "hardware": self.hardware, **self.frame}

    def _run(self):
        next_frame, next_devices, next_status = 0.0, 0.0, 0.0
        while self.running:
            try:
                command = self.commands.get(timeout=0.001 if self.status == "playing" else 0.03)
            except Empty:
                command = None
            if command:
                action, args, future = command
                try:
                    result = self._command(action, args)
                    self._publish()
                    future.set_result(result if result is not None else self.state)
                except Exception as exc:
                    # Return a worker failure to its caller and preserve the song.
                    self.error = str(exc)
                    if action not in ("load", "song", "voices"):
                        try:
                            self._stop()
                        except (OSError, ProtocolError) as cleanup_error:
                            self.error += f"；{cleanup_error}"
                    self._publish()
                    future.set_exception(exc)
            now = time.monotonic()
            try:
                if self.status == "playing":
                    self._advance(min(self.songs[self.selected].duration, now - self.origin))
                    if self.position >= self.songs[self.selected].duration and (
                            self.songs[self.selected].mode != "opna" or now - self.origin >= self.position + .1):
                        self._finish()
                    elif self.output and self.songs[self.selected].mode == "vgm" and now >= next_status:
                        if not self.output.query_status().playing:
                            self._finish()
                        next_status = now + 0.5
                if now >= next_devices:
                    self.device_info = devices(self.device)
                    if self.output and not any(
                        d["id"] == self.device["id"] and d["mode"] == self.device["mode"] for d in self.device_info["items"]
                    ):
                        raise OSError("播放设备已断开")
                    next_devices = now + 1
                if now >= next_frame:
                    if self.status == "playing" and self.visual:
                        self.frame = self.visual.snapshot(self.voices)
                    self._publish()
                    next_frame = now + 1 / 30
            except Exception as exc:
                self.error = str(exc)
                try:
                    self._stop()
                except (OSError, ProtocolError) as cleanup_error:
                    self.error += f"；{cleanup_error}"
                self._publish()

    def _command(self, action, args):
        if action == "load":
            song = load_song(args["data"], args["name"], str(len(self.songs) + 1))
            self.songs[song.id] = song
            if self.selected is None:
                self.selected = song.id
                self.status = "ready"
            self.error = ""
            return song.info()
        if action == "song":
            if args["id"] not in self.songs:
                raise ValueError("曲目不存在")
            return self.songs[args["id"]].index()
        if action == "select":
            if args.get("id") not in self.songs:
                raise ValueError("曲目不存在")
            self._stop()
            self.selected = args["id"]
            if self.songs[self.selected].mode == "opna":
                self.voices = [v if v <= 11 else 1 for v in self.voices]
            self.status = "ready"
            self.error = ""
        elif action == "voices":
            voices = args["voices"]
            limit = 11 if self.selected and self.songs[self.selected].mode == "opna" else 18
            if len(voices) != 6 or any(type(v) is not int or not 1 <= v <= limit for v in voices):
                raise ValueError(f"请选择六个 01–{limit} 声部")
            self.voices = voices[:]
            if self.visual:
                self.frame = self.visual.snapshot(self.voices)
        elif action == "play":
            if self.status == "paused":
                return self._command("resume", args)
            if self.status != "playing":
                self._start(args.get("device_id"))
        elif action == "pause":
            if self.status == "playing":
                self._advance(min(self.songs[self.selected].duration, time.monotonic() - self.origin))
                if self.visual:
                    self.frame = self.visual.snapshot(self.voices)
                if self.output:
                    if self.songs[self.selected].mode == "midi":
                        self.output.silence()
                    else:
                        self.output.pause_buffered()
                self.status = "paused"
        elif action == "resume":
            if self.status == "paused":
                resumed_at = time.monotonic()
                if self.songs[self.selected].mode == "midi":
                    self.visual.close()
                    self.visual = OplVisual(True)
                    # Resume retriggers the same held notes on board and PC core.
                    def send(data):
                        if self.output:
                            self.output.send(data)
                        self.visual.midi(data)
                    self.midi.restore(send)
                    self.visual.position = self.position
                    self.visual.frame_count = round(self.position * 49716)
                elif self.output:
                    resumed_at = self.output.resume_buffered()
                if self.songs[self.selected].mode == "midi":
                    resumed_at = time.monotonic()
                self.origin = resumed_at - self.position
                self.status = "playing"
        elif action == "stop":
            self._stop()
            self.error = ""
        elif action == "restart":
            self._stop()
            self._start(args.get("device_id"))
        elif action == "close":
            try:
                self._stop()
            finally:
                self.running = False
        else:
            raise ValueError("未知播放动作")

    def _start(self, device_id=None):
        if not self.selected:
            raise ValueError("请先打开文件")
        self._stop()
        song = self.songs[self.selected]
        self.hardware = None
        self.device_info = devices(self.device)
        available = [d for d in self.device_info["items"] if d["mode"] == song.mode]
        if not self.visual_test:
            self.device = next((d for d in available if d["id"] == device_id), None) if device_id else next(iter(available), None)
            if self.device is None:
                raise ValueError("SW0 → " + ("MIDI" if song.mode == "midi" else "OPNA 原曲（需要 PC98 固件）" if song.mode == "opna" else "OPL3 VGM"))
        if song.mode == "opna" and self.visual_test:
            raise ValueError("YM2608 原曲需要连接 OPNA 板端，电脑 OPL3 核心不能预览")
        if song.mode == "opna":
            from opna_visual import OpnaVisual
            self.voices = [v if v <= 11 else 1 for v in self.voices]
            self.visual = OpnaVisual(song.opna_data)
        else:
            self.visual = OplVisual(song.mode == "midi")
        started_at = None
        if not self.visual_test:
            if song.mode == "midi":
                self.output = MidiOutput(self.device["id"])
                reset = [0xf0, 0x7e, 0x7f, 9, 1, 0xf7]
                self.output.send(reset)
                self.visual.midi(reset)
            elif song.mode == "opna":
                from opna import OpnaTransport
                self.output = OpnaTransport(self.device["id"])
                hello = self.output.open()
                if len(song.opna_music[0]) > hello.preload_capacity:
                    raise ValueError("曲目超过板端缓冲容量")
                self.status = "uploading"
                self._publish()
                self.output.upload_music(song.opna_music, self._upload_progress)
                started_at = self.output.play_buffered()
            else:
                built = build_preloaded_song(song.opl_song)
                self.output = ZyboTransport(self.device["id"])
                hello = self.output.open()
                if len(built.data) > hello.preload_capacity:
                    raise ValueError("曲目超过板端缓冲容量")
                self.status = "uploading"
                self._publish()
                self.output.upload_song(built.data, self._upload_progress)
                started_at = self.output.play_buffered()
        self.origin = started_at if started_at is not None else time.monotonic()
        self.status, self.error, self.upload = "playing", "", 100
        self._advance(0)

    def _upload_progress(self, done, total):
        self.upload = int(done * 100 / total)
        self._publish()

    def _advance(self, target):
        song = self.songs[self.selected]
        if song.mode == "opna":
            self.visual.advance_to(target)
            while self.cursor < len(song.events) and song.events[self.cursor].time <= target:
                self.cursor += 1
            self.position = target
            return
        while self.cursor < len(song.events) and song.events[self.cursor].time <= target:
            event = song.events[self.cursor]
            self.visual.advance_to(event.time)
            if song.mode == "midi":
                if self.output:
                    self.output.send(event.data)
                self.visual.midi(event.data)
                self.midi.apply(event.data)
            else:
                self.visual.opl(*event.data)
            self.cursor += 1
        self.visual.advance_to(target)
        self.position = target

    def _finish(self):
        if self.visual:
            self.frame = self.visual.snapshot(self.voices)
        self._release()
        self.status = "ended"
        self.midi = MidiState()
        ids = list(self.songs)
        next_index = ids.index(self.selected) + 1
        if next_index < len(ids):
            old_mode = self.songs[self.selected].mode
            self.selected = ids[next_index]
            self._stop()
            if self.songs[self.selected].mode == old_mode:
                self._start()

    def _release(self):
        try:
            if self.output:
                output, self.output = self.output, None
                try:
                    if self.songs[self.selected].mode == "opna":
                        output.query_status()
                        self.hardware = output.last_status
                finally:
                    output.close()
        finally:
            if self.visual:
                self.visual.close()
                self.visual = None
            self.device = None

    def _stop(self):
        try:
            self._release()
        finally:
            self.position, self.cursor, self.upload = 0.0, 0, 0
            self.midi = MidiState()
            self.frame = {"total": [[0] * 512 for _ in range(2)],
                          "waves": [[0] * 512 for _ in range(6)], "opl": []}
            self.status = "ready" if self.selected else "empty"
