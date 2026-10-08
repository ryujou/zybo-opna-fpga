// SPDX-License-Identifier: GPL-3.0-or-later
module opna_axi_host (
    input wire clk, resetn, raw_half_due, half_ce, core_busy, core_irq_n, memory_fault,
    input wire mode_switch,
    input wire [7:0] core_dout,
    input wire [2:0] adpcm_status,
    input wire memory_pending, audio_ready,
    input wire [31:0] memory_faults,
    input wire [11:0] s_awaddr, s_araddr,
    input wire s_awvalid, s_wvalid, s_bready, s_arvalid, s_rready,
    input wire [31:0] s_wdata,
    input wire [3:0] s_wstrb,
    output wire s_awready, s_wready, s_arready,
    output reg s_bvalid, s_rvalid,
    output reg [1:0] s_bresp, s_rresp,
    output reg [31:0] s_rdata,
    output reg run_enable, mute,
    output reg [31:0] pcm_gain, ssg_gain, master_gain,
    output reg [1:0] clip_clear,
    input wire [31:0] clip_left, clip_right,
    output reg [31:0] ddr_base,
    output reg [1:0] memory_type,
    output reg invalidate,
    output reg ic_n, resetting, reset_pending,
    output reg cs_n, wr_n, rd_n,
    output reg [1:0] core_addr,
    output reg [7:0] core_din,
    output reg prime_valid, prime_resume,
    output wire [17:0] prime_address,
    input wire prime_done
);
    reg aw_hold, w_hold, ar_hold;
    (* ASYNC_REG="TRUE" *) reg mode_meta, mode_sync;
    always @(posedge clk) begin
        if (!resetn) begin mode_meta<=0; mode_sync<=0; end
        else begin mode_meta<=mode_switch; mode_sync<=mode_meta; end
    end
    reg [11:0] aw_address, ar_address;
    reg [31:0] write_data;
    reg [3:0] write_strobes;
    reg [11:0] reset_ticks;
    reg [10:0] guard_ticks;
    reg [7:0] selected [0:1];
    reg [15:0] sample_start;
    reg [2:0] lane;
    reg reading, resume_ready;
    reg [6:0] bus_ticks;
    localparam IDLE=0, NEXT=1, PRIME=2, WAIT_BUS=3, HOLD=4, GAP=5, RESUME_WAIT=6, RESUME=7;
    reg [2:0] state;
    assign s_awready = !aw_hold && !s_bvalid;
    assign s_wready = !w_hold && !s_bvalid;
    assign s_arready = !ar_hold && !s_rvalid;
    assign prime_address = {sample_start[12:0],5'b0};

    always @(posedge clk) begin
        if (!resetn) begin
            selected[0]<=0; selected[1]<=0; sample_start<=0;
        end else if (state==IDLE && aw_hold && w_hold && !s_bvalid &&
                     write_strobes==15 && aw_address[11:2]==1 && write_data[1]) begin
            selected[0]<=0; selected[1]<=0; sample_start<=0;
        end else if (state==WAIT_BUS && half_ce && !resetting && !core_busy &&
                     guard_ticks==0 && !reading) begin
            if (!core_addr[0]) selected[core_addr[1]]<=core_din;
            else begin
                if (core_addr==3 && selected[1]==2) sample_start[7:0]<=core_din;
                if (core_addr==3 && selected[1]==3) sample_start[15:8]<=core_din;
            end
        end
    end

    always @(posedge clk) begin
        if (!resetn) begin
            aw_hold<=0; w_hold<=0; ar_hold<=0;
            s_bvalid<=0; s_rvalid<=0; s_bresp<=0; s_rresp<=0; s_rdata<=0;
            aw_address<=0; ar_address<=0; write_data<=0; write_strobes<=0;
            run_enable<=1; mute<=0; ddr_base<=32'h01000000; memory_type<=1;
            pcm_gain<=65536; ssg_gain<=65536; master_gain<=65536; clip_clear<=0;
            invalidate<=0; reset_ticks<=2304; guard_ticks<=0;
            ic_n<=0; resetting<=1; reset_pending<=0;
            state<=IDLE; lane<=0; reading<=0; resume_ready<=0; bus_ticks<=0;
            cs_n<=1; wr_n<=1; rd_n<=1; core_addr<=0; core_din<=0; prime_valid<=0; prime_resume<=0;
        end else begin
            invalidate<=0; prime_valid<=0; prime_resume<=0;
            clip_clear<=0;
            if (s_bvalid && s_bready) s_bvalid<=0;
            if (s_rvalid && s_rready) s_rvalid<=0;
            if (s_awvalid && s_awready) begin aw_hold<=1; aw_address<=s_awaddr; end
            if (s_wvalid && s_wready) begin
                w_hold<=1; write_data<=s_wdata; write_strobes<=s_wstrb;
            end
            if (s_arvalid && s_arready) begin ar_hold<=1; ar_address<=s_araddr; end
            if (half_ce) begin
                if (reset_ticks!=0) reset_ticks<=reset_ticks-1'b1;
                if (reset_ticks==1153) ic_n<=1;
                if (reset_ticks==1) resetting<=0;
                if (guard_ticks!=0) guard_ticks<=guard_ticks-1'b1;
            end
            // Commit IC between consumed phases; pending blocks the core so
            // a paused memory transaction cannot advance with the old IC.
            // Complete all accepted RAM1 banks before invalidating their cache.
            if (raw_half_due && reset_pending && !memory_pending) begin
                reset_pending<=0; ic_n<=0; reset_ticks<=2304; invalidate<=1;
                cs_n<=1; wr_n<=1; rd_n<=1;
            end
            case (state)
                IDLE: begin
                    if (aw_hold && w_hold && !s_bvalid) begin
                        if (aw_address[11:2]==0) begin
                            if (memory_fault || !run_enable) begin
                                s_bvalid<=1; s_bresp<=memory_fault ? 0 : 2; aw_hold<=0; w_hold<=0;
                            end else begin reading<=0; lane<=0; state<=NEXT; end
                        end else begin
                            s_bvalid<=1; s_bresp<=0; aw_hold<=0; w_hold<=0;
                            if (write_strobes==15) begin
                                case (aw_address[11:2])
                                    1: begin
                                        if (write_data[1]) begin
                                            run_enable<=write_data[0]; mute<=write_data[2];
                                            guard_ticks<=0; resetting<=1; reset_pending<=1;
                                        end else if (!run_enable && write_data[0]) begin
                                            mute<=write_data[2];
                                            run_enable<=0; reading<=0;
                                            if (memory_fault) s_bresp<=0;
                                            else begin
                                                s_bvalid<=0; aw_hold<=1; w_hold<=1; state<=RESUME_WAIT;
                                            end
                                        end else if (raw_half_due) begin
                                            run_enable<=write_data[0]; mute<=write_data[2];
                                        end else begin s_bvalid<=0; aw_hold<=1; w_hold<=1; end
                                    end
                                    3: if (!run_enable && write_data[2:0]==0) begin
                                        if (raw_half_due) begin ddr_base<=write_data; invalidate<=1; end
                                        else begin s_bvalid<=0; aw_hold<=1; w_hold<=1; end
                                    end else s_bresp<=2;
                                    4: if (!run_enable && write_data<3) begin
                                        if (raw_half_due) begin memory_type<=write_data[1:0]; invalidate<=1; end
                                        else begin s_bvalid<=0; aw_hold<=1; w_hold<=1; end
                                    end else s_bresp<=2;
                                    9,10,11: if (!run_enable && mute) begin
                                        case (aw_address[11:2])
                                            9: pcm_gain<=write_data;
                                            10: ssg_gain<=write_data;
                                            11: master_gain<=write_data;
                                        endcase
                                    end else s_bresp<=2;
                                    12: clip_clear[0]<=1;
                                    13: clip_clear[1]<=1;
                                    default: s_bresp<=2;
                                endcase
                            end else s_bresp<=2;
                        end
                    end else if (ar_hold && !s_rvalid) begin
                        if (ar_address[11:2]==0) begin
                            if (memory_fault || !run_enable) begin
                                s_rvalid<=1; s_rresp<=memory_fault ? 0 : 2; s_rdata<=0; ar_hold<=0;
                            end else begin
                                reading<=1;
                                if (raw_half_due) begin core_addr<=ar_address[1:0]; state<=WAIT_BUS; end
                            end
                        end else begin
                            s_rvalid<=1; s_rresp<=0; ar_hold<=0;
                            case (ar_address[11:2])
                                1: s_rdata<={29'b0,mute,1'b0,run_enable};
                            2: s_rdata<={21'b0,adpcm_status,2'b0,(aw_hold || w_hold),audio_ready,memory_fault,
                                             memory_pending,resetting,core_busy};
                                3: s_rdata<=ddr_base;
                                4: s_rdata<={30'b0,memory_type};
                                5: s_rdata<=memory_faults;
                                6: s_rdata<={31'b0,!core_irq_n};
                                7: s_rdata<=32'h26080008;
                                8: s_rdata<=32'h53570000 | {31'b0,mode_sync};
                                9: s_rdata<=pcm_gain;
                                10: s_rdata<=ssg_gain;
                                11: s_rdata<=master_gain;
                                12: s_rdata<=clip_left;
                                13: s_rdata<=clip_right;
                                default: begin s_rdata<=0; s_rresp<=2; end
                            endcase
                        end
                    end
                end
                NEXT: begin
                    if (lane==4) begin
                        aw_hold<=0; w_hold<=0; s_bvalid<=1; s_bresp<=0; state<=IDLE;
                    end else if (!write_strobes[lane]) lane<=lane+1'b1;
                    else if (raw_half_due) begin
                        core_addr<=lane[1:0]; core_din<=write_data[lane*8+:8];
                        if (lane==3 && selected[1]==0 && write_data[29]) begin
                            prime_valid<=1; state<=PRIME;
                        end else state<=WAIT_BUS;
                    end
                end
                PRIME: if (prime_done) state<=WAIT_BUS;
                RESUME_WAIT: if (!memory_pending) begin
                    invalidate<=1; prime_valid<=1; prime_resume<=1; resume_ready<=0; state<=RESUME;
                end
                RESUME: begin
                    if (prime_done) resume_ready<=1;
                    if (raw_half_due && (prime_done || resume_ready)) begin
                        run_enable<=1; aw_hold<=0; w_hold<=0; resume_ready<=0;
                        s_bvalid<=1; s_bresp<=0; state<=IDLE;
                    end
                end
                WAIT_BUS: if (half_ce && !resetting && !core_busy && guard_ticks==0) begin
                    cs_n<=0; wr_n<=reading; rd_n<=!reading;
                    bus_ticks<=32; state<=HOLD;
                end
                HOLD: if (half_ce) begin
                    bus_ticks<=bus_ticks-1'b1;
                    if (bus_ticks==1) begin
                        if (reading) s_rdata<=32'(core_dout) << (ar_address[1:0]*8);
                        else if (core_addr[0])
                            guard_ticks<=(core_addr==1 && selected[0]==8'h10) ? 1152 : 166;
                        cs_n<=1; wr_n<=1; rd_n<=1; bus_ticks<=32; state<=GAP;
                    end
                end
                GAP: if (half_ce) begin
                    bus_ticks<=bus_ticks-1'b1;
                    if (bus_ticks==1) begin
                        if (reading) begin
                            ar_hold<=0; s_rvalid<=1; s_rresp<=0; state<=IDLE;
                        end else begin lane<=lane+1'b1; state<=NEXT; end
                    end
                end
                default: state<=IDLE;
            endcase
            if (memory_fault && state!=IDLE) begin
                state<=IDLE;
                if (reading) begin ar_hold<=0; s_rvalid<=1; s_rresp<=0; s_rdata<=0; end
                else begin aw_hold<=0; w_hold<=0; s_bvalid<=1; s_bresp<=0; end
            end
            if (memory_fault && raw_half_due) begin cs_n<=1; wr_n<=1; rd_n<=1; end
            if (memory_fault && !invalidate && !reset_pending && !(state==IDLE && aw_hold && w_hold &&
                aw_address[11:2]==1 && write_strobes==15 && write_data[1])) begin
                run_enable<=0; mute<=1;
            end
        end
    end
endmodule
