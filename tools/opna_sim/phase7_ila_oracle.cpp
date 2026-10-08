// SPDX-License-Identifier: GPL-2.0-or-later
// Replay consumed native half-cycles with the pinned LLE/manual ZERO model.
#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
extern "C" {
#include "fmopna_2608.h"
void FMOPNA_ClockZeroManual(fmopna_t *chip, int clk);
}

int main(int argc, char **argv) {
    try {
        if (argc != 3)
            throw std::runtime_error("usage: phase7_ila_oracle INPUT OUTPUT");
        std::ifstream input(argv[1]);
        std::ofstream output(argv[2]);
        if (!input || !output) throw std::runtime_error("oracle file open failed");
        output << "sample,dout,irq_n,busy,pcm_valid,pcm_left,pcm_right,"
                  "ssg_a,ssg_b,ssg_c,dm,dm_d,a8,ras_n,cas_n,we_n,romcs_n,mden\n";
        fmopna_t chip{};
        chip.input.test = 1;
        chip.input.ic = chip.input.cs = chip.input.wr = chip.input.rd = 1;
        chip.input.gpio_a = chip.input.gpio_b = 0;
        chip.input.ad = chip.input.da = 0;
        uint16_t serial = 0;
        int previous_s = 0, previous_sh1 = 0, previous_sh2 = 0;
        int left = 0, right = 0;
        uint64_t sample = 0, expected_sample = 0;
        int phase, ic, cs, wr, rd, addr, data, dm, dt0;
        while (input >> sample) {
            if (!(input >> phase >> ic >> cs >> wr >> rd >> addr >> data >> dm >> dt0))
                throw std::runtime_error("incomplete consumed-input row");
            if (sample != expected_sample++ || phase < 0 || phase > 1 ||
                ic < 0 || ic > 1 || cs < 0 || cs > 1 || wr < 0 || wr > 1 ||
                rd < 0 || rd > 1 || addr < 0 || addr > 3 ||
                data < 0 || data > 255 || dm < 0 || dm > 255 || dt0 != (dm & 1))
                throw std::runtime_error("invalid consumed-input row");
            chip.input.ic = ic;
            chip.input.cs = cs;
            chip.input.wr = wr;
            chip.input.rd = rd;
            chip.input.a0 = addr & 1;
            chip.input.a1 = (addr >> 1) & 1;
            chip.input.data = data;
            chip.input.dm = dm;
            chip.input.dt0 = dt0;
            FMOPNA_ClockZeroManual(&chip, phase);
            int valid = 0;
            // The decoder runs through the entire reset/warm prefix. IC does
            // not reset the external serial DAC or its held output words.
            if (previous_s && !chip.o_s) {
                if (previous_sh1 && !chip.o_sh1) {
                    right = int16_t(serial ^ 0x8000);
                    valid |= 2;
                }
                if (previous_sh2 && !chip.o_sh2) {
                    left = int16_t(serial ^ 0x8000);
                    valid |= 1;
                }
                serial = uint16_t((serial >> 1) | ((chip.o_opo & 1) << 15));
                previous_sh1 = chip.o_sh1;
                previous_sh2 = chip.o_sh2;
            }
            previous_s = chip.o_s;
            int envelope = chip.ssg_hold[0] ? 31 : chip.ssg_envcnt[0];
            if ((chip.ssg_dir[0] ^ ((chip.ssg_envmode >> 2) & 1)) == 0)
                envelope ^= 31;
            if (chip.ssg_t2[0] && !(chip.ssg_envmode & 8)) envelope = 0;
            const int levels[] = {chip.ssg_level_a, chip.ssg_level_b, chip.ssg_level_c};
            std::array<int, 3> volume{};
            for (int channel = 0; channel < 3; ++channel) {
                volume[channel] = (levels[channel] & 16) ? envelope :
                    ((levels[channel] & 15) * 2 + 1);
                const bool gate =
                    (!(chip.ssg_mode & (1 << channel)) && (chip.ssg_sign[0] & (1 << channel))) ||
                    (!(chip.ssg_mode & (8 << channel)) && chip.ssg_noise_bit);
                if (gate) volume[channel] = 0;
            }
            output << sample << ',' << (chip.o_data & 255) << ',' << !chip.o_irq_pull << ','
                   << (chip.busy_cnt_en[1] != 0) << ',' << valid << ',' << left << ',' << right;
            for (int value : volume) output << ',' << value;
            const int pins[] = {chip.o_dm & 255, chip.o_dm_d, chip.o_a8, chip.o_ras,
                                chip.o_cas, chip.o_we, chip.o_romcs, chip.o_mden};
            for (int value : pins) output << ',' << value;
            output << '\n';
        }
        if (!input.eof() || !expected_sample)
            throw std::runtime_error("invalid or empty consumed-input trace");
        if (!output) throw std::runtime_error("oracle output write failed");
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
