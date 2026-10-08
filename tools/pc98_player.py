#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Python desktop player for the Zybo PC98 OPNA USB mode."""
import argparse
import json
from pathlib import Path
import queue
import struct
import sys
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

import play_pc98

usb = play_pc98.usb


def timestamp(seconds):
    seconds = int(seconds)
    return f"{seconds // 60:02d}:{seconds % 60:02d}"


class Player:
    def __init__(self, root, library=None):
        self.root, self.library = root, library
        self.paths = []
        self.selected_data = None
        self.worker = None
        self.stop_requested = threading.Event()
        self.messages = queue.Queue()
        self.closing = False
        self.probing = False
        self.connected = False
        self.active_track = None
        self.next_probe = 0
        root.title("PC-98 原声播放器")
        root.geometry("880x590")
        root.minsize(780, 530)
        root.configure(bg="#f3f5f8")
        root.protocol("WM_DELETE_WINDOW", self.close)
        style = ttk.Style(root)
        style.theme_use("clam")
        style.configure("TFrame", background="#f3f5f8")
        style.configure("TLabel", background="#f3f5f8", foreground="#253247", font=("Microsoft YaHei UI", 10))
        style.configure("TButton", font=("Microsoft YaHei UI", 10), padding=(16, 9))
        style.configure("Play.TButton", background="#087f8c", foreground="white")
        style.map("Play.TButton", background=[("active", "#096873"), ("disabled", "#ccd4df")])
        style.configure("Treeview", rowheight=36, font=("Microsoft YaHei UI", 10), borderwidth=0)
        style.configure("Treeview.Heading", font=("Microsoft YaHei UI", 10, "bold"), padding=8)
        style.map("Treeview", background=[("selected", "#dbeef0")], foreground=[("selected", "#123c43")])
        style.configure("Music.Horizontal.TProgressbar", background="#087f8c", troughcolor="#dfe6ef", borderwidth=0, thickness=7)

        header = tk.Frame(root, bg="#18273c", padx=26, pady=20)
        header.pack(fill="x")
        tk.Label(header, text="PC-98 原声播放器", bg="#18273c", fg="white", font=("Microsoft YaHei UI", 21, "bold")).pack(anchor="w")
        tk.Label(header, text="东方 PC-98   /   PMD · VGM · VGZ", bg="#18273c", fg="#aabccd", font=("Segoe UI", 10)).pack(anchor="w", pady=(5, 0))

        toolbar = ttk.Frame(root, padding=(24, 18, 24, 12))
        toolbar.pack(fill="x")
        self.open_button = ttk.Button(toolbar, text="打开曲目…", command=self.open_files)
        self.open_button.pack(side="left")
        self.count_label = ttk.Label(toolbar, text="选择 PC-98 原曲文件")
        self.count_label.pack(side="left", padx=15)
        self.connection = tk.Label(toolbar, text="检查设备…", bg="#e7ecf2", fg="#526275", padx=12, pady=8, font=("Microsoft YaHei UI", 9))
        self.connection.pack(side="right")

        self.status = ttk.Label(root, text="SW0 关闭（0）：MIDI；开启（1）：原曲模式。", padding=(24, 13), foreground="#637286", wraplength=800)
        self.status.pack(side="bottom", fill="x")
        body = ttk.Frame(root, padding=(24, 0, 24, 12))
        body.pack(fill="both", expand=True)
        body.columnconfigure(0, weight=4)
        body.columnconfigure(1, weight=5)
        body.rowconfigure(0, weight=1)
        left = ttk.Frame(body)
        left.grid(row=0, column=0, sticky="nsew", padx=(0, 24))
        self.tracks = ttk.Treeview(left, columns=("song",), show="headings", selectmode="browse")
        self.tracks.heading("song", text="曲目列表", anchor="w")
        self.tracks.column("song", width=300, minwidth=210)
        scroll = ttk.Scrollbar(left, orient="vertical", command=self.tracks.yview)
        self.tracks.configure(yscrollcommand=scroll.set)
        scroll.pack(side="right", fill="y")
        self.tracks.pack(fill="both", expand=True)
        self.tracks.bind("<<TreeviewSelect>>", self.select)
        self.tracks.bind("<Double-1>", lambda _: self.play())

        right = ttk.Frame(body, padding=(0, 18, 0, 0))
        right.grid(row=0, column=1, sticky="nsew")
        ttk.Label(right, text="当前曲目", foreground="#7b8798").pack(anchor="w")
        self.title = ttk.Label(right, text="等待选择音乐", font=("Microsoft YaHei UI", 20, "bold"), wraplength=350)
        self.title.pack(anchor="w", pady=(15, 10))
        self.details = ttk.Label(right, text="选择东方 PC-98 原曲，点击播放", wraplength=350, foreground="#637286")
        self.details.pack(anchor="w")
        self.voices = ttk.Label(right, text="", foreground="#087f8c")
        self.voices.pack(anchor="w", pady=(12, 0))
        self.progress = ttk.Progressbar(right, style="Music.Horizontal.TProgressbar", maximum=100)
        self.progress.pack(fill="x", pady=(35, 10))
        times = ttk.Frame(right)
        times.pack(fill="x")
        self.elapsed = ttk.Label(times, text="00:00", font=("Segoe UI", 12))
        self.elapsed.pack(side="left")
        self.total = ttk.Label(times, text="--:--", foreground="#7b8798", font=("Segoe UI", 12))
        self.total.pack(side="right")
        controls = ttk.Frame(right)
        controls.pack(fill="x", pady=(25, 0))
        self.play_button = ttk.Button(controls, text="▶  播放", style="Play.TButton", command=self.play, state="disabled")
        self.play_button.pack(side="left")
        self.stop_button = ttk.Button(controls, text="■  停止", command=self.stop, state="disabled")
        self.stop_button.pack(side="left", padx=10)
        music_root = (Path(sys.executable).parent / "music" if getattr(sys, "frozen", False)
                      else Path(__file__).resolve().parents[1] / "build/native_music/touhou_original")
        self.song_titles = {}
        index = music_root / "pmd_index.json"
        if index.exists():
            for entry in json.loads(index.read_text(encoding="utf-8")):
                path = music_root / Path(entry["file"]).parent.name / Path(entry["file"]).name
                if path.exists():
                    self.song_titles[path] = entry["title"]
                    self.add_track(path)
        self.count_label.configure(text=f"{len(self.paths)} 首曲目")
        if self.paths:
            self.tracks.selection_set("0")
        root.after(100, self.poll)

    def backend(self):
        library = self.library
        if library is None and getattr(sys, "frozen", False):
            library = Path(sys._MEIPASS) / "libusb-1.0.dll"
        backend = usb.usb.backend.libusb1.get_backend(
            **({"find_library": lambda _: str(library.resolve())} if library else {}))
        if backend is None:
            raise RuntimeError("找不到 libusb，请使用打包的播放器，或通过 --libusb 指定 USB 库。")
        return backend

    def add_track(self, path):
        if path not in self.paths:
            index = len(self.paths)
            self.paths.append(path)
            title = self.song_titles.get(path, path.stem)
            self.tracks.insert("", "end", iid=str(index), values=(title,))

    def open_files(self):
        chosen = filedialog.askopenfilenames(title="选择 PC-98 原曲", filetypes=[("PC-98 原曲", "*.m *.m2 *.m26 *.m86 *.vgm *.vgz")])
        for name in chosen:
            self.add_track(Path(name))
        self.count_label.configure(text=f"{len(self.paths)} 首曲目" if self.paths else "选择 PC-98 原曲文件")
        if chosen:
            self.tracks.selection_set(str(self.paths.index(Path(chosen[0]))))

    def select(self, _=None):
        if self.worker and self.worker.is_alive():
            if self.tracks.selection() != (self.active_track,):
                self.tracks.selection_set(self.active_track)
            return
        selection = self.tracks.selection()
        if not selection:
            return
        path = self.paths[int(selection[0])]
        self.selected_data = path
        self.title.configure(text=self.song_titles.get(path, path.stem))
        self.details.configure(text=f"{path.suffix.upper().lstrip('.')}  ·  YM2608")
        self.voices.configure(text="")
        self.progress["value"] = 0
        self.elapsed.configure(text="00:00")
        self.total.configure(text="--:--")
        self.play_button.configure(state="normal" if self.connected else "disabled")

    def play(self):
        if not self.selected_data or (self.worker and self.worker.is_alive()):
            return
        if self.probing:
            self.root.after(100, self.play)
            return
        self.active_track = self.tracks.selection()[0]
        self.stop_requested.clear()
        self.play_button.configure(state="disabled")
        self.open_button.configure(state="disabled")
        self.stop_button.configure(state="normal")
        self.status.configure(text="正在准备曲目…")
        self.worker = threading.Thread(target=self.play_worker, args=(self.selected_data,), daemon=True)
        self.worker.start()

    def play_worker(self, song):
        device, incoming, failed, entered = None, bytearray(), False, False
        try:
            song, gains = play_pc98.load_music_with_mix(song)
            if self.stop_requested.is_set():
                return
            self.messages.put(("metadata", song[2], song[3], bool(song[1])))
            backend = self.backend()
            device = usb.usb.core.find(idVendor=0xcafe, idProduct=0x4012, backend=backend)
            if device is None:
                raise RuntimeError("原声设备未连接。请将 SW0 开启（上拨），等待设备重新枚举。")
            if not device.serial_number.startswith("ZOPNA"):
                raise RuntimeError("当前设备是 OPL3，请先加载 OPNA 双模式固件。")
            usb.usb.util.claim_interface(device, 0)
            hello = usb.request(device, incoming, 1)
            if len(hello) != 24 or hello[:2] != play_pc98.vgm_mix.PROTOCOL:
                raise RuntimeError("音量播放需要 OPNA USB 2.2 固件及匹配的 FPGA，请加载配套镜像。")
            events, memory, duration, counts, clock = song
            if len(events) > struct.unpack_from("<I", hello, 12)[0]:
                raise ValueError("曲目寄存器数据超过板卡的 8 MiB 容量。")
            entered = True
            usb.request(device, incoming, 2)
            usb.request(device, incoming, 5)
            play_pc98.vgm_mix.set_mix(usb, device, incoming, gains)
            if memory:
                self.messages.put(("status", "正在装载 ADPCM 样本…"))
                usb.request(device, incoming, 14, struct.pack("<IIB", 0, len(memory), 0))
                for offset in range(0, len(memory), 1024):
                    if self.stop_requested.is_set():
                        return
                    usb.request(device, incoming, 15, memory[offset:offset + 1024])
                usb.request(device, incoming, 16)
            usb.request(device, incoming, 8, struct.pack("<I", len(events)))
            for offset in range(0, len(events), 1024):
                if self.stop_requested.is_set():
                    return
                usb.request(device, incoming, 9, events[offset:offset + 1024])
                if offset % 16384 == 0:
                    self.messages.put(("status", f"正在装载曲目… {min(100, (offset + 1024) * 100 // len(events))}%"))
            usb.request(device, incoming, 10)
            usb.play_with_pending_in(device, incoming)
            self.messages.put(("status", "正在播放 · 声音从板卡耳机口输出"))
            started, next_probe = time.monotonic(), 0
            while not self.stop_requested.wait(0.1):
                elapsed = time.monotonic() - started
                self.messages.put(("progress", min(elapsed, duration), duration))
                if elapsed >= duration + 0.1:
                    state = usb.status(device, incoming)
                    if state["flags"] or state["queued_writes"]:
                        raise RuntimeError("设备报告播放未完成。")
                    self.messages.put(("status", "播放完成"))
                    break
                if elapsed >= next_probe:
                    if usb.usb.core.find(idVendor=0xcafe, idProduct=0x4012, backend=backend) is None:
                        entered = False
                        self.messages.put(("status", "原声设备已断开或切换模式，播放已停止。"))
                        break
                    next_probe = elapsed + 1
            if self.stop_requested.is_set():
                self.messages.put(("status", "已停止"))
        except (usb.usb.core.USBError, OSError, RuntimeError, ValueError) as error:
            failed = True
            self.messages.put(("error", str(error)))
        finally:
            if device is not None:
                if entered:
                    try:
                        play_pc98.stop_device(device, incoming)
                    except (usb.usb.core.USBError, RuntimeError) as error:
                        if not failed:
                            self.messages.put(("error", f"设备已断开，停止指令未送达：{error}"))
                usb.usb.util.dispose_resources(device)
            if self.stop_requested.is_set():
                self.messages.put(("status", "已停止"))
            self.messages.put(("done",))

    def probe_worker(self):
        try:
            backend = self.backend()
            native = usb.usb.core.find(idVendor=0xcafe, idProduct=0x4012, backend=backend)
            if native is not None:
                try:
                    text, color = ("原声模式已连接", "#d9eee8") if native.serial_number.startswith("ZOPNA") else ("当前为 OPL3 设备", "#fff0d9")
                finally:
                    usb.usb.util.dispose_resources(native)
            elif usb.usb.core.find(idVendor=0xcafe, idProduct=0x4014, backend=backend) is not None:
                text, color = "MIDI 模式 · 请开启 SW0", "#fff0d9"
            else:
                text, color = "原声设备未连接", "#e7ecf2"
        except (usb.usb.core.USBError, OSError, RuntimeError) as error:
            text, color = "USB 不可用", "#fff0d9"
            self.messages.put(("status", str(error)))
        self.messages.put(("connection", text, color))

    def stop(self):
        self.stop_requested.set()
        self.stop_button.configure(state="disabled")
        self.status.configure(text="正在停止…")

    def poll(self):
        while not self.messages.empty():
            item = self.messages.get_nowait()
            if item[0] == "progress":
                self.progress["value"] = item[1] / item[2] * 100 if item[2] else 0
                self.elapsed.configure(text=timestamp(item[1]))
            elif item[0] == "metadata":
                self.total.configure(text=timestamp(item[1]))
                self.voices.configure(text="  /  ".join(name for key, name in [("FM/control", "FM"), ("SSG", "SSG"), ("rhythm", "节奏")] if item[2].get(key)) + ("  /  ADPCM" if item[3] else ""))
            elif item[0] == "status":
                self.status.configure(text=item[1])
            elif item[0] == "error":
                self.status.configure(text=item[1])
                if not self.closing:
                    messagebox.showerror("播放停止", item[1])
            elif item[0] == "done":
                self.open_button.configure(state="normal")
                self.play_button.configure(state="normal" if self.selected_data and self.connected else "disabled")
                self.stop_button.configure(state="disabled")
                self.next_probe = 0
            elif item[0] == "connection":
                self.connection.configure(text=item[1], bg=item[2])
                self.connected = item[1] == "原声模式已连接"
                if not (self.worker and self.worker.is_alive()):
                    self.play_button.configure(state="normal" if self.selected_data and self.connected else "disabled")
                self.probing = False
        active = self.worker and self.worker.is_alive()
        if self.closing and not active:
            self.root.destroy()
            return
        if not active and not self.probing and time.monotonic() >= self.next_probe and not self.closing:
            self.probing = True
            self.next_probe = time.monotonic() + 2
            threading.Thread(target=self.probe_worker, daemon=True).start()
        self.root.after(80, self.poll)

    def close(self):
        self.closing = True
        self.stop()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--libusb", type=Path)
    args = parser.parse_args()
    root = tk.Tk()
    Player(root, args.libusb)
    root.mainloop()
