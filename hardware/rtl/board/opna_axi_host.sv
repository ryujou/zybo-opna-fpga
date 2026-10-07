// SPDX-License-Identifier: GPL-3.0-or-later
module opna_axi_host (
    input wire clk, resetn, half_ce, core_busy, core_irq_n, memory_fault,
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
    output reg [31:0] ddr_base,
    output reg [1:0] memory_type,
    output reg invalidate,
    output wire ic_n, resetting,
    output reg cs_n, wr_n, rd_n,
    output reg [1:0] core_addr,
    output reg [7:0] core_din,
    output reg prime_valid, prime_resume,
    output wire [17:0] prime_address,
    input wire prime_done
);
    reg aw_hold, w_hold, ar_hold;
    reg [11:0] aw_address, ar_address;
    reg [31:0] write_data;
    reg [3:0] write_strobes;
    reg [11:0] reset_ticks;
    reg [10:0] guard_ticks;
    reg [7:0] selected [0:1];
    reg [15:0] sample_start;
    reg [2:0] lane;
    reg reading;
    reg [6:0] bus_ticks;
    localparam IDLE=0, NEXT=1, PRIME=2, WAIT_BUS=3, HOLD=4, GAP=5, RESUME_WAIT=6, RESUME=7;
    reg [2:0] state;
    assign s_awready = !aw_hold && !s_bvalid;
    assign s_wready = !w_hold && !s_bvalid;
    assign s_arready = !ar_hold && !s_rvalid;
    assign resetting = reset_ticks != 0;
    assign ic_n = reset_ticks <= 1152;
    assign prime_address = {sample_start[12:0],5'b0};

    always @(posedge clk) begin
        if (!resetn) begin
            aw_hold<=0; w_hold<=0; ar_hold<=0;
            s_bvalid<=0; s_rvalid<=0; s_bresp<=0; s_rresp<=0; s_rdata<=0;
            aw_address<=0; ar_address<=0; write_data<=0; write_strobes<=0;
            run_enable<=1; mute<=0; ddr_base<=32'h01000000; memory_type<=1;
            invalidate<=0; reset_ticks<=2304; guard_ticks<=0;
            selected[0]<=0; selected[1]<=0; sample_start<=0;
            state<=IDLE; lane<=0; reading<=0; bus_ticks<=0;
            cs_n<=1; wr_n<=1; rd_n<=1; core_addr<=0; core_din<=0; prime_valid<=0; prime_resume<=0;
        end else begin
            invalidate<=0; prime_valid<=0; prime_resume<=0;
            if (s_bvalid && s_bready) s_bvalid<=0;
            if (s_rvalid && s_rready) s_rvalid<=0;
            if (s_awvalid && s_awready) begin aw_hold<=1; aw_address<=s_awaddr; end
            if (s_wvalid && s_wready) begin
                w_hold<=1; write_data<=s_wdata; write_strobes<=s_wstrb;
            end
            if (s_arvalid && s_arready) begin ar_hold<=1; ar_address<=s_araddr; end
            if (half_ce) begin
                if (reset_ticks!=0) reset_ticks<=reset_ticks-1'b1;
                if (guard_ticks!=0) guard_ticks<=guard_ticks-1'b1;
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
                                        run_enable<=write_data[0]; mute<=write_data[2];
                                        if (!run_enable && write_data[0] && !write_data[1]) begin
                                            run_enable<=0; reading<=0;
                                            if (memory_fault) s_bresp<=0;
                                            else begin
                                                s_bvalid<=0; aw_hold<=1; w_hold<=1; state<=RESUME_WAIT;
                                            end
                                        end
                                        if (write_data[1]) begin
                                            reset_ticks<=2304; guard_ticks<=0; invalidate<=1;
                                            selected[0]<=0; selected[1]<=0; sample_start<=0;
                                        end
                                    end
                                    3: if (!run_enable && write_data[2:0]==0) begin
                                        ddr_base<=write_data; invalidate<=1;
                                    end else s_bresp<=2;
                                    4: if (!run_enable && write_data<3) begin
                                        memory_type<=write_data[1:0]; invalidate<=1;
                                    end else s_bresp<=2;
                                    default: s_bresp<=2;
                                endcase
                            end else s_bresp<=2;
                        end
                    end else if (ar_hold && !s_rvalid) begin
                        if (ar_address[11:2]==0) begin
                            if (memory_fault || !run_enable) begin
                                s_rvalid<=1; s_rresp<=memory_fault ? 0 : 2; s_rdata<=0; ar_hold<=0;
                            end else begin
                                reading<=1; core_addr<=ar_address[1:0]; state<=WAIT_BUS;
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
                                7: s_rdata<=32'h26080007;
                                default: begin s_rdata<=0; s_rresp<=2; end
                            endcase
                        end
                    end
                end
                NEXT: begin
                    if (lane==4) begin
                        aw_hold<=0; w_hold<=0; s_bvalid<=1; s_bresp<=0; state<=IDLE;
                    end else if (!write_strobes[lane]) lane<=lane+1'b1;
                    else begin
                        core_addr<=lane[1:0]; core_din<=write_data[lane*8+:8];
                        if (lane==3 && selected[1]==0 && write_data[29]) begin
                            prime_valid<=1; state<=PRIME;
                        end else state<=WAIT_BUS;
                    end
                end
                PRIME: if (prime_done) state<=WAIT_BUS;
                RESUME_WAIT: if (!memory_pending) begin
                    invalidate<=1; prime_valid<=1; prime_resume<=1; state<=RESUME;
                end
                RESUME: if (prime_done) begin
                    run_enable<=1; aw_hold<=0; w_hold<=0;
                    s_bvalid<=1; s_bresp<=0; state<=IDLE;
                end
                WAIT_BUS: if (!resetting && !core_busy && guard_ticks==0) begin
                    cs_n<=0; wr_n<=reading; rd_n<=!reading;
                    bus_ticks<=32; state<=HOLD;
                    if (!reading) begin
                        if (!core_addr[0]) selected[core_addr[1]]<=core_din;
                        else begin
                            if (core_addr==3 && selected[1]==2) sample_start[7:0]<=core_din;
                            if (core_addr==3 && selected[1]==3) sample_start[15:8]<=core_din;
                        end
                    end
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
                cs_n<=1; wr_n<=1; rd_n<=1; state<=IDLE;
                if (reading) begin ar_hold<=0; s_rvalid<=1; s_rresp<=0; s_rdata<=0; end
                else begin aw_hold<=0; w_hold<=0; s_bvalid<=1; s_bresp<=0; end
            end
            if (memory_fault && !invalidate && !(state==IDLE && aw_hold && w_hold &&
                aw_address[11:2]==1 && write_strobes==15 && write_data[1])) begin
                run_enable<=0; mute<=1;
            end
        end
    end
endmodule
