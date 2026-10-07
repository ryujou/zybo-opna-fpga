// OPNA YM2608B adaptation, modified 2026-10-07; original notices retained.
// SPDX-License-Identifier: GPL-3.0-or-later
// JT12 ADPCM-A arithmetic, Copyright (C) Jose Tejada Gomez.
// YM2608 scan/timing from YM2608-LLE, Copyright (C) 2023-2024 nukeykt.
package jt10_opna_rhythm;
    import jt10_opna_rom::*;
    typedef struct packed {
        logic [1:0][2:0] count, channel;
        logic sync, eclk1_l, eclk2_l, eclk1, eclk2, dclk_l;
        logic [1:0] fclk_select;
        logic [1:0][3:0] fm_count;
        logic fm_overflow, fm_sync;
        logic [1:0][7:0] params;
        logic [1:0] tl_select, key_dump;
        logic [1:0][5:0] tl, key_mask, ic, key, stop;
        logic [5:0] tl_l;
        logic [2:0][2:0] tl_shift;
        logic eos, step, isend;
        logic [1:0][14:0] accumulator;
        logic [1:0][16:0][14:0] registers;
        logic delta_load, index_load, count_is1;
        logic [5:0] delta_index;
        logic [14:0] index;
        logic [3:0] nibble;
        logic sample_load, shift_load;
        logic [11:0] sample;
        logic [1:0][4:0] multiply_control;
        logic [1:0][12:0] multiply_accumulator;
        logic [12:0] multiply_load;
        logic signed [12:0] shifted_sample;
        logic [2:0][1:0] pan;
        logic write_trigger0, write_trigger1;
        logic [2:0] write_latch;
        logic [1:0][15:0] mix_left, mix_right;
        logic [15:0] sum_left, sum_right;
        logic mix_load;
    } rhythm_t;

    localparam logic [63:0][10:0] STEP_SIZE = {
        11'd1552,11'd1552,11'd1552,11'd1552,11'd1552,11'd1552,11'd1552,11'd1552,
        11'd1552,11'd1552,11'd1552,11'd1552,11'd1552,11'd1552,11'd1552,11'd1552,
        11'd1411,11'd1282,11'd1166,11'd1060,11'd963,11'd876,11'd796,11'd724,
        11'd658,11'd598,11'd544,11'd494,11'd449,11'd408,11'd371,11'd337,
        11'd307,11'd279,11'd253,11'd230,11'd209,11'd190,11'd173,11'd157,
        11'd143,11'd130,11'd118,11'd107,11'd97,11'd88,11'd80,11'd73,
        11'd66,11'd60,11'd55,11'd50,11'd45,11'd41,11'd37,11'd34,
        11'd31,11'd28,11'd25,11'd23,11'd21,11'd19,11'd17,11'd16
    };
    localparam logic [7:0][12:0] START_ADDRESS = {
        13'd0,13'd0,13'h1f80,13'h1d00,13'h1b80,13'h0440,13'h01c0,13'd0
    };
    localparam logic [7:0][5:0] STEP_ADJUST = {
        6'd9,6'd7,6'd5,6'd2,6'd63,6'd63,6'd63,6'd63
    };

    function automatic rhythm_t rhythm_advance(
        input rhythm_t previous,
        input logic mclk2, reset_chip, clk1, clk2, aclk1, aclk2, dclk,
        input logic fsm_rss, fsm_rss2, fsm_sel23,
        input logic write0, write1, write_data, address10,
        input logic [8:0] bus,
        input logic [5:0][7:0] channel_registers
    );
        rhythm_t w;
        integer level, add1, add2, delta, adjust, nibble, sample;
        logic fclk1, fclk2, write3, match_channel, key_event, kon, koff;
        logic key, stop, ic, c0,c1,c2,c3,c4,c5,c6,c7,c8;
        logic [5:0] mask;
        integer i;
        w = previous;
        if (write_data) w.write_trigger0 = 1;
        else if (w.write_latch[0]) w.write_trigger0 = 0;
        if (mclk2) w.dclk_l = dclk;
        if (clk2) w.sync = !fsm_rss2;
        if (aclk1) begin
            w.count[0] = (w.count[1] == 5 || w.sync) ? 0 : w.count[1] + 3'd1;
            w.eclk1_l = w.count[1] == 2 || w.count[1] == 3;
            w.eclk2_l = w.count[1] == 5 || w.count[1] == 0;
            w.fclk_select[0] = w.count[1] == 5 || w.count[1] == 0 || w.count[1] == 1;
        end
        if (aclk2) begin
            w.count[1] = w.count[0];
            w.eclk1 = w.eclk1_l;
            w.eclk2 = w.eclk2_l;
            w.fclk_select[1] = w.fclk_select[0];
        end
        fclk1 = !w.dclk_l && aclk1 && w.fclk_select[1];
        fclk2 = !w.dclk_l && aclk2 && w.fclk_select[1];
        if (clk1) begin
            w.fm_count[0] = (w.fm_overflow || w.fm_sync) ? 0 : w.fm_count[1] + 4'd1;
            w.tl_select[0] = write0 ? bus == 9'h011 : w.tl_select[1];
            w.tl[0] = reset_chip ? 0 :
                (w.tl_select[1] && !bus[8] && write1 ? bus[5:0] : w.tl[1]);
        end
        if (clk2) begin
            w.fm_count[1] = w.fm_count[0];
            w.fm_overflow = (w.fm_count[0] & 4'd11) == 11;
            w.fm_sync = fsm_sel23;
            w.tl_select[1] = w.tl_select[0];
            w.tl[1] = w.tl[0];
        end
        if (w.eclk1)
            w.channel[0] = (reset_chip || w.channel[1] == 5 ||
                (fsm_rss && w.channel[0] == 0)) ? 0 : w.channel[1] + 3'd1;
        if (w.eclk2) w.channel[1] = w.channel[0];
        match_channel = w.fm_count[1] == w.channel[1];
        if (clk1 && match_channel) w.params[0] = channel_registers[5];
        if (w.count[1] == 3) begin
            w.params[1] = w.params[0];
            w.tl_l = w.tl[1];
            w.tl_shift[1] = w.tl_shift[0];
        end
        level = ((int'(w.params[1] & 8'h1f) | 32) + int'(w.tl_l) + 1) ^ 63;
        key = w.key[1][5];
        if (!(level & 64) || !key) level = 63;
        else level = level & 63;
        if (w.count[1] == 5) begin
            w.tl_shift[0] = level >> 3;
            w.tl_shift[2] = w.tl_shift[1];
        end
        if (aclk1) begin
            w.multiply_control[0] = w.multiply_control[1] >> 1;
            if (w.count[1] == 5 && level != 63)
                w.multiply_control[0] = w.multiply_control[0] | ((15 - (level & 7)) << 1);
            w.sample_load = w.count[1] == 5;
            w.shift_load = w.count[1] == 0;
            add1 = 0;
            if (w.multiply_control[1][0]) begin
                add1 = w.sample;
                if (add1 & 'h800) add1 = add1 | 'h1000;
            end
            add2 = 0;
            if (w.count[1] != 5) begin
                add2 = w.multiply_accumulator[1] >> 1;
                if (add2 & 'h800) add2 = add2 | 'h1000;
            end
            w.multiply_accumulator[0] = add1 + add2;
        end
        if (aclk2) begin
            w.multiply_control[1] = w.multiply_control[0];
            w.multiply_accumulator[1] = w.multiply_accumulator[0];
        end
        if (w.count[1] == 5 && !w.sample_load) begin
            w.sample = w.registers[1][16][11:0];
            w.multiply_load = w.multiply_accumulator[1];
        end
        if (w.count[1] == 0 && !w.shift_load) begin
            sample = w.multiply_load;
            if (sample & 'h1000) sample = sample | ~'h1fff;
            w.shifted_sample = sample >>> w.tl_shift[2];
        end
        if (w.eclk1) begin
            w.write_trigger1 = w.write_trigger0;
            w.write_latch[1] = w.write_latch[0];
        end
        if (w.eclk2) begin
            w.write_latch[0] = w.write_trigger1;
            w.write_latch[2] = w.write_latch[1];
        end
        write3 = w.write_latch[0] && !w.write_latch[2];
        if (w.eclk1) begin
            if (reset_chip) begin
                w.key_dump[0] = 0;
                w.key_mask[0] = 0;
            end else if (write3 && address10 && !bus[8]) begin
                w.key_dump[0] = bus[7];
                w.key_mask[0] = bus[5:0];
            end else begin
                w.key_dump[0] = w.key_dump[1];
                w.key_mask[0] = w.key_mask[1];
            end
            mask = w.key_mask[1] & (6'd1 << w.channel[1]);
            key_event = |mask;
            w.key_mask[0] = w.key_mask[0] & ~mask;
            kon = key_event && !w.key_dump[1];
            koff = key_event && w.key_dump[1];
            w.ic[0] = {w.ic[1][4:0], reset_chip};
            ic = reset_chip || (|w.ic[1]);
            w.key[0] = {w.key[1][4:0], (!ic && !koff && (w.key[1][5] || kon))};
            w.stop[0] = {w.stop[1][4:0], (!kon && (w.stop[1][5] || ic || koff || w.eos))};
        end
        if (w.eclk2) begin
            w.key_dump[1] = w.key_dump[0];
            w.key_mask[1] = w.key_mask[0];
            w.ic[1] = w.ic[0];
            w.key[1] = w.key[0];
            w.stop[1] = w.stop[0];
        end
        if (w.count[1] == 0) begin
            w.eos = w.isend;
            w.step = !w.index[0];
        end
        // The JT ADPCM-A delta is accumulated over the native six phases;
        // intermediate shifts and carries retain the YM2608 rounding.
        if (aclk1) begin
            mask = w.key_mask[1] & (6'd1 << w.channel[1]);
            kon = (|mask) && !w.key_dump[1];
            stop = w.stop[1][5];
            nibble = w.nibble;
            adjust = STEP_ADJUST[w.nibble[2:0]];
            c5 = w.count[1] == 2;
            c6 = w.count[1] == 3 || w.count[1] == 4;
            c8 = !kon && (w.count[1] == 0 || w.count[1] == 1 ||
                (w.count[1] == 5 && !w.eos));
            c0 = !kon && !w.eos && nibble[3] && w.count[1] == 5 && w.step;
            c1 = !kon && !w.eos && !nibble[3] && w.count[1] == 5 && w.step;
            c2 = !kon && w.count[1] == 1 && w.step;
            c3 = kon && w.count[1] == 0;
            c4 = !kon && !w.eos && !stop && w.count[1] == 0;
            c7 = (w.count[1] == 2 && nibble[0]) ||
                 (w.count[1] == 3 && nibble[1]) || (w.count[1] == 4 && nibble[2]);
            delta = STEP_SIZE[w.delta_index];
            add1 = 0;
            add2 = 0;
            if (c7) add1 = add1 | delta;
            if (c1) add1 = add1 | (w.accumulator[1] & 'hfff);
            if (c0) add1 = add1 | ((w.accumulator[1] & 'hfff) ^ 'hfff);
            if (c2) add1 = add1 | adjust;
            if (c3) add1 = add1 | (int'(START_ADDRESS[w.channel[1]]) << 2);
            if (c4 && w.channel[1] < 4) add1 = add1 | 1;
            if (c8) add2 = add2 | w.registers[1][16];
            if (c6) add2 = add2 | ((w.accumulator[1] >> 1) & 'h7ff);
            if (c5) add2 = add2 | (delta >> 1);
            w.accumulator[0] = add1 + add2 + (c4 || c0);
            w.delta_load = w.count[1] == 5;
            w.index_load = w.count[1] == 1;
            w.count_is1 = w.count[1] == 1;
        end
        if (aclk2) begin
            w.accumulator[1] = w.accumulator[0];
            if (w.count_is1) begin
                if (w.accumulator[0][5:0] == 6'h3f) w.accumulator[1][5:0] = 0;
                if ((w.accumulator[0] & 15'h38) == 15'h30 ||
                    (w.accumulator[0] & 15'h3c) == 15'h38) w.accumulator[1][3:0] = 0;
            end
        end
        if (w.count[1] == 5 && !w.delta_load) w.delta_index = w.registers[1][14][5:0];
        if (w.count[1] == 1 && !w.index_load) begin
            w.index = w.registers[1][14];
            case (w.index[14:2])
                13'h01bf,13'h043f,13'h1b7f,13'h1cff,13'h1f7f,13'h1fff: w.isend = 1;
                default: w.isend = 0;
            endcase
        end
        if (w.count[1] == 0) begin
            nibble = rhythm_byte(w.index[14:2]);
            w.nibble = w.index[1] ? nibble >> 4 : nibble;
        end
        if (fclk1) begin
            for (i = 1; i < 17; i = i + 1) w.registers[0][i] = w.registers[1][i-1];
            w.registers[0][0] = w.accumulator[1];
        end
        if (fclk2) w.registers[1] = w.registers[0];
        if (w.count[1] == 5) begin
            w.pan[0] = w.params[1][7:6];
            w.pan[2] = w.pan[1];
        end
        if (w.count[1] == 3) w.pan[1] = w.pan[0];
        return w;
    endfunction

    function automatic rhythm_t rhythm_mix(input rhythm_t previous);
        rhythm_t w;
        logic [15:0] sample;
        w = previous;
        if (w.eclk1) begin
            sample = {w.shifted_sample[12], w.shifted_sample[12], w.shifted_sample[11:0], 2'b0};
            w.mix_left[0] = (w.channel[1] == 0 ? 16'd0 : w.mix_left[1]) +
                (w.pan[2][1] ? sample : 16'd0);
            w.mix_right[0] = (w.channel[1] == 0 ? 16'd0 : w.mix_right[1]) +
                (w.pan[2][0] ? sample : 16'd0);
            w.mix_load = w.channel[1] == 0;
        end
        if (w.eclk2) begin
            w.mix_left[1] = w.mix_left[0];
            w.mix_right[1] = w.mix_right[0];
        end
        if (w.channel[1] == 0 && !w.mix_load) begin
            w.sum_left = w.mix_left[1];
            w.sum_right = w.mix_right[1];
        end
        return w;
    endfunction
endpackage
