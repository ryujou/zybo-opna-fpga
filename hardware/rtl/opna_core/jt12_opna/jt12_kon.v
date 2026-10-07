// OPNA YM2608B adaptation, modified 2026-10-07; original notices retained.


/* This file is part of JT12.


    JT12 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT12 program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT12.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 27-1-2017

*/

module jt12_kon(
    input           rst,
    input           clk,
    input           clk_en /* synthesis direct_enable */,
    input   [3:0]   keyon_op,
    input   [2:0]   keyon_ch,
    input   [1:0]   next_op,
    input   [2:0]   next_ch,
    input           up_keyon,
    input           opna_csm_key,

    output  reg     keyon_I
);

parameter num_ch=6;

wire csr_out;

generate
if(num_ch==6) begin
    // The timer bypasses the register-key ring. Match its EG ingress latency.
    wire csm_eg;
    jt12_sh_rst #(.width(1), .stages(17), .rstval(1'b0)) u_csm(
        .clk(clk), .clk_en(clk_en), .rst(rst),
        .din(opna_csm_key), .drop(csm_eg)
    );
    always @(posedge clk) if( clk_en ) begin
        keyon_I <= !rst && ((csm_eg && next_ch==3'd2) || csr_out);
    end

    // The native key comparator precedes this register scan by seven slots.
    // Capture each channel there, before its four operator states enter EG.
    reg [3:0] sampled_key [0:5];
    reg [2:0] sample_ch;
    reg sample_valid;
    integer i;
    wire [2:0] key_index = {1'b0,keyon_ch[1:0]} + (keyon_ch[2] ? 3'd3 : 3'd0);
    wire [2:0] next_index = {1'b0,next_ch[1:0]} + (next_ch[2] ? 3'd3 : 3'd0);
    wire key_upnow = next_op == 0;
    wire [3:0] tkeyon_op = sampled_key[next_index];
    always @(*) begin
        sample_valid = 1;
        case ({next_op,next_ch})
            {2'd1,3'd1}: sample_ch = 0;
            {2'd1,3'd2}: sample_ch = 1;
            {2'd1,3'd4}: sample_ch = 2;
            {2'd1,3'd5}: sample_ch = 4;
            {2'd1,3'd6}: sample_ch = 5;
            {2'd2,3'd0}: sample_ch = 6;
            default: begin sample_ch = 0; sample_valid = 0; end
        endcase
    end
    always @(posedge clk) if (clk_en) begin
        if (rst) begin
            for (i=0; i<6; i=i+1) sampled_key[i] <= 0;
        end else if (sample_valid && up_keyon && sample_ch == keyon_ch)
            sampled_key[key_index] <= keyon_op;
    end

    wire middle1;
    wire middle2;
    wire middle3;
    wire din      = key_upnow ? tkeyon_op[0] : csr_out;
    wire mid_din2 = key_upnow ? tkeyon_op[3] : middle1;
    wire mid_din3 = key_upnow ? tkeyon_op[1] : middle2;
    wire mid_din4 = key_upnow ? tkeyon_op[2] : middle3;

    jt12_sh_rst #(.width(1),.stages(6),.rstval(1'b0)) u_konch0(
        .clk    ( clk       ),
        .clk_en ( clk_en    ),
        .rst    ( rst       ),
        .din    ( din       ),
        .drop   ( middle1   )
    );

    jt12_sh_rst #(.width(1),.stages(6),.rstval(1'b0)) u_konch1(
        .clk    ( clk       ),
        .clk_en ( clk_en    ),
        .rst    ( rst       ),
        .din    ( mid_din2  ),
        .drop   ( middle2   )
    );

    jt12_sh_rst #(.width(1),.stages(6),.rstval(1'b0)) u_konch2(
        .clk    ( clk       ),
        .clk_en ( clk_en    ),
        .rst    ( rst       ),
        .din    ( mid_din3  ),
        .drop   ( middle3   )
    );

    jt12_sh_rst #(.width(1),.stages(6),.rstval(1'b0)) u_konch3(
        .clk    ( clk       ),
        .clk_en ( clk_en    ),
        .rst    ( rst       ),
        .din    ( mid_din4  ),
        .drop   ( csr_out   )
    );
end
else begin // 3 channels
    reg din;
    reg [3:0] next_op_hot;

    always @(*) begin
        case( next_op )
            2'd0: next_op_hot = 4'b0001; // S1
            2'd1: next_op_hot = 4'b0100; // S3
            2'd2: next_op_hot = 4'b0010; // S2
            2'd3: next_op_hot = 4'b1000; // S4
        endcase
        din = keyon_ch[1:0]==next_ch[1:0] && up_keyon ? |(keyon_op&next_op_hot) : csr_out;
    end

    always @(posedge clk) if( clk_en ) begin
        keyon_I <= csr_out; // No CSM for YM2203
    end

    jt12_sh_rst #(.width(1),.stages(12),.rstval(1'b0)) u_konch1(
        .clk    ( clk       ),
        .clk_en ( clk_en    ),
        .rst    ( rst       ),
        .din    ( din       ),
        .drop   ( csr_out   )
    );
end
endgenerate


endmodule
