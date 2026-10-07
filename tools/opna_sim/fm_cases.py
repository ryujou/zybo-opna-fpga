"""Phase 3 legal bus traces; native PCM expectations come from pinned LLE."""


def channel_register(bus, channel, register, value):
    bus.reg(register + channel % 3, value, port=channel // 3)


def key(bus, channel, slots=15):
    bus.reg(0x28, slots * 16 + channel % 3 + (4 if channel >= 3 else 0))


def voice(bus, channel=0, algorithm=7, pan=0xc0):
    for operator in (0, 4, 8, 12):
        for register, value in ((0x30, 1), (0x40, 0), (0x50, 31),
                                (0x60, 0), (0x70, 0), (0x80, 15), (0x90, 0)):
            channel_register(bus, channel, register + operator, value)
    channel_register(bus, channel, 0xb0, algorithm)
    channel_register(bus, channel, 0xb4, pan)
    channel_register(bus, channel, 0xa4, 0x22)
    channel_register(bus, channel, 0xa0, 0x69 + channel * 17)


def cases(bus_type):
    result = {}

    def setup():
        bus = bus_type()
        bus.reg(0x29, 0x9f)
        return bus

    bus = setup()
    bus.tick += 12000
    result["silence"] = (bus, 0)

    for name, pan, active in (("pan_left", 0x80, 1), ("pan_right", 0x40, 2),
                               ("pan_stereo", 0xc0, 3)):
        bus = setup()
        voice(bus, pan=pan)
        key(bus, 0)
        bus.tick += 48000
        result[name] = (bus, active)

    bus = setup()
    voice(bus)
    key(bus, 0)
    for algorithm in range(8):
        for feedback in range(8):
            channel_register(bus, 0, 0xb0, algorithm | feedback << 3)
            bus.tick += 8192
    result["algorithms_feedback"] = (bus, 3)

    for algorithm in range(8):
        bus = setup()
        voice(bus, algorithm=algorithm)
        key(bus, 0)
        bus.tick += 48000
        result[f"algorithm_{algorithm}"] = (bus, 3)

    bus = setup()
    for channel in range(6):
        voice(bus, channel)
        for slots in (1, 2, 4, 8, 15):
            key(bus, channel, slots)
            bus.tick += 8192
    bus.tick += 48000
    result["six_channels_slots"] = (bus, 3)

    bus = setup()
    voice(bus)
    for audible, slots in ((0, 1), (1, 4), (2, 2), (3, 8)):
        for operator in range(4):
            channel_register(bus, 0, 0x40 + operator * 4,
                             0 if operator == audible else 127)
        for mask in (15, slots):
            key(bus, 0, mask)
            bus.tick += 4096
            key(bus, 0, 0)
            bus.tick += 4096
    result["key_operator_isolation"] = (bus, 3)

    bus = setup()
    voice(bus)
    key(bus, 0)
    for detune in range(8):
        for multiplier in (0, 1, 15):
            for operator in (0, 4, 8, 12):
                channel_register(bus, 0, 0x30 + operator, detune << 4 | multiplier)
            bus.tick += 8192
    for multiplier in range(16):
        channel_register(bus, 0, 0x3c, multiplier)
        bus.tick += 4096
    for block in range(8):
        for fnum in (0, 1, 2047):
            channel_register(bus, 0, 0xa4, block << 3 | fnum >> 8)
            channel_register(bus, 0, 0xa0, fnum & 255)
            bus.tick += 4096
    result["frequency_detune_multiplier"] = (bus, 3)

    bus = setup()
    voice(bus)
    key(bus, 0)
    for high in (0, 0x3f, 0x22):
        channel_register(bus, 0, 0xa4, high)
        bus.tick += 8192
    channel_register(bus, 0, 0xa0, 0x69)
    bus.tick += 8192
    channel_register(bus, 0, 0xa4, 0x22)
    bus.reg(0xac, 0x3f)
    channel_register(bus, 0, 0xa0, 0x69)
    bus.tick += 8192
    result["frequency_latch"] = (bus, 3)

    bus = setup()
    voice(bus)
    channel_register(bus, 0, 0xa4, 0x3f)
    channel_register(bus, 0, 0xa0, 255)
    for ks in range(4):
        for ar, dr, sr, sl, rr in ((0, 0, 0, 0, 0), (1, 1, 1, 1, 1),
                                   (31, 31, 31, 15, 15), (31, 0, 0, 0, 15)):
            key(bus, 0, 0)
            for operator in (0, 4, 8, 12):
                for register, value in ((0x50, ks << 6 | ar), (0x60, dr),
                                        (0x70, sr), (0x80, sl << 4 | rr)):
                    channel_register(bus, 0, register + operator, value)
            key(bus, 0)
            bus.tick += 40000
            key(bus, 0, 0)
            bus.tick += 16000
    result["envelope_boundaries"] = (bus, 3)

    for name, ar, dr, sl, duration in (
            ("attack_rounding", 24, 0, 1, 100000),
            ("sustain_level_change", 31, 31, 1, 100000),
            ("decay_granularity", 31, 22, 15, 48000)):
        bus = setup()
        voice(bus)
        for operator in (0, 4, 8, 12):
            if name != "decay_granularity":
                channel_register(bus, 0, 0x50 + operator, ar)
            channel_register(bus, 0, 0x60 + operator, dr)
            channel_register(bus, 0, 0x80 + operator, sl << 4 | 15)
        key(bus, 0)
        bus.tick += duration
        if name == "sustain_level_change":
            for operator in (0, 4, 8, 12):
                channel_register(bus, 0, 0x80 + operator, 255)
            bus.tick += 100000
        result[name] = (bus, 3)

    bus = setup()
    voice(bus)
    for mode in range(8, 16):
        key(bus, 0, 0)
        for operator in (0, 4, 8, 12):
            channel_register(bus, 0, 0x60 + operator, 31)
            channel_register(bus, 0, 0x70 + operator, 31)
            channel_register(bus, 0, 0x90 + operator, mode)
        key(bus, 0)
        bus.tick += 48000
    result["ssg_eg_shapes"] = (bus, 3)

    bus = setup()
    voice(bus)
    key(bus, 0)
    for speed in range(8):
        bus.reg(0x22, 8 | speed)
        for depth in range(8):
            channel_register(bus, 0, 0xb4, 0xc0 | (depth % 4) << 4 | depth)
            for operator in (0, 4, 8, 12):
                channel_register(bus, 0, 0x60 + operator, 0x80 if depth & 1 else 0)
            bus.tick += 10000
    bus.reg(0x22, 0)
    result["lfo_am_pm"] = (bus, 3)

    bus = setup()
    voice(bus, 2)
    key(bus, 2)
    for mode in (0x40, 0xc0, 0):
        bus.reg(0x27, mode)
        for index in range(3):
            bus.reg(0xac + index, 0x20 + index)
            bus.reg(0xa8 + index, 0x40 + index * 32)
        bus.tick += 48000
    result["channel3_special"] = (bus, 3)

    bus = setup()
    voice(bus, 2)
    for index in range(3):
        bus.reg(0xac + index, 0x22)
        bus.reg(0xa8 + index, 0x69)
    bus.reg(0x24, 0xff)
    bus.reg(0x25, 0)
    bus.reg(0x27, 0x85)
    bus.tick += 120000
    bus.reg(0x27, 0x30)
    bus.tick += 48000
    result["csm_timer_a"] = (bus, 3)

    bus = setup()
    voice(bus)
    for phase in range(24):
        bus.tick += phase
        key(bus, 0, 15 if phase % 3 else 0)
        channel_register(bus, 0, 0xb0, phase % 8 | (phase % 8) << 3)
        channel_register(bus, 0, 0x4c, phase * 5)
        channel_register(bus, 0, 0xa0, phase * 7)
        bus.tick += 4096
    result["dynamic_writes_keys"] = (bus, 3)

    bus = setup()
    for channel in range(6):
        voice(bus, channel)
        key(bus, channel)
    bus.tick += 48000
    bus.reg(0x29, 0x1f)
    key(bus, 4, 0)
    bus.tick += 48000
    bus.reg(0x29, 0x9f)
    key(bus, 4)
    bus.tick += 48000
    result["three_six_channel_switch"] = (bus, 3)

    bus = setup()
    voice(bus)
    key(bus, 0)
    bus.tick += 24000
    reset_tick = bus.tick
    bus.events += [(bus.tick, 0, 1, 1, 1, 0, 0), (bus.tick + 1152, 1, 1, 1, 1, 0, 0)]
    bus.tick += 2304
    voice(bus)
    key(bus, 0)
    bus.tick += 24000
    result["fm_reset_active"] = (bus, 3)
    for delta in (1, 5, 6, 11, 12, 24, 36, 48, 60, 72, 144):
        variant = bus_type()
        variant.tick = bus.tick
        variant.events = [(event[0] + delta, *event[1:]) if event[0] == reset_tick else event
                          for event in bus.events]
        result[f"fm_reset_phase_{delta:03d}"] = (variant, 3)

    result.update(sch_cases(bus_type))
    return result


def sch_cases(bus_type):
    """Fixed SCH contract: native LLE output, explicitly different ymfm checks."""
    result = {}
    bus = bus_type()
    bus.reg(0x29, 0x9f)
    voice(bus, 3)
    key(bus, 3)
    bus.tick += 24000
    switch = bus.tick
    bus.reg(0x29, 0x1f)
    bus.tick += 24000
    bus.fm_windows = {
        "before": (switch - 12000, switch, {"lle": 3, "ymfm": 3}),
        "after": (switch + 4096, bus.tick + 4096, {"lle": 3, "ymfm": 0})}
    result["sch_high_channel"] = (bus, 3)

    bus = bus_type()
    bus.reg(0x29, 0x1f)
    voice(bus, 0)
    key(bus, 3)
    start = bus.tick
    bus.tick += 24000
    bus.fm_windows = {"after": (start + 4096, bus.tick + 4096, {"lle": 3, "ymfm": 0})}
    result["sch_key_alias"] = (bus, 3)

    for other_key in (False, True):
        bus = bus_type()
        bus.reg(0x29, 0x1f)
        voice(bus, 3)
        key(bus, 3)
        if other_key:
            key(bus, 1, slots=0)
        bus.tick += 24000
        switch = bus.tick
        bus.reg(0x29, 0x9f)
        bus.tick += 24000
        bus.fm_windows = {
            "before": (switch - 12000, switch, {"lle": 0, "ymfm": 0}),
            "after": (switch + 4096, bus.tick + 4096, {"lle": 0 if other_key else 3, "ymfm": 3})}
        name = "sch_enable_after_other_key" if other_key else "sch_enable_after_key"
        result[name] = (bus, 0 if other_key else 3)
    return result
