"""Phase 4 bus traces and independent SSG register/shape expectations."""
from copy import deepcopy
from fm_cases import voice, key


def cases(bus_type):
    result = {}

    def setup():
        bus = bus_type()
        bus.reg(7, 0x3f)
        bus.ssg_reads = []
        bus.ymfm_reads = []
        bus.ssg_windows = []
        return bus

    def read(bus, register, expected, ymfm=None):
        bus.write(0, register)
        bus.read(1)
        bus.ssg_reads.append(expected)
        bus.ymfm_reads.append(expected if ymfm is None else ymfm)

    def window(bus, ticks, kind, expected=None):
        start = bus.tick
        bus.tick += ticks
        bus.ssg_windows.append((start, bus.tick, kind, expected))

    bus = setup()
    window(bus, 8192, "constant", [1, 1, 1])
    result["ssg_reset"] = bus

    bus = setup()
    for channel, period in enumerate((3, 7, 13)):
        bus.reg(channel * 2, period)
        bus.reg(channel * 2 + 1, 0)
        bus.reg(8 + channel, 15 - channel)
    bus.reg(7, 0x38)
    window(bus, 32768, "tones")
    result["ssg_tones_abc"] = bus

    bus = setup()
    for period in (0, 1, 2, 255, 256, 4095):
        for channel in range(3):
            bus.reg(channel * 2, period & 255)
            bus.reg(channel * 2 + 1, period >> 8)
            bus.reg(8 + channel, 15)
        bus.reg(7, 0x38)
        window(bus, max(8192, period * 256), "tones")
    result["ssg_tone_periods"] = bus

    bus = setup()
    for level in range(16):
        for channel in range(3):
            bus.reg(8 + channel, level)
        window(bus, 512, "constant", [level * 2 + 1] * 3)
    result["ssg_fixed_levels"] = bus

    bus = setup()
    for channel in range(3):
        bus.reg(channel * 2, 3 + channel)
        bus.reg(8 + channel, 15)
    bus.reg(6, 1)
    for mode in range(64):
        bus.reg(7, mode)
        window(bus, 2048, "mixer", mode)
    result["ssg_mixer_modes"] = bus

    bus = setup()
    for channel in range(3):
        bus.reg(8 + channel, 15)
    bus.reg(7, 7)
    for period in (0, 1, 2, 15, 31):
        bus.reg(6, period)
        window(bus, 131072, "noise")
    result["ssg_noise_periods"] = bus

    for shape in range(16):
        bus = setup()
        for channel in range(3):
            bus.reg(8 + channel, 16)
        bus.reg(11, 2)
        bus.reg(12, 0)
        shape_start = bus.tick + 64
        bus.reg(13, shape)
        bus.tick += 20000
        bus.ssg_windows.append((shape_start, bus.tick, "shape", shape))
        result[f"ssg_shape_{shape:02}"] = bus

    bus = setup()
    for channel in range(3):
        bus.reg(8 + channel, 16)
    bus.reg(13, 10)
    for period in (0, 1, 2, 4095, 4096, 4097, 65535):
        bus.reg(11, period & 255)
        bus.reg(12, period >> 8)
        bus.reg(13, 10)
        window(bus, max(16384, period * 128), "envelope")
    result["ssg_envelope_periods"] = bus

    bus = setup()
    bus.reg(8, 16)
    bus.reg(11, 1)
    bus.reg(13, 14)
    for phase in range(16):
        bus.tick += 1024 + phase
        bus.reg(13, 14)
        window(bus, 2048, "envelope")
    result["ssg_retrigger_phases"] = bus

    bus = setup()
    masks = (255, 15, 255, 15, 255, 15, 31, 255, 31, 31, 31, 255, 255, 15, 255, 255)
    for register, mask in enumerate(masks):
        bus.reg(register, 255)
        read(bus, register, 0 if register >= 14 else mask,
             255 if register != 13 else 255)
    # Port 1 cannot select or change the SSG register bank.
    bus.reg(8, 7)
    bus.reg(8, 31, port=1)
    read(bus, 8, 7)
    result["ssg_readback_bank"] = bus

    bus = setup()
    for channel in range(3):
        bus.reg(channel * 2, 2 + channel)
        bus.reg(8 + channel, 16)
    bus.reg(6, 3)
    bus.reg(7, 0)
    bus.reg(11, 1)
    bus.reg(13, 14)
    for divider in (0x2f, 0x2d, 0x2e, 0x2f, 0x2e, 0x2d):
        bus.write(0, divider)
        window(bus, 16384, "dynamic")
    result["ssg_prescaler"] = bus

    bus = setup()
    bus.reg(0x29, 0x9f)
    for channel in range(6):
        voice(bus, channel)
        key(bus, channel)
    for channel in range(3):
        bus.reg(channel * 2, 3 + channel)
        bus.reg(8 + channel, 16)
    bus.reg(6, 2)
    bus.reg(7, 0)
    bus.reg(11, 1)
    bus.reg(13, 10)
    window(bus, 32768, "dynamic")
    result["fm_ssg_parallel"] = bus
    bus = deepcopy(bus)
    for divider in (0x2f, 0x2d, 0x2e, 0x2f, 0x2d):
        bus.write(0, divider)
        window(bus, 16384, "dynamic")
    result["fm_ssg_prescaler"] = bus
    for algorithm in range(8):
        variant = deepcopy(bus)
        selected = [None, None]
        events = []
        for event in variant.events:
            event = list(event)
            if event[2:5] == [0, 0, 1]:
                port = event[5] // 2
                if event[5] % 2 == 0:
                    selected[port] = event[6]
                elif selected[port] in (0xb0, 0xb1, 0xb2):
                    event[6] = 0x28 | algorithm
            events.append(tuple(event))
        variant.events = events
        result[f"fm_ssg_algorithm_{algorithm}_prescaler"] = variant

    bus = setup()
    for channel in range(3):
        bus.reg(channel * 2, 1 + channel)
        bus.reg(8 + channel, 16)
    bus.reg(7, 0)
    bus.reg(6, 1)
    bus.reg(11, 2)
    bus.reg(13, 14)
    bus.tick += 8192
    for phase in (0, 1, 7, 15):
        bus.tick += phase
        bus.events += [(bus.tick, 0, 1, 1, 1, 0, 0),
                       (bus.tick + 1152, 1, 1, 1, 1, 0, 0)]
        bus.tick += 2304
        window(bus, 2048, "reset_codes")
        bus.reg(8, 16)
        bus.reg(7, 0x3e)
        bus.reg(11, 1)
        bus.reg(13, 14)
        bus.tick += 4096
    result["ssg_reset_active"] = bus
    return result
