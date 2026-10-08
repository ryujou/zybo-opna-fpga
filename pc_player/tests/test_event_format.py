from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from protocol import OplWrite
from song_builder import MAX_WRITES_PER_EVENT, build_preloaded_song
from vgm_loader import LoadedVgm, OplStreamEvent


def _iter_events(data: bytes):
    offset = 0
    while offset < len(data):
        assert offset + 5 <= len(data), 'truncated event header'
        delay_us = int.from_bytes(data[offset:offset + 4], 'little', signed=False)
        write_count = data[offset + 4]
        offset += 5
        assert write_count <= 255
        assert write_count <= MAX_WRITES_PER_EVENT
        writes = []
        for _ in range(write_count):
            assert offset + 3 <= len(data), 'truncated write payload'
            bank = data[offset]
            reg = data[offset + 1]
            value = data[offset + 2]
            offset += 3
            assert bank in (0, 1)
            assert 0 <= reg <= 255
            assert 0 <= value <= 255
            writes.append((bank, reg, value))
        assert 0 <= delay_us <= 0xFFFFFFFF
        yield delay_us, writes
    assert offset == len(data)


def run() -> None:
    writes = [OplWrite(i % 2, i % 256, (i * 7) % 256) for i in range(465)]
    tail = OplWrite(0, 0xB0, 0)
    song = LoadedVgm([
        OplStreamEvent(42000, writes),
        OplStreamEvent(123, [tail]),
    ], total_us=42123, title='burst.vgm')
    built = build_preloaded_song(song)
    events = list(_iter_events(built.data))
    assert len(events) == built.event_count == 9
    assert [delay for delay, _ in events] == [42000] + [0] * 7 + [123]
    actual = [write for _, chunk in events for write in chunk]
    expected = [(w.bank, w.reg, w.value) for w in writes + [tail]]
    assert actual == expected
    assert built.write_count == len(actual) == 466
    assert built.total_delay_us == 42123


if __name__ == '__main__':
    run()
    print('test_event_format: ok')
