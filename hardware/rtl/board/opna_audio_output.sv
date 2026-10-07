// SPDX-License-Identifier: GPL-3.0-or-later
// SSG amplitudes are from ymfm (BSD-3-Clause), Aaron Giles; pinned sources.json.
module opna_audio_output (
    input wire sys_clk, sys_resetn, audio_clk, audio_resetn, mute,
    input wire [1:0] pcm_valid,
    input wire signed [15:0] pcm_left, pcm_right,
    input wire [4:0] ssg_a, ssg_b, ssg_c,
    output wire i2s_sclk, i2s_ws,
    output reg i2s_sd,
    output wire ac_mute_n, ready
);
    function automatic [14:0] amplitude(input [4:0] code);
        case (code)
            // Native fixed-volume zero has code 1; both quiet codes are silent.
            0,1: amplitude=0;
            2: amplitude=78; 3: amplitude=141; 4: amplitude=178; 5: amplitude=222;
            6: amplitude=262; 7: amplitude=306; 8: amplitude=369; 9: amplitude=441;
            10: amplitude=509; 11: amplitude=585; 12: amplitude=701; 13: amplitude=836;
            14: amplitude=965; 15: amplitude=1112; 16: amplitude=1334; 17: amplitude=1595;
            18: amplitude=1853; 19: amplitude=2146; 20: amplitude=2576; 21: amplitude=3081;
            22: amplitude=3576; 23: amplitude=4135; 24: amplitude=5000; 25: amplitude=6006;
            26: amplitude=7023; 27: amplitude=8155; 28: amplitude=9963; 29: amplitude=11976;
            30: amplitude=14132; 31: amplitude=16382;
        endcase
    endfunction
    function automatic signed [15:0] saturate(input signed [18:0] value);
        if (value>32767) saturate=32767;
        else if (value< -32768) saturate=-32768;
        else saturate=value[15:0];
    endfunction
    reg signed [15:0] pending_left, pending_right, paired_left, paired_right;
    reg [1:0] seen;
    wire signed [15:0] next_left = pcm_valid[0] ? pcm_left : pending_left;
    wire signed [15:0] next_right = pcm_valid[1] ? pcm_right : pending_right;
    wire [1:0] next_seen = seen | pcm_valid;
    wire [16:0] ssg_sum = {2'b0,amplitude(ssg_a)} +
                          {2'b0,amplitude(ssg_b)} + {2'b0,amplitude(ssg_c)};
    reg request_toggle, response_toggle;
    (* ASYNC_REG="TRUE" *) reg [1:0] request_sync, response_sync, mute_sync;
    reg [31:0] mailbox;
    reg [31:0] audio_frame;
    reg [7:0] phase;
    reg active;
    reg sys_ready;
    assign i2s_sclk = phase[1];
    assign i2s_ws = phase[7];
    assign ac_mute_n = active && !mute_sync[1];
    assign ready = sys_ready;
    always @(posedge sys_clk) begin
        if (!sys_resetn) begin
            pending_left<=0; pending_right<=0; paired_left<=0; paired_right<=0;
            seen<=0; request_sync<=0; response_toggle<=0; mailbox<=0; sys_ready<=0;
        end else begin
            request_sync<={request_sync[0],request_toggle};
            if (pcm_valid[0]) pending_left<=pcm_left;
            if (pcm_valid[1]) pending_right<=pcm_right;
            if (next_seen==3) begin
                paired_left<=next_left; paired_right<=next_right; seen<=0;
            end else seen<=next_seen;
            // A complete stereo mailbox is held until the next audio request.
            // Sampling the most recent native pair implements 48 kHz ZOH.
            if (request_sync[1]!=response_toggle) begin
                mailbox <= mute ? 32'b0 :
                    {saturate($signed(paired_left)+$signed({2'b0,ssg_sum})),
                     saturate($signed(paired_right)+$signed({2'b0,ssg_sum}))};
                response_toggle<=request_sync[1];
                sys_ready<=1;
            end
        end
    end
    always @(posedge audio_clk) begin
        if (!audio_resetn) begin
            phase<=0; request_toggle<=0; response_sync<=0; mute_sync<=3;
            audio_frame<=0; i2s_sd<=0; active<=0;
        end else begin
            phase<=phase+1'b1;
            response_sync<={response_sync[0],response_toggle};
            mute_sync<={mute_sync[0],mute};
            // WS changes one bit before each 16-bit I2S word. Remaining bits
            // in the 32-bit slot are zero; the codec is configured for 16 bits.
            if (phase==255) begin
                if (response_sync[1]==request_toggle) begin
                    audio_frame<=mailbox; active<=1;
                end
                request_toggle<=!request_toggle;
            end
            if (phase[1:0]==3) begin
                if (phase[6:2]<16 && !mute_sync[1])
                    i2s_sd<=phase[7] ? audio_frame[15-phase[6:2]] : audio_frame[31-phase[6:2]];
                else i2s_sd<=0;
            end
        end
    end
endmodule
