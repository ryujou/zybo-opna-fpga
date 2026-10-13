// OPNA YM2608B adaptation, modified 2026-10-07; original notices retained.
// SPDX-License-Identifier: GPL-3.0-or-later
// JT49 envelope/mixer and noise polynomial, Copyright Jose Tejada Gomez.
// OPNA two-phase timing derived from YM2608-LLE, Copyright 2023-2024 nukeykt.
// Pinned sources and licenses: tools/opna_sim/sources.json.
package jt49_opna;
    typedef struct packed {
        logic [1:0] prescaler1, prescaler2, div1, div2, div3;
        logic [1:0][3:0] select;
        logic [15:0] selected_period;
        logic [7:0][11:0] count_low;
        logic [7:0][3:0] count_high;
        logic [1:0][2:0] overflow_low, overflow_env, sign;
        logic [2:0] sign_toggle;
        logic [3:0] period_high;
        logic overflow_latch, high_add, counter_reload, channel_overflow;
        logic [1:0] envelope_select;
        logic frequency_reset;
        logic [1:0][4:0] envelope_count;
        logic [1:0] direction, hold_level, finished;
        logic envelope_add, restart, restart_sampled, restart_reset, restart_select;
        logic noise_add, noise_step, noise_overflow_low, noise_bit;
        logic [1:0][5:0] noise_count;
        logic [1:0][16:0] poly17;
    } jt49_state_t;

    // Each call advances one chip half-cycle, including transparent phases.
    function automatic jt49_state_t advance(
        input jt49_state_t previous,
        input logic chip_clk, ic, divider_reset,
        input logic addr2d, addr2e, addr2f, restart_write,
        input logic [15:0][7:0] registers
    );
        jt49_state_t w;
        logic ssg_clock, count_overflow, envelope_overflow, reset_frequency;
        logic [12:0] low_sum;
        logic [5:0] envelope_sum;
        logic feedback;
        w = previous;
        if (!chip_clk) begin
            w.prescaler1[0] = (w.prescaler1[1] && !addr2f) || addr2e;
            w.prescaler2[0] = (w.prescaler2[1] && !addr2f) || addr2d || ic;
        end else begin
            w.prescaler1[1] = w.prescaler1[0] && !ic;
            w.prescaler2[1] = w.prescaler2[0];
        end
        if (!chip_clk) w.div1[0] = !w.div1[1];
        else w.div1[1] = w.div1[0];
        if (!w.div1[0]) w.div2[0] = !w.div2[1];
        else w.div2[1] = w.div2[0];
        if (!w.div2[0]) w.div3[0] = !w.div3[1];
        else w.div3[1] = w.div3[0];
        if (divider_reset) begin
            w.div1 = 0;
            w.div2 = 0;
            w.div3 = 0;
        end
        ssg_clock = w.prescaler2[1] ? (w.prescaler1[1] ? w.div2[0] : w.div3[0]) : w.div1[0];
        if (w.restart_reset) w.restart = 0;
        if (ic || restart_write) w.restart = 1;
        if (!ssg_clock) begin
            w.envelope_add = w.overflow_env[1][2] && w.select[1][3];
            w.envelope_count[1] = w.hold_level[0] ? 5'd31 : w.envelope_count[0];
            w.direction[1] = w.direction[0];
            w.hold_level[1] = w.hold_level[0];
            w.finished[1] = w.finished[0];
            w.restart_sampled = w.restart;
            w.restart_select = w.select[1][3];
            w.select[0] = {w.select[1][2:0], !(|w.select[1][2:0]) && !ic};
            w.selected_period = 0;
            if (w.select[1][0]) w.selected_period |= {registers[5], registers[4]};
            if (w.select[1][1]) w.selected_period |= {registers[3], registers[2]};
            if (w.select[1][2]) w.selected_period |= {registers[1], registers[0]};
            if (w.select[1][3]) w.selected_period |= {registers[12], registers[11]};
            // The shared counter scans C, B, A, envelope. The envelope alone
            // propagates the low 12-bit carry into a separate 4-bit ring.
            low_sum = {1'b0, w.count_low[7]} + 13'd1;
            w.count_low[0] = low_sum[11:0];
            w.count_low[4] = w.count_low[3];
            w.count_low[6] = w.count_low[5];
            w.overflow_low[1] = w.overflow_low[0];
            w.sign_toggle = w.select[1][3] ? w.overflow_low[0] : 3'd0;
            w.count_high[1] = w.count_high[0];
            w.count_high[3] = w.count_high[2];
            w.count_high[5] = w.count_high[4];
            w.count_high[7] = w.count_high[6];
            w.sign[1] = w.sign[0];
            // A zero low period makes the subtraction negative; retain the
            // signed comparison used by the native borrow circuit.
            envelope_overflow = !w.counter_reload &&
                (int'(w.period_high) - int'(w.overflow_latch) < int'(w.count_high[0]));
            w.high_add = w.select[1][3] && low_sum[12];
            w.envelope_select[0] = w.select[1][3];
            w.overflow_env[0] = {w.overflow_env[1][1:0], envelope_overflow};
            reset_frequency = w.channel_overflow ||
                ((envelope_overflow || w.counter_reload) && w.envelope_select[1]);
            w.count_low[2] = reset_frequency ? 12'd0 : w.count_low[1];
            w.frequency_reset = reset_frequency;
            w.noise_add = w.select[1][0];
            w.noise_count[1] = w.noise_count[0];
            w.noise_step = (registers[6][4:0] <= w.noise_count[0][5:1]) && w.noise_overflow_low;
        end else begin
            envelope_sum = {1'b0, w.envelope_count[1]} + w.envelope_add;
            w.envelope_count[0] = w.restart_sampled ? 5'd0 : envelope_sum[4:0];
            w.direction[0] = !w.restart_sampled &&
                (w.direction[1] ^ (envelope_sum[5] && registers[13][1] && !w.hold_level[1]));
            w.hold_level[0] = !w.restart_sampled &&
                (w.hold_level[1] || (envelope_sum[5] && registers[13][0]));
            w.finished[0] = !w.restart_sampled && (w.finished[1] || envelope_sum[5]);
            w.restart_reset = w.restart_sampled && w.restart_select;
            w.select[1] = w.select[0];
            w.count_low[1] = w.count_low[0];
            w.count_low[3] = w.count_low[2];
            w.count_low[5] = w.count_low[4];
            w.count_low[7] = w.count_low[6];
            count_overflow = w.selected_period[11:0] <= w.count_low[0];
            w.overflow_latch = count_overflow;
            w.period_high = w.selected_period[15:12];
            w.overflow_low[0] = {w.overflow_low[1][1:0], count_overflow};
            w.sign[0] = ic ? 3'd0 : w.sign[1] ^ w.sign_toggle;
            w.count_high[0] = w.count_high[7] + w.high_add;
            w.count_high[2] = w.frequency_reset ? 4'd0 : w.count_high[1];
            w.count_high[4] = w.count_high[3];
            w.count_high[6] = w.count_high[5];
            w.envelope_select[1] = w.envelope_select[0];
            w.channel_overflow = (!w.envelope_select[0] && count_overflow) || ic;
            w.counter_reload = w.envelope_select[0] && w.restart_sampled;
            w.overflow_env[1] = w.overflow_env[0];
            w.noise_count[0] = w.noise_step ? 6'd0 : w.noise_count[1] + w.noise_add;
            w.noise_overflow_low = w.noise_count[1][0] && w.noise_add;
        end
        // JT49's right-shifting polynomial mirrors the native left-shifting
        // representation. Its two latches preserve the output bit's timing.
        if (!w.noise_step) begin
            feedback = w.poly17[1][0] ^ w.poly17[1][3] ^ (w.poly17[1] == 0);
            w.poly17[0] = {feedback, w.poly17[1][16:1]};
        end else w.poly17[1] = ic ? 17'd0 : w.poly17[0];
        if (ssg_clock) w.noise_bit = w.poly17[1][0];
        advance = w;
    endfunction

    function automatic logic [2:0][4:0] levels(
        input jt49_state_t w, input logic [15:0][7:0] registers
    );
        logic [4:0] gain, envelope;
        logic invert, gate_on;
        logic [2:0][4:0] result;
        gain = w.hold_level[0] ? 5'd0 : ~w.envelope_count[0];
        invert = w.direction[0] ^ registers[13][2];
        envelope = invert ? ~gain : gain;
        if (w.finished[0] && !registers[13][3]) envelope = 0;
        for (int channel = 0; channel < 3; channel++) begin
            gate_on = (registers[7][channel] || !w.sign[0][channel]) &&
                      (registers[7][channel + 3] || !w.noise_bit);
            result[channel] = !gate_on ? 5'd0 :
                (registers[channel + 8][4] ? envelope : {registers[channel + 8][3:0], 1'b1});
        end
        levels = result;
    endfunction
endpackage
