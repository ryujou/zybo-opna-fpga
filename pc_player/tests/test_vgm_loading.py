from __future__ import annotations

import gzip
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from vgm_loader import load_vgm_file as load_song
from song_builder import build_preloaded_song
from vgm_loader import LoadedVgm
def _make_minimal_vgm(path: Path) -> bytes:
    commands = bytes([
        0x5E, 0x20, 0x01,
        0x61, 0x10, 0x00,
        0x5F, 0x40, 0x3F,
        0x62,
        0x66,
    ])
    total_samples = 16 + 735
    eof_offset = 0x80 + len(commands) - 4
    header = bytearray(0x80)
    header[0:4] = b'Vgm '
    header[4:8] = struct.pack('<I', eof_offset)
    header[8:12] = struct.pack('<I', 0x00000150)
    header[0x18:0x1C] = struct.pack('<I', total_samples)
    header[0x34:0x38] = struct.pack('<I', 0x4C)
    header[0x5C:0x60] = struct.pack('<I', 14318180)
    blob = bytes(header) + commands
    path.write_bytes(blob)
    return blob


def run() -> None:
    temp_vgm = ROOT / '_tmp_direct_path.vgm'
    temp_vgz = ROOT / '_tmp_direct_path.vgz'
    try:
        raw = _make_minimal_vgm(temp_vgm)
        temp_vgz.write_bytes(gzip.compress(raw))

        song_vgm = load_song(str(temp_vgm))
        assert isinstance(song_vgm, LoadedVgm)
        built_vgm = build_preloaded_song(song_vgm)
        assert built_vgm.backend_name == 'vgm loader'
        assert built_vgm.data

        song_vgz = load_song(str(temp_vgz))
        assert isinstance(song_vgz, LoadedVgm)
        built_vgz = build_preloaded_song(song_vgz)
        assert built_vgz.backend_name == 'vgm loader'
        assert built_vgz.data == built_vgm.data
        assert song_vgm.total_us == round(751 * 1_000_000 / 44100)
        assert sum(event.delta_us for event in song_vgm.events) == song_vgm.total_us
        assert song_vgm.events[0].writes[0].reg == 0x20
        assert song_vgm.events[1].writes[0].bank == 1
        assert song_vgm.events[1].writes[0].value == 0x3F
    finally:
        for path in (temp_vgm, temp_vgz):
            if path.exists():
                path.unlink()


if __name__ == '__main__':
    run()
    print('test_vgm_loading: ok')
