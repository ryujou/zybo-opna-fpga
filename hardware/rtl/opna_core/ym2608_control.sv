// OPNA YM2608B adaptation, modified 2026-10-07; original notices retained.
// SPDX-License-Identifier: GPL-2.0-or-later
// Control timing derived from YM2608-LLE, Copyright (C) 2023-2024 nukeykt.
// See tools/opna_sim/vendor/ym2608_lle/LICENSE and sources.json.
module ym2608_control #(parameter ENABLE_RHYTHM = 1, ENABLE_ADPCM = 1) (
    input wire clk,
    input wire half_ce,
    input wire chip_clk,
    input wire ic_n, cs_n, wr_n, rd_n,
    input wire [1:0] addr,
    input wire [7:0] din,
    input wire [2:0] adpcm_flags,
    input wire [7:0] adpcm_dout,
    input wire adpcm_read_valid,
    input wire [7:0] gpio_a, gpio_b,
    input wire [7:0] memory_data, adc_input, adc_feedback,
    input wire memory_dt0,
    output wire [7:0] memory_dm,
    output wire memory_dm_d, memory_a8, memory_ras_n, memory_cas_n, memory_we_n,
    output wire memory_romcs_n, memory_mden,
    output wire [2:0] adpcm_status,
    output wire adpcm_playing,
    output wire [7:0] adc_sample,
    output wire [7:0] dout,
    output wire irq_n,
    output wire busy,
    output wire [1:0] prescaler,
    output wire six_channels,
    output wire [4:0] irq_enable,
    output wire [4:0] status_mask,
    output wire flags_reset,
    output wire [1:0] timer_overflow,
    output wire [6:0] fm_key,
    output wire fm_csm_key,
    output wire fm_step,
    output wire [19:0] fm_pg_add,
    output wire fm_overlap,
    output wire fm_clk1_only,
    output logic fm_clk1_only_advance,
    output wire [6:0] fm_am,
    output wire [6:0] fm_tl,
    output wire [3:0] fm_ssg,
    output wire [2:0] fm_mod_algorithm, fm_feedback,
    output logic [4:0] fm_scan,
    output wire [6:0] fm_lfo,
    output wire fm_eg_step,
    output wire [1:0] fm_eg_low,
    output wire [3:0] fm_eg_shift,
    output wire [4:0] fm_eg_keycode,
    input wire signed [13:0] fm_wave,
    input wire [1:0] fm_wave_pan,
    input wire fm_wave_enable,
    output wire signed [15:0] fm_pcm_left, fm_pcm_right,
    output wire [1:0] pcm_valid,
    output wire [4:0] ssg_a, ssg_b, ssg_c
);
    import jt49_opna::*;
    import jt10_opna_rhythm::*;
    import jt10_opna_adpcm::*;
    // One enabled system edge represents one chip half-cycle. Both transparent
    // phases are retained so writes and timer reloads keep their chip timing.
    typedef struct packed {
        logic [1:0] ic1, icfm;
        logic [1:0][17:0] ic2;
        logic [1:0][3:0] ic3;
        logic iccheck1, iccheck3, clk1, clk2, step, fm_phase_pending;
        logic fm_slot_ready, fm_delayed_step, fm_run;
        logic [1:0][11:0] divider;
        logic [7:0][1:0][3:0] ps;
        logic [6:0][1:0] aux_ps;
        logic dclk;
        logic [1:0][1:0] divsel;
        logic [2:0] trig0, trig1;
        logic [2:0][2:0] wrpipe;
        logic [8:0] data_l, bus1, bus2;
        logic [1:0][8:0] address;
        logic [1:0][9:0] timer_a;
        logic [1:0][7:0] timer_b;
        logic [1:0][3:0] timer_ctrl;
        logic [1:0][1:0] timer_reset;
        logic [1:0] sch;
        logic [1:0][6:0] key_latch;
        logic [1:0] csm_enabled;
        logic [1:0][1:0] ch3_mode;
        logic ch3_enabled;
        logic [1:0][8:0] pg_address;
        logic [1:0][7:0] pg_data;
        logic [1:0] pg_write_address, pg_write_data;
        logic [1:0][1:0] pg_cnt1;
        logic [1:0][2:0] pg_cnt2, pg_ch_cnt2;
        logic [1:0][1:0] pg_ch_cnt1;
        logic pg_cnt_sync, pg_ch_sync;
        logic pg_is40;
        logic pg_is18, pg_rss_overflow;
        logic [1:0][3:0] pg_rss_count;
        logic [1:0][5:0][7:0] rss_registers;
        logic [1:0][11:0][1:0][6:0] op_tl;
        logic [1:0][11:0][1:0][3:0] op_ssg;
        logic [1:0][1:0][6:0] eg_tl;
        logic [1:0][1:0][3:0] eg_ssg;
        logic [6:0] tl_csm, tl_output;
        logic [3:0] ssg_output;
        logic [1:0] fsm_ch3;
        logic fsm_ch3_decode;
        logic [1:0][2:0] eg_ch3;
        logic pg_is60, pg_is90, pg_isb0;
        logic [1:0][5:0][5:0] pg_connect;
        logic [2:0] pg_algorithm;
        logic pg_carrier;
        logic [1:0][11:0][1:0] am_enable;
        logic [1:0][5:0] am_level;
        logic [1:0][1:0] am_shift;
        logic [6:0] am_amount, am_output;
        logic pg_is30, pg_isa0, pg_isa4, pg_isa8, pg_isac, pg_isb4;
        logic [1:0][5:0][13:0] pg_freq_reg, pg_freq3_reg;
        logic [1:0][5:0][7:0] pg_b4;
        logic [1:0][5:0] pg_a4, pg_ac;
        logic [1:0][11:0][1:0][6:0] pg_multi_dt;
        logic [3:0][10:0] pg_fnum;
        logic [3:0][4:0] pg_kcode;
        logic [4:0] eg_keycode;
        logic [6:0] pg_lfo1, pg_lfo2;
        logic [1:0] pg_lfo_shift;
        logic pg_lfo_sign;
        logic signed [8:0] pg_lfo_pm;
        logic [11:0] pg_lfo_fnum;
        logic [2:0] pg_block;
        logic [6:0] pg_dt_mul;
        logic [1:0][1:0] pg_dt_note;
        logic [1:0] pg_dt_blockmax, pg_dt_sign;
        logic [3:0] pg_dt_add1;
        logic [1:0] pg_dt_add2;
        logic [4:0] pg_dt_sum;
        logic [16:0] pg_freq;
        logic signed [5:0] pg_detune;
        logic [1:0][16:0] pg_freqdt;
        logic [4:0][3:0] pg_mul;
        logic [5:0][19:0] pg_add;
        logic [19:0] pg_used_add;
        logic [12:0][19:0] pg_add_history;
        logic csm_key;
        logic [1:0][3:0] lfo_reg;
        logic [1:0][6:0] lfo_subcount, lfo_count;
        logic [3:0] lfo_sync;
        logic lfo_overflow, lfo_reset;
        logic lfo_mode, lfo_zero_overflow;
        logic [6:0] lfo_loaded;
        logic [1:0][4:0] irq, mask;
        logic [1:0][9:0] count_a;
        logic [1:0][7:0] count_b;
        logic [1:0][3:0] subcount_b;
        logic [1:0] suboverflow_b, overflow_a, overflow_b;
        logic [1:0] load_a_l, load_b_l, status_a, status_b;
        logic load_a, load_b, reload_a, reload_b;
        logic sync_timer;
        logic [1:0] sync_l;
        logic [1:0][1:0] fsm1;
        logic [1:0][2:0] fsm2;
        logic fsm_zero;
        logic [1:0] fsm_sel0, fsm_sel1, fsm_sel11, fsm_sel23;
        logic fsm_0_decode;
        logic eg_sync;
        logic [1:0] eg_prescaler_clock, eg_timer_step, eg_ic;
        logic [1:0][1:0] eg_prescaler;
        logic [2:0] eg_step;
        logic [1:0][11:0] eg_clock_delay, eg_timer, eg_timer_masked;
        logic [1:0] eg_timer_carry, eg_timer_sum, eg_timer_mask;
        logic [1:0] eg_low_lock;
        logic [3:0] eg_shift_lock;
        logic fsm_11_decode, fsm_23_decode;
        logic fsm_rss, fsm_rss2;
        logic dac_sync_l, dac_sync_r, dac_load_l, dac_load_r;
        logic [1:0] dac_sync3;
        logic [17:0] adpcm_output;
        logic [1:0][17:0] fm_acc_left, fm_acc_right;
        logic [17:0] fm_output;
        logic [13:0] fm_wave_latched;
        logic [1:0] fm_pan;
        logic fm_output_enable;
        logic [1:0][15:0] dac_shift;
        logic [2:0] dac_top;
        logic dac_bit, dac_opo, dac_pin;
        logic [15:0] dac_serial;
        logic fsm_sh1_decode, fsm_sh2_decode;
        logic [1:0] fsm_sh1, fsm_sh2;
        logic sh1, sh2, previous_s, previous_sh1, previous_sh2;
        logic [1:0][4:0] busy_count;
        logic [1:0] busy_en;
        logic ssg_selected;
        logic [4:0] ssg_address;
        logic [15:0][7:0] ssg;
        jt49_state_t ssg_wave;
        rhythm_t rhythm;
        adpcm_t adpcm;
        logic [4:0] status;
        logic [7:0] dout;
        logic irq_active, flags_reset;
        logic [1:0] pcm_valid;
        logic signed [15:0] pcm_left, pcm_right;
    } state_t;
    state_t q = '0;
    state_t s;
    logic reset_chip, read_bus, write_bus, write_addr, write_data;
    logic [2:0] write_en;
    logic divider_overflow, phase1, phase2, irq_reset;
    logic bclk1, bclk2, aclk1, aclk2;
    logic [10:0] sum_a;
    logic [8:0] sum_b;
    logic [4:0] sub_sum;
    logic [5:0] busy_sum;
    logic [4:0] fsm_count;
    logic dac_load_left, dac_load_right;
    logic [17:0] dac_sample;
    logic [6:0] lfo_limit;
    logic [1:0] eg_timer_add;
    integer i;
    localparam [191:0] PG_PM_SHIFT1 = 192'h00027f00027f00027f0493ff249fff27ffffffffffffffff;
    localparam [191:0] PG_PM_SHIFT2 = 192'h2bf5ff2bf5ff2bf5ffebfebf4bf4bffd25ff492fffffffff;
    logic pg_op_match, pg_ch_match, pg_counter_reset;
    logic [13:0] pg_selected_freq;
    logic [4:0] pg_channel_count;
    logic [5:0] pg_pm_index;
    logic [2:0] pg_dt_index;
    logic [5:0] pg_dt_value;
    logic [7:0] lfo_sum;
    logic [17:0] mix_left, mix_right;
    logic adc_da_mode, adc_ad_mode, serial_s, serial_sh1, serial_sh2, serial_pin;
    logic irq_adpcm_reset;


    assign dout = q.dout;
    assign irq_n = !q.irq_active;
    assign flags_reset = q.flags_reset;
    assign pcm_valid = q.pcm_valid;
    assign fm_pcm_left = q.pcm_left;
    assign fm_pcm_right = q.pcm_right;
    assign busy = q.busy_en[1];
    assign prescaler = q.divsel[1];
    assign six_channels = q.sch[1];
    assign irq_enable = q.irq[1];
    assign status_mask = q.mask[1];
    assign timer_overflow = {q.overflow_b[1], q.overflow_a[1]};
    assign memory_dm = q.adpcm.mem_bus[7:0];
    assign memory_dm_d = !q.adpcm.mem_dir;
    assign memory_a8 = q.adpcm.mem_bus[8];
    assign memory_ras_n = !q.adpcm.mem_ras[1];
    assign memory_cas_n = !q.adpcm.mem_cas[1];
    assign memory_we_n = !q.adpcm.mem_we[1];
    assign memory_romcs_n = !(q.adpcm.reg_data[1][0] && q.adpcm.mem_ctrl_l[0]);
    assign memory_mden = !q.adpcm.reg_data[1][0] && q.adpcm.mem_ctrl_l[0];
    assign adpcm_status = {q.adpcm.zero_flag,q.adpcm.brdy_flag,q.adpcm.eos_flag};
    assign adpcm_playing = q.adpcm.start_l[0];
    assign adc_sample = q.adpcm.adc_buf;
    logic [6:0] fm_key_advance;
    logic [19:0] fm_pg_add_advance;
    logic [2:0] fm_mod_algorithm_advance, fm_feedback_advance;
    logic fm_csm_key_advance;
    assign fm_key = fm_key_advance;
    assign fm_csm_key = fm_csm_key_advance;
    // JT stage II follows the native phase adder by twelve operator slots.
    assign fm_feedback = fm_feedback_advance;
    assign fm_mod_algorithm = fm_mod_algorithm_advance;
    logic [6:0] fm_tl_advance, fm_am_advance;
    logic [3:0] fm_ssg_advance;
    assign fm_tl = fm_tl_advance;
    assign fm_ssg = fm_ssg_advance;
    assign fm_am = fm_am_advance;
    assign fm_pg_add = fm_pg_add_advance;
    assign fm_step = half_ce && s.fm_run;
    logic fm_overlap_advance;
    assign fm_overlap = fm_overlap_advance;
    assign fm_clk1_only = half_ce && s.clk1 && !s.clk2;
    logic [4:0] fm_slot;
    logic [2:0] fm_channel;
    assign fm_lfo = s.lfo_loaded;
    assign fm_eg_step = s.eg_step[2];
    assign fm_eg_low = s.eg_low_lock;
    assign fm_eg_shift = s.eg_shift_lock;
    assign fm_eg_keycode = s.eg_keycode;
    assign {ssg_c, ssg_b, ssg_a} = levels(q.ssg_wave, q.ssg);

    function automatic logic address_match(input logic [8:0] value);
        address_match = ((s.bus2 & value) == 0) && ((s.bus1 & (value ^ 9'h1ff)) == 0);
    endfunction

    function automatic logic [7:0] ssg_mask(input integer number);
        case (number)
            1, 3, 5, 13: ssg_mask = 8'h0f;
            6, 8, 9, 10: ssg_mask = 8'h1f;
            default: ssg_mask = 8'hff;
        endcase
    endfunction

    // The next native phase supplies JT's parameters before the shared system
    // edge. This also covers both phases being open during a divider switch.
    always_comb begin
      s = q;
      s.pcm_valid = 0;
      begin
        reset_chip = !ic_n;
        if (!chip_clk) begin
            divider_overflow = 0;
            s.dclk = 1;
            case (s.divsel[1])
                2: begin
                    divider_overflow = (s.divider[1] & 12'h7ff) == 0;
                    s.dclk = (s.divider[1] & 12'hffc) == 0;
                end
                0: begin
                    divider_overflow = (s.divider[1] & 12'h007) == 0;
                    s.dclk = (s.divider[1] & 12'h007) != 0;
                end
                3: begin
                    divider_overflow = (s.divider[1] & 12'h01f) == 0;
                    s.dclk = (s.divider[1] & 12'h01f) == 0;
                end
            endcase
            s.ic1[0] = reset_chip;
            s.ic2[0] = {s.ic2[1][16:0], s.ic1[1]};
            s.ic3[0] = {s.ic3[1][2:0], s.iccheck1};
            s.divider[0] = {s.divider[1][10:0], (!s.iccheck1 && divider_overflow)};
            s.ps[0][0] = (s.divider[1] & 12'h861) != 0;
            s.ps[1][0] = (s.divider[1] & 12'h30c) != 0;
            s.ps[2][0] = (s.divider[1] & 12'h012) != 0;
            s.ps[3][0] = (s.divider[1] & 12'h024) != 0;
            s.ps[4][0] = {s.ps[4][1][2:0], ((s.divider[1] & 12'h005) != 0)};
            s.ps[5][0] = (s.divider[1] & 12'h924) != 0;
            s.ps[6][0] = (s.divider[1] & 12'h249) != 0;
            s.ps[7][0] = {s.ps[7][1][2:0], ((s.divider[1] & 12'h009) == 0)};
            s.aux_ps[0][0] = (s.divider[1] & 12'h03c) != 0;
            s.aux_ps[1][0] = (s.divider[1] & 12'hf00) != 0;
            s.aux_ps[2][0] = (s.divider[1] & 12'h00c) != 0;
            s.aux_ps[3][0] = (s.divider[1] & 12'h021) != 0;
            s.aux_ps[4][0] = (s.divider[1] & 12'h002) != 0;
            s.aux_ps[5][0] = (s.divider[1] & 12'h001) != 0;
            s.aux_ps[6][0] = (s.divider[1] & 12'h555) != 0;
        end else begin
            s.ic1[1] = s.ic1[0];
            s.ic2[1] = s.ic2[0];
            s.ic3[1] = s.ic3[0];
            s.iccheck1 = s.ic1[1] && !s.ic2[1][17];
            s.iccheck3 = s.ic3[1][3];
            s.divider[1] = s.divider[0];
            for (i = 0; i < 8; i = i + 1) s.ps[i][1] = s.ps[i][0];
            for (i = 0; i < 7; i = i + 1) s.aux_ps[i][1] = s.aux_ps[i][0];
        end
        if (s.clk1) s.icfm[0] = reset_chip;
        if (s.clk2) s.icfm[1] = s.icfm[0];
        s.clk1 = 1;
        s.clk2 = 1;
        bclk1 = 1;
        bclk2 = 1;
        aclk1 = 1;
        aclk2 = 1;
        case (s.divsel[1])
            2: begin
                s.clk1 = s.ps[0][1][0]; s.clk2 = s.ps[1][1][0];
                bclk1 = s.ps[5][1][0]; bclk2 = s.ps[6][1][0];
                aclk1 = s.aux_ps[0][1]; aclk2 = s.aux_ps[1][1];
            end
            0: begin
                s.clk1 = s.ps[4][1][1] && s.ps[4][0][2];
                s.clk2 = s.ps[4][1][0] && s.ps[4][0][1];
                bclk1 = !chip_clk; bclk2 = chip_clk;
                aclk1 = s.aux_ps[4][1]; aclk2 = s.aux_ps[5][1];
            end
            3: begin
                s.clk1 = s.ps[2][1][0]; s.clk2 = s.ps[3][1][0];
                aclk1 = s.aux_ps[2][1]; aclk2 = s.aux_ps[3][1];
                bclk1 = (!s.ps[7][1][2] && s.ps[7][0][3]) || (!s.ps[7][1][0] && !s.ps[7][0][1]);
                bclk2 = (!s.ps[7][1][0] && s.ps[7][0][1]) || (!s.ps[7][1][1] && !s.ps[7][0][2]);
            end
        endcase
        // Commit once when clk2 receives a newly evaluated clk1. Repeated
        // clk2 alone holds the slot; overlapping clk1/clk2 commits every tick.
        s.step = 0;
        s.fm_run = 0;
        s.fm_delayed_step = 0;
        if (s.clk1) s.fm_phase_pending = 1;
        if (s.clk2 && s.fm_phase_pending) begin
            s.step = 1;
            s.fm_phase_pending = 0;
            s.fm_slot_ready = 1;
        end
        // In the default divider, JT finishes at clk1 ingress. The faster
        // divider needs the result one half-cycle earlier. Open phases commit
        // immediately; a lone repeated clk2 never schedules a second slot.
        if (s.step && s.clk1) begin
            s.fm_run = 1;
            s.fm_slot_ready = 0;
        end else if (q.fm_delayed_step) begin
            s.fm_run = 1;
            s.fm_slot_ready = 0;
        end else if (q.clk2 && !s.clk2 && s.fm_slot_ready) begin
            if (q.divsel[1] == 2) s.fm_delayed_step = 1;
            else begin
                s.fm_run = 1;
                s.fm_slot_ready = 0;
            end
        end
        read_bus = ic_n && !rd_n && !cs_n;
        write_bus = !wr_n && !cs_n;
        write_addr = reset_chip || (write_bus && !addr[0]);
        write_data = ic_n && write_bus && addr[0];
        for (i = 0; i < 3; i = i + 1) begin
            if ((i == 1) ? write_data : write_addr) s.trig0[i] = 1;
            else if (s.wrpipe[i][0]) s.trig0[i] = 0;
            phase1 = (i == 2) ? !chip_clk : s.clk1;
            phase2 = (i == 2) ? chip_clk : s.clk2;
            if (phase1) begin
                s.trig1[i] = s.trig0[i];
                s.wrpipe[i][1] = s.wrpipe[i][0];
            end
            if (phase2) begin
                s.wrpipe[i][0] = s.trig1[i];
                s.wrpipe[i][2] = s.wrpipe[i][1];
            end
            write_en[i] = s.wrpipe[i][0] && !s.wrpipe[i][2];
        end
        if (write_bus) s.data_l = {addr[1], din};
        if (reset_chip) s.bus2 = s.bus2 | 9'h02f;
        else if (!read_bus) s.bus2 = s.data_l ^ 9'h1ff;
        if (s.icfm[1]) s.bus1[7:0] = 0;
        else if (!read_bus && ic_n) s.bus1 = s.data_l;
        else if (read_bus && addr == 1 && s.address[1] == 9'h0ff) s.bus1[7:0] = 1;
        if (!chip_clk) begin
            s.divsel[0] = s.divsel[1];
            if (write_en[2] && address_match(9'h02f)) s.divsel[0] = 0;
            if (reset_chip) s.divsel[0] = 2;
            if (write_en[2] && address_match(9'h02d)) s.divsel[0] = s.divsel[0] | 2;
            if (write_en[2] && address_match(9'h02e)) s.divsel[0] = s.divsel[0] | 1;
        end else s.divsel[1] = s.divsel[0];

        irq_reset = 0;
        if (s.clk1) begin
            s.address[0] = write_en[0] ? s.bus1 : s.address[1];
            irq_reset = s.address[1] == 9'h110 && s.bus1[8] && write_en[1] && !s.bus2[7];
            s.timer_a[0] = s.timer_a[1];
            s.timer_b[0] = s.timer_b[1];
            s.timer_ctrl[0] = s.timer_ctrl[1];
            s.sch[0] = s.sch[1];
            s.key_latch[0] = s.key_latch[1];
            s.csm_enabled[0] = s.csm_enabled[1];
            s.ch3_mode[0] = s.ch3_mode[1];
            s.lfo_reg[0] = s.lfo_reg[1];
            s.irq[0] = s.irq[1];
            s.mask[0] = s.mask[1];
            if (reset_chip) begin
                s.timer_a[0] = 0;
                s.timer_b[0] = 0;
                s.timer_ctrl[0] = 0;
                s.sch[0] = 0;
                s.key_latch[0] = 0;
                s.csm_enabled[0] = 0;
                s.ch3_mode[0] = 0;
                s.lfo_reg[0] = 0;
                s.irq[0] = 31;
                s.mask[0] = 28;
            end else if (write_en[1] && s.address[1][8] == s.bus1[8]) begin
                case (s.address[1])
                    9'h022: s.lfo_reg[0] = s.bus1[3:0];
                    9'h024: s.timer_a[0][9:2] = s.bus1[7:0];
                    9'h025: s.timer_a[0][1:0] = s.bus1[1:0];
                    9'h026: s.timer_b[0] = s.bus1[7:0];
                    9'h027: begin
                        s.timer_ctrl[0] = s.bus1[3:0];
                        s.csm_enabled[0] = s.bus1[7:6] == 2;
                        s.ch3_mode[0] = s.bus1[7:6];
                    end
                    9'h028: s.key_latch[0] = {s.bus1[7:4], s.bus1[2:0]};
                    9'h029: begin s.sch[0] = s.bus1[7]; s.irq[0] = ~s.bus2[4:0]; end
                    9'h110: if (s.bus2[7]) s.mask[0] = {~s.bus2[4:2], s.bus1[1:0]};
                endcase
            end
            s.timer_reset[0] = (s.address[1] == 9'h027 && !s.bus1[8] && write_en[1]) ? s.bus1[5:4] : 0;
            s.sync_l[0] = s.sync_timer;
            sum_a = {1'b0, s.count_a[1]} + (s.load_a && s.sync_timer);
            s.count_a[0] = s.reload_a ? s.timer_a[1] : (!s.load_a ? 10'd0 : sum_a[9:0]);
            s.overflow_a[0] = sum_a[10];
            s.load_a_l[0] = s.load_a;
            s.status_a[0] = (s.timer_reset[1][0] || reset_chip || irq_reset || s.mask[1][0]) ? 0 : s.status_a[1];
            s.status_a[0] = s.status_a[0] || (!s.timer_reset[1][0] && !reset_chip && !s.mask[1][0] && s.timer_ctrl[1][2] && s.overflow_a[1]);
            sub_sum = {1'b0, s.subcount_b[1]} + s.sync_timer;
            s.subcount_b[0] = reset_chip ? 4'd0 : sub_sum[3:0];
            s.suboverflow_b[0] = sub_sum[4];
            sum_b = {1'b0, s.count_b[1]} + (s.load_b && s.suboverflow_b[1]);
            s.count_b[0] = s.reload_b ? s.timer_b[1] : (!s.load_b ? 8'd0 : sum_b[7:0]);
            s.overflow_b[0] = sum_b[8];
            s.load_b_l[0] = s.load_b;
            s.status_b[0] = (s.timer_reset[1][1] || reset_chip || irq_reset || s.mask[1][1]) ? 0 : s.status_b[1];
            s.status_b[0] = s.status_b[0] || (!s.timer_reset[1][1] && !reset_chip && !s.mask[1][1] && s.timer_ctrl[1][3] && s.overflow_b[1]);
        end
        if (s.clk2) begin
            s.address[1] = s.address[0];
            if (ENABLE_ADPCM) s.adpcm.irq_eos_l = s.adpcm.eos_repeat;
            s.timer_a[1] = s.timer_a[0];
            s.timer_b[1] = s.timer_b[0];
            s.timer_ctrl[1] = s.timer_ctrl[0];
            s.timer_reset[1] = s.timer_reset[0];
            s.sch[1] = s.sch[0];
            s.key_latch[1] = s.key_latch[0];
            s.csm_enabled[1] = s.csm_enabled[0];
            s.ch3_mode[1] = s.ch3_mode[0];
            s.lfo_reg[1] = s.lfo_reg[0];
            s.irq[1] = s.irq[0];
            s.mask[1] = s.mask[0];
            s.count_a[1] = s.count_a[0];
            s.overflow_a[1] = s.overflow_a[0];
            s.sync_timer = s.fsm_sel1[1];
            s.sync_l[1] = s.sync_l[0];
            s.load_a_l[1] = s.load_a_l[0];
            if (s.sync_l[0] && s.sync_l[1]) begin
                s.load_a = s.timer_ctrl[1][0];
                s.load_b = s.timer_ctrl[1][1];
            end
            s.reload_a = s.overflow_a[1] || (!s.load_a_l[1] && s.load_a);
            // CSM fires on the initial Timer A load as well as on overflow.
            if (s.sync_l[0] && s.sync_l[1]) s.csm_key = s.csm_enabled[1] && s.reload_a;
            s.status_a[1] = s.status_a[0];
            s.subcount_b[1] = s.subcount_b[0];
            s.suboverflow_b[1] = s.suboverflow_b[0];
            s.count_b[1] = s.count_b[0];
            s.overflow_b[1] = s.overflow_b[0];
            s.load_b_l[1] = s.load_b_l[0];
            s.reload_b = s.overflow_b[1] || (!s.load_b_l[1] && s.load_b);
            s.status_b[1] = s.status_b[0];
        end

        // Native register scan: DT/MUL has two 12-slot banks; frequencies
        // and the shared high-byte latches advance on the channel scan.
        if (s.clk1) begin
            s.pg_write_address[0] = write_en[0] ? (|s.bus1[7:4]) : s.pg_write_address[1];
            s.pg_address[0] = reset_chip ? 9'd0 :
                ((|s.bus1[7:4]) && write_en[0] ? s.bus1 : s.pg_address[1]);
            s.pg_data[0] = reset_chip ? 8'd0 :
                (s.pg_write_address[1] && write_en[1] ? s.bus1[7:0] : s.pg_data[1]);
            s.pg_write_data[0] = (s.pg_write_address[1] && write_en[1]) ||
                (s.pg_write_data[1] && !write_en[0]);
            pg_counter_reset = s.pg_cnt_sync || reset_chip;
            s.pg_cnt1[0] = (pg_counter_reset || s.pg_cnt1[1][1]) ? 2'd0 : s.pg_cnt1[1] + 2'd1;
            s.pg_cnt2[0] = pg_counter_reset ? 3'd0 : s.pg_cnt2[1] + s.pg_cnt1[1][1];
            s.pg_rss_count[0] = (s.pg_cnt_sync || s.pg_rss_overflow) ? 4'd0 : s.pg_rss_count[1] + 4'd1;
            for (i = 1; i < 6; i = i + 1) begin
                s.pg_freq_reg[0][i] = s.pg_freq_reg[1][i-1];
                s.pg_freq3_reg[0][i] = s.pg_freq3_reg[1][i-1];
                s.pg_connect[0][i] = s.pg_connect[1][i-1];
                s.pg_b4[0][i] = s.pg_b4[1][i-1];
                s.rss_registers[0][i] = s.rss_registers[1][i-1];
            end
            for (i = 1; i < 12; i = i + 1) begin
                s.pg_multi_dt[0][i] = s.pg_multi_dt[1][i-1];
                s.op_tl[0][i] = s.op_tl[1][i-1];
                s.op_ssg[0][i] = s.op_ssg[1][i-1];
                s.am_enable[0][i] = s.am_enable[1][i-1];
            end
            s.op_tl[0][0][0] = reset_chip ? 7'd0 :
                (s.pg_is40 && !s.pg_address[1][3] ? s.pg_data[1][6:0] : s.op_tl[1][11][0]);
            s.op_tl[0][0][1] = reset_chip ? 7'd0 :
                (s.pg_is40 && s.pg_address[1][3] ? s.pg_data[1][6:0] : s.op_tl[1][11][1]);
            s.op_ssg[0][0][0] = reset_chip ? 4'd0 :
                (s.pg_is90 && !s.pg_address[1][3] ? s.pg_data[1][3:0] : s.op_ssg[1][11][0]);
            s.op_ssg[0][0][1] = reset_chip ? 4'd0 :
                (s.pg_is90 && s.pg_address[1][3] ? s.pg_data[1][3:0] : s.op_ssg[1][11][1]);
            s.am_enable[0][0][0] = reset_chip ? 1'b0 :
                (s.pg_is60 && !s.pg_address[1][3] ? s.pg_data[1][7] : s.am_enable[1][11][0]);
            s.am_enable[0][0][1] = reset_chip ? 1'b0 :
                (s.pg_is60 && s.pg_address[1][3] ? s.pg_data[1][7] : s.am_enable[1][11][1]);
            s.pg_a4[0] = reset_chip ? 6'd0 : (s.pg_isa4 ? s.pg_data[1][5:0] : s.pg_a4[1]);
            s.pg_ac[0] = reset_chip ? 6'd0 : (s.pg_isac ? s.pg_data[1][5:0] : s.pg_ac[1]);
            s.pg_freq_reg[0][0] = reset_chip ? 14'd0 :
                (s.pg_isa0 ? {s.pg_a4[1], s.pg_data[1]} : s.pg_freq_reg[1][5]);
            s.pg_freq3_reg[0][0] = reset_chip ? 14'd0 :
                (s.pg_isa8 ? {s.pg_ac[1], s.pg_data[1]} : s.pg_freq3_reg[1][5]);
            s.pg_connect[0][0] = reset_chip ? 6'd0 :
                (s.pg_isb0 ? s.pg_data[1][5:0] : s.pg_connect[1][5]);
            s.pg_b4[0][0] = reset_chip ? 8'hc0 : (s.pg_isb4 ? s.pg_data[1] & 8'hf7 : s.pg_b4[1][5]);
            s.rss_registers[0][0] = reset_chip ? 8'd0 :
                (s.pg_is18 ? s.pg_data[1] & 8'hdf : s.rss_registers[1][5]);
            s.pg_multi_dt[0][0][0] = reset_chip ? 7'd0 :
                (s.pg_is30 && !s.pg_address[1][3] ? s.pg_data[1][6:0] : s.pg_multi_dt[1][11][0]);
            s.pg_multi_dt[0][0][1] = reset_chip ? 7'd0 :
                (s.pg_is30 && s.pg_address[1][3] ? s.pg_data[1][6:0] : s.pg_multi_dt[1][11][1]);
            pg_counter_reset = s.pg_ch_sync || reset_chip;
            s.pg_ch_cnt1[0] = (pg_counter_reset || s.pg_ch_cnt1[1][1]) ? 2'd0 : s.pg_ch_cnt1[1] + 2'd1;
            s.pg_ch_cnt2[0] = pg_counter_reset ? 3'd0 : s.pg_ch_cnt2[1] + s.pg_ch_cnt1[1][1];
            pg_channel_count = {s.pg_ch_cnt2[1], s.pg_ch_cnt1[1]};
            pg_selected_freq = s.pg_freq_reg[1][4];
            if (s.ch3_enabled) case (pg_channel_count)
                1: pg_selected_freq = s.pg_freq3_reg[1][5];
                9: pg_selected_freq = s.pg_freq3_reg[1][0];
                17: pg_selected_freq = s.pg_freq3_reg[1][4];
            endcase
            s.pg_fnum[0] = pg_selected_freq[10:0];
            s.pg_kcode[0] = {pg_selected_freq[13:11], pg_selected_freq[10],
                (pg_selected_freq[10] ? |pg_selected_freq[9:7] : &pg_selected_freq[9:7])};
            s.pg_fnum[2] = s.pg_fnum[1];
            s.pg_kcode[2] = s.pg_kcode[1];
        end
        if (s.clk2) begin
            s.pg_address[1] = s.pg_address[0];
            s.pg_data[1] = s.pg_data[0];
            s.pg_write_address[1] = s.pg_write_address[0];
            s.pg_write_data[1] = s.pg_write_data[0];
            pg_ch_match = s.pg_write_data[0] && s.pg_cnt1[0] == s.pg_address[0][1:0] &&
                s.pg_cnt2[0][0] == s.pg_address[0][8];
            pg_op_match = pg_ch_match && s.pg_cnt2[0][1] == s.pg_address[0][2];
            s.pg_is40 = pg_op_match && s.pg_address[0][7:4] == 4;
            s.pg_isb0 = pg_ch_match && s.pg_address[0][7:2] == 6'h2c;
            s.pg_is60 = pg_op_match && s.pg_address[0][7:4] == 6;
            s.pg_is90 = pg_op_match && s.pg_address[0][7:4] == 9;
            s.pg_is30 = pg_op_match && s.pg_address[0][7:4] == 3;
            s.pg_isa0 = pg_ch_match && s.pg_address[0][7:2] == 6'h28;
            s.pg_isa4 = pg_ch_match && s.pg_address[0][7:2] == 6'h29;
            s.pg_isa8 = pg_ch_match && s.pg_address[0][7:2] == 6'h2a;
            s.pg_isac = pg_ch_match && s.pg_address[0][7:2] == 6'h2b;
            s.pg_isb4 = pg_ch_match && s.pg_address[0][7:2] == 6'h2d;
            s.pg_cnt1[1] = s.pg_cnt1[0];
            s.pg_cnt2[1] = s.pg_cnt2[0];
            s.pg_cnt_sync = s.fsm_sel23[1];
            s.pg_rss_count[1] = s.pg_rss_count[0];
            s.pg_rss_overflow = (s.pg_rss_count[0] & 4'd11) == 11;
            s.pg_is18 = s.pg_write_data[0] && s.pg_rss_count[0] == s.pg_address[0][2:0] &&
                s.pg_address[0][2:1] != 3 && s.pg_address[0][8:3] == 6'h03;
            s.rss_registers[1] = s.rss_registers[0];
            s.ch3_enabled = |s.ch3_mode[0];
            s.pg_freq_reg[1] = s.pg_freq_reg[0];
            s.pg_freq3_reg[1] = s.pg_freq3_reg[0];
            s.pg_connect[1] = s.pg_connect[0];
            s.pg_b4[1] = s.pg_b4[0];
            s.pg_multi_dt[1] = s.pg_multi_dt[0];
            s.op_tl[1] = s.op_tl[0];
            s.op_ssg[1] = s.op_ssg[0];
            s.am_enable[1] = s.am_enable[0];
            s.pg_a4[1] = s.pg_a4[0];
            s.pg_ac[1] = s.pg_ac[0];
            s.pg_ch_sync = s.fsm_sel23[1];
            s.pg_ch_cnt1[1] = s.pg_ch_cnt1[0];
            s.pg_ch_cnt2[1] = s.pg_ch_cnt2[0];
            s.pg_fnum[1] = s.pg_fnum[0];
            s.pg_fnum[3] = s.pg_fnum[2];
            s.pg_kcode[1] = s.pg_kcode[0];
            s.pg_kcode[3] = s.pg_kcode[2];
            s.eg_keycode = s.pg_kcode[2];
        end

        if (s.clk1) begin
            fsm_count = {s.fsm2[1], s.fsm1[1]};
            if ((fsm_count & 5'd30) == 22 || (fsm_count & 5'd28) == 24 || (fsm_count & 5'd30) == 28)
                s.pg_carrier = s.pg_algorithm >= 4;
            else if ((fsm_count & 5'd30) == 14 || (fsm_count & 5'd28) == 16 || (fsm_count & 5'd30) == 20)
                s.pg_carrier = s.pg_algorithm >= 5;
            else if ((fsm_count & 5'd30) == 6 || (fsm_count & 5'd28) == 8 || (fsm_count & 5'd30) == 12)
                s.pg_carrier = s.pg_algorithm == 7;
            else s.pg_carrier = 1;
            s.fsm1[0] = (s.iccheck3 || s.fsm1[1][1]) ? 2'd0 : s.fsm1[1] + 2'd1;
            s.fsm2[0] = s.iccheck3 ? 3'd0 : s.fsm2[1] + s.fsm1[1][1];
            fsm_count = {s.fsm2[0], s.fsm1[0]};
            s.fsm_ch3_decode = (fsm_count & 5'd7) == 1;
            s.fsm_ch3[1] = s.fsm_ch3[0];
            s.fsm_0_decode = (fsm_count & 5'd30) == 30;
            s.fsm_zero = fsm_count == 0;
            s.fsm_11_decode = fsm_count == 13;
            s.fsm_23_decode = fsm_count == 29;
            s.fsm_sel11[1] = s.fsm_sel11[0];
            s.fsm_sel23[1] = s.fsm_sel23[0];
            s.fsm_rss2 = !s.fsm_23_decode && !s.fsm_sel23[1];
            s.fsm_sh1_decode = (fsm_count & 5'd28) == 4 || fsm_count == 8;
            s.fsm_sh2_decode = (fsm_count & 5'd28) == 20 || fsm_count == 24;
            s.fsm_sel1[1] = s.fsm_sel1[0];
            s.fsm_sel0[1] = s.fsm_sel0[0];
            s.fsm_sh1[1] = s.fsm_sh1[0];
            s.fsm_sh2[1] = s.fsm_sh2[0];
        end
        if (s.clk2) begin
            s.pg_algorithm = s.pg_connect[0][4][2:0];
            s.fsm1[1] = s.fsm1[0];
            s.fsm2[1] = s.fsm2[0];
            s.fsm_rss = s.fsm2[0][1];
            s.fsm_ch3[0] = s.fsm_ch3_decode;
            s.fsm_sel1[0] = s.fsm_zero;
            s.fsm_sel0[0] = s.fsm_0_decode;
            s.fsm_sel11[0] = s.fsm_11_decode;
            s.fsm_sel23[0] = s.fsm_23_decode;
            s.fsm_sh1[0] = s.fsm_sh1_decode;
            s.fsm_sh2[0] = s.fsm_sh2_decode;
        end

        // The EG timer is a serial 12-bit counter. Its low and leading-one
        // locks are captured once per three FM frames, on the native phases.
        if (s.clk1) begin
            s.eg_prescaler_clock[0] = s.eg_sync;
            s.eg_prescaler[0] = (reset_chip || (s.eg_prescaler[1][1] && s.eg_sync)) ?
                2'd0 : s.eg_prescaler[1] + s.eg_sync;
            s.eg_step[0] = s.eg_prescaler[1][1];
            s.eg_step[2] = s.eg_step[1];
            s.eg_timer_step[1] = s.eg_timer_step[0];
            s.eg_ic[0] = reset_chip;
            s.eg_clock_delay[0] = {s.eg_clock_delay[1][10:0], s.eg_prescaler_clock[1]};
            eg_timer_add = {1'b0, s.eg_timer[1][10]} +
                (s.eg_timer_carry[1] || (s.eg_prescaler[1][1] && s.eg_prescaler_clock[1]));
            s.eg_timer[0] = {s.eg_timer[1][10:0], s.eg_timer_sum[1]};
            s.eg_timer_carry[0] = eg_timer_add[1];
            s.eg_timer_sum[0] = eg_timer_add[0];
            s.eg_timer_mask[0] = (s.eg_prescaler_clock[1] || s.eg_clock_delay[1][11] || s.eg_ic[1]) ?
                1'b0 : s.eg_timer_sum[1] || s.eg_timer_mask[1];
            s.eg_timer_masked[0] = {s.eg_timer_masked[1][10:0],
                (s.eg_timer_sum[1] && !s.eg_timer_mask[1])};
            if (s.eg_timer_step[0] && s.eg_timer_step[1]) begin
                s.eg_low_lock = {s.eg_timer[0][10], s.eg_timer[0][11]};
                s.eg_shift_lock = {(|(s.eg_timer_masked[0] & 12'h01f)),
                    (|(s.eg_timer_masked[0] & 12'h1e1)), (|(s.eg_timer_masked[0] & 12'h666)),
                    (|(s.eg_timer_masked[0] & 12'haaa))};
            end
        end
        if (s.clk2) begin
            s.eg_sync = s.fsm_sel0[1];
            s.eg_prescaler_clock[1] = s.eg_prescaler_clock[0];
            s.eg_prescaler[1] = s.eg_prescaler[0];
            s.eg_step[1] = s.eg_step[0];
            s.eg_timer_step[0] = s.eg_step[0] && s.eg_prescaler_clock[0];
            s.eg_ic[1] = s.eg_ic[0];
            s.eg_timer_sum[1] = s.eg_timer_sum[0] && !s.eg_ic[0];
            s.eg_timer[1] = s.eg_timer[0];
            s.eg_clock_delay[1] = s.eg_clock_delay[0];
            s.eg_timer_carry[1] = s.eg_timer_carry[0];
            s.eg_timer_mask[1] = s.eg_timer_mask[0];
            s.eg_timer_masked[1] = s.eg_timer_masked[0];
        end

        // Disabling the LFO resets its phase but leaves the divider running.
        // The divider and output latch use the chip FSM's two clock phases.
        if (s.clk1) begin
            s.lfo_subcount[0] = (reset_chip || s.lfo_overflow) ? 7'd0 :
                s.lfo_subcount[1] + s.lfo_sync[0];
            lfo_sum = {1'b0,s.lfo_count[1]} + s.lfo_overflow;
            s.lfo_zero_overflow = lfo_sum[7] && s.lfo_mode;
            s.lfo_count[0] = s.lfo_reset ? 7'd0 : lfo_sum[6:0];
            s.lfo_sync[1] = s.lfo_sync[0];
            s.lfo_sync[3] = s.lfo_sync[2];
        end
        if (s.clk2) begin
            case (s.lfo_reg[0][2:0])
                0: lfo_limit = 108;
                1: lfo_limit = 77;
                2: lfo_limit = 71;
                3: lfo_limit = 67;
                4: lfo_limit = 62;
                5: lfo_limit = 44;
                6: lfo_limit = 8;
                7: lfo_limit = 5;
            endcase
            s.lfo_sync[0] = s.fsm_sel23[1];
            s.lfo_sync[2] = s.lfo_sync[1];
            s.lfo_subcount[1] = s.lfo_subcount[0];
            s.lfo_mode = ENABLE_ADPCM && (s.adpcm.sample_l[2] ||
                (s.adpcm.reg_data[0][6] && s.adpcm.start_l[1]));
            s.lfo_overflow = s.lfo_mode ? s.lfo_subcount[0] == 127 :
                (s.lfo_subcount[0] & lfo_limit) == lfo_limit;
            // The manual requires continuous quiet; nonquiet clears the count.
            s.lfo_reset = s.lfo_mode ? !s.adpcm.adc_quiet : !s.lfo_reg[0][3];
            s.lfo_count[1] = s.lfo_count[0];
            if (!s.lfo_sync[3] && s.lfo_sync[2]) s.lfo_loaded = s.lfo_count[1];
        end


        // Keep the PG parameter latches on the native transparent phases.
        if (s.clk1) begin
            pg_pm_index = {s.pg_b4[1][5][2:0],
                (s.lfo_loaded[5] ? ~s.lfo_loaded[4:2] : s.lfo_loaded[4:2])};
            s.pg_lfo1 = s.pg_fnum[1][10:4] >> PG_PM_SHIFT1[pg_pm_index*3 +: 3];
            s.pg_lfo2 = s.pg_fnum[1][10:4] >> PG_PM_SHIFT2[pg_pm_index*3 +: 3];
            s.pg_lfo_shift = s.pg_b4[1][5][2:0] > 5 ? 3'd7 - s.pg_b4[1][5][2:0] : 2'd2;
            s.pg_lfo_sign = s.lfo_loaded[6];
            s.pg_lfo_fnum = {s.pg_fnum[3], 1'b0} + {{3{s.pg_lfo_pm[8]}}, s.pg_lfo_pm};
            s.pg_block = s.pg_kcode[3][4:2];
            s.pg_dt_mul = s.pg_multi_dt[1][11][s.pg_cnt2[1][2]];
            s.pg_dt_note[1] = s.pg_dt_note[0];
            s.pg_dt_blockmax[1] = s.pg_dt_blockmax[0];
            s.pg_dt_sign[1] = s.pg_dt_sign[0];
            s.pg_dt_sum = {1'b0, s.pg_dt_add1} + s.pg_dt_add2 + 5'd1;
            s.pg_freqdt[0] = s.pg_freq + {{11{s.pg_detune[5]}}, s.pg_detune};
            s.pg_mul[1] = s.pg_mul[0];
            s.pg_mul[3] = s.pg_mul[2];
            s.pg_add[0] = s.pg_mul[4] ? {3'd0, s.pg_freqdt[1]} * s.pg_mul[4] : {4'd0, s.pg_freqdt[1][16:1]};
            s.pg_add[2] = s.pg_add[1];
            s.pg_add[4] = s.pg_add[3];
            s.pg_used_add = s.pg_add[5];
        end
        if (s.clk2) begin
            s.pg_lfo_pm = ({1'b0,s.pg_lfo1} + {1'b0,s.pg_lfo2}) >> s.pg_lfo_shift;
            if (s.pg_lfo_sign) s.pg_lfo_pm = -s.pg_lfo_pm;
            s.pg_freq = ({7'd0, s.pg_lfo_fnum} << s.pg_block) >> 2;
            s.pg_dt_note[0] = s.pg_kcode[2][1:0];
            s.pg_dt_blockmax[0] = s.pg_kcode[2][4:2] == 7;
            s.pg_dt_add1 = {(|s.pg_dt_mul[5:4]), s.pg_kcode[2][4:2]};
            s.pg_dt_add2 = {s.pg_dt_mul[5], (&s.pg_dt_mul[5:4])};
            s.pg_dt_sign[0] = s.pg_dt_mul[6];
            pg_dt_index = {s.pg_dt_sum[0], s.pg_dt_blockmax[1] ? 2'd0 : s.pg_dt_note[1]};
            case (pg_dt_index)
                0: pg_dt_value = 16;
                1: pg_dt_value = 17;
                2: pg_dt_value = 19;
                3: pg_dt_value = 20;
                4: pg_dt_value = 22;
                5: pg_dt_value = 24;
                6: pg_dt_value = 27;
                7: pg_dt_value = 29;
            endcase
            s.pg_detune = pg_dt_value >> (9 - s.pg_dt_sum[4:1]);
            if (s.pg_dt_sign[1]) s.pg_detune = -s.pg_detune;
            s.pg_mul[0] = s.pg_dt_mul[3:0];
            s.pg_mul[2] = s.pg_mul[1];
            s.pg_mul[4] = s.pg_mul[3];
            s.pg_freqdt[1] = s.pg_freqdt[0];
            s.pg_add[1] = s.pg_add[0];
            s.pg_add[3] = s.pg_add[2];
            s.pg_add[5] = s.pg_add[4];
        end
        // Advance this transfer once per slot at the native clk2 commit.
        if (s.step) s.pg_add_history = {s.pg_add_history[11:0], s.pg_used_add};

        // TL and AM are sampled at their native output taps, independently
        // of the envelope-level feedback ring.
        if (s.clk1) begin
            s.eg_tl[0][0] = s.op_tl[1][11][s.pg_cnt2[1][2]];
            s.eg_tl[1][0] = s.eg_tl[0][1];
            s.eg_ssg[0][0] = s.op_ssg[1][11][s.pg_cnt2[1][2]];
            s.eg_ssg[1][0] = s.eg_ssg[0][1];
            s.eg_ch3[1] = s.eg_ch3[0];
            s.tl_csm = s.ch3_mode[0] == 2 && s.eg_ch3[0][1] ? 7'd0 : s.eg_tl[1][0];
            s.am_level[0] = s.lfo_loaded[6] ? s.lfo_loaded[5:0] : ~s.lfo_loaded[5:0];
            s.am_shift[0] = s.am_enable[1][11][s.pg_cnt2[1][2]] ? s.pg_b4[1][5][5:4] : 2'd0;
            case (s.am_shift[1])
                0: s.am_amount = 0;
                1: s.am_amount = {3'd0, s.am_level[1][5:2]};
                2: s.am_amount = {1'b0, s.am_level[1]};
                3: s.am_amount = {s.am_level[1], 1'b0};
            endcase
        end
        if (s.clk2) begin
            s.eg_tl[0][1] = s.eg_tl[0][0];
            s.eg_tl[1][1] = s.eg_tl[1][0];
            s.eg_ssg[0][1] = s.eg_ssg[0][0];
            s.eg_ssg[1][1] = s.eg_ssg[1][0];
            s.ssg_output = s.eg_ssg[1][0];
            s.eg_ch3[0] = {s.eg_ch3[1][1:0], s.fsm_ch3[1]};
            s.tl_output = s.tl_csm;
            s.am_level[1] = s.am_level[0];
            s.am_shift[1] = s.am_shift[0];
            s.am_output = s.am_amount;
        end
        if (reset_chip) begin
            s.ssg_selected = 0;
            s.ssg_address = 0;
            for (i = 0; i < 16; i = i + 1) s.ssg[i] = s.bus1[7:0] & ssg_mask(i);
        end else begin
            if (write_addr && !addr[1]) begin
                s.ssg_selected = s.bus1[7:4] == 0;
                if (s.bus1[7:5] == 0) s.ssg_address = s.bus1[4:0];
            end
            if (s.ssg_selected && write_data && !addr[1])
                s.ssg[s.ssg_address[3:0]] = s.bus1[7:0] & ssg_mask(s.ssg_address);
        end
        if (s.ssg_selected && read_bus && addr == 1) begin
            if (s.ssg_address == 14) s.bus1[7:0] = gpio_a;
            else if (s.ssg_address == 15) s.bus1[7:0] = gpio_b;
            else s.bus1[7:0] = (s.bus1[7:0] & ~ssg_mask(s.ssg_address)) | s.ssg[s.ssg_address[3:0]];
        end
        s.ssg_wave = advance(s.ssg_wave, chip_clk, reset_chip, s.ic3[1][2],
            write_en[2] && address_match(9'h02d),
            write_en[2] && address_match(9'h02e),
            write_en[2] && address_match(9'h02f),
            s.ssg_selected && write_data && !addr[1] && s.ssg_address == 13, s.ssg);
        if (read_bus && addr == 3 && adpcm_read_valid) s.bus1[7:0] = adpcm_dout;
        if (ENABLE_RHYTHM)
            s.rhythm = rhythm_advance(s.rhythm, chip_clk, reset_chip, s.clk1, s.clk2,
                aclk1, aclk2, s.dclk, s.fsm_rss, s.fsm_rss2, s.fsm_sel23[1],
                write_en[0], write_en[1], write_data, s.address[1] == 9'h010,
                s.bus1, s.rss_registers[1]);
        if (ENABLE_ADPCM) begin
            s.adpcm = adpcm_advance(s.adpcm, reset_chip, s.clk1, s.clk2,
                !s.aux_ps[6][1], s.aux_ps[6][1], ic_n && write_bus && !addr[0] && addr[1],
                write_data && addr[1], read_bus && addr == 3, s.fsm_sel23[1],
                s.bus1, memory_data, memory_dt0, adc_input, adc_feedback);
            if (read_bus && addr == 3) begin
                if (s.adpcm.selected[8]) s.bus1[7:0] = s.adpcm.mem_data_l3;
                if (s.adpcm.selected[15]) s.bus1[7:0] = s.adpcm.adc_buf;
            end
        end

        if (s.clk1) begin
            busy_sum = {1'b0, s.busy_count[1]} + s.busy_en[1];
            s.busy_count[0] = reset_chip ? 5'd0 : busy_sum[4:0];
            s.busy_en[0] = write_en[1] || (s.busy_en[1] && !(busy_sum[5] || reset_chip));
        end
        if (s.clk2) begin
            s.busy_count[1] = s.busy_count[0];
            s.busy_en[1] = s.busy_en[0];
        end
        if (ENABLE_ADPCM) begin
            irq_adpcm_reset = s.address[1] == 9'h110 && s.bus1[8] && write_en[1] && !s.bus2[7];
            if (s.clk1) begin
                s.adpcm.eos_l[0] = s.adpcm.eos_flag;
                s.adpcm.eos_repeat = s.adpcm.eos_l[1] && s.adpcm.set_eos && s.adpcm.reg_data[0][4];
            end
            if (s.clk2) begin
                s.adpcm.zero_set = s.lfo_zero_overflow;
                s.adpcm.eos_l[1] = s.adpcm.eos_l[0];
            end
            s.adpcm.eos_flag = (s.mask[1][2] || s.adpcm.irq_eos_l || irq_adpcm_reset) ? 1'b0 :
                s.adpcm.eos_flag || s.adpcm.set_eos;
            s.adpcm.brdy_flag = (s.mask[1][3] || irq_adpcm_reset) ? 1'b0 :
                s.adpcm.brdy_flag || s.adpcm.brdy_set_l[1];
            s.adpcm.zero_flag = (s.mask[1][4] || irq_adpcm_reset) ? 1'b0 :
                s.adpcm.zero_flag || s.adpcm.zero_set;
        end
        if (!(read_bus && !addr[0]))
            s.status = {ENABLE_ADPCM ? {s.adpcm.zero_flag,s.adpcm.brdy_flag,s.adpcm.eos_flag} :
                (adpcm_flags & ~s.mask[1][4:2]), s.status_b[1], s.status_a[1]};
        s.flags_reset = irq_reset || reset_chip;
        s.irq_active = |(s.status & s.irq[1]);
        s.dout = 0;
        if (read_bus) begin
            case (addr)
                0: s.dout = {s.busy_en[1], 5'd0, s.status[1:0]};
                1, 3: s.dout = s.bus1[7:0];
                2: s.dout = {s.busy_en[1], 1'b0, (ENABLE_ADPCM && s.adpcm.start_l[0]), s.status};
            endcase
        end
        if (s.clk2) begin
            s.sh1 = s.fsm_sh1[1];
            s.sh2 = s.fsm_sh2[1];
        end
        // Preserve the native serial word, including a reset during transmission.
        mix_left = ENABLE_RHYTHM ? {{2{s.rhythm.sum_left[15]}},s.rhythm.sum_left} : 18'd0;
        mix_right = ENABLE_RHYTHM ? {{2{s.rhythm.sum_right[15]}},s.rhythm.sum_right} : 18'd0;
        if (ENABLE_ADPCM && !s.adpcm.reg_data[0][6] && s.adpcm.start_l[2]) begin
            if (s.adpcm.reg_data[1][7]) mix_left = mix_left + s.adpcm_output;
            if (s.adpcm.reg_data[1][6]) mix_right = mix_right + s.adpcm_output;
        end
        if (s.clk1) begin
            s.dac_sync3[0] = s.dac_sync_r;
            if (ENABLE_ADPCM)
                s.adpcm.dac_w70[0] = (!s.dac_sync_r && s.adpcm.dac_w70[1]) ||
                    (s.adpcm.selected[14] && write_en[1]);
            s.fm_wave_latched = fm_wave;
            s.fm_acc_left[0] = (s.dac_sync_l ? mix_left : s.fm_acc_left[1]) +
                (s.fm_pan[1] && s.fm_output_enable ? s.fm_output : 18'd0);
            s.fm_acc_right[0] = (s.dac_sync_r ? mix_right : s.fm_acc_right[1]) +
                (s.fm_pan[0] && s.fm_output_enable ? s.fm_output : 18'd0);
            s.dac_load_l = s.dac_sync_l;
            s.dac_load_r = s.dac_sync_r;
        end
        if (s.clk2) begin
            s.dac_sync3[1] = s.dac_sync3[0];
            if (ENABLE_ADPCM) s.adpcm.dac_w70[1] = s.adpcm.dac_w70[0];
            s.dac_sync_l = s.fsm_sel11[1];
            s.dac_sync_r = s.fsm_sel23[1];
            s.fm_output = {{5{s.fm_wave_latched[13]}}, s.fm_wave_latched[13:1]};
            s.fm_pan = s.pg_b4[0][5][7:6];
            s.fm_output_enable = s.pg_carrier;
            s.fm_acc_left[1] = s.fm_acc_left[0];
            s.fm_acc_right[1] = s.fm_acc_right[0];
        end
        if (ENABLE_RHYTHM) s.rhythm = rhythm_mix(s.rhythm);
        if (ENABLE_ADPCM && s.dac_sync3[1])
            s.adpcm_output = {{3{s.adpcm.sample[12]}},s.adpcm.sample,2'b0};
        dac_load_left = s.dac_sync_l && !s.dac_load_l;
        dac_load_right = s.dac_sync_r && !s.dac_load_r;
        dac_sample = dac_load_left ? s.fm_acc_left[1] : s.fm_acc_right[1];
        if (dac_load_left || dac_load_right) s.dac_top = dac_sample[17:15];
        if (bclk1) begin
            if (ENABLE_ADPCM) begin
                s.adpcm.dac_shift[1] = s.adpcm.dac_shift[0];
                s.adpcm.dac_set[1] = s.adpcm.dac_set[0];
                s.adpcm.dac_bit[1] = s.adpcm.dac_bit[0];
            end
            s.dac_shift[0] = {1'b0, s.dac_shift[1][15:1]};
            s.dac_bit = s.dac_shift[1][0];
            s.dac_pin = s.dac_opo;
        end
        if (bclk2) begin
            if (ENABLE_ADPCM) begin
                s.adpcm.dac_bit[0] = s.adpcm.dac_shift[1][0];
                s.adpcm.dac_shift[0] = {(!reset_chip && s.adpcm.dac_shift[1][0]),s.adpcm.dac_shift[1][23:1]};
                if (s.adpcm.dac_w70[1] && s.dac_sync_r && !s.adpcm.dac_set[1])
                    s.adpcm.dac_shift[0][23:8] = {8'd0,s.adpcm.reg_data[14]};
                s.adpcm.dac_set[0] = s.adpcm.dac_w70[1] && s.dac_sync_r;
            end
            s.dac_shift[1] = s.dac_shift[0];
            if (dac_load_left || dac_load_right)
                s.dac_shift[1] = s.dac_shift[1] | {!dac_sample[17], dac_sample[14:0]};
            if (s.dac_top == 1 || s.dac_top[2:1] == 1) s.dac_opo = 1;
            else if (s.dac_top == 6 || s.dac_top[2:1] == 2) s.dac_opo = 0;
            else s.dac_opo = s.dac_bit;
        end
        if (ENABLE_ADPCM && s.aux_ps[6][1]) s.adpcm.adc_bit = s.adpcm.adc_w61[0][0];
        adc_da_mode = ENABLE_ADPCM && s.adpcm.reg_data[1][2] && s.adpcm.sample_l[2];
        adc_ad_mode = ENABLE_ADPCM && ((s.adpcm.reg_data[0][6] && s.adpcm.start_l[2]) ||
            (!s.adpcm.reg_data[1][2] && s.adpcm.sample_l[2]));
        serial_sh1 = adc_da_mode ? (s.adpcm.reg_data[1][7] && s.sh1) : (adc_ad_mode ? 1'b0 : s.sh1);
        serial_sh2 = adc_da_mode ? (s.adpcm.reg_data[1][6] && s.sh2) : (adc_ad_mode ? s.adpcm.adc_w58[2] : s.sh2);
        serial_pin = adc_da_mode ? s.adpcm.dac_bit[1] : (adc_ad_mode ? s.adpcm.adc_bit : s.dac_pin);
        serial_s = adc_ad_mode ? s.aux_ps[6][1] : bclk1;
        // The external DAC latches right on SH1 and left on SH2 at S falling.
        if (s.previous_s && !serial_s) begin
            if (s.previous_sh1 && !serial_sh1) begin
                s.pcm_valid[1] = 1;
                s.pcm_right = s.dac_serial ^ 16'h8000;
            end
            if (s.previous_sh2 && !serial_sh2) begin
                s.pcm_valid[0] = 1;
                s.pcm_left = s.dac_serial ^ 16'h8000;
            end
            s.dac_serial = {serial_pin, s.dac_serial[15:1]};
            s.previous_sh1 = serial_sh1;
            s.previous_sh2 = serial_sh2;
        end
        s.previous_s = serial_s;
      end
      fm_overlap_advance = s.clk1 && s.clk2;
      fm_clk1_only_advance = s.clk1 && !s.clk2;
      fm_ssg_advance = s.ssg_output;
      fm_tl_advance = s.tl_output;
      fm_am_advance = s.am_output;
      fm_pg_add_advance = s.pg_add_history[12];
      fm_mod_algorithm_advance = s.pg_connect[1][5][2:0];
      fm_key_advance = s.key_latch[1];
      fm_csm_key_advance = s.csm_key;
      fm_feedback_advance = s.pg_connect[1][0][5:3];
      // JT's operator pipeline completes just before the matching native clk1.
      fm_slot = s.fsm2[1] * 5'd3 + 5'(s.fsm1[1]) + 5'd7;
      if (fm_slot >= 5'd24) fm_slot = fm_slot - 5'd24;
      fm_channel = fm_slot % 5'd6;
      fm_scan[4:3] = fm_slot / 5'd6;
      fm_scan[2:0] = fm_channel < 3'd3 ? fm_channel : fm_channel + 3'd1;
      // Select the completed native phase at the boundary; retain procedural
      // if semantics for disabled or unknown enables.
      if (half_ce) begin
      end else begin
          s = q;
          s.pcm_valid = 0;
      end
    end
    always @(posedge clk) q <= s;
endmodule
