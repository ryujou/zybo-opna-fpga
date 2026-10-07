"""Phase 5 rhythm ROM, Delta-T and external memory pin traces."""

from fm_cases import voice, key


PATTERN = (0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
           0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe)
RHYTHM_BYTES = (448, 640, 5952, 384, 640, 128)


def prepare(bus_type, memory_type="ram8"):
    bus = bus_type()
    bus.memory_type = memory_type
    bus.memory = {address: PATTERN[address % len(PATTERN)] for address in range(2048)}
    bus.audio_windows = []
    bus.payload = None
    bus.ymfm_payload = None
    bus.adc_events = None
    bus.adc_feedback = 0
    return bus


def window(bus, ticks, activity="active", pan=0xc0):
    start = bus.tick
    bus.tick += ticks
    bus.audio_windows.append((start, bus.tick, activity, pan))


def cpu_read(bus):
    bus.events += [(bus.tick, 1, 0, 1, 0, 3, 0),
                   (bus.tick + 8, 1, 1, 1, 1, 3, 0)]
    bus.tick += 32


def delta_t(bus, start=0, stop=1, limit=0xffff, delta=0xffff, level=0xff, pan=0xc0):
    bus.reg(0x00, 1, port=1)
    bus.reg(0x10, 0x13, port=1)
    bus.reg(0x10, 0x80, port=1)
    memory_bits = {"rom": 1, "ram8": 2, "ram1": 0}[bus.memory_type]
    for register, data in ((0x01, pan | memory_bits), (0x02, start & 255),
                           (0x03, start >> 8), (0x04, stop & 255), (0x05, stop >> 8),
                           (0x0c, limit & 255), (0x0d, limit >> 8),
                           (0x09, delta & 255), (0x0a, delta >> 8), (0x0b, level)):
        bus.reg(register, data, port=1)


def rhythm(bus, mask=0x3f, pan=0xc0, total=63, level=31):
    bus.reg(0x11, total)
    for channel in range(6):
        bus.reg(0x18 + channel, pan | level)
    bus.reg(0x10, mask)


