`timescale 1ns/1ps
module phase7_host_test(output reg done=0);
    reg clk=0; always #5 clk=~clk;
    reg resetn=0;
    wire half_ce=1;
    reg core_busy=0, core_irq_n=1, memory_fault=0;
    wire [1:0] memory_type,core_addr;
    wire [7:0] core_dout=8'ha0+core_addr;
    wire [2:0] adpcm_status=3'b101;
    wire memory_pending=0, audio_ready=1;
    wire [31:0] memory_faults=0;
    reg [11:0] s_awaddr=0,s_araddr=0;
    reg s_awvalid=0,s_wvalid=0,s_bready=0,s_arvalid=0,s_rready=0;
    reg [31:0] s_wdata=0;
    reg [3:0] s_wstrb=0;
    wire s_awready,s_wready,s_arready,s_bvalid,s_rvalid;
    wire [1:0] s_bresp,s_rresp;
    wire [31:0] s_rdata,ddr_base;
    wire run_enable,mute,invalidate,ic_n,resetting,cs_n,wr_n,rd_n;
    wire [7:0] core_din;
    wire prime_valid,prime_resume; wire [17:0] prime_address;
    reg prime_done=0;
    always @(posedge clk) begin
        prime_done<=prime_valid && prime_resume;
    end
    opna_axi_host dut(.*);
    integer writes=0;
    reg [7:0] observed_data[0:15]; reg [1:0] observed_port[0:15];
    reg prior_wr=1;
    integer host_ticks=0,last_data_release=-2000,required_wait=0;
    reg[7:0] register_address[0:1];
    reg prior_ic=0,prior_reset=1;
    integer last_ic_fall=-1,last_ic_rise=-1;
    always @(posedge clk) begin
        #1;
        host_ticks=host_ticks+1;
        if(prior_ic && !ic_n) last_ic_fall=host_ticks;
        if(!prior_ic && ic_n) begin
            if(last_ic_fall>=0 && host_ticks-last_ic_fall!=1152) $fatal(1,"host IC low duration");
            last_ic_rise=host_ticks;
        end
        if(prior_reset && !resetting && last_ic_rise>=0 && host_ticks-last_ic_rise!=1152)
            $fatal(1,"host IC stable duration");
        prior_ic=ic_n; prior_reset=resetting;
        if (prior_wr && !wr_n) begin
            if(host_ticks-last_data_release<required_wait) $fatal(1,"host manual wait after WR release");
            observed_data[writes]=core_din; observed_port[writes]=core_addr; writes=writes+1;
            if(!core_addr[0]) register_address[core_addr[1]]=core_din;
        end
        if(!prior_wr && wr_n && core_addr[0]) begin
            last_data_release=host_ticks;
            required_wait=core_addr==1 && register_address[0]==16 ? 1152 : 166;
        end
        prior_wr=wr_n;
    end
    task send_aw(input [11:0] a);
        @(negedge clk); s_awaddr=a; s_awvalid=1;
        do @(posedge clk); while(!s_awready);
        @(negedge clk); s_awvalid=0;
    endtask
    task send_w(input [31:0] d,input [3:0] st);
        @(negedge clk); s_wdata=d; s_wstrb=st; s_wvalid=1;
        do @(posedge clk); while(!s_wready);
        @(negedge clk); s_wvalid=0;
    endtask
    task response(input [1:0] expected);
        wait(s_bvalid); if(s_bresp!==expected) $fatal(1,"host BRESP");
        repeat(5) begin @(posedge clk); if(!s_bvalid || s_bresp!==expected) $fatal(1,"host B backpressure"); end
        @(negedge clk); s_bready=1; @(negedge clk); s_bready=0;
    endtask
    task write32(input [11:0] a,input [31:0] d,input [3:0] st,input integer order,input [1:0] resp);
        if(order==0) begin send_aw(a); repeat(3) @(posedge clk); send_w(d,st); end
        else begin send_w(d,st); repeat(3) @(posedge clk); send_aw(a); end
        response(resp);
    endtask
    task read32(input [11:0] a,input [31:0] expected);
        @(negedge clk); s_araddr=a; s_arvalid=1;
        do @(posedge clk); while(!s_arready);
        @(negedge clk); s_arvalid=0;
        wait(s_rvalid);
        repeat(5) begin @(posedge clk); if(s_rdata!==expected || s_rresp!==0) $fatal(1,"host read/backpressure addr%h got%h expected%h",a,s_rdata,expected); end
        @(negedge clk); s_rready=1; @(negedge clk); s_rready=0;
    endtask
    initial begin
        repeat(4) @(posedge clk); @(negedge clk); resetn=1; wait(!resetting);
        write32(0,32'hdeadbeef,15,0,0);
        if(writes!=4) $fatal(1,"host full strobes count");
        for(integer i=0;i<4;i=i+1)
            if(observed_port[i]!==i || observed_data[i]!==((32'hdeadbeef>>(i*8))&255)) $fatal(1,"host bank/lane%0d",i);
        write32(3,32'h42000000,8,1,0);
        if(observed_port[4]!==3 || observed_data[4]!==8'h42) $fatal(1,"host bank1 data byte");
        read32(3,32'ha3000000); read32(0,32'ha0);
        read32(12,32'h01000000); read32(28,32'h26080007);
        write32(0,16,1,0,0); write32(1,32'h00003f00,2,0,0);
        write32(0,17,1,0,0); // Explicit 576 MCLK wait after rhythm WR release.
        core_busy=1;
        fork
            begin write32(1,32'h00005500,2,0,0); end
            begin repeat(40) @(posedge clk); if(writes!=8) $fatal(1,"host ignored busy"); core_busy=0; end
        join
        write32(2,0,4,0,0); // Bank1 selected ADPCM control.
        fork
            begin write32(3,32'h20000000,8,1,0); end
            begin wait(prime_valid); repeat(8) @(posedge clk); memory_fault=1; end
        join
        if(!cs_n || !wr_n || !rd_n) $fatal(1,"host fault bus release");
        memory_fault=0;
        write32(4,2,15,0,0); // RUN=0 reset must still finish.
        if(run_enable || !resetting || ic_n) $fatal(1,"host IC command");
        wait(ic_n); if(!resetting) $fatal(1,"host reset stabilization absent");
        wait(!resetting);
        write32(12,32'h01200000,15,1,0); read32(12,32'h01200000);
        write32(16,2,15,0,0); read32(16,2);
        write32(4,1,15,0,0);
        $display("CHECK host_independent_aw_w_ar_four_byte_banks_busy_backpressure_ic_fault"); done=1;
    end
endmodule

module phase7_audio_test(output reg done=0);
    reg sys_clk=0,audio_clk=0;
    always #5 sys_clk=~sys_clk;
    always #40.690104 audio_clk=~audio_clk;
    reg sys_resetn=0,audio_resetn=0,mute=0;
    reg [1:0] pcm_valid=0;
    reg signed [15:0] pcm_left=0,pcm_right=0;
    reg [4:0] ssg_a=1,ssg_b=1,ssg_c=1;
    wire i2s_sclk,i2s_ws,i2s_sd,ac_mute_n,ready;
    opna_audio_output dut(.*);
    task pair(input signed[15:0] l,r);
        @(negedge sys_clk); pcm_left=l; pcm_valid=1;
        @(negedge sys_clk); pcm_valid=0;
        repeat(40) @(posedge sys_clk);
        @(negedge sys_clk); pcm_right=r; pcm_valid=2;
        @(negedge sys_clk); pcm_valid=0;
    endtask
    task decode(input reg channel,output reg[15:0] value);
        if(channel) @(posedge i2s_ws); else @(negedge i2s_ws);
        @(posedge i2s_sclk); // I2S delays MSB one SCLK after WS changes.
        value=0;
        repeat(16) begin @(posedge i2s_sclk); value={value[14:0],i2s_sd}; end
        repeat(15) begin @(posedge i2s_sclk); if(i2s_sd!==0) $fatal(1,"I2S padding"); end
    endtask
    reg [15:0] l,r;
    initial begin
        repeat(4) @(posedge sys_clk); @(negedge sys_clk); sys_resetn=1;
        #173; audio_resetn=1;
        pair(16'h1234,-16'sh2345);
        repeat(4) @(posedge i2s_ws);
        decode(0,l); decode(1,r);
        if(l!==16'h1234 || r!==-16'sh2345) $fatal(1,"I2S external decode %h/%h",l,r);
        if(!ready || !ac_mute_n) $fatal(1,"audio sticky ready");
        ssg_a=31; ssg_b=30; ssg_c=29;
        pair(1000,-2000);
        repeat(3) @(posedge i2s_ws);
        decode(0,l); decode(1,r);
        if(l!==32767 || r!==32767) $fatal(1,"audio three SSG / clipping");
        ssg_a=0; ssg_b=1; ssg_c=2;
        pair(1111,-2222);
        repeat(3) @(posedge i2s_ws);
        decode(0,l); decode(1,r);
        if(l!==1189 || r!==16'(-2144)) $fatal(1,"audio SSG amplitude unity %h/%h",l,r);
        mute=1; repeat(3) @(posedge i2s_ws); decode(0,l); decode(1,r);
        if(l!==0 || r!==0 || ac_mute_n) $fatal(1,"audio mute");
        audio_resetn=0; #293; audio_resetn=1; mute=0;
        repeat(3) @(posedge i2s_ws); decode(0,l); decode(1,r);
        if(l!==1189 || r!==16'(-2144)) $fatal(1,"audio separate domain reset");
        $display("CHECK audio_external_i2s16_stereo_pair_zoh_ssg_saturation_async_reset"); done=1;
    end
endmodule

module phase7_board_tb;
    wire host_done,audio_done;
    phase7_host_test host(host_done);
    phase7_audio_test audio(audio_done);
    initial begin wait(host_done && audio_done); $display("BOARD_SUBSYSTEM_PASS"); $finish; end
    initial begin #10000000; $fatal(1,"board subsystem timeout"); end
endmodule
