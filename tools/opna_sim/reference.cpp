#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include "ymfm_opn.h"
extern "C" {
#include "fmopna_2608.h"
void FMOPNA_ClockZeroManual(fmopna_t *chip, int clk);
}
#include "fmopna_rom.h"

struct Pins {
    uint64_t tick;
    int ic, cs, wr, rd, address, data;
    bool reading() const { return ic && !cs && !rd; }
    bool writing() const { return ic && !cs && !wr; }
};

struct Trace {
    uint64_t end;
    std::vector<Pins> events;
    explicit Trace(const char *path) {
        std::ifstream in(path);
        if (!(in >> end) || end == 0) throw std::runtime_error("invalid trace length");
        Pins p{};
        while (in >> p.tick) {
            if (!(in >> p.ic >> p.cs >> p.wr >> p.rd >> p.address >> p.data))
                throw std::runtime_error("incomplete trace row");
            if (p.tick >= end || (!events.empty() && p.tick <= events.back().tick) ||
                p.ic < 0 || p.ic > 1 || p.cs < 0 || p.cs > 1 ||
                p.wr < 0 || p.wr > 1 || p.rd < 0 || p.rd > 1 ||
                p.address < 0 || p.address > 3 || p.data < 0 || p.data > 255 ||
                (!p.cs && !p.wr && !p.rd))
                throw std::runtime_error("invalid trace pins or time");
            events.push_back(p);
        }
        if (!in.eof() || events.empty() || events.front().tick != 0 ||
            events.back().reading() || events.back().writing())
            throw std::runtime_error("trace must start at zero and release bus");
    }
};

std::vector<uint8_t> load_memory(const char *path) {
    std::ifstream in(path);
    if (!in) throw std::runtime_error("missing memory input");
    std::vector<uint8_t> ram(1 << 18, 0);
    unsigned address, value;
    while (in >> address) {
        if (!(in >> value) || address >= ram.size() || value > 255)
            throw std::runtime_error("invalid memory byte");
        ram[address] = uint8_t(value);
    }
    if (!in.eof()) throw std::runtime_error("invalid memory input");
    return ram;
}

struct Output {
    std::ofstream file;
    int irq = -1, busy = -1;
    std::array<int, 3> ssg{{-1, -1, -1}};
    explicit Output(const char *path) : file(path) {
        if (!file) throw std::runtime_error("cannot open output");
        file << "tick,kind,index,value\n";
    }
    void emit(uint64_t tick, const char *kind, int index, int value) {
        file << tick << ',' << kind << ',' << index << ',' << value << '\n';
    }
    void flags(uint64_t tick, int irq_now, int busy_now) {
        if (irq_now != irq) { irq = irq_now; emit(tick, "irq", 0, irq); }
        if (busy_now != busy) { busy = busy_now; emit(tick, "busy", 0, busy); }
    }
};

class Host : public ymfm::ymfm_interface {
public:
    uint64_t tick = 0, busy_until = 0;
    std::array<int64_t, 2> timers{{-1, -1}};
    bool irq = false;
    std::vector<uint8_t> ram;
    explicit Host(std::vector<uint8_t> data) : ram(std::move(data)) {}
    void ymfm_set_timer(uint32_t n, int32_t clocks) override {
        timers.at(n) = clocks < 0 ? -1 : int64_t(tick + uint64_t(clocks) * 2);
    }
    void ymfm_set_busy_end(uint32_t clocks) override { busy_until = tick + clocks * 2; }
    bool ymfm_is_busy() override { return tick < busy_until; }
    void ymfm_update_irq(bool state) override { irq = state; }
    uint8_t ymfm_external_read(ymfm::access_class type, uint32_t address) override {
        if (type == ymfm::ACCESS_ADPCM_A) return rss_rom[address & 8191];
        if (type == ymfm::ACCESS_ADPCM_B) return ram.at(address);
        return 0;
    }
    void ymfm_external_write(ymfm::access_class type, uint32_t address, uint8_t value) override {
        if (type == ymfm::ACCESS_ADPCM_B) ram.at(address) = value;
    }
    void advance(uint64_t now) {
        tick = now;
        for (unsigned n = 0; n < timers.size(); ++n)
            if (timers[n] >= 0 && uint64_t(timers[n]) <= tick) {
                timers[n] = -1;
                m_engine->engine_timer_expired(n);
            }
    }
};

