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

// OPNA rate increments use the native timer locks (YM2608-LLE).
module jt12_eg_step(
    input           attack,
    input [4:0]     base_rate,
    input [4:0]     keycode,
    input [1:0]     ks,
    input           timer_step,
    input [1:0]     timer_low,
    input [3:0]     timer_shift,
    output reg      step,
    output reg [5:0] rate,
    output          sum_up
);
reg [6:0] pre_rate;
reg [3:0] rate_sum;
always @(*) begin
    pre_rate = {base_rate,1'b0} + (keycode >> (ks ^ 2'b11));
    rate = pre_rate[6] ? 6'd63 : pre_rate[5:0];
    rate_sum = timer_shift + rate[5:2];
    step = 0;
    if (rate[5:4] == 2'b11) begin
        case (rate[1:0])
            0: step = 0;
            1: step = timer_low == 0;
            2: step = !timer_low[0];
            3: step = timer_low != 3;
        endcase
        if (attack && rate[5:2] == 15) step = 1;
    end else if (base_rate != 0) begin
        case (rate_sum)
            12: step = rate != 0;
            13: step = rate[1];
            14: step = rate[0];
            default: step = 0;
        endcase
    end
end
assign sum_up = timer_step;
endmodule
