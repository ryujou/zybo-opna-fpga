"""Phase 6 mixed-source and uninterrupted-run pin traces."""

import json
from pathlib import Path
import random
import struct

from adpcm_cases import PATTERN, cpu_read, delta_t, prepare, rhythm, window
from fm_cases import channel_register, key, voice


FIXTURE = Path(__file__).parent / "fixtures/counterattack"
TICKS_PER_SECOND = 16_000_000


def manual_bus(bus_type):
    class ManualBus(bus_type):
        def reg(self, register, data, port=0):
            start = self.tick
            super().reg(register, data, port=port)
            if port == 0 and register == 0x10:
                # Rhythm key data WR releases at start+96; wait 576 clocks.
                self.tick = max(self.tick, start + 1248)
    return ManualBus


def mixed_setup(bus, pan=0xc0, synchronized=False):
    bus.reg(0x29, 0x9f)
    for channel in range(6):
        voice(bus, channel, algorithm=7, pan=pan)
        if synchronized:
            channel_register(bus, channel, 0xa0, 0x69)
        key(bus, channel)
    for channel, period in enumerate((3, 5, 7)):
        bus.reg(channel * 2, period)
        bus.reg(channel * 2 + 1, 0)
        bus.reg(8 + channel, 15)
    bus.reg(7, 0x38)
    rhythm(bus, pan=pan)
    delta_t(bus, stop=31, pan=pan)
    bus.reg(0x00, 0xb0, port=1)


def active_contract(start, end, pan=0xc0):
    return {"coverage": ["MIX", "RUN"], "scenario": ["mixed"],
            "signed_windows": [(start, end, pan)] if pan else [],
            "source_windows": [(start, end, [0, 1, 2, 3])] if pan == 0xc0 else [],
            "ssg_windows": [(start, end, "mixer", 0x38)],
            "cadence_windows": [(start, end, 288)]}


def reset(bus, offset=0):
    start = bus.tick + offset
    bus.events += [(start, 0, 1, 1, 1, 0, 0),
                   (start + 1152, 1, 1, 1, 1, 0, 0)]
    bus.tick = start + 3456
    return start


def music_data():
    """Read only the commands present in the preserved Furnace export."""
    data = (FIXTURE / "Counterattack.vgm").read_bytes()
    if data[:4] != b"Vgm ":
        raise RuntimeError("Counterattack VGM signature")
    u32 = lambda offset: struct.unpack_from("<I", data, offset)[0]
    if u32(8) != 0x171 or u32(0x48) != 7_987_200:
        raise RuntimeError("Counterattack VGM version/clock")
    gd3 = 0x14 + u32(0x14)
    tags = data[gd3 + 12:gd3 + 12 + u32(gd3 + 8)].decode("utf-16le").split("\0")
    if tags[0] != "Counterattack" or tags[6] != "MelonadeM":
        raise RuntimeError("Counterattack VGM title/composer")
    position = 0x34 + u32(0x34)
    samples = 0
    writes, memory = [], {}
    while position < len(data):
        command = data[position]
        if command in (0x56, 0x57):
            writes.append((samples, command - 0x56, data[position + 1], data[position + 2]))
            position += 3
        elif command == 0x61:
            samples += struct.unpack_from("<H", data, position + 1)[0]
            position += 3
        elif command in (0x62, 0x63):
            samples += 735 if command == 0x62 else 882
            position += 1
        elif 0x70 <= command <= 0x7f:
            samples += command - 0x6f
            position += 1
        elif command == 0x67:
            if data[position + 1:position + 3] != b"\x66\x81":
                raise RuntimeError("Counterattack requires a YM2608 ADPCM-B block")
            length, size, address = (u32(position + offset) for offset in (3, 7, 11))
            payload = data[position + 15:position + 7 + length]
            if size != 262144 or address + len(payload) > size:
                raise RuntimeError("Counterattack ADPCM memory range")
            memory.update((address + index, value) for index, value in enumerate(payload))
            position += 7 + length
        elif command == 0x66:
            break
        else:
            raise RuntimeError(f"Counterattack unsupported VGM command {command:02x}")
    if samples != u32(0x18) or len(writes) != 41480 or len(memory) != 34560:
        raise RuntimeError("Counterattack preserved export contents")
    return writes, memory, samples


