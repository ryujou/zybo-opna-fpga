// OPNA YM2608B adaptation, modified 2026-10-07; original notices retained.
/*  This file is part of JT12.

    JT12 is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT12 is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT12.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 29-10-2018

    */

module jt12_eg (
    input               rst,
    input               clk,
    input               clk_en /* synthesis direct_enable */,
    input               zero,
    input               eg_stop,
    input               timer_step,
    input       [1:0]   timer_low,
    input       [3:0]   timer_shift,
    // envelope configuration
    input       [4:0]   native_keycode,
    input       [4:0]   arate_I, // attack  rate
    input       [4:0]   rate1_I, // decay   rate
    input       [4:0]   rate2_I, // sustain rate
    input       [3:0]   rrate_I, // release rate
    input       [3:0]   sl_I,   // sustain level
    input       [1:0]   ks_II,     // key scale
    // SSG operation
    input               ssg_en_I,
    input       [2:0]   ssg_eg_I,
    // envelope operation
    input               keyon_I,
    // envelope number
    input       [6:0]   lfo_mod,
    input               amsen_IV,
    input       [1:0]   ams_IV,
    input       [6:0]   tl_IV,
    input       [3:0]   ssg_shape_IX,
    input       [11:0]  ssg_state_IX,
    input       [9:0]   eg_audible_IX,

    output  reg [9:0]   eg_V,
    output  reg         ssg_dir_V, ssg_key_V,
    output  reg         pg_rst_II
);

parameter num_ch=6;

// Native rate decoding precedes its increment gate by one FM slot. Carry
// both snapshots to the corresponding operator in the shared JT pipeline.
reg [6:0] timer_pipe [0:16];
reg [4:0] keycode_pipe [0:17];
integer timer_stage;
always @(posedge clk) if (clk_en) begin
    timer_pipe[0] <= {timer_step, timer_low, timer_shift};
    for (timer_stage=1; timer_stage<17; timer_stage=timer_stage+1)
        timer_pipe[timer_stage] <= timer_pipe[timer_stage-1];
    keycode_pipe[0] <= native_keycode;
    for (timer_stage=1; timer_stage<18; timer_stage=timer_stage+1)
        keycode_pipe[timer_stage] <= keycode_pipe[timer_stage-1];
end

wire keyon_last_I;
wire keyon_now_I  = !keyon_last_I && keyon_I;
wire keyoff_now_I = keyon_last_I && !keyon_I;

wire step_II, pg_rst_I;

wire ssg_dir_in_I;
reg  ssg_dir_II, ssg_dir_III, ssg_dir_IV;
reg  ssg_key_II, ssg_key_III, ssg_key_IV;
wire [2:0] state_in_I, state_next_I;

reg attack_II, attack_III;
reg keyon_II;
wire [4:0] base_rate_I;
reg  [4:0] base_rate_II;
wire  [5:0] rate_out_II;
reg  [5:1] rate_in_III;
reg step_III, ssg_en_II, ssg_en_III;
wire sum_out_II;
reg sum_in_III;

wire [9:0] eg_in_I, pure_eg_out_III, eg_next_III, eg_out_IV;
reg  [9:0] eg_in_II, eg_in_III, eg_in_IV;



