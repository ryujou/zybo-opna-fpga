// OPNA YM2608B adaptation, modified 2026-10-07; original notices retained.
module ym2608 #(parameter ENABLE_FM = 1, ENABLE_RHYTHM = 1, ENABLE_ADPCM = 1) (
    input wire clk, half_ce, chip_clk,
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
    output wire irq_n, busy,
    output wire [1:0] prescaler,
    output wire six_channels,
    output wire [4:0] irq_enable, status_mask,
    output wire flags_reset,
    output wire [1:0] timer_overflow,
    output wire [1:0] pcm_valid,
    output wire signed [15:0] pcm_left, pcm_right,
    output wire [4:0] ssg_a, ssg_b, ssg_c
);
    wire signed [13:0] fm_wave;
    wire [1:0] fm_wave_pan;
    wire fm_wave_enable;
    wire signed [15:0] fm_pcm_left, fm_pcm_right;
    assign pcm_left = fm_pcm_left;
    assign pcm_right = fm_pcm_right;
    wire [6:0] fm_key;
    wire [6:0] fm_lfo;
    wire fm_eg_step;
    wire [1:0] fm_eg_low;
    wire [3:0] fm_eg_shift;
    wire [4:0] fm_eg_keycode;
    wire fm_csm_key;
    wire fm_step;
    wire [19:0] fm_pg_add;
    wire fm_overlap, fm_clk1_only;
    wire [6:0] fm_am;
    wire [6:0] fm_tl;
    wire [3:0] fm_ssg;
    wire [2:0] fm_mod_algorithm, fm_feedback;
    wire [4:0] fm_scan;
    ym2608_control #(.ENABLE_RHYTHM(ENABLE_RHYTHM), .ENABLE_ADPCM(ENABLE_ADPCM)) control (.*);
    generate if (ENABLE_FM) begin : fm
        jt12_top #(
            .use_lfo(1), .use_ssg(1), .num_ch(6), .use_pcm(0), .use_adpcm(1),
            .FULLFM(1), .JT49_DIV(3), .mask_div(0)
        ) engine (
            .rst(!ic_n), .clk(clk), .cen(half_ce && chip_clk),
            .din(din), .addr(addr), .cs_n(cs_n || !half_ce), .wr_n(wr_n),
            .opna_key(fm_key), .opna_sch(six_channels), .opna_overlap(fm_overlap), .opna_clk1_only(fm_clk1_only),
            .opna_csm_key(fm_csm_key),
            .opna_feedback(fm_feedback), .opna_mod_algorithm(fm_mod_algorithm), .opna_tl(fm_tl), .opna_am(fm_am), .opna_ssg(fm_ssg), .opna_pg_add(fm_pg_add), .opna_fm_step(fm_step), .opna_scan(fm_scan),
            .opna_lfo(fm_lfo),
            .opna_eg_step(fm_eg_step), .opna_eg_low(fm_eg_low), .opna_eg_shift(fm_eg_shift),
            .opna_eg_keycode(fm_eg_keycode),
            .adpcma_data(8'b0), .adpcmb_data(8'b0), .ch_enable(6'b0),
            .IOA_in(gpio_a), .IOB_in(gpio_b), .debug_bus(8'b0), .en_hifi_pcm(1'b0),
            .fm_wave(fm_wave), .fm_wave_pan(fm_wave_pan), .fm_wave_enable(fm_wave_enable)
        );
    end else begin : control_only
        assign fm_wave = 0;
        assign fm_wave_pan = 0;
        assign fm_wave_enable = 0;
    end endgenerate
endmodule
