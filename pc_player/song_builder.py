from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable

from protocol import OplWrite
from vgm_loader import LoadedVgm, OplStreamEvent

# Keep this at 63 to match the existing streaming protocol limit in protocol.py.
# A preloaded event could theoretically carry up to 255 writes because the count
# field is one byte, but using 63 keeps the file format compatible with both
# streaming and buffered playback firmware parsers.
MAX_WRITES_PER_EVENT = 63


@dataclass
class BuiltSong:
    data: bytes
    event_count: int
    write_count: int
    total_delay_us: int
    backend_name: str = "vgm loader"


def build_preloaded_song(song: LoadedVgm) -> BuiltSong:
    return _build_from_opl_events(song.events, song.total_us)


def _build_from_opl_events(events: Iterable[OplStreamEvent], total_delay_us: int) -> BuiltSong:
    payload = bytearray()
    event_count = 0
    write_count = 0

    for event in events:
        if not event.writes:
            continue
        event_count += _append_event(payload, event.delta_us, event.writes)
        write_count += len(event.writes)

    return BuiltSong(
        data=bytes(payload),
        event_count=event_count,
        write_count=write_count,
        total_delay_us=total_delay_us,
    )

def _append_event(payload: bytearray, delay_us: int, writes: Iterable[OplWrite]) -> int:
    """Append one logical event, splitting large simultaneous write bursts.

    File format per chunk:
      uint32 delay_us
      uint8  write_count
      repeated write_count times: uint8 bank, uint8 reg, uint8 value

    Large VGM initialization bursts use multiple chunks. Only the first chunk
    carries the delay, so simultaneous register writes keep their timing.
    """
    write_list = list(writes)
    if not write_list:
        return 0

    chunk_count = 0
    offset = 0
    first_chunk = True
    while offset < len(write_list):
        chunk = write_list[offset : offset + MAX_WRITES_PER_EVENT]
        chunk_delay = int(delay_us) if first_chunk else 0
        payload.extend(chunk_delay.to_bytes(4, "little", signed=False))
        payload.append(len(chunk))
        for write in chunk:
            payload.extend([write.bank & 0x01, write.reg & 0xFF, write.value & 0xFF])
        offset += len(chunk)
        first_chunk = False
        chunk_count += 1

    return chunk_count
