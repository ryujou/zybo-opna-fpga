"""Phase 2 inputs and independent register-level expectations."""


def cases(bus_type):
    result = {}
    bus = bus_type()
    bus.read(0)
    result["reset_status"] = (bus, [0])

    bus = bus_type()
    masks = {0: 255, 1: 15, 6: 31, 7: 255, 8: 31, 11: 255, 12: 255, 13: 15}
    for register, mask in masks.items():
        bus.reg(register, 255)
        bus.write(0, register)
        bus.read(1)
    result["ssg_masks"] = (bus, list(masks.values()))

    bus = bus_type()
    bus.write(0, 0x30)
    bus.write(1, 1)
    bus.read(0)
    bus.tick += 512
    bus.read(0)
    result["busy_window"] = (bus, [128, 0])

    for timer in ("a", "b"):
        bus = bus_type()
        if timer == "a":
            bus.reg(0x24, 255)
            bus.reg(0x25, 3)
            bus.reg(0x27, 5)
            bus.tick += 4096
            expected = 1
        else:
            bus.reg(0x26, 255)
            bus.reg(0x27, 10)
            bus.tick += 16000
            expected = 2
        bus.read(0)
        bus.reg(0x27, 0x30)
        bus.read(0)
        result[f"timer_{timer}"] = (bus, [expected, 0])

    bus = bus_type()
    bus.reg(0x29, 0)
    bus.reg(0x24, 255)
    bus.reg(0x25, 3)
    bus.reg(0x27, 5)
    bus.tick += 4096
    bus.read(0)
    bus.reg(0x29, 1)
    bus.read(0)
    bus.reg(0x27, 0x30)
    bus.read(0)
    result["irq_mask"] = (bus, [1, 1, 0])

    bus = bus_type()
    for address in (0x2f, 0x2d, 0x2e, 0x2f, 0x2d):
        bus.write(0, address)
        bus.tick += 1024
    result["prescaler"] = (bus, [])

    bus = bus_type()
    bus.reg(0x29, 0x9f)
    bus.reg(0x29, 0x1f)
    result["channel_mode"] = (bus, [])

    bus = bus_type()
    bus.reg(0x27, 5, port=1)
    bus.reg(0x29, 0x9f, port=1)
    bus.read(0)
    result["bank_isolation"] = (bus, [0])

    bus = bus_type()
    bus.reg(0x24, 255)
    bus.reg(0x25, 3)
    bus.reg(0x27, 5)
    bus.tick += 4096
    bus.events += [(bus.tick, 0, 1, 1, 1, 0, 0), (bus.tick + 1152, 1, 1, 1, 1, 0, 0)]
    bus.tick += 2304
    bus.read(0)
    result["reset_active"] = (bus, [0])

    bus = bus_type()
    bus.read(2)
    bus.write(0, 0xff)
    bus.tick += 512
    bus.read(1)
    result["extended_status_id"] = (bus, [0, 1])

    for timer in ("a", "b"):
        bus = bus_type()
        if timer == "a":
            bus.reg(0x24, 0)
            bus.reg(0x25, 0xfc)  # Reserved bits do not change the 10-bit value.
            bus.reg(0x27, 5)
            wait, flag = 300000, 1  # 1024 * 144 master clocks at default divide.
        else:
            bus.reg(0x26, 0)
            bus.reg(0x27, 10)
            wait, flag = 1200000, 2  # 256 * 16 * 144 master clocks.
        bus.read(0)
        bus.tick += wait
        bus.read(0)
        bus.reg(0x27, 0x30)
        bus.read(0)
        result[f"timer_{timer}_minimum"] = (bus, [0, flag, 0])

    bus = bus_type()
    bus.reg(0x24, 255)
    bus.reg(0x25, 3)
    bus.reg(0x27, 4)  # Flag enabled but timer stopped.
    bus.tick += 2048
    bus.read(0)
    bus.reg(0x27, 1)  # Timer running with flag disabled.
    bus.tick += 2048
    bus.read(0)
    bus.reg(0x27, 5)
    bus.tick += 2048
    bus.read(0)
    bus.reg(0x27, 0)  # Stop does not clear a pending flag.
    bus.read(0)
    bus.reg(0x27, 0x10)
    bus.read(0)
    result["timer_enable_stop"] = (bus, [0, 0, 1, 1, 0])

    bus = bus_type()
    bus.reg(0x24, 255)
    bus.reg(0x25, 3)
    bus.reg(0x27, 5)
    bus.tick += 2048
    bus.reg(0x10, 0x1d, port=1)  # Keep ADPCM flags masked in the control phase.
    bus.read(0)
    bus.reg(0x10, 0x1c, port=1)
    bus.read(0)
    bus.reg(0x27, 0)
    bus.reg(0x10, 0x80, port=1)
    bus.read(0)
    result["flag_control"] = (bus, [0, 1, 0])

    bus = bus_type()
    bus.reg(0x24, 255)
    bus.reg(0x25, 3)
    bus.reg(0x27, 5)
    # Hold a status read across the first overflow. Flags/IRQ remain latched
    # until the read is released, although the timer continues counting.
    bus.tick = 4896
    bus.events += [(bus.tick, 1, 0, 1, 0, 0, 0),
                   (bus.tick + 512, 1, 1, 1, 1, 0, 0)]
    bus.tick += 1024
    bus.read(0)
    result["status_read_hold"] = (bus, [0, 1])

    bus = bus_type()
    bus.reg(0x24, 255)
    bus.reg(0x25, 2)
    bus.reg(0x26, 255)
    bus.reg(0x27, 15)
    for address in (0x2f, 0x2d, 0x2e, 0x2f, 0x2d):
        bus.write(0, address)
        bus.tick += 4096
        bus.read(0)
    bus.reg(0x27, 0x30)
    bus.read(0)
    result["timers_prescaler"] = (bus, [3, 3, 3, 3, 3, 0])

    bus = bus_type()
    expected = []
    for offset in range(24):
        bus.tick += offset
        bus.reg(0x29, 0x9f if offset & 1 else 0x1f)
        bus.reg(8, offset & 15)
        bus.write(0, 8)
        bus.read(1)
        expected.append(offset & 15)
        bus.write(2, 0x29)
        bus.write(1, 0x9f)  # Data on the other bank must not write register 29.
        bus.tick += 512
    result["bus_phase_sweep"] = (bus, expected)
    return result
