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

module jt12_eg_pure(
	input			attack,
	input			step,
	input [ 5:1]	rate,
	input [ 9:0]	eg_in,
	input 			ssg_en,	
	input 			sum_up,
	output reg  [9:0] eg_pure
);

reg [ 3:0] 	dr_sum;
reg [ 9:0]	dr_adj;
reg	[10:0]	dr_result;

always @(*) begin : dr_calculation
	case( rate[5:2] )
		4'b1100: dr_sum = { 2'b0, step, ~step }; // 12
		4'b1101: dr_sum = { 1'b0, step, ~step, 1'b0 }; // 13
		4'b1110: dr_sum = { step, ~step, 2'b0 }; // 14
		4'b1111: dr_sum = 4'd8;// 15
		default: dr_sum = { 3'b0, step };
	endcase
	// Decay rate attenuation is multiplied by 4 for SSG operation
	dr_adj = ssg_en ? {4'd0, dr_sum, 2'd0} : {6'd0, dr_sum};
	dr_result = dr_adj + eg_in;
end

reg [10:0] ar_result;
reg [ 9:0] ar_sum;

always @(*) begin : ar_calculation
	// Shift the complement at the selected rate before rounding. Doubling
	// an already rounded decrement loses one attenuation bit.
	casez( rate[5:2] )
		default: ar_sum = step ? {4'd0, eg_in[9:4]} + 10'd1 : 10'd0;
		4'b1100: ar_sum = step ? {3'd0, eg_in[9:3]} + 10'd1 : {4'd0, eg_in[9:4]} + 10'd1;
		4'b1101: ar_sum = step ? {2'd0, eg_in[9:2]} + 10'd1 : {3'd0, eg_in[9:3]} + 10'd1;
		4'b111?: ar_sum = step ? {1'd0, eg_in[9:1]} + 10'd1 : {2'd0, eg_in[9:2]} + 10'd1;
	endcase
	ar_result = eg_in-ar_sum;
end
///////////////////////////////////////////////////////////
// rate not used below this point
reg [9:0] eg_pre_fastar; // pre fast attack rate
always @(*) begin
	if(sum_up) begin
		if( attack  )
			eg_pre_fastar = ar_result[10] ? 10'd0: ar_result[9:0];
		else 
			eg_pre_fastar = dr_result[10] ? 10'h3FF : dr_result[9:0];
	end
	else eg_pre_fastar = eg_in;
	eg_pure = (attack&rate[5:1]==5'h1F) ? 10'd0 : eg_pre_fastar;
end

endmodule // jt12_eg_pure
