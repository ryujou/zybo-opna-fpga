// SPDX-License-Identifier: GPL-3.0-or-later
module opna_zybo_system (
    (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 sys_clk CLK",
       X_INTERFACE_PARAMETER="ASSOCIATED_BUSIF S_AXI:M_AXI, ASSOCIATED_RESET sys_resetn, FREQ_HZ 100000000" *)
    input wire sys_clk,
    (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 sys_resetn RST", X_INTERFACE_PARAMETER="POLARITY ACTIVE_LOW" *)
    input wire sys_resetn,
    (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 audio_clk CLK",
       X_INTERFACE_PARAMETER="ASSOCIATED_RESET audio_resetn, FREQ_HZ 12288002" *)
    input wire audio_clk,
    (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 audio_resetn RST", X_INTERFACE_PARAMETER="POLARITY ACTIVE_LOW" *)
    input wire audio_resetn,
    (* X_INTERFACE_PARAMETER="PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 12, ID_WIDTH 0, FREQ_HZ 100000000" *)
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    input wire [11:0] S_AXI_AWADDR,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *)
    input wire [2:0] S_AXI_AWPROT,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input wire S_AXI_AWVALID,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output wire S_AXI_AWREADY,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input wire [31:0] S_AXI_WDATA,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input wire [3:0] S_AXI_WSTRB,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input wire S_AXI_WVALID,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output wire S_AXI_WREADY,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output wire [1:0] S_AXI_BRESP,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output wire S_AXI_BVALID,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input wire S_AXI_BREADY,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
    input wire [11:0] S_AXI_ARADDR,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *)
    input wire [2:0] S_AXI_ARPROT,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input wire S_AXI_ARVALID,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output wire S_AXI_ARREADY,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output wire [31:0] S_AXI_RDATA,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output wire [1:0] S_AXI_RRESP,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output wire S_AXI_RVALID,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input wire S_AXI_RREADY,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWID" *)
    output wire [5:0] M_AXI_AWID,
    (* X_INTERFACE_PARAMETER="PROTOCOL AXI4, DATA_WIDTH 64, ADDR_WIDTH 32, ID_WIDTH 6, FREQ_HZ 100000000" *)
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWADDR" *)
    output wire [31:0] M_AXI_AWADDR,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWLEN" *)
    output wire [7:0] M_AXI_AWLEN,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWSIZE" *)
    output wire [2:0] M_AXI_AWSIZE,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWBURST" *)
    output wire [1:0] M_AXI_AWBURST,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWLOCK" *)
    output wire M_AXI_AWLOCK,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWCACHE" *)
    output wire [3:0] M_AXI_AWCACHE,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWPROT" *)
    output wire [2:0] M_AXI_AWPROT,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWQOS" *)
    output wire [3:0] M_AXI_AWQOS,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWVALID" *)
    output wire M_AXI_AWVALID,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWREADY" *)
    input wire M_AXI_AWREADY,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI WDATA" *)
    output wire [63:0] M_AXI_WDATA,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI WSTRB" *)
    output wire [7:0] M_AXI_WSTRB,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI WLAST" *)
    output wire M_AXI_WLAST,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI WVALID" *)
    output wire M_AXI_WVALID,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI WREADY" *)
    input wire M_AXI_WREADY,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI BID" *)
    input wire [5:0] M_AXI_BID,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI BRESP" *)
    input wire [1:0] M_AXI_BRESP,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI BVALID" *)
    input wire M_AXI_BVALID,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI BREADY" *)
    output wire M_AXI_BREADY,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARID" *)
    output wire [5:0] M_AXI_ARID,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARADDR" *)
    output wire [31:0] M_AXI_ARADDR,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARLEN" *)
    output wire [7:0] M_AXI_ARLEN,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARSIZE" *)
    output wire [2:0] M_AXI_ARSIZE,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARBURST" *)
    output wire [1:0] M_AXI_ARBURST,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARLOCK" *)
    output wire M_AXI_ARLOCK,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARCACHE" *)
    output wire [3:0] M_AXI_ARCACHE,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARPROT" *)
    output wire [2:0] M_AXI_ARPROT,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARQOS" *)
    output wire [3:0] M_AXI_ARQOS,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARVALID" *)
    output wire M_AXI_ARVALID,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARREADY" *)
    input wire M_AXI_ARREADY,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RID" *)
    input wire [5:0] M_AXI_RID,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RDATA" *)
    input wire [63:0] M_AXI_RDATA,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RRESP" *)
    input wire [1:0] M_AXI_RRESP,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RLAST" *)
    input wire M_AXI_RLAST,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RVALID" *)
    input wire M_AXI_RVALID,
    (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RREADY" *)
    output wire M_AXI_RREADY,
    (* X_INTERFACE_INFO="xilinx.com:signal:interrupt:1.0 irq INTERRUPT", X_INTERFACE_PARAMETER="SENSITIVITY LEVEL_HIGH" *)
    output wire irq,
    output wire i2s_sclk, i2s_ws, i2s_sd, ac_mute_n,
    output wire [3:0] led
);
    wire run_enable, mute, invalidate, resetting, ic_n;
    wire [31:0] ddr_base, memory_faults;
    wire [1:0] memory_type;
    wire cs_n, wr_n, rd_n;
    wire [1:0] core_addr;
    wire [7:0] core_din, core_dout;
    wire busy, irq_n, memory_pending, memory_fault, memory_ready, audio_ready;
    wire prime_valid, prime_done, prime_resume;
    wire [17:0] prime_address;
    wire [7:0] memory_dm, memory_data;
    wire memory_dm_d, memory_a8, memory_ras_n, memory_cas_n, memory_we_n;
    wire memory_romcs_n, memory_mden, memory_dt0;
    wire [2:0] adpcm_status;
    wire [1:0] pcm_valid;
    wire signed [15:0] pcm_left, pcm_right;
    wire [4:0] ssg_a, ssg_b, ssg_c;
    reg [4:0] half_acc;
    reg chip_phase;
    reg half_ce_delayed;
    wire half_due=half_acc>=21;
    // A cache miss stops before consuming an incorrect sample. It is a visible
    // fault, never an alternate normal-play clock rate.
    wire half_ce=half_due && (resetting || (run_enable && !memory_fault && memory_ready));
    always @(posedge sys_clk) begin
        if (!sys_resetn) begin half_acc<=0; chip_phase<=0; half_ce_delayed<=0; end
        else begin
            half_acc<=half_due ? half_acc-21 : half_acc+4;
            half_ce_delayed<=half_ce;
            if (half_ce) chip_phase<=!chip_phase;
        end
    end
    assign irq=!irq_n || memory_fault;
    assign led={memory_fault,resetting,busy,run_enable};
    opna_axi_host host (
        .clk(sys_clk), .resetn(sys_resetn), .half_ce(half_ce), .core_busy(busy),
        .core_irq_n(irq_n), .memory_fault(memory_fault), .core_dout(core_dout),
        .adpcm_status(adpcm_status), .memory_pending(memory_pending), .audio_ready(audio_ready),
        .memory_faults(memory_faults), .s_awaddr(S_AXI_AWADDR), .s_araddr(S_AXI_ARADDR),
        .s_awvalid(S_AXI_AWVALID), .s_wvalid(S_AXI_WVALID), .s_bready(S_AXI_BREADY),
        .s_arvalid(S_AXI_ARVALID), .s_rready(S_AXI_RREADY), .s_wdata(S_AXI_WDATA),
        .s_wstrb(S_AXI_WSTRB), .s_awready(S_AXI_AWREADY), .s_wready(S_AXI_WREADY),
        .s_arready(S_AXI_ARREADY), .s_bvalid(S_AXI_BVALID), .s_rvalid(S_AXI_RVALID),
        .s_bresp(S_AXI_BRESP), .s_rresp(S_AXI_RRESP), .s_rdata(S_AXI_RDATA),
        .run_enable(run_enable), .mute(mute), .ddr_base(ddr_base), .memory_type(memory_type),
        .invalidate(invalidate), .ic_n(ic_n), .resetting(resetting), .cs_n(cs_n),
        .wr_n(wr_n), .rd_n(rd_n), .core_addr(core_addr), .core_din(core_din),
        .prime_valid(prime_valid), .prime_resume(prime_resume), .prime_address(prime_address), .prime_done(prime_done)
    );
    ym2608 core (
        .clk(sys_clk), .half_ce(half_ce), .chip_clk(chip_phase), .ic_n(ic_n),
        .cs_n(cs_n), .wr_n(wr_n), .rd_n(rd_n), .addr(core_addr), .din(core_din),
        .adpcm_flags(3'b0), .adpcm_dout(8'b0), .adpcm_read_valid(1'b0),
        .gpio_a(8'b0), .gpio_b(8'b0), .memory_data(memory_data), .memory_dt0(memory_dt0),
        .adc_input(8'b0), .adc_feedback(8'b0), .memory_dm(memory_dm),
        .memory_dm_d(memory_dm_d), .memory_a8(memory_a8), .memory_ras_n(memory_ras_n),
        .memory_cas_n(memory_cas_n), .memory_we_n(memory_we_n),
        .memory_romcs_n(memory_romcs_n), .memory_mden(memory_mden),
        .adpcm_status(adpcm_status), .dout(core_dout), .irq_n(irq_n), .busy(busy),
        .pcm_valid(pcm_valid), .pcm_left(pcm_left), .pcm_right(pcm_right),
        .ssg_a(ssg_a), .ssg_b(ssg_b), .ssg_c(ssg_c)
    );
    opna_ddr_memory memory (
        .clk(sys_clk), .resetn(sys_resetn), .invalidate(invalidate), .ddr_base(ddr_base),
        .memory_type(memory_type), .prime_valid(prime_valid), .prime_resume(prime_resume), .prime_address(prime_address),
        .prime_done(prime_done), .dm(memory_dm), .a8(memory_a8), .dm_d(memory_dm_d),
        .ras_n(memory_ras_n), .cas_n(memory_cas_n), .we_n(memory_we_n),
        .romcs_n(memory_romcs_n), .mden(memory_mden), .sample_edge(half_due && run_enable && !resetting),
        .memory_data(memory_data), .memory_dt0(memory_dt0), .memory_ready(memory_ready),
        .pending(memory_pending), .fault(memory_fault), .faults(memory_faults),
        .m_araddr(M_AXI_ARADDR), .m_arvalid(M_AXI_ARVALID), .m_arready(M_AXI_ARREADY),
        .m_rdata(M_AXI_RDATA), .m_rresp(M_AXI_RRESP), .m_rvalid(M_AXI_RVALID),
        .m_rlast(M_AXI_RLAST), .m_rready(M_AXI_RREADY), .m_awaddr(M_AXI_AWADDR),
        .m_awvalid(M_AXI_AWVALID), .m_awready(M_AXI_AWREADY), .m_wdata(M_AXI_WDATA),
        .m_wstrb(M_AXI_WSTRB), .m_wvalid(M_AXI_WVALID), .m_wready(M_AXI_WREADY),
        .m_bvalid(M_AXI_BVALID), .m_bresp(M_AXI_BRESP), .m_bready(M_AXI_BREADY)
    );
    assign M_AXI_ARID=0;
    assign M_AXI_ARLEN=7;
    assign M_AXI_ARSIZE=3;
    assign M_AXI_ARBURST=1;
    assign M_AXI_ARLOCK=0;
    assign M_AXI_ARCACHE=3;
    assign M_AXI_ARPROT=0;
    assign M_AXI_ARQOS=0;
    assign M_AXI_AWID=0;
    assign M_AXI_AWLEN=0;
    assign M_AXI_AWSIZE=3;
    assign M_AXI_AWBURST=1;
    assign M_AXI_AWLOCK=0;
    assign M_AXI_AWCACHE=3;
    assign M_AXI_AWPROT=0;
    assign M_AXI_AWQOS=0;
    assign M_AXI_WLAST=1;
    opna_audio_output audio (
        .sys_clk(sys_clk), .sys_resetn(sys_resetn), .audio_clk(audio_clk),
        .audio_resetn(audio_resetn), .mute(mute || memory_fault || resetting),
        .pcm_valid(pcm_valid & {2{half_ce_delayed}}), .pcm_left(pcm_left), .pcm_right(pcm_right),
        .ssg_a(ssg_a), .ssg_b(ssg_b), .ssg_c(ssg_c),
        .i2s_sclk(i2s_sclk), .i2s_ws(i2s_ws), .i2s_sd(i2s_sd),
        .ac_mute_n(ac_mute_n), .ready(audio_ready)
    );
endmodule