void run_ymfm(const Trace &trace, const std::vector<uint8_t> &ram, Output &out) {
    Host host(ram);
    ymfm::ym2608 chip(host);
    chip.set_fidelity(ymfm::OPN_FIDELITY_MAX);
    chip.reset();
    Pins pins = trace.events.front();
    size_t cursor = 0;
    uint64_t next_audio = 0;
    for (uint64_t tick = 0; tick < trace.end; ++tick) {
        // Complete the read using the previous edge's state, before advancing
        // timers to the release edge. Call read once (ADPCM reads have effects).
        if (cursor < trace.events.size() && trace.events[cursor].tick == tick) {
            const Pins &next = trace.events[cursor];
            if (pins.reading() && (!next.reading() || next.address != pins.address))
                out.emit(tick - 1, "read", pins.address, chip.read(pins.address));
        }
        host.advance(tick);
        if (cursor < trace.events.size() && trace.events[cursor].tick == tick) {
            const Pins next = trace.events[cursor++];
            if (!next.ic && pins.ic) {
                chip.reset();
                host.timers = {{-1, -1}};
                host.busy_until = 0;
                host.irq = false;
            }
            if (next.ic && !pins.ic) next_audio = tick + 16;
            if (next.writing() && (!pins.writing() || next.address != pins.address))
                chip.write(next.address, next.data);
            pins = next;
        }
        if (pins.ic && tick == next_audio) {
            ymfm::ym2608::output_data sample;
            chip.generate(&sample);
            out.emit(tick, "pcm", 0, sample.data[0]);
            out.emit(tick, "pcm", 1, sample.data[1]);
            out.emit(tick, "ssg_pcm", 0, sample.data[2]);
            next_audio += 16;
        }
        out.flags(tick, host.irq, host.ymfm_is_busy());
    }
}

