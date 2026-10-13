`timescale 1ns/1ps
module phase7_ddr_model (
    input wire clk,resetn,
    input wire [31:0] M_AXI_ARADDR,M_AXI_AWADDR,
    input wire [7:0] M_AXI_ARLEN,M_AXI_AWLEN,
    input wire [2:0] M_AXI_ARSIZE,M_AXI_AWSIZE,
    input wire [1:0] M_AXI_ARBURST,M_AXI_AWBURST,
    input wire M_AXI_ARVALID,M_AXI_AWVALID,M_AXI_WVALID,M_AXI_WLAST,
    output wire M_AXI_ARREADY,M_AXI_AWREADY,M_AXI_WREADY,
    input wire [63:0] M_AXI_WDATA,
    input wire [7:0] M_AXI_WSTRB,
    output reg [63:0] M_AXI_RDATA,
    output reg [1:0] M_AXI_RRESP,M_AXI_BRESP,
    output reg M_AXI_RVALID,M_AXI_RLAST,M_AXI_BVALID,
    input wire M_AXI_RREADY,M_AXI_BREADY,
    input wire inject_error, stall_reads,
    input wire [15:0] latency
);
    reg [7:0] bytes[0:262143];
    integer cycles=0,read_wait,read_beat,write_wait;
    reg read_pending,aw_hold,w_hold,write_pending;
    reg [17:0] read_address,write_address;
    reg [63:0] write_data;
    reg [7:0] write_mask;
    assign M_AXI_ARREADY=!read_pending && !M_AXI_RVALID && cycles%7!=2;
    assign M_AXI_AWREADY=!aw_hold && !write_pending && !M_AXI_BVALID && cycles%5!=1;
    assign M_AXI_WREADY=!w_hold && !write_pending && !M_AXI_BVALID && cycles%7!=3;
    initial for(integer i=0;i<262144;i=i+1) bytes[i]=(i*37+(i>>9)+8'h53)&255;
    always @(posedge clk) begin
        if(!resetn) begin
            cycles<=0; read_pending<=0; M_AXI_RVALID<=0; M_AXI_RLAST<=0;
            M_AXI_RDATA<=0; M_AXI_RRESP<=0; M_AXI_BVALID<=0; M_AXI_BRESP<=0;
            aw_hold<=0; w_hold<=0; write_pending<=0; read_wait<=0; read_beat<=0;
            write_wait<=0; read_address<=0; write_address<=0; write_data<=0; write_mask<=0;
        end else begin
            cycles<=cycles+1;
            if(M_AXI_ARVALID && M_AXI_ARREADY) begin
                if(M_AXI_ARLEN!=7 || M_AXI_ARSIZE!=3 || M_AXI_ARBURST!=1 || M_AXI_ARADDR[5:0]!=0)
                    $fatal(1,"HP0 burst read protocol");
                if(M_AXI_ARADDR<32'h01000000 || M_AXI_ARADDR>32'h0103ffc0)
                    $fatal(1,"HP0 read outside full native 256KiB %h",M_AXI_ARADDR);
                read_pending<=1; read_address<=M_AXI_ARADDR-32'h01000000;
                read_wait<=latency; read_beat<=0;
            end
            if(read_pending && !M_AXI_RVALID && !stall_reads) begin
                if(read_wait!=0) read_wait<=read_wait-1;
                else begin
                    for(integer i=0;i<8;i=i+1) M_AXI_RDATA[i*8+:8]<=bytes[read_address+read_beat*8+i];
                    M_AXI_RVALID<=1; M_AXI_RLAST<=read_beat==7;
                    M_AXI_RRESP<=inject_error ? 2 : 0;
                end
            end
            if(M_AXI_RVALID && M_AXI_RREADY) begin
                M_AXI_RVALID<=0;
                if(M_AXI_RLAST) read_pending<=0;
                else begin read_beat<=read_beat+1; read_wait<=cycles%4; end
            end
            if(M_AXI_AWVALID && M_AXI_AWREADY) begin
                if(M_AXI_AWLEN!=0 || M_AXI_AWSIZE!=3 || M_AXI_AWBURST!=1 || M_AXI_AWADDR[2:0]!=0)
                    $fatal(1,"HP0 write protocol");
                if(M_AXI_AWADDR<32'h01000000 || M_AXI_AWADDR>32'h0103fff8)
                    $fatal(1,"HP0 write outside full native 256KiB");
                aw_hold<=1; write_address<=M_AXI_AWADDR-32'h01000000;
            end
            if(M_AXI_WVALID && M_AXI_WREADY) begin
                if(!M_AXI_WLAST) $fatal(1,"HP0 write last");
                w_hold<=1; write_data<=M_AXI_WDATA; write_mask<=M_AXI_WSTRB;
            end
            if(aw_hold && w_hold && !write_pending) begin
                for(integer i=0;i<8;i=i+1) if(write_mask[i]) bytes[write_address+i]<=write_data[i*8+:8];
                aw_hold<=0; w_hold<=0; write_pending<=1; write_wait<=latency;
            end
            if(write_pending && !M_AXI_BVALID) begin
                if(write_wait!=0) write_wait<=write_wait-1;
                else begin M_AXI_BVALID<=1; M_AXI_BRESP<=inject_error ? 2 : 0; end
            end
            if(M_AXI_BVALID && M_AXI_BREADY) begin M_AXI_BVALID<=0; write_pending<=0; end
        end
    end
endmodule