jt12_eg_comb u_comb(
    ///////////////////////////////////
    // I
    .keyon_now      ( keyon_now_I   ),
    .keyoff_now     ( keyoff_now_I  ),
    .state_in       ( state_in_I    ),
    .eg_in          ( eg_in_I       ),
    // envelope configuration   
    .arate          ( arate_I       ), // attack  rate
    .rate1          ( rate1_I       ), // decay   rate
    .rate2          ( rate2_I       ), // sustain rate
    .rrate          ( rrate_I       ),
    .sl             ( sl_I          ),   // sustain level
    // SSG operation
    .ssg_en         ( ssg_en_I      ),
    .ssg_eg         ( ssg_eg_I      ),
    // SSG output inversion

    .base_rate      ( base_rate_I   ),
    .state_next     ( state_next_I  ),
    .pg_rst         ( pg_rst_I      ),
    ///////////////////////////////////
    // II
    .step_attack    ( attack_II     ),
    .step_rate_in   ( base_rate_II  ),
    .keycode        ( keycode_pipe[17] ),
    .timer_step     ( timer_pipe[15][6] && !keyon_II ),
    .timer_low      ( timer_pipe[16][5:4] ),
    .timer_shift    ( timer_pipe[16][3:0] ),
    .ks             ( ks_II         ),
    .step           ( step_II       ),
    .step_rate_out  ( rate_out_II   ),
    .sum_up_out     ( sum_out_II    ),
    ///////////////////////////////////
    // III
    .pure_attack    ( attack_III        ),
    .pure_step      ( step_III          ),
    .pure_rate      ( rate_in_III[5:1]  ),
    .pure_ssg_en    ( ssg_en_III        ), 
    .pure_eg_in     ( eg_in_III         ),
    .pure_eg_out    ( pure_eg_out_III   ),
    .sum_up_in      ( sum_in_III        ),
    ///////////////////////////////////
    // IV
    .lfo_mod        ( lfo_mod       ),
    .amsen          ( amsen_IV      ),
    .ams            ( ams_IV        ),
    .tl             ( tl_IV         ),
    .final_ssg_inv  ( 1'b0          ), 
    .final_eg_in    ( eg_in_IV      ),
    .final_eg_out   ( eg_out_IV     )
);

// Key-off uses this operator's audible level before TL and AM, including
// the SSG shape sampled at the native output tap.
wire [9:0] eg_audible_I;
reg [9:0] eg_audible_reset_stage;
// IX precedes the native level reset tap by one operator stage.
always @(posedge clk) if (clk_en) eg_audible_reset_stage <= eg_audible_IX;
jt12_sh_rst #(.width(10),.stages(4*num_ch-9),.rstval(1'b1)) u_eg_audible (
    .clk(clk), .clk_en(clk_en), .rst(rst),
    .din(eg_audible_reset_stage), .drop(eg_audible_I)
);
wire [9:0] eg_effective_I = keyoff_now_I ? eg_audible_I : eg_in_I;
always @(posedge clk) if(clk_en) begin
    eg_in_II <= ssg_en_I && eg_effective_I[9] && !keyon_now_I &&
        (keyoff_now_I || state_in_I == 3'b000 ||
         (ssg_eg_I[0] && !(ssg_eg_I[2] ^ ssg_eg_I[1]))) ? 10'h3ff : eg_effective_I;
    attack_II   <= state_next_I[0];
    keyon_II    <= keyon_now_I;
    base_rate_II<= base_rate_I;
    ssg_en_II   <= ssg_en_I;
    ssg_dir_II  <= ssg_dir_in_I;
    ssg_key_II  <= keyon_I;
    pg_rst_II   <= pg_rst_I;

    eg_in_III   <= eg_in_II;
    attack_III  <= attack_II;
    rate_in_III <= rate_out_II[5:1];
    ssg_en_III  <= ssg_en_II;
    ssg_dir_III <= ssg_dir_II;
    ssg_key_III <= ssg_key_II;
    step_III    <= step_II;
    sum_in_III  <= sum_out_II;

    ssg_dir_IV  <= ssg_dir_III;
    ssg_key_IV  <= ssg_key_III;
    eg_in_IV    <= pure_eg_out_III;
    eg_V        <= eg_out_IV;
    ssg_dir_V   <= ssg_dir_IV;
    ssg_key_V   <= ssg_key_IV;
end

// OPNA resets the stored level at its native ring stage. The first six JT
// feedback stages precede that point; their ordinary data delay is unchanged.
wire [9:0] eg_reset_stage;
jt12_sh #( .width(10), .stages(6) ) u_egpre(
    .clk(clk), .clk_en(clk_en), .din(eg_in_IV), .drop(eg_reset_stage)
);
jt12_sh_rst #( .width(10), .stages(4*num_ch-9), .rstval(1'b1) ) u_egsh(
    .clk(clk), .clk_en(clk_en), .rst(rst), .din(eg_reset_stage), .drop(eg_in_I)
);

jt12_sh_rst #( .width(3), .stages(4*num_ch), .rstval(1'b1) ) u_egstate(
    .clk    ( clk       ),
    .clk_en ( clk_en    ),
    .rst    ( rst       ),
    .din    ( state_next_I  ),
    .drop   ( state_in_I    )
);

// Current output uses the old direction. The native shape updates that
// operator's direction for its next pass, independently of ATT.
wire ssg_over_IX = ssg_state_IX[9];
wire ssg_dir_next_IX = ssg_shape_IX[3] && ssg_state_IX[10] &&
    ((ssg_state_IX[11] ^ (ssg_shape_IX[1:0] == 2'b10 && ssg_over_IX)) ||
     (ssg_shape_IX[1:0] == 2'b11 && ssg_over_IX));
jt12_sh_rst #( .width(1), .stages(4*num_ch-8), .rstval(1'b0) ) u_ssg_dir(
    .clk    ( clk           ),
    .clk_en ( clk_en        ),
    .rst    ( rst           ),
    .din    ( ssg_dir_next_IX),
    .drop   ( ssg_dir_in_I  )
);

jt12_sh_rst #( .width(1), .stages(4*num_ch), .rstval(1'b0) ) u_konsh(
    .clk    ( clk       ),
    .clk_en ( clk_en    ),
    .rst    ( rst       ),  
    .din    ( keyon_I   ),
    .drop   ( keyon_last_I  )
);


endmodule // jt12_eg