def music_case(bus_type, excerpt_samples=44100):
    writes, memory, total_samples = music_data()
    bus = prepare(manual_bus(bus_type))
    bus.memory = memory
    bus.music_samples = bytes(memory[address] for address in sorted(memory))
    bus.music_writes = []
    bus.music_raw_writes = []
    origin = bus.tick
    count, delayed, greatest_delay = 0, 0, 0
    for sample, port, register, value in writes:
        if sample >= excerpt_samples:
            break
        ideal = origin + sample * TICKS_PER_SECOND // 44100
        delay = max(0, bus.tick - ideal)
        delayed += int(bool(delay))
        greatest_delay = max(greatest_delay, delay)
        bus.tick = max(bus.tick, ideal)
        bus.music_raw_writes.append((sample, port, register, value))
        bus.music_writes.append((bus.tick + 64, port, register, value))
        bus.reg(register, value, port=port)
        count += 1
    bus.tick = max(bus.tick, origin + excerpt_samples * TICKS_PER_SECOND // 44100)
    bus.audio_windows.append((origin + 1_000_000, bus.tick, "active", 0xc0))
    provenance = json.loads((FIXTURE / "source.json").read_text(encoding="utf-8"))
    contract = {"coverage": ["MIX", "RUN"], "scenario": ["music"],
                "music": {**provenance, "excerpt_samples": excerpt_samples,
                          "total_samples": total_samples, "register_writes": count,
                          "sample_bytes": len(memory), "serialized_writes": delayed,
                          "maximum_serialization_delay_ticks": greatest_delay},
                "source_windows": [(origin + 1_000_000, bus.tick, [0, 1, 2, 3])],
                "ssg_windows": [(origin + 1_000_000, bus.tick, "constant", [1, 1, 1])],
                "ymfm_ssg_activity": False,
                "cadence_windows": [(origin + 1_000_000, bus.tick, 288)]}
    return bus, contract


def cases(bus_type):
    base_bus_type = bus_type
    bus_type = manual_bus(bus_type)
    result = {}
    for pan in (0, 0x40, 0x80, 0xc0):
        bus = prepare(bus_type)
        mixed_setup(bus, pan=pan)
        bus.tick += 8192
        start = bus.tick
        window(bus, 131072, "active" if pan else "silent", pan)
        result[f"mix_pan_{pan:02x}"] = (bus, active_contract(start, bus.tick, pan))

    bus = prepare(bus_type)
    mixed_setup(bus, synchronized=True)
    bus.tick += 8192
    start = bus.tick
    window(bus, 196608)
    contract = active_contract(start, bus.tick)
    contract["clipping_window"] = (start, bus.tick)
    result["mix_clipping"] = (bus, contract)

    bus = prepare(bus_type)
    mixed_setup(bus)
    for channel in range(6):
        channel_register(bus, channel, 0xb4, 0x80)
    for channel in range(6):
        bus.reg(0x18 + channel, 0x40 | 31)
    bus.reg(0x01, 0x42, port=1)
    bus.tick += 8192
    start = bus.tick
    window(bus, 131072)
    contract = active_contract(start, bus.tick)
    contract["source_windows"] = [(start, bus.tick, [0, 2, 3])]
    contract["source_zero_windows"] = [(start, bus.tick, [1])]
    result["mix_split_sources"] = (bus, contract)

    for seed in (0x2608, 0xcafe):
        bus = prepare(bus_type)
        mixed_setup(bus)
        generator = random.Random(seed)
        actions = []
        expected = []
        attack_rates = {(channel, operator): 31 for channel in range(6)
                        for operator in (0, 4, 8, 12)}
        ssg_modes = dict.fromkeys(attack_rates, 0)
        bus.random_events = []
        original_reg = bus.reg

        def register(register, value, port=0):
            bus.random_events.append((bus.tick + 64, port, register, value))
            original_reg(register, value, port=port)

        bus.reg = register
        start = bus.tick
        for index in range(192):
            action = generator.randrange(8)
            channel = generator.randrange(6)
            operator = generator.choice((0, 4, 8, 12))
            actions.append(action)
            if action == 0:
                key(bus, channel, generator.randrange(16))
            elif action == 1:
                channel_register(bus, channel, 0xa4, generator.randrange(64))
                channel_register(bus, channel, 0xa0, generator.randrange(256))
            elif action == 2:
                register = generator.choice((0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90))
                masks = {0x30: 0x7f, 0x40: 0x7f, 0x50: 0xdf, 0x60: 0x9f,
                         0x70: 0x1f, 0x80: 0xff, 0x90: 0x0f}
                value = generator.randrange(256) & masks[register]
                selected_operator = (channel, operator)
                if register == 0x50:
                    if ssg_modes[selected_operator] & 8:
                        value = (value & 0xc0) | 31
                    attack_rates[selected_operator] = value
                elif register == 0x90:
                    # The application manual requires AR=1F for SSG-EG.
                    if value & 8 and attack_rates[selected_operator] & 31 != 31:
                        attack = (attack_rates[selected_operator] & 0xc0) | 31
                        channel_register(bus, channel, 0x50 + operator, attack)
                        attack_rates[selected_operator] = attack
                    ssg_modes[selected_operator] = value
                channel_register(bus, channel, register + operator, value)
            elif action == 3:
                channel_register(bus, channel, 0xb0, generator.randrange(64))
                channel_register(bus, channel, 0xb4,
                                 generator.choice((0, 0x40, 0x80, 0xc0)))
            elif action == 4:
                channel %= 3
                period = generator.randrange(4096)
                bus.reg(channel * 2, period & 255)
                bus.reg(channel * 2 + 1, period >> 8)
                level = generator.randrange(32)
                bus.reg(8 + channel, level)
                bus.write(0, 8 + channel)
                bus.read(1)
                expected.append(level)
            elif action == 5:
                bus.reg(6, generator.randrange(32))
                bus.reg(7, generator.randrange(64))
                bus.reg(11, generator.randrange(256))
                bus.reg(12, generator.randrange(256))
                bus.reg(13, generator.randrange(16))
            elif action == 6:
                bus.reg(0x11, generator.randrange(64))
                bus.reg(0x18 + channel,
                        generator.choice((0, 0x40, 0x80, 0xc0)) | generator.randrange(32))
                bus.reg(0x10, generator.randrange(64))
            else:
                bus.reg(0x09, generator.randrange(256), port=1)
                bus.reg(0x0a, generator.randrange(256), port=1)
                bus.reg(0x0b, generator.randrange(256), port=1)
                bus.reg(0x01, generator.choice((2, 0x42, 0x82, 0xc2)), port=1)
            bus.tick += generator.randrange(512, 4097)
        bus.reg = original_reg
        contract = {"coverage": ["BUS", "FM", "EG", "SSG", "RHY", "ADP", "MIX", "RUN"],
                    "scenario": ["random"], "seed": seed, "random_actions": actions,
                    "random_events": len(bus.random_events),
                    "expected_reads": {model: {1: expected} for model in ("lle", "ymfm")},
                    "cadence_windows": [(start, bus.tick, 288)]}
        result[f"run_seed_{seed:04x}"] = (bus, contract)

    for name, offset in (("serial_even", 0), ("serial_odd", 1), ("timer_irq", 73)):
        bus = prepare(bus_type)
        mixed_setup(bus)
        bus.reg(0x24, 255)
        bus.reg(0x25, 3)
        bus.reg(0x26, 255)
        bus.reg(0x27, 15)
        bus.reg(0x10, 0x10, port=1)
        bus.tick += 32768
        bus.read(0)
        reset_tick = reset(bus, offset)
        bus.read(0)
        bus.read(2)
        quiet = bus.tick
        window(bus, 8192, "silent")
        bus.reg(0x29, 0x9f)
        mixed_setup(bus)
        bus.tick += 8192
        start = bus.tick
        window(bus, 65536)
        contract = active_contract(start, bus.tick)
        contract.update({"scenario": ["reset", "mixed"], "reset_tick": reset_tick,
                         "expected_reads": {model: {0: [3, 0], 2: [0]}
                                            for model in ("lle", "ymfm")}})
        contract["ssg_windows"].append((quiet, quiet + 8192, "reset_codes", None))
        result[f"run_reset_{name}"] = (bus, contract)

    bus = prepare(bus_type)
    mixed_setup(bus)
    bus.tick += 16384
    reset_tick = reset(bus, 15)
    bus.read(0)
    bus.read(2)
    quiet = bus.tick
    window(bus, 8192, "silent")
    delta_t(bus, stop=1)
    bus.reg(0x00, 0x20, port=1)
    bus.write(2, 8)
    cpu_read(bus)
    cpu_read(bus)
    bus.tick += 2048
    bus.payload = list(PATTERN * 4)
    for _ in bus.payload:
        cpu_read(bus)
        bus.tick += 2048
    result["run_reset_memory"] = (bus, {
        "coverage": ["BUS", "ADP", "STA", "RUN"], "scenario": ["reset"],
        "reset_tick": reset_tick,
        "expected_reads": {model: {0: [0], 2: [0]} for model in ("lle", "ymfm")},
        "dummy_reads": {"lle": [152, 186], "ymfm": [0, 0]},
        "ssg_windows": [(quiet, quiet + 8192, "reset_codes", None)]})

    result["run_music_counterattack"] = music_case(base_bus_type)

    bus = prepare(bus_type)
    mixed_setup(bus)
    bus.reg(0x24, 255)
    bus.reg(0x25, 3)
    bus.reg(0x26, 255)
    bus.reg(0x27, 15)
    bus.reg(0x10, 0x10, port=1)
    bus.tick += 8192
    start = bus.tick
    for index in range(8):
        bus.tick = start + index * 2_000_000
        bus.reg(0x10, 0x3f)
        bus.read(0)
    bus.tick = start + TICKS_PER_SECOND
    bus.audio_windows.append((start, bus.tick, "active", 0xc0))
    contract = active_contract(start, bus.tick)
    contract.update({"scenario": ["long", "mixed"], "duration_ticks": TICKS_PER_SECOND,
                     "expected_reads": {model: {0: [3] * 8} for model in ("lle", "ymfm")}})
    result["run_long_drift"] = (bus, contract)
    return result