void run_lle(const Trace &trace, const std::vector<uint8_t> &ram, Output &out,
             bool controls = false, int memory_type = -1, int ad_input = 0, int da_feedback = 0,
             const std::vector<std::pair<uint64_t, int>> &ad_events = {}, bool mix_trace = false) {
    fmopna_t chip{};
    chip.input.test = 1;
    chip.input.ic = chip.input.cs = chip.input.wr = chip.input.rd = 1;
    chip.input.gpio_a = chip.input.gpio_b = 0;
    chip.input.ad = ad_input;
    chip.input.da = da_feedback == 256 ? 128 : da_feedback;
    Pins pins = trace.events.front();
    size_t cursor = 0;
    size_t adc_cursor = 0;
    uint16_t serial = 0;
    int previous_s = 0, previous_sh1 = 0, previous_sh2 = 0;
    int previous_ras = 1, previous_cas = 1;
    uint32_t memory_address = 0;
    std::vector<uint8_t> writable = memory_type >= 0 ? ram : std::vector<uint8_t>{};
    int previous_we = 1, previous_memory_enable = 0;
    uint32_t previous_memory_address = 0;
    std::array<int, 8> previous_memory_pins{{-1, -1, -1, -1, -1, -1, -1, -1}};
    int previous_adpcm_flags = -1, previous_adpcm_busy = -1, previous_adc = -1;
    std::array<int, 3> previous_limit{{-1,-1,-1}};
    std::array<int, 5> previous_control{{-1, -1, -1, -1, -1}};
    std::array<int, 4> previous_mix{{0x40000, 0x40000, 0x40000, 0x40000}};
    bool previous_load_left = false, previous_load_right = false;
    for (uint64_t tick = 0; tick < trace.end; ++tick) {
        if (adc_cursor < ad_events.size() && ad_events[adc_cursor].first == tick)
            chip.input.ad = ad_events[adc_cursor++].second;
        if (cursor < trace.events.size() && trace.events[cursor].tick == tick) {
            const Pins next = trace.events[cursor++];
            if (pins.reading() && (!next.reading() || next.address != pins.address))
                out.emit(tick - 1, "read", pins.address, chip.o_data & 255);
            pins = next;
            chip.input.ic = pins.ic;
            chip.input.cs = pins.cs;
            chip.input.wr = pins.wr;
            chip.input.rd = pins.rd;
            chip.input.a0 = pins.address & 1;
            chip.input.a1 = (pins.address >> 1) & 1;
            chip.input.data = pins.data;
        }
        if (memory_type >= 0) FMOPNA_ClockZeroManual(&chip, int(tick & 1));
        else FMOPNA_Clock(&chip, int(tick & 1));
        if (mix_trace) {
            const bool load_left = chip.ac_da_sync2 && !chip.ac_shifter_load_l;
            const bool load_right = chip.ac_da_sync && !chip.ac_shifter_load_r;
            if (tick >= 3456) {
                const int accumulators[] = {chip.ac_fm_accm1[1], chip.ac_fm_accm2[1]};
                const bool loads[] = {load_left && !previous_load_left,
                                      load_right && !previous_load_right};
                for (int i = 0; i < 2; ++i)
                    if (loads[i]) out.emit(tick, "mix_acc", i,
                        (accumulators[i] & 0x1ffff) - (accumulators[i] & 0x20000));
                const int sources[] = {
                    (chip.ac_fm_output & 0x1ffff) - (chip.ac_fm_output & 0x20000),
                    int16_t(chip.ac_rss_sum_l), int16_t(chip.ac_rss_sum_r),
                    (chip.ac_ad_output & 0x1ffff) - (chip.ac_ad_output & 0x20000)};
                for (int i = 0; i < 4; ++i)
                    if (sources[i] != previous_mix[i]) {
                        out.emit(tick, "mix_source", i, sources[i]);
                        previous_mix[i] = sources[i];
                    }
            }
            previous_load_left = load_left;
            previous_load_right = load_right;
        }
        if (controls && tick == 3456) {
            out.irq = out.busy = -1;
            out.ssg.fill(-1);
            previous_control.fill(-1);
        }
        out.flags(tick, chip.o_irq_pull != 0, chip.busy_cnt_en[1] != 0);
        if (controls) {
            const int values[] = {chip.prescaler_sel[1], chip.reg_sch[1], chip.reg_irq[1],
                                  chip.timer_a_of[1], chip.timer_b_of[1]};
            for (int i = 0; i < 5; ++i)
                if (values[i] != previous_control[i]) {
                    out.emit(tick, i < 3 ? "mode" : "timer", i < 3 ? i : i - 3, values[i]);
                    previous_control[i] = values[i];
                }
        }
        // YM3016 consumes LSB-first serial data on S falling edges.
        if (previous_s && !chip.o_s) {
            if (previous_sh1 && !chip.o_sh1)
                out.emit(tick, "pcm", 1, int16_t(serial ^ 0x8000));
            if (previous_sh2 && !chip.o_sh2) {
                out.emit(tick, "pcm", 0, int16_t(serial ^ 0x8000));
                // Sampling drives the external DAC through OPO/S/SH2.
                // Its 8-bit trial code occupies the high byte of the word.
                if (da_feedback == 256)
                    chip.input.da = serial >> 8;
            }
            serial = uint16_t((serial >> 1) | ((chip.o_opo & 1) << 15));
            previous_sh1 = chip.o_sh1;
            previous_sh2 = chip.o_sh2;
        }
        previous_s = chip.o_s;
        int envelope = chip.ssg_hold[0] ? 31 : chip.ssg_envcnt[0];
        if ((chip.ssg_dir[0] ^ ((chip.ssg_envmode >> 2) & 1)) == 0) envelope ^= 31;
        if (chip.ssg_t2[0] && !(chip.ssg_envmode & 8)) envelope = 0;
        const int levels[] = {chip.ssg_level_a, chip.ssg_level_b, chip.ssg_level_c};
        for (int ch = 0; ch < 3; ++ch) {
            int volume = (levels[ch] & 16) ? envelope : ((levels[ch] & 15) * 2 + 1);
            const bool gate = (!(chip.ssg_mode & (1 << ch)) && (chip.ssg_sign[0] & (1 << ch))) ||
                              (!(chip.ssg_mode & (8 << ch)) && chip.ssg_noise_bit);
            if (gate) volume = 0;
            if (out.ssg[ch] != volume) {
                out.ssg[ch] = volume;
                out.emit(tick, "ssg", ch, volume);
            }
        }
        const uint32_t address_bus = (chip.o_dm & 255) | ((chip.o_a8 & 1) << 8);
        if (previous_cas && !chip.o_cas)
            memory_address = (memory_address & 0x1ff) | (address_bus << 9);
        if (previous_ras && !chip.o_ras)
            memory_address = (memory_address & 0x3fe00) | address_bus;
        const bool memory_enable = !chip.o_romcs || chip.o_mden;
        if (memory_type >= 0) {
            if (tick == 3456) {
                writable = ram;
                previous_memory_pins.fill(-1);
                previous_adpcm_flags = previous_adpcm_busy = previous_adc = -1;
                previous_limit.fill(-1);
            }
            const int pins[] = {chip.o_dm & 255, chip.o_dm_d, chip.o_a8,
                chip.o_ras, chip.o_cas, chip.o_we, chip.o_romcs, chip.o_mden};
            for (int i = 0; i < 8; ++i)
                if (pins[i] != previous_memory_pins[i]) {
                    out.emit(tick, "mem_pin", i, pins[i]);
                    previous_memory_pins[i] = pins[i];
                }
            const int flags = chip.eos_flag | (chip.brdy_flag << 1) | (chip.zero_flag << 2);
            if (flags != previous_adpcm_flags) {
                out.emit(tick, "adpcm", 0, flags);
                previous_adpcm_flags = flags;
            }
            if (chip.ad_start_l[0] != previous_adpcm_busy) {
                out.emit(tick, "adpcm", 1, chip.ad_start_l[0]);
                previous_adpcm_busy = chip.ad_start_l[0];
            }
            if ((chip.ad_ad_buf & 255) != previous_adc) {
                out.emit(tick, "adpcm", 2, chip.ad_ad_buf & 255);
                previous_adc = chip.ad_ad_buf & 255;
            }
            const int limit_values[] = {chip.ad_limit_match2[1],
                chip.ad_address_cnt[0][1] | (chip.ad_address_cnt[1][1] << 9) |
                    (chip.ad_address_cnt[2][1] << 18), chip.ad_address_cnt[3][1]};
            for (int i = 0; i < 3; ++i)
                if (limit_values[i] != previous_limit[i]) {
                    out.emit(tick, "limit", i, limit_values[i]);
                    previous_limit[i] = limit_values[i];
                }
            // Early writes latch on CAS; late writes latch on WE. DM carries
            // one byte for RAM8 or one bit on each of eight RAM1 bank lines.
            const bool write = memory_type != 0 && !chip.o_ras && !chip.o_cas &&
                !chip.o_we && !chip.o_dm_d && (previous_we || previous_cas);
            if (write) {
                if (memory_type == 1) writable.at(memory_address) = chip.o_dm & 255;
                else for (unsigned bank = 0; bank < 8; ++bank) {
                    const uint32_t bit_address = (bank << 18) | memory_address;
                    uint8_t &byte = writable.at(bit_address >> 3);
                    const uint8_t mask = uint8_t(1 << (bit_address & 7));
                    byte = uint8_t((byte & ~mask) | ((chip.o_dm & (1 << bank)) ? mask : 0));
                }
                out.emit(tick, "mem_write", int(memory_address), chip.o_dm & 255);
            }
            if (memory_enable) {
                int data = 0;
                if (memory_type != 2) data = writable.at(memory_address);
                else for (unsigned bank = 0; bank < 8; ++bank) {
                    const uint32_t bit_address = (bank << 18) | memory_address;
                    data |= ((writable.at(bit_address >> 3) >> (bit_address & 7)) & 1) << bank;
                }
                chip.input.dm = data;
                if (!previous_memory_enable || previous_memory_address != memory_address)
                    out.emit(tick, "mem_read", int(memory_address), data);
            }
        } else if (memory_enable) {
            chip.input.dm = ram.at(memory_address);
        }
        if (memory_enable) {
            chip.input.dt0 = chip.input.dm & 1;
        }
        previous_we = chip.o_we;
        previous_memory_enable = memory_enable;
        previous_memory_address = memory_address;
        previous_cas = chip.o_cas;
        previous_ras = chip.o_ras;
    }
}