def cases(bus_type):
    result = {}
    for channel, length in enumerate(RHYTHM_BYTES):
        bus = prepare(bus_type)
        rhythm(bus, 1 << channel)
        # Channels 4/5 advance the rhythm nibble address at half the rate.
        ticks = length * 2 * 864 * (2 if channel >= 4 else 1) + 16384
        window(bus, ticks)
        window(bus, 16384, "silent")
        result[f"rhythm_rom_{channel}"] = (bus, {})

    bus = prepare(bus_type)
    rhythm(bus)
    for total in (0, 1, 31, 32, 62, 63):
        bus.reg(0x11, total)
        bus.reg(0x10, 0x3f)
        window(bus, 32768, "silent" if total == 0 else "active")
    for level in range(32):
        for channel in range(6):
            bus.reg(0x18 + channel, 0xc0 | ((level + channel) & 31))
        bus.reg(0x10, 0x3f)
        window(bus, 16384)
    result["rhythm_levels"] = (bus, {})

    bus = prepare(bus_type)
    for pan in (0, 0x40, 0x80, 0xc0):
        rhythm(bus, pan=pan)
        bus.tick += 8192
        window(bus, 65536, "active" if pan else "silent", pan)
    result["rhythm_pan"] = (bus, {})

    bus = prepare(bus_type)
    rhythm(bus)
    window(bus, 65536)
    bus.reg(0x10, 0xbf)
    bus.tick += 8192
    window(bus, 16384, "silent")
    bus.reg(0x10, 0x3f)
    window(bus, 65536)
    result["rhythm_stop_restart"] = (bus, {})

    for memory_type in ("rom", "ram8", "ram1"):
        bus = prepare(bus_type, memory_type)
        delta_t(bus, stop=3)
        bus.reg(0x00, 0xa0, port=1)
        window(bus, 131072)
        bus.read(2)
        result[f"adpcm_nibbles_{memory_type}"] = (bus, {"eos": True})

    for delta in (0, 1, 0x1000, 0x24de, 0xffff):
        bus = prepare(bus_type)
        if delta == 1:
            bus.memory[0] = 0x7f
        delta_t(bus, stop=31, delta=delta)
        bus.reg(0x00, 0xa0, port=1)
        ticks = 20000000 if delta == 1 else 131072
        window(bus, ticks, "silent" if delta == 0 else "active")
        bus.read(2)
        result[f"adpcm_rate_{delta:04x}"] = (bus, {})

    for pan in (0, 0x40, 0x80, 0xc0):
        bus = prepare(bus_type)
        delta_t(bus, stop=15, pan=pan)
        bus.reg(0x00, 0xa0, port=1)
        window(bus, 65536, "active" if pan else "silent", pan)
        result[f"adpcm_pan_{pan:02x}"] = (bus, {})

    bus = prepare(bus_type)
    delta_t(bus, stop=31)
    bus.reg(0x00, 0xb0, port=1)
    for level in (0, 1, 2, 127, 128, 254, 255):
        bus.reg(0x0b, level, port=1)
        bus.tick += 8192
        window(bus, 32768, "silent" if level == 0 else "active")
    result["adpcm_levels"] = (bus, {})

    bus = prepare(bus_type)
    delta_t(bus, stop=0)
    bus.reg(0x00, 0xb0, port=1)
    window(bus, 131072)
    bus.read(2)
    result["adpcm_repeat"] = (bus, {"repeat": True})

    for memory_type in ("rom", "ram8", "ram1"):
        bus = prepare(bus_type, memory_type)
        delta_t(bus, start=1, stop=5 if memory_type == "ram1" else 3)
        bus.reg(0x00, 0x20, port=1)
        bus.write(2, 8)
        for _ in range(2):
            cpu_read(bus)
        bus.tick += 2048
        for _ in range(16):
            cpu_read(bus)
            bus.tick += 2048
        start = 4 if memory_type == "ram1" else 32
        bus.payload = [bus.memory[start + offset] for offset in range(16)]
        result[f"adpcm_cpu_read_{memory_type}"] = (bus, {})

    for memory_type in ("ram8", "ram1"):
        bus = prepare(bus_type, memory_type)
        delta_t(bus, start=1, stop=8)
        bus.reg(0x00, 0x60, port=1)
        bus.write(2, 8)
        payload = [0x5a, 0xa5, 0xff, 0, *PATTERN[:12]]
        for data in payload:
            bus.write(3, data)
            bus.tick += 4096
        bus.reg(0x00, 1, port=1)
        bus.reg(0x00, 0x20, port=1)
        bus.write(2, 8)
        for _ in range(2):
            cpu_read(bus)
        bus.tick += 2048
        for _ in range(len(payload)):
            cpu_read(bus)
            bus.tick += 2048
        bus.payload = payload
        result[f"adpcm_cpu_write_read_{memory_type}"] = (bus, {"write": True})

    for memory_type, start, stop, count in (("ram8", 15, 17, 40),
                                           ("ram1", 0x1fff, 0x2004, 20),
                                           ("ram1", 0xe001, 0xe005, 16)):
        bus = prepare(bus_type, memory_type)
        address = start << (2 if memory_type == "ram1" else 5)
        payload = [PATTERN[(offset + 5) % 16] for offset in range(count)]
        bus.memory.update({address + offset: data for offset, data in enumerate(payload)})
        delta_t(bus, start=start, stop=stop)
        bus.reg(0x00, 0x20, port=1)
        bus.write(2, 8)
        cpu_read(bus)
        cpu_read(bus)
        bus.tick += 2048
        for _ in payload:
            cpu_read(bus)
            bus.tick += 2048
        bus.payload = payload
        result[f"adpcm_cpu_boundary_{memory_type}_{start:04x}"] = (bus, {})

    bus = prepare(bus_type)
    delta_t(bus, start=1, stop=1, limit=1)
    bus.reg(0x00, 0xb0, port=1)
    window(bus, 131072)
    result["adpcm_limit_wrap"] = (bus, {"limit": True, "repeat": True})

    bus = prepare(bus_type)
    delta_t(bus, delta=0x24de)
    bus.reg(0x00, 0x80, port=1)
    bus.write(2, 8)
    for data in PATTERN * 4:
        bus.write(3, data)
        bus.tick += 4096
    bus.audio_windows.append((bus.events[0][0] + 16384, bus.tick, "active", 0xc0))
    result["adpcm_cpu_stream"] = (bus, {})

    for phase in (0, 1, 7, 15):
        bus = prepare(bus_type)
        delta_t(bus, stop=31)
        bus.reg(0x00, 0xb0, port=1)
        window(bus, 32768)
        bus.tick += phase
        bus.events += [(bus.tick, 0, 1, 1, 1, 0, 0),
                       (bus.tick + 1152, 1, 1, 1, 1, 0, 0)]
        bus.tick += 4096
        window(bus, 16384, "silent")
        bus.read(2)
        result[f"adpcm_reset_{phase:02}"] = (bus, {})

    bus = prepare(bus_type)
    delta_t(bus, stop=0)
    bus.reg(0x29, 0x9c)
    bus.reg(0x00, 0xa0, port=1)
    window(bus, 65536)
    bus.read(2)
    for mask in (0x1f, 0x13, 0x1b, 0x17, 0x80, 0x03):
        bus.reg(0x10, mask, port=1)
        bus.read(2)
    result["adpcm_status_masks"] = (bus, {"eos": True})

    for memory_type in ("rom", "ram8", "ram1"):
        bus = prepare(bus_type, memory_type)
        start = 0xffff if memory_type == "ram1" else 0x1fff
        address = 0x3fffc if memory_type == "ram1" else 0x3ffe0
        payload = list(PATTERN[:4] if memory_type == "ram1" else PATTERN * 2)
        bus.memory.update({address + offset: data for offset, data in enumerate(payload)})
        delta_t(bus, start=start, stop=start)
        bus.reg(0x00, 0x20, port=1)
        bus.write(2, 8)
        cpu_read(bus)
        cpu_read(bus)
        bus.tick += 2048
        for offset in range(len(payload)):
            cpu_read(bus)
            bus.tick += 2048
            if offset == len(payload) - 2:
                bus.read(2)
        bus.read(2)
        bus.payload = payload
        if memory_type == "ram1":
            # ymfm checks the incremented address against LIMIT before the
            # final byte. At FFFF it wraps early; the native payload stays full.
            bus.ymfm_payload = payload[:-1] + [bus.memory[0]]
        result[f"adpcm_cpu_end_{memory_type}"] = (bus, {"eos": True})

    for variant in ("silence", "nonquiet", "interrupted", "flags", "reset"):
        bus = prepare(bus_type)
        bus.reg(0x29, 0x90)
        bus.reg(0x00, 1, port=1)
        bus.reg(0x10, 3, port=1)
        bus.reg(0x06, 0xf4, port=1)
        bus.reg(0x07, 1, port=1)
        bus.reg(0x00, 8, port=1)
        bus.reg(0x01, 8, port=1)
        bus.adc_feedback = 256
        bus.adc_events = [(0, 64 if variant == "nonquiet" else 128)]
        quiet_start = bus.tick
        if variant == "interrupted":
            bus.adc_events += [(bus.tick + 2000000, 192), (bus.tick + 2200000, 128)]
            quiet_start = bus.tick + 2200000
            bus.tick += 7300000
        elif variant == "reset":
            bus.tick += 2000000
            bus.events += [(bus.tick, 0, 1, 1, 1, 0, 0),
                           (bus.tick + 1152, 1, 1, 1, 1, 0, 0)]
            bus.tick += 3200000
        else:
            bus.tick += 5000000
        bus.read(2)
        if variant == "flags":
            for enable in (0x80, 0x90):
                bus.reg(0x29, enable)
                bus.read(2)
            for mask in (0x13, 0x03):
                bus.reg(0x10, mask, port=1)
                bus.read(2)
            bus.tick += 4800000
            bus.read(2)
            bus.reg(0x10, 0x80, port=1)
            bus.read(2)
            bus.reg(0x00, 0, port=1)
            bus.reg(0x01, 0, port=1)
            bus.read(2)
        result[f"adpcm_zero_{variant}"] = (bus, {"zero": variant, "quiet_start": quiet_start})

    bus = prepare(bus_type)
    bus.reg(0x29, 0x9f)
    for channel in range(6):
        voice(bus, channel, algorithm=7)
        key(bus, channel)
    bus.reg(7, 0x38)
    for channel in range(3):
        bus.reg(channel * 2, channel + 3)
        bus.reg(8 + channel, 15)
    rhythm(bus)
    delta_t(bus, stop=31)
    bus.reg(0x00, 0xb0, port=1)
    window(bus, 131072)
    result["fm_ssg_rhythm_adpcm_parallel"] = (bus, {})

    bus = prepare(bus_type)
    rhythm(bus)
    delta_t(bus, stop=31)
    bus.reg(0x00, 0xb0, port=1)
    window(bus, 32768)
    for selector in (0x2f, 0x2d, 0x2e, 0x2f, 0x2d):
        bus.write(0, selector)
        window(bus, 16384)
    result["rhythm_adpcm_prescaler"] = (bus, {})
    return result
