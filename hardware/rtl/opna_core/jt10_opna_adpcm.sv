// OPNA YM2608B adaptation, modified 2026-10-07; original notices retained.
// SPDX-License-Identifier: GPL-3.0-or-later
// JT12 Delta-T arithmetic, Copyright (C) Jose Tejada Gomez.
// Native memory/DSP timing from YM2608-LLE, Copyright (C) 2023-2024 nukeykt.
package jt10_opna_adpcm;
    typedef struct packed {
        logic [15:0] selected;
        logic [15:0][7:0] reg_data;
        logic [2:0] sample_l, start_l;
        logic [1:0][2:0] read_port_l, write_port_l;
        logic [1:0][1:0] rw_l;
        logic rw_en;
        logic [1:0] rec_start_l, w2, w4, address_end_l2;
        logic [1:0][4:0] w2_l;
        logic address_end_l;
        logic [1:0][1:0] w12;
        logic [1:0] w13, mode6_l, code_end, code_ed_end;
        logic [1:0][5:0] mem_sync, mem_code_ptr, mem_cond;
        logic mem_sync_run;
        logic [5:0] mem_ptr_store;
        logic [13:0] mem_ctrl, mem_ctrl_l;
        logic [1:0][3:0] end_sel, stop_match, limit_match;
        logic [1:0][2:0] start_sel;
        logic [1:0] stop_match2, limit_match2, address_carry;
        logic [3:0][1:0][8:0] address_count;
        logic [8:0] mem_bus;
        logic [7:0] mem_data_l1, mem_data_l2, mem_data_l3, mem_data_bus;
        logic [1:0][7:0] mem_data_l4;
        logic [2:0] mem_addr_bank;
        logic [1:0][2:0] mem_bit_count, mem_shift_count, mem_ucount;
        logic [1:0] mem_shift_zero_l, mem_en_l, mem_stop;
        logic [1:0] mem_w7, mem_w8, mem_w10, mem_w15, mem_w17, mem_w20;
        logic [1:0][1:0] mem_rw_en;
        logic [1:0] brdy_set_l, mem_we, mem_cas, mem_ras;
        logic mem_w21, mem_w22, mem_dir;
        logic [3:0] mem_nibble;
        logic mem_nibble_msb, mem_nibble_load;
        logic [1:0][6:0] code_ptr;
        logic [20:0] code_ctrl, code_ctrl_l;
        logic [2:0] code_reg_id, code_sync;
        logic [3:0] dsp_ctrl;
        logic [7:0] dsp_bus;
        logic [1:0] dsp_carry_mode, dsp_enc_bit_l, dsp_vol_o, dsp_delta_sel;
        logic dsp_enc_bit;
        logic [1:0][1:0] dsp_w30_l;
        logic [1:0][2:0] dsp_w31_l;
        logic [8:0] dsp_w32, dsp_w32_l;
        logic [7:0] dsp_w33, dsp_w34;
        logic [1:0][7:0] dsp_w36;
        logic dsp_w35_l;
        logic [1:0][2:0] dsp_count1;
        logic [1:0][1:0] dsp_count1_run;
        logic [1:0][7:0] dsp_mul_acc1;
        logic [7:0] dsp_mul_acc1_add1, dsp_mul_acc1_add2;
        logic dsp_mul_acc1_c, dsp_mul_acc2_load;
        logic [8:0] dsp_mul_acc2, dsp_mul_acc2_add1, dsp_mul_acc2_add2;
        logic [1:0][1:0] dsp_w38, dsp_w41, dsp_w43;
        logic [15:0] dsp_w40, dsp_w45;
        logic [12:0] sample;
        logic [1:0][1:0] dsp_count2, dsp_load_alu1, dsp_load_alu2;
        logic dsp_load_alu1_h;
        logic [15:0] dsp_alu_in1, dsp_alu_in2, dsp_alu_result;
        logic [1:0] dsp_load_result, dsp_alu_mask, dsp_alu_neg, dsp_read_result;
        logic [1:0] dsp_w46, dsp_w52, dsp_w69;
        logic dsp_ctrl10_l, dsp_alu_overflow;
        logic [1:0] dsp_alu_shift;
        logic [1:0][1:0][7:0] dsp_sregs2;
        logic [7:0][7:0] dsp_regs;
        logic [7:0] dsp_regs_out;
        logic [1:0][3:0] adc_count1;
        logic [1:0][4:0] adc_count2;
        logic [1:0][10:0] adc_count3;
        logic [1:0] adc_count3_overflow, adc_count3_enable;
        logic adc_count3_load;
        logic [10:0] adc_count3_load_value;
        logic adc_compare, adc_w55, adc_w56, adc_w60;
        logic [1:0] adc_w53, adc_w55_l, adc_w62;
        logic [2:0] adc_w57, adc_w58;
        logic [1:0][7:0] adc_w61;
        logic [1:0][6:0] adc_w66;
        logic [6:0] adc_w65_l, adc_w68;
        logic [7:0] adc_shift, adc_buf, adc_input, adc_dac;
        logic adc_quiet, set_eos;
        logic eos_flag, brdy_flag, zero_flag, zero_set, eos_repeat, irq_eos_l;
        logic [1:0] eos_l;
        logic [1:0][23:0] dac_shift;
        logic [1:0] dac_w70, dac_set, dac_bit;
        logic adc_bit;
    } adpcm_t;

    localparam logic [7:0][7:0] DELTA_ADJUST = {
        8'd153,8'd128,8'd102,8'd77,8'd57,8'd57,8'd57,8'd57
    };

    function automatic adpcm_t adpcm_advance(
        input adpcm_t previous,
        input logic reset_chip, clk1, clk2, cclk1, cclk2,
        input logic write2, write3, read3, fsm_sel23,
        input logic [8:0] bus,
        input logic [7:0] memory_data,
        input logic memory_dt0,
        input logic [7:0] adc_input, adc_feedback
    );
        adpcm_t w;
        logic start, rec, memdata, repeat_enable, rom, ramtype, reset;
        logic mode1,mode2,mode3,mode4,mode5,mode6,mode7,mode8,mode9,mode10,mode11;
        logic code_end, repeat_event, w28,w6,sync,w16,w18,p5,w19,p1,p2,p3,p4,w23,w24,w25,w26,w27,w29;
        logic t1,t2,read_sample,write_sample,mem_enable,nibble_load,write8,read8;
        logic w30,w31,w44,w35_l,w37,w39,b8,w42,w47,w48,w49,w51,w54,w59;
        logic neg,c1,c2,b15_i1,b15_i2,b15_s,carry,clip_high,clip_low;
        integer cond,next_ptr,cond_next,ctrl,store_addr,stop_value,limit_value,start_value;
        integer add,mask,data1,data2,data3,data4,nibble,acc1,acc2,count1,w35;
        integer i1,i2,sum,shift,shift2,w63,w64,w67;
        integer i;
        w = previous;
        if (write2) w.selected = 16'd1 << bus[7:0];
        if (reset_chip) begin
            w.reg_data[0] = 0;
            w.reg_data[1] = 0;
        end else if (write3) begin
            if (w.selected[0]) w.reg_data[0] = bus[7:0] & 8'hf9;
            if (w.selected[1]) w.reg_data[1] = bus[7:0] & 8'hcf;
        end
        if (write3) begin
            for (i = 2; i < 14; i = i + 1)
                if (w.selected[i] && i != 8) w.reg_data[i] = bus[7:0];
            if (w.selected[7]) w.reg_data[7] = bus[2:0];
            if (w.selected[14]) w.reg_data[14] = bus[7:0] ^ 8'h80;
        end
        start = w.reg_data[0][7]; rec = w.reg_data[0][6];
        memdata = w.reg_data[0][5]; repeat_enable = w.reg_data[0][4];
        rom = w.reg_data[1][0]; ramtype = w.reg_data[1][1];
        reset = w.reg_data[0][0] || reset_chip;
        mode1 = memdata && rec && !w.start_l[2] && w.w2_l[1][4] && w.write_port_l[1][2];
        mode2 = !w.start_l[2] && w.w2_l[1][4];
        mode3 = !memdata && !w.start_l[2];
        mode4 = memdata && w.start_l[2] && w.w2_l[1][4];
        mode5 = memdata && rec && w.start_l[2];
        mode6 = memdata && !rec && w.start_l[2];
        mode7 = !ramtype && rom && memdata && !rec && !w.start_l[2] &&
            w.w2_l[1][4] && w.read_port_l[1][2];
        mode8 = !memdata && !rec && w.start_l[2] && w.write_port_l[1][2];
        mode9 = ramtype && !rom && memdata && !rec && !w.start_l[2] &&
            w.w2_l[1][4] && w.read_port_l[1][2];
        mode10 = !memdata && rec && w.start_l[2] && w.read_port_l[1][2];
        mode11 = !ramtype && !rom && memdata && !rec && !w.start_l[2] &&
            w.w2_l[1][4] && w.read_port_l[1][2];
        code_end = w.code_end[1] && w.w2_l[1][4];
        repeat_event = repeat_enable && code_end && !w.code_ed_end[1];
        w28 = repeat_event || (!w.mode6_l[1] && mode6);
        w6 = mode7 || mode9 || (w28 && ((!rom && ramtype) || (!ramtype && rom)));
        sync = w.mem_sync_run || !w.mem_w20[1];
        w16 = !w.mem_w10[1] && sync;
        w18 = !(w.mem_w17[1] && (sync || !memdata));
        p5 = w.code_ctrl_l[0] && !rec && w.start_l[2] && (w16 || !memdata);
        w19 = !(w18 && w.start_l[2] && !p5);
        p1 = rec && w16 && w19 && memdata && w.mem_w15[1];
        p2 = !rec && w16 && w19 && memdata && w.mem_w15[1];
        p3 = rec && !w18;
        p4 = (!rec && (w16 || !memdata) && !w18) || p5;
        w23 = p1 || p2;
        w24 = (p4 && !memdata) || (!w.start_l[2] && p1);
        w25 = p2 || p3;
        w26 = mode5 && !w.rec_start_l[1];
        w27 = mode11 || (!rom && w28 && !ramtype);
        w29 = w28 || w26 || mode10 || mode8;
        if (cclk1) begin
            w.sample_l[1] = w.sample_l[0];
            read_sample = read3 && w.selected[8];
            write_sample = write3 && w.selected[8];
            w.read_port_l[0] = {w.read_port_l[1][1:0], read_sample};
            w.write_port_l[0] = {w.write_port_l[1][1:0], write_sample};
            w.rw_l[1] = w.rw_l[0];
            w.start_l[1] = w.start_l[0];
            t1 = !w.address_end_l2[1] || w.address_end_l;
            w.w2[0] = (w.w2[1] && t1) || (w.rw_en && w.w4[1]) ||
                (t1 && (reset || (w.address_end_l && rec) || (w.w4[1] && w.start_l[2])));
            w.w4[0] = (w.w4[1] && t1) || (w.address_end_l && rec) || (w.address_end_l && p2);
            w.w2_l[0] = {w.w2_l[1][3:0],w.w2[1]};
            w.address_end_l2[0] = w.address_end_l;
            w.w12[0] = {w.w12[1][0], (mode2 || mode3 || mode4)};
            w.w13[0] = w.w12[1] == 1;
            w.mode6_l[0] = mode6;
            w.code_ed_end[0] = code_end;
        end
        if (cclk2) begin
            w.sample_l[0] = w.reg_data[1][3];
            w.sample_l[2] = w.sample_l[1];
            w.read_port_l[1] = w.read_port_l[0];
            w.write_port_l[1] = w.write_port_l[0];
            w.rw_l[0] = {w.rw_l[1][0], (w.read_port_l[0][0] || w.write_port_l[0][0])};
            w.rw_en = !w.rw_l[0][0] && w.rw_l[0][1];
            w.rec_start_l[1] = w.rec_start_l[0];
            w.start_l[0] = start;
            w.start_l[2] = w.start_l[1];
            w.w2[1] = w.w2[0]; w.w4[1] = w.w4[0]; w.w2_l[1] = w.w2_l[0];
            w.address_end_l = w.stop_match2[0];
            w.address_end_l2[1] = w.address_end_l2[0];
            w.w12[1] = w.w12[0]; w.w13[1] = w.w13[0];
            w.mode6_l[1] = w.mode6_l[0]; w.code_ed_end[1] = w.code_ed_end[0];
        end
        cond = 0;
        if (cclk1) begin
            w.mem_sync[0] = (reset_chip || w.mem_ctrl_l[6]) ? 6'd0 :
                w.mem_sync[1] + w.mem_sync_run;
            cond_next = (mode1 ? 1 : 0) | (w26 ? 2 : 0) | (w27 ? 4 : 0) |
                (w6 ? 8 : 0) | (w23 ? 16 : 0);
            if (sync) cond = w.mem_cond[1];
            else cond_next = cond_next | w.mem_cond[1];
            if (!(cond & 15)) cond = cond | 32;
            w.mem_cond[0] = cond_next;
            next_ptr = 0; store_addr = 0; ctrl = 0;
            case (w.mem_code_ptr[1][3:0])
                0,1,2: ctrl = 14'b00100000000000;
                3: ctrl = 14'b10011000000000;
                4: ctrl = 14'b10111000010000;
                5: ctrl = 14'b11010000000000;
                6: ctrl = 14'b11110000000000;
                7: ctrl = 14'b11000000000001;
                8: ctrl = 14'b11100000000001;
            endcase
            case (w.mem_code_ptr[1])
                6'h09: ctrl = ctrl | 14'b11100000000010;
                6'h0a: ctrl = ctrl | 14'b11000010000000;
                6'h0b: ctrl = ctrl | 14'b00000110000000;
                6'h0d,6'h1b: begin
                    if (sync) begin
                        if (w.stop_match2[1]) next_ptr = next_ptr | 'h7f;
                        if (!w.mem_w22 || (cond & 16)) begin
                            next_ptr = next_ptr | (w.mem_code_ptr[1] == 6'h0d ? 'h44 : 'h54);
                            ctrl = ctrl | 14'b10011000000000;
                        end
                        if (!(cond & 16) && w.mem_w22)
                            next_ptr = next_ptr | (w.mem_code_ptr[1] == 6'h0d ? 'h4d : 'h5b);
                    end else begin
                        next_ptr = 'h7a; ctrl = ctrl | 14'b00100000000000; store_addr = 1;
                    end
                end
                6'h19: ctrl = ctrl | 14'b00100100001000;
                6'h29: ctrl = ctrl | 14'b00100000000100;
                6'h2b: begin
                    if (sync) begin
                        if (w.stop_match2[1]) next_ptr = next_ptr | 'h7f;
                        if (!(cond & 16)) next_ptr = next_ptr | 'h6b;
                        else begin next_ptr = next_ptr | 'h64; ctrl = ctrl | 14'b10011000000000; end
                    end else begin
                        next_ptr = 'h7a; ctrl = ctrl | 14'b00100000000000; store_addr = 1;
                    end
                end
                6'h3a,6'h3b: ctrl = ctrl | 14'b00100000000000;
                6'h3c: ctrl = ctrl | 14'b10011000000000;
                6'h3d: ctrl = ctrl | 14'b00111001000000;
                6'h2f: begin
                    if (sync) begin
                        if (!(cond & 16)) next_ptr = 'h6f;
                        else begin next_ptr = 'h40; ctrl = ctrl | 14'b00100000100000; end
                    end else begin
                        next_ptr = 'h7a; ctrl = ctrl | 14'b00100000000000; store_addr = 1;
                    end
                end
                6'h3f: begin
                    if (sync) begin
                        if (cond & 1) begin next_ptr = next_ptr | 'h40; ctrl = 14'b00100000100000; end
                        if (cond & 2) next_ptr = next_ptr | 'h6f;
                        if (cond & 4) begin next_ptr = next_ptr | 'h50; ctrl = 14'b00100000100000; end
                        if (cond & 8) begin next_ptr = next_ptr | 'h60; ctrl = 14'b00100000100000; end
                        if (cond & 32) next_ptr = next_ptr | 'h7f;
                    end else begin
                        next_ptr = 'h7a; ctrl = ctrl | 14'b00100000000000; store_addr = 1;
                    end
                end
            endcase
            if (w.mem_ctrl_l[6]) next_ptr = next_ptr | w.mem_ptr_store | 'h40;
            if (reset_chip) next_ptr = next_ptr | 'h7f;
            w.mem_code_ptr[0] = (next_ptr & 64) ? next_ptr & 63 : w.mem_code_ptr[1] + 6'd1;
            if (store_addr) w.mem_ptr_store = w.mem_code_ptr[1];
            w.mem_ctrl = ctrl;
        end
        if (cclk2) begin
            w.mem_code_ptr[1] = w.mem_code_ptr[0]; w.mem_ctrl_l = w.mem_ctrl;
            w.mem_cond[1] = w.mem_cond[0]; w.mem_sync[1] = w.mem_sync[0];
            w.mem_sync_run = (w.mem_sync[0] & 6'd40) != 40;
        end
        if (cclk1) begin
            stop_value = 0; limit_value = 0; start_value = 0;
            w.end_sel[0] = w.end_sel[1];
            if (w.end_sel[1][0]) begin
                stop_value = ((int'(w.reg_data[4] & 8'h0f)) << 5) | 31;
                limit_value = ((int'(w.reg_data[12] & 8'h0f)) << 5) | 31;
            end
            if (w.end_sel[1][2]) begin
                stop_value = stop_value | ((int'(w.reg_data[5] & 8'h1f) << 4) | (w.reg_data[4] >> 4));
                limit_value = limit_value | ((int'(w.reg_data[13] & 8'h1f) << 4) | (w.reg_data[12] >> 4));
            end
            if (w.end_sel[1][3]) begin
                stop_value = stop_value | (w.reg_data[5] >> 5);
                limit_value = limit_value | (w.reg_data[13] >> 5);
            end
            w.stop_match[0] = {w.stop_match[1][2:0], stop_value == w.address_count[3][1]};
            w.limit_match[0] = {w.limit_match[1][2:0], limit_value == w.address_count[3][1]};
            w.stop_match2[0] = (((w.stop_match[0] & 4'd11) == 11 && w.end_sel[1][3]) ||
                w.stop_match2[1]) && !(w.mem_cond[1][1] || w.start_sel[1][0]);
            w.stop_match2[0] = w.stop_match2[0] || reset;
            w.limit_match2[0] = (w.limit_match[0] & 4'd11) == 11 && w.end_sel[1][3];
            w.start_sel[0] = w.start_sel[1];
            if (w.start_sel[1][0]) start_value = int'(w.reg_data[2] & 8'h0f) << 5;
            if (w.start_sel[1][1]) start_value = start_value |
                (int'(w.reg_data[3] & 8'h1f) << 4) | (w.reg_data[2] >> 4);
            if (w.start_sel[1][2]) start_value = start_value | (w.reg_data[3] >> 5);
            for (i = 0; i < 4; i = i + 1) w.address_count[i][0] = 0;
            add = w.address_count[3][1] + (w.mem_ctrl_l[9] || w.address_carry[1]);
            carry = ((add >> 9) & 1) && !w.mem_ctrl_l[6];
            add = add & 'h1ff;
            if (!w.limit_match2[1]) begin
                if (w.mem_ctrl_l[11]) begin
                    w.address_count[0][0] = (|w.start_sel[1]) ? start_value : add;
                    w.address_count[1][0] = w.address_count[0][1];
                    w.address_count[2][0] = w.address_count[1][1];
                end else if (!reset_chip) begin
                    for (i = 0; i < 3; i = i + 1) w.address_count[i][0] = w.address_count[i][1];
                end
            end
            if (w.mem_ctrl_l[11]) w.address_count[3][0] = w.address_count[2][1];
            else if (!reset_chip) w.address_count[3][0] = w.address_count[3][1];
            w.address_carry[0] = w.mem_ctrl_l[11] ? carry : w.address_carry[1];
        end
        if (cclk2) begin
            w.end_sel[1] = {w.end_sel[0][2:0], w.mem_ctrl[4]};
            w.start_sel[1] = {w.start_sel[0][1:0], w.mem_ctrl[5]};
            w.stop_match[1] = w.stop_match[0]; w.limit_match[1] = w.limit_match[0];
            w.stop_match2[1] = w.stop_match2[0]; w.limit_match2[1] = w.limit_match2[0];
            for (i = 0; i < 4; i = i + 1) w.address_count[i][1] = w.address_count[i][0];
            w.address_carry[1] = w.address_carry[0];
        end
        if (cclk1) begin
            if (w.mem_ctrl_l[0]) w.mem_addr_bank = w.address_count[3][1][2:0];
            data1 = w.mem_ctrl_l[0] ? ((w.mem_bus & 9'h0fe) | memory_dt0) : 0;
            if (w.mem_ctrl_l[1]) begin
                if (ramtype) data1 = data1 | w.mem_data_l2;
                else if (w.mem_data_l2[w.mem_bit_count[1]]) data1 = data1 | 255;
            end
            if ((w.mem_ctrl_l[1] && ramtype) || w.mem_ctrl_l[0]) w.mem_data_l1 = data1;
            else if (w.mem_ctrl_l[1]) begin
                mask = 1 << w.mem_addr_bank;
                w.mem_data_l1 = (w.mem_data_l1 & ~mask) | (mask & data1);
            end
            w.mem_bit_count[0] = w.mem_ctrl_l[5] ? 3'd0 :
                w.mem_bit_count[1] + (!ramtype && w.mem_ctrl_l[8]);
            data2 = p1 ? w.mem_data_bus : 0;
            if (w.mem_ctrl_l[2]) data2 = data2 | w.mem_data_l1;
            if (w.mem_ctrl_l[3] && w.mem_data_l1[w.mem_addr_bank]) data2 = data2 | 255;
            if (w.mem_ctrl_l[2] || p1) w.mem_data_l2 = data2;
            else if (w.mem_ctrl_l[3]) begin
                mask = 1 << w.mem_bit_count[1];
                w.mem_data_l2 = (w.mem_data_l2 & ~mask) | (mask & data2);
            end
            data4 = p4 ? w.mem_data_bus : (w.mem_w7[1] ?
                ((int'(w.mem_data_l4[1] & 8'h7f) << 1) | !w.dsp_enc_bit) : w.mem_data_l4[1]);
            w.mem_data_l4[0] = data4;
            w.mem_w7[0] = w.code_ctrl_l[12]; w.mem_w8[0] = w.code_ctrl_l[11];
            add = w.mem_shift_count[1] + w.mem_w7[1];
            w.mem_shift_count[0] = w.start_l[2] ? add & 7 : 0;
            w.mem_shift_zero_l[0] = w.mem_shift_count[1][1:0] == 0;
            mem_enable = w.start_l[2] && memdata;
            w.mem_en_l[0] = mem_enable;
            w.mem_stop[0] = !mem_enable && w.mem_en_l[1];
            w.mem_w10[0] = (mem_enable && !w.mem_en_l[1] && !rec) ||
                (!memdata && w.start_l[2]) || repeat_event || w23 ||
                (w.mem_w10[1] && !(reset || w.mem_stop[1] || w.w13[1] || w.mem_w21));
            w.mem_w15[0] = mem_enable || w.rw_en || (w.mem_w15[1] &&
                !(reset || w.mem_stop[1] || w.w13[1] || w16 || (!memdata && (p3 || p4))));
            w.brdy_set_l[0] = memdata ? (!w.mem_w15[1] && w16) : !w.mem_w15[1];
            w.mem_w17[0] = (add & 8) != 0 || (w.mem_w17[1] && w18);
            w.mem_rw_en[0] = {w.mem_rw_en[1][0],w.rw_en};
            w.mem_w20[0] = w.mem_rw_en[1][1] || w.start_l[2] || reset ||
                (w.mem_w20[1] && ((cond & 32) != 0));
            w.mem_ucount[0] = w.mem_ctrl_l[5] ? 3'd0 :
                w.mem_ucount[1] + (!ramtype && w.mem_ctrl_l[8]);
            w.mem_we[0] = w.mem_ctrl_l[7]; w.mem_cas[0] = w.mem_ctrl_l[12];
            w.mem_ras[0] = w.mem_ctrl_l[13];
        end
        if (cclk2) begin
            w.mem_bit_count[1] = w.mem_bit_count[0]; w.mem_data_l4[1] = w.mem_data_l4[0];
            w.mem_w7[1] = w.mem_w7[0]; w.mem_w8[1] = w.mem_w8[0];
            w.mem_shift_count[1] = w.mem_shift_count[0]; w.mem_shift_zero_l[1] = w.mem_shift_zero_l[0];
            w.mem_en_l[1] = w.mem_en_l[0]; w.mem_stop[1] = w.mem_stop[0];
            w.mem_w10[1] = w.mem_w10[0]; w.mem_w15[1] = w.mem_w15[0];
            w.brdy_set_l[1] = w.brdy_set_l[0]; w.mem_w17[1] = w.mem_w17[0];
            w.mem_rw_en[1] = w.mem_rw_en[0]; w.mem_ucount[1] = w.mem_ucount[0];
            w.mem_w20[1] = w.mem_w20[0];
            w.mem_w21 = w.mem_ctrl[2] || (ramtype && w.mem_ctrl[8]) ||
                (!ramtype && w.mem_ctrl[8] && w.mem_ucount[0] == 7);
            w.mem_w22 = w.mem_ucount[0] == 0;
            w.mem_we[1] = w.mem_we[0]; w.mem_cas[1] = w.mem_cas[0]; w.mem_ras[1] = w.mem_ras[0];
            w.mem_dir = w.mem_ctrl[7] || w.mem_ctrl[10];
        end
        nibble_load = rec ? (w.mem_shift_count[1][1:0] == 0 && !w.mem_shift_zero_l[1]) :
            (w.mem_shift_count[1][1:0] == 0 && w.mem_w7[1]);
        if (cclk1) w.mem_nibble_load = nibble_load;
        if (nibble_load && !w.mem_nibble_load)
            w.mem_nibble = rec ? (w.mem_data_l4[1][3:0] ^ 4'd8) : w.mem_data_l4[1][7:4];
        w.mem_nibble_msb = w.mem_w8[1] && w.mem_nibble[3];
        write8 = w.selected[8] && write3; read8 = w.selected[8] && read3;
        if (write8 || w25) w.mem_data_l3 = (write8 ? bus[7:0] : 8'd0) |
            (w25 ? w.mem_data_bus : 8'd0);
        if (!w.mem_dir) w.mem_bus = {1'b0,memory_data};
        if (w.mem_ctrl_l[10]) w.mem_bus = w.address_count[3][1];
        if (w.mem_ctrl_l[7]) w.mem_bus = {1'b0,w.mem_data_l1};
        if (p2) w.mem_data_bus = w.mem_data_l2;
        if (w24) w.mem_data_bus = w.mem_data_l3;
        if (p3) w.mem_data_bus = w.mem_data_l4[1] ^ 8'h88;
        if (cclk1) begin
            w44 = w.dsp_count1_run[1] == 0;
            next_ptr = 0; ctrl = 0; carry = 0; t1 = 0;
            case (w.code_ptr[1])
                7'h3f,7'h7f: begin
                    if (w29) begin ctrl = 21'b000100000011110011001; next_ptr = 'h32; end
                    else next_ptr = 'h3f;
                end
                7'h32,7'h72: ctrl = 21'b000100000001110111001;
                7'h33,7'h73: ctrl = 21'b000100000000110111101;
                7'h34,7'h74: ctrl = 21'b000100000000110011011;
                7'h35,7'h75: ctrl = 21'b000100000000110111011;
                7'h36,7'h76: ctrl = 21'b000100000000010011100;
                7'h3b: next_ptr = 'h31;
                7'h77: ctrl = 21'b000100000000110011111;
                7'h78: ctrl = 21'b000100000000110111111;
                7'h79: ctrl = 21'b000000000000110011001;
                7'h7a: if (!p5) begin next_ptr = 'h3a; ctrl = 21'b000000000000110011001; end
                7'h7b: begin
                    if (w.code_sync[2]) begin ctrl = 21'b000000100010110010000; next_ptr = 7; end
                    else next_ptr = 'h3b;
                end
                7'h41: ctrl = 21'b100000000000110110010;
                7'h42: ctrl = 21'b000001000000000001000;
                7'h43: ctrl = 21'b000000000000100000000;
                7'h44: ctrl = 21'b001100000000100000010;
                7'h45: ctrl = 21'b000100000000100100010;
                7'h46: begin
                    if (w.dsp_alu_overflow) ctrl = 21'b000000100010110010000;
                    else begin next_ptr = 'h24; ctrl = 21'b100000000000010101010; end
                end
                7'h48: ctrl = 21'b100001000000000000000;
                7'h49: ctrl = 21'b100000000000000100000;
                7'h4a: ctrl = 21'b011000001011000000000;
                7'h4b: ctrl = 21'b000000000001010000000;
                7'h4c: ctrl = 21'b000000000000000011000;
                7'h4d: ctrl = 21'b100001001000000000100 |
                    (w.mem_data_l4[0][7] ? 21'b000000100000000000000 : 21'd0);
                7'h4e: ctrl = 21'b100000000000010110100;
                7'h4f,7'h50,7'h53,7'h54:
                    if (!w.mem_data_l4[0][7]) ctrl = 21'b000000000000000010000;
                7'h51,7'h55: ctrl = 21'b011000101000100011000;
                7'h52,7'h56: ctrl = 21'b000000000000010010000;
                7'h58: ctrl = 21'b011001000000010010000;
                7'h5a: begin ctrl = 21'b100000100100010010110; carry = 1; end
                7'h5b: begin ctrl = 21'b100000000100000100110; carry = 1; end
                7'h5c: begin ctrl = 21'b001100000100000000000; carry = 1; end
                7'h5d: begin ctrl = 21'b000100000100000100000; carry = 1; end
                7'h5e: ctrl = 21'b000000000100010000000;
                7'h5f: ctrl = 21'b001100000100000000110;
                7'h60: ctrl = 21'b000100000000000100110;
                7'h61: ctrl = 21'b000100000000001000100;
                7'h62: ctrl = 21'b000100000000000100100;
                7'h63: ctrl = 21'b100000000000010101010;
                7'h64: ctrl = 21'b100000000000000000000;
                7'h65: ctrl = 21'b100000000000000100000;
                7'h66: ctrl = 21'b000000100010000000000;
                7'h69: begin
                    if (!w44) next_ptr = 'h29;
                    else ctrl = 21'b000001000000111010000;
                end
                7'h6b: begin ctrl = 21'b000000000000110001000; t1 = 1; end
                7'h6c: ctrl = 21'b001000000000000000000;
                7'h6f: begin
                    if (w.w12[1][0]) next_ptr = 'h3f;
                    if (w.code_sync[2]) begin
                        next_ptr = next_ptr | 1; ctrl = 21'b100000100000000000010;
                    end else next_ptr = next_ptr | 'h2f;
                end
            endcase
            if (!rec) next_ptr = next_ptr | 64;
            if (reset) next_ptr = next_ptr | 63;
            w.code_ptr[0] = (next_ptr & 63) ? next_ptr : w.code_ptr[1] + 7'd1;
            w.code_end[0] = w.code_ptr[1][5:0] == 63;
            w.dsp_carry_mode[0] = carry; w.dsp_enc_bit_l[0] = w.dsp_enc_bit;
            w.dsp_vol_o[0] = t1; w.code_ctrl = ctrl;
        end
        if (cclk2) begin
            w.code_ptr[1] = w.code_ptr[0]; w.code_end[1] = w.code_end[0];
            w.code_ctrl_l = w.code_ctrl;
            w.dsp_ctrl = {w.code_ctrl[8:7], w.code_ctrl[4:3]};
            w.dsp_carry_mode[1] = w.dsp_carry_mode[0];
            w.dsp_enc_bit_l[1] = w.dsp_enc_bit_l[0];
            w.code_reg_id = {w.code_ctrl[1],w.code_ctrl[2],w.code_ctrl[5]};
            w.dsp_vol_o[1] = w.dsp_vol_o[0];
        end
        w30 = w.dsp_ctrl == 5 || w.dsp_ctrl == 13;
        w31 = w30 || w.dsp_ctrl == 3;
        w35 = w.dsp_w36[1];
        if (w.dsp_w31_l[1][1]) w35 = w35 | w.dsp_w33;
        count1 = w.dsp_w31_l[1][1] ? 0 : (w.dsp_count1[1] + w.dsp_count1_run[1][0]) & 7;
        if (w.dsp_ctrl == 1) w.dsp_bus = w.reg_data[9];
        if (w.dsp_delta_sel[1]) w.dsp_bus = w.reg_data[10];
        if (w.code_ctrl_l[6]) w.dsp_bus = w.dsp_w45[7:0];
        if (w.dsp_w46[1]) w.dsp_bus = w.dsp_w45[15:8];
        if (w.dsp_ctrl == 3) w.dsp_bus = DELTA_ADJUST[w.mem_nibble[2:0]];
        if (w.code_ctrl_l[18]) w.dsp_bus = w.dsp_alu_result[7:0];
        if (w.dsp_read_result[1]) w.dsp_bus = w.dsp_alu_result[15:8];
        if (w.code_ctrl_l[13]) w.dsp_bus = w.adc_buf;
        if (w.dsp_vol_o[1]) w.dsp_bus = w.reg_data[11];
        if (!w.code_ctrl_l[9] && w.dsp_w69[1]) w.dsp_bus = w.dsp_sregs2[0][1];
        if (!w.code_ctrl_l[9] && w.code_ctrl_l[10]) w.dsp_bus = w.dsp_sregs2[1][1];
        if (w.dsp_ctrl == 7) w.dsp_bus = 127;
        if (w.dsp_ctrl == 15) w.dsp_bus = 0;
        if (cclk1) begin
            w.dsp_delta_sel[0] = w.dsp_ctrl == 1;
            w.dsp_w30_l[0] = {w.dsp_w30_l[1][0],w30};
            w.dsp_w31_l[0] = {w.dsp_w31_l[1][1:0],w31};
            w.dsp_w36[0] = w35 >> 1; w.dsp_w35_l = w35 & 1;
            w.dsp_count1[0] = count1; w.dsp_count1_run[0] = w.dsp_count1_run[1];
            acc2 = int'(w.dsp_mul_acc2_add1) + int'(w.dsp_mul_acc2_add2) + w.dsp_mul_acc1_c;
            w.dsp_mul_acc1_add1 = (w35 & 1) ? w.dsp_w34 : 8'd0;
            w.dsp_mul_acc1_add2 = count1 ? ((w.dsp_mul_acc1[0] >> 1) | ((acc2 & 1) << 7)) : 0;
            w.dsp_mul_acc1[1] = w.dsp_mul_acc1[0]; w.dsp_w32_l = w.dsp_w32;
            w.dsp_mul_acc2_load = count1 != 0; w.dsp_mul_acc2 = acc2 & 'h1ff;
            w.dsp_w38[0] = {w.dsp_w38[1][0],(count1 != 0 && w.dsp_mul_acc1[0][0])};
            w.dsp_w41[0] = {w.dsp_w41[1][0], w.dsp_ctrl == 11};
            w.dsp_w43[0] = {w.dsp_w43[1][0], w.dsp_count1_run[1] == 2};
            w.dsp_w46[0] = w.code_ctrl_l[6];
            w.dsp_count2[0] = w.dsp_ctrl == 14 ? 2'd0 : w.dsp_count2[1] + (w.dsp_ctrl == 6);
            w.dsp_ctrl10_l = w.dsp_ctrl == 10;
            w.dsp_load_alu1[0] = {w.dsp_load_alu1[1][0],w.code_ctrl_l[14]};
            w.dsp_load_alu2[0] = {w.dsp_load_alu2[1][0],w.code_ctrl_l[15]};
            w.dsp_load_alu1_h = w.dsp_load_alu1[1][0] || w.dsp_ctrl == 9;
            w.dsp_load_result[0] = w.code_ctrl_l[19]; w.dsp_alu_mask[0] = w.dsp_ctrl == 2;
            w.dsp_alu_neg[0] = w.code_ctrl_l[16]; w.dsp_read_result[0] = w.code_ctrl_l[18];
            w.dsp_w52[0] = w.code_ctrl_l[13];
            w.dsp_sregs2[0][0] = (w.dsp_w69[1] && w.code_ctrl_l[9]) ? w.dsp_bus : w.dsp_sregs2[0][1];
            w.dsp_sregs2[1][0] = (w.code_ctrl_l[10] && w.code_ctrl_l[9]) ? w.dsp_bus : w.dsp_sregs2[1][1];
            w.dsp_w69[0] = w.code_ctrl_l[10];
        end
        if (cclk2) begin
            w.dsp_delta_sel[1] = w.dsp_delta_sel[0];
            w.dsp_w30_l[1] = w.dsp_w30_l[0]; w.dsp_w31_l[1] = w.dsp_w31_l[0];
            w.dsp_w36[1] = w.dsp_w36[0]; w.dsp_count1[1] = w.dsp_count1[0];
            w.dsp_count1_run[1] = {w.dsp_count1_run[0][0],w.dsp_count1[0] != 7};
            acc1 = int'(w.dsp_mul_acc1_add1) + int'(w.dsp_mul_acc1_add2);
            w.dsp_mul_acc1_c = (acc1 & 256) != 0; w.dsp_mul_acc1[0] = acc1 & 255;
            w37 = !w.dsp_w38[0][1] && w.dsp_mul_acc1[1][5:0] == 0;
            w39 = w.dsp_mul_acc1[1][7:6] == 0 && w.dsp_mul_acc2 == 0;
            b8 = !w.dsp_w32_l[8] && !(w37 && w39);
            w.dsp_mul_acc2_add1 = w.dsp_w35_l ? (w.dsp_w32_l ^ 9'h100) : 9'd0;
            w.dsp_mul_acc2_add2 = w.dsp_mul_acc2_load ? {b8,w.dsp_mul_acc2[8:1]} : 9'd0;
            w.dsp_w38[1] = w.dsp_w38[0]; w.dsp_w41[1] = w.dsp_w41[0];
            w42 = w.dsp_mul_acc2[8:6] != 0 || w.dsp_mul_acc2[5:4] == 3;
            if (w.dsp_w41[0][1]) begin
                w.dsp_w40 = 0;
                if (!w42) w.dsp_w40 = {3'd0,w.dsp_mul_acc2[3:0],w.dsp_mul_acc1[1],w.dsp_w38[0][1]};
                w.dsp_w40 = w.dsp_w40 | (int'(w.dsp_mul_acc2 & 9'h030) << 9);
                if (w42) w.dsp_w40 = w.dsp_w40 | 16'h6000;
                if (w39) w.dsp_w40 = w.dsp_w40 | 16'd127;
            end else w.dsp_w40 = {w.dsp_mul_acc2,w.dsp_mul_acc1[1][7:1]};
            w.dsp_w43[1] = w.dsp_w43[0]; w.dsp_w46[1] = w.dsp_w46[0];
            w.dsp_count2[1] = w.dsp_count2[0];
            w.dsp_load_alu1[1] = w.dsp_load_alu1[0]; w.dsp_load_alu2[1] = w.dsp_load_alu2[0];
            w.dsp_load_result[1] = w.dsp_load_result[0]; w.dsp_alu_mask[1] = w.dsp_alu_mask[0];
            w.dsp_alu_shift = w.dsp_ctrl10_l ? 2'd0 : w.dsp_count2[0];
            w.dsp_alu_neg[1] = w.dsp_alu_neg[0]; w.dsp_read_result[1] = w.dsp_read_result[0];
            w.dsp_w52[1] = w.dsp_w52[0];
            w.dsp_sregs2[0][1] = w.dsp_sregs2[0][0]; w.dsp_sregs2[1][1] = w.dsp_sregs2[1][0];
            w.dsp_w69[1] = w.dsp_w69[0];
        end
        w47 = w.code_ctrl_l[20]; w48 = w.code_ctrl[20] && cclk2;
        w49 = !w.code_ctrl[20] && w.code_ctrl_l[17];
        w51 = w.code_ctrl_l[20] && !cclk2;
        if (w49 && !w51) w.dsp_regs[w.code_reg_id] = w.dsp_bus;
        if (w.dsp_w52[1]) begin w.dsp_regs[0] = 0; w.dsp_regs[1] = 0; end
        if (w48 && !w51) w.dsp_regs_out = w.dsp_regs[w.code_reg_id];
        if (w47) w.dsp_bus = w.dsp_regs_out;
        // Successive approximation uses the external DAC feedback input.
        if (w.adc_w57[2]) w.adc_compare = w.adc_dac < w.adc_input;
        else w.adc_dac = adc_feedback;
        w54 = !w.adc_shift[0] && !w.adc_w53[1];
        w64 = w54 ? (w.adc_w65_l ^ 127) : w.adc_w65_l;
        w63 = (w64 + (w54 && w.adc_w55)) & 127;
        if (cclk1) begin
            w.adc_count1[0] = w.adc_count3_overflow[1] ? 4'd0 : w.adc_count1[1] + w.adc_w57[2];
            w.adc_w53[0] = w.adc_w57[2] ? !(w54 || (w.adc_shift[0] && !w.adc_compare)) : w.adc_w53[1];
            w.adc_w55_l[0] = w.adc_w55;
            t1 = w.adc_w57[2] || w.adc_count3_overflow[1];
            w.adc_count2[0] = t1 ? 5'd0 : w.adc_count2[1] + w.adc_w55;
            w.adc_w62[0] = t1;
            w.adc_w57[1] = w.adc_w57[0]; w.adc_w58[1] = w.adc_w58[0];
            w.adc_w61[0] = w.adc_w61[1] >> 1;
            if (w.adc_w62[1]) w.adc_w61[0] = w.adc_w61[0] | w63 | (!w54 ? 128 : 0);
            w59 = w54 ^ w.adc_w60;
            w.adc_w66[0] = w.adc_w57[2] ? (w59 ? w.adc_w65_l : w.adc_w68) : w.adc_w66[1];
            add = w.adc_count3[1] + (!w.adc_count3_overflow[1] && w.adc_count3_enable[1]);
            t2 = w.sample_l[2] || w.start_l[2];
            w.adc_count3[0] = add & 'h7ff; w.adc_count3_overflow[0] = (add & 'h800) != 0;
            w.adc_count3_enable[0] = t2;
            w.adc_count3_load = w.adc_count3_overflow[1] || (t2 && !w.adc_count3_enable[1]);
            w.adc_count3_load_value = {w.reg_data[7][2:0],w.reg_data[6]} ^ 11'h7ff;
        end
        if (cclk2) begin
            count1 = w.adc_count1[0] | (reset_chip ? 8 : 0);
            shift = (count1 & 8) ? 0 : 1 << (count1 & 7);
            shift2 = (count1 & 8) ? 0 : 128 >> (count1 & 7);
            w.adc_shift = shift; w.adc_count1[1] = count1;
            w.adc_w53[1] = w.adc_w53[0]; w.adc_w55 = !(count1 & 8);
            w.adc_w55_l[1] = w.adc_w55_l[0]; w.adc_count2[1] = w.adc_count2[0];
            w.adc_w57[0] = w.adc_count2[0] == 23; w.adc_w57[2] = w.adc_w57[1];
            w.adc_w58[0] = w.adc_count2[0][4:3] == 0; w.adc_w58[2] = w.adc_w58[1];
            w.adc_w61[1] = w.adc_w61[0]; w.adc_w62[1] = w.adc_w62[0];
            w67 = (shift & 1) ? 0 : w.adc_w66[0];
            w.adc_w65_l = shift2 + w67;
            w.adc_w66[1] = w.adc_w66[0]; w.adc_w68 = w67;
            w.adc_count3[1] = w.adc_count3[0];
            if (w.adc_count3_load) w.adc_count3[1] = w.adc_count3[1] | w.adc_count3_load_value;
            w.adc_count3_overflow[1] = w.adc_count3_overflow[0];
            w.adc_count3_enable[1] = w.adc_count3_enable[0];
        end
        if (w.adc_w57[2]) w.adc_w60 = w.adc_compare;
        if (!w.adc_w55) w.adc_input = adc_input;
        w.adc_w56 = !w.adc_w55 && w.adc_w55_l[1];
        if (w.adc_w56) w.adc_buf = w63 | (w54 ? 128 : 0);
        w.set_eos = w.w13[1] || (w.adc_w56 && w.sample_l[2]);
        if (w31 && !w.dsp_w31_l[0][0]) w.dsp_w33 = w.dsp_bus;
        if (w.dsp_w31_l[1][0] && !w.dsp_w31_l[0][1]) w.dsp_w34 = w.dsp_bus;
        if (w.dsp_w31_l[1][1] && !w.dsp_w31_l[0][2]) begin
            w.dsp_w32 = {1'b0,w.dsp_bus};
            if (!w.dsp_w32[7] || !w.dsp_w30_l[1][1]) w.dsp_w32[8] = 1;
        end
        if (w.dsp_w43[1][0] && !w.dsp_w43[0][1]) w.dsp_w45 = w.dsp_w40;
        w.sample = (w.dsp_w45[15:3] == 13'h1fff || w.dsp_w45[15:4] == 0) ? 13'd0 : w.dsp_w45[15:3];
        if (w.code_ctrl_l[14] && !w.dsp_load_alu1[0][0]) w.dsp_alu_in1[7:0] = w.dsp_bus;
        if (w.code_ctrl_l[15] && !w.dsp_load_alu2[0][0]) w.dsp_alu_in2[7:0] = w.dsp_bus;
        if ((w.dsp_load_alu1[1][0] || w.dsp_ctrl == 9) && !w.dsp_load_alu1_h)
            w.dsp_alu_in1[15:8] = w.dsp_bus;
        if (w.dsp_load_alu2[1][0] && !w.dsp_load_alu2[0][1]) w.dsp_alu_in2[15:8] = w.dsp_bus;
        if (w.dsp_ctrl == 4) w.dsp_alu_in1 = 0;
        if (w.dsp_ctrl == 9) w.dsp_alu_in1[7:0] = 0;
        i1 = w.dsp_alu_in1;
        i2 = w.dsp_alu_mask[1] ? 0 : w.dsp_alu_in2 >> w.dsp_alu_shift;
        c1 = w.dsp_carry_mode[1] && w.dsp_alu_in2[0]; c2 = w.mem_nibble_msb;
        neg = w.dsp_alu_neg[1] || c2;
        b15_i1 = (i1 & 'h8000) != 0; b15_i2 = (i2 & 'h8000) != 0;
        if (neg) i2 = i2 ^ 'hffff;
        carry = !(!neg && (c2 || !c1)) && (!c2 || !c1);
        sum = i1 + i2 + carry;
        w.dsp_alu_overflow = (sum & 'h10000) != 0;
        sum = (sum & 'hffff) ^ 'h8000;
        b15_s = (sum & 'h8000) != 0;
        if (!w.code_ctrl_l[19] && !w.dsp_load_result[1]) begin
            clip_high = !b15_s && w.dsp_ctrl != 8 && !b15_i1 && ((!neg && !b15_i2) || (neg && b15_i2));
            clip_low = b15_s && w.dsp_ctrl != 8 && b15_i1 && ((!neg && b15_i2) || (neg && !b15_i2));
            w.dsp_alu_result = (clip_high ? 16'hffff : (clip_low ? 16'd0 : sum)) ^ 16'h8000;
        end
        w.dsp_enc_bit = (b15_i1 && !b15_i2) || (!b15_i1 && !w.dsp_alu_overflow && !b15_i2) ||
            (b15_i1 && !w.dsp_alu_overflow && b15_i2);
        if (clk2) w.code_sync[0] = fsm_sel23;
        if (cclk1) w.code_sync[1] = w.code_sync[0];
        if (cclk2) w.code_sync[2] = w.code_sync[1];
        w.adc_quiet = w.adc_buf[7:3] == 0 || w.adc_buf[7:3] == 31;
        return w;
    endfunction
endpackage
