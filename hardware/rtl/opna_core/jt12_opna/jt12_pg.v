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
    Date: 14-2-2016
    
    Based on information posted by Nemesis on:
http://gendev.spritesmind.net/forum/viewtopic.php?t=386&postdays=0&postorder=asc&start=167

    Based on jt51_phasegen.v, from JT51 
    
    */


/*

    tab size 4

*/

module jt12_pg(
    input clk,
    input clk_en /* synthesis direct_enable */,
    input rst,
    input [10:0] fnum_I,
    input [2:0] block_I,
    input [19:0] opna_pg_add,
    input opna_overlap,
    input pg_rst_II,
    output reg [4:0] keycode_II,
    output [9:0] phase_VIII,
    output [9:0] phase_current_VIII
);
parameter num_ch = 6;

wire [4:0] keycode_I = {block_I, fnum_I[10],
    (fnum_I[10] ? |fnum_I[9:7] : &fnum_I[9:7])};
wire [19:0] phase_drop;
wire [19:0] phase_in = pg_rst_II ? 20'd0 : phase_drop + opna_pg_add;
wire [9:0] phase_II = phase_in[19:10];

always @(posedge clk) if (clk_en) keycode_II <= keycode_I;

// IC resets the register scan; phase storage clears through operator key events.
reg [19:0] phase_memory [0:4*num_ch-1];
reg [9:0] phase_padding [0:5];
integer stage;
initial begin
    for (stage=0; stage<4*num_ch; stage=stage+1) phase_memory[stage] = 0;
    for (stage=0; stage<6; stage=stage+1) phase_padding[stage] = 0;
end
assign phase_drop = phase_memory[4*num_ch-1];
// With both native phases open, the operator sees the phase latch being
// committed in this slot rather than the previous transparent-phase value.
assign phase_VIII = opna_overlap ? phase_padding[4] : phase_padding[5];
assign phase_current_VIII = phase_padding[5];
always @(posedge clk) if (clk_en) begin
    phase_memory[0] <= phase_in;
    for (stage=1; stage<4*num_ch; stage=stage+1) phase_memory[stage] <= phase_memory[stage-1];
    phase_padding[0] <= phase_II;
    for (stage=1; stage<6; stage=stage+1) phase_padding[stage] <= phase_padding[stage-1];
end
endmodule