int main(int argc, char **argv) {
    try {
        if (argc != 5 && argc != 7 && argc != 8)
            throw std::runtime_error("usage: reference MODEL TRACE MEMORY OUTPUT [AD_INPUT DA_FEEDBACK [MIX_TRACE]]");
        std::vector<std::pair<uint64_t, int>> ad_events;
        const bool adc_trace = argc >= 7 && argv[5][0] == '@';
        const int ad_input = argc >= 7 && !adc_trace ? std::stoi(argv[5]) : 0;
        if (adc_trace) {
            std::ifstream input(argv[5] + 1);
            if (!input) throw std::runtime_error("ADC trace open failed");
            uint64_t tick;
            int value;
            while (input >> tick >> value) {
                if (value < 0 || value > 255 || (!ad_events.empty() && tick <= ad_events.back().first))
                    throw std::runtime_error("invalid ADC event");
                ad_events.emplace_back(tick, value);
            }
            if (!input.eof() || ad_events.empty() || ad_events.front().first != 0)
                throw std::runtime_error("invalid ADC trace");
        }
        const int da_feedback = argc >= 7 ? std::stoi(argv[6]) : 0;
        const bool mix_trace = argc == 8 && std::stoi(argv[7]) == 1;
        if (ad_input < 0 || ad_input > 255 || da_feedback < 0 || da_feedback > 256)
            throw std::runtime_error("invalid digital AD/DA test input");
        Trace trace(argv[2]);
        auto memory = load_memory(argv[3]);
        Output output(argv[4]);
        const std::string model(argv[1]);
        if (model == "lle") run_lle(trace, memory, output);
        else if (model == "lle-control") run_lle(trace, memory, output, true);
        else if (model == "lle-adpcm-rom") run_lle(trace, memory, output, true, 0, ad_input, da_feedback, ad_events, mix_trace);
        else if (model == "lle-adpcm-ram8") run_lle(trace, memory, output, true, 1, ad_input, da_feedback, ad_events, mix_trace);
        else if (model == "lle-adpcm-ram1") run_lle(trace, memory, output, true, 2, ad_input, da_feedback, ad_events, mix_trace);
        else if (model == "ymfm") run_ymfm(trace, memory, output);
        else throw std::runtime_error("unknown model");
        output.file.flush();
        if (!output.file) throw std::runtime_error("output write failed");
    } catch (const std::exception &e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
    return 0;
}
