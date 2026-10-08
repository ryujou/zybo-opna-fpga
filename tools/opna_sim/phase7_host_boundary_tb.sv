`timescale 1ns/1ps
module phase7_host_boundary_tb;
    reg clk=0; always #5 clk=~clk;
    reg resetn=0;
    wire run_enable,mute,invalidate,ic_n,resetting,reset_pending,cs_n,wr_n,rd_n;
    reg core_busy=0,core_irq_n=1,memory_fault=0;
    reg [4:0] half_acc=0;
    reg chip_phase=0;
    wire raw_half_due=half_acc>=21;
    wire half_ce=resetn && raw_half_due && !reset_pending &&
                 (resetting || (run_enable && !memory_fault));
    always @(posedge clk) begin
        if(!resetn) begin half_acc<=0; chip_phase<=0; end
        else begin
            half_acc<=raw_half_due ? half_acc-21 : half_acc+4;
            if(half_ce) chip_phase<=!chip_phase;
        end
    end
    wire [1:0] memory_type,core_addr;
    wire [7:0] core_dout=8'ha0+core_addr;
    wire [2:0] adpcm_status=0;
    wire memory_pending=0,audio_ready=1;
    wire [31:0] memory_faults=0;
    reg [11:0] s_awaddr=0,s_araddr=0;
    reg s_awvalid=0,s_wvalid=0,s_bready=0,s_arvalid=0,s_rready=0;
    reg [31:0] s_wdata=0;
    reg [3:0] s_wstrb=0;
    wire s_awready,s_wready,s_arready,s_bvalid,s_rvalid;
    wire [1:0] s_bresp,s_rresp;
    wire [31:0] s_rdata,ddr_base;
    wire [7:0] core_din;
    wire prime_valid,prime_resume;
    wire [17:0] prime_address;
    reg prime_done=0;
    wire mode_switch=0;
    wire [31:0] pcm_gain, ssg_gain, master_gain;
    wire [1:0] clip_clear;
    reg [31:0] clip_left=0, clip_right=0;
    opna_axi_host dut(.*);
    always @(posedge clk) begin
        prime_done<=prime_valid;
        if(invalidate) memory_fault<=0;
    end

    wire [50:0] sources={resetting,reset_pending,run_enable,ic_n,cs_n,wr_n,rd_n,
                         core_addr,core_din,memory_type,ddr_base};
    integer sys_cycles=0,native_ticks=0,release_cycle=0;
    integer last_change[0:50];
    integer minimum_source_gap=1000000,source_changes=0;
    integer low_count=0,high_count=0,reset_epochs=0,ctrl_cycle=0,ic_commit_cycle=0;
    integer first_low_cycle=0,first_high_cycle=0,warm_end_cycle=0;
    integer last_data_release=-2000,required_guard=0,active_ticks=0;
    integer writes=0,reads=0;
    reg epoch_active=0,previous_resetn=0,previous_wr=1,previous_rd=1;
    reg [7:0] selected[0:1];
    reg old_raw,old_ce,old_resetn,old_ic,old_pending,old_phase,old_resetting;
    reg [50:0] old_sources;
    reg old_ctrl_reset;
    initial begin
        for(integer bitno=0;bitno<51;bitno=bitno+1) last_change[bitno]=-1000000;
        selected[0]=0; selected[1]=0;
    end
    always @(posedge clk) begin
        sys_cycles=sys_cycles+1;
        old_raw=raw_half_due; old_ce=half_ce; old_resetn=resetn;
        old_ic=ic_n; old_pending=reset_pending; old_phase=chip_phase;
        old_resetting=resetting; old_sources=sources;
        old_ctrl_reset=dut.state==0 && dut.aw_hold && dut.w_hold && !s_bvalid &&
                       dut.aw_address==4 && dut.write_strobes==15 && dut.write_data[1];
        if(old_resetn && !previous_resetn) begin
            release_cycle=sys_cycles; epoch_active=1; low_count=0; high_count=0;
            first_low_cycle=0; first_high_cycle=0;
        end
        if(old_ce) begin
            native_ticks=native_ticks+1;
            if(native_ticks==1 && (sys_cycles-release_cycle+1!=7 || old_phase!=0))
                $fatal(1,"SYS reset first native edge");
            for(integer bitno=0;bitno<51;bitno=bitno+1) begin
                if(sys_cycles-last_change[bitno]<6)
                    $fatal(1,"native source[%0d] captured only %0d SYS after update",bitno,sys_cycles-last_change[bitno]);
                if(last_change[bitno]>=0 && sys_cycles-last_change[bitno]<minimum_source_gap)
                    minimum_source_gap=sys_cycles-last_change[bitno];
            end
            if(epoch_active) begin
                if(!old_ic) begin
                    if(low_count==0) first_low_cycle=sys_cycles;
                    low_count=low_count+1;
                    if(high_count!=0 || low_count>1152) $fatal(1,"reset consumed IC0 count");
                end else begin
                    if(high_count==0) first_high_cycle=sys_cycles;
                    high_count=high_count+1;
                    if(low_count!=1152 || high_count>1152) $fatal(1,"reset consumed IC1 count");
                end
            end
            if(!cs_n && !wr_n) active_ticks=active_ticks+1;
            if(!cs_n && !rd_n) active_ticks=active_ticks+1;
        end
        if(old_pending && old_ce) $fatal(1,"reset pending consumed old native state");
        if(old_ctrl_reset) ctrl_cycle=sys_cycles;
        #1;
        if(old_resetn) begin
            for(integer bitno=0;bitno<48;bitno=bitno+1)
                if(old_sources[bitno]!==sources[bitno] && !old_raw)
                    $fatal(1,"native port source[%0d] changed outside raw boundary",bitno);
            if(old_pending && old_raw) begin
                if(old_ce || reset_pending || ic_n || !resetting || dut.reset_ticks!=2304)
                    $fatal(1,"pending reset boundary commit");
                ic_commit_cycle=sys_cycles; epoch_active=1; low_count=0; high_count=0;
                first_low_cycle=0; first_high_cycle=0;
            end
            if(old_ctrl_reset && (!resetting || !reset_pending)) $fatal(1,"reset request not immediate");
            if(!old_pending && reset_pending && chip_phase!==old_phase && !old_ce)
                $fatal(1,"pending reset changed chip phase");
            if(old_resetting && !resetting) begin
                if(low_count!=1152 || high_count!=1152) $fatal(1,"reset total consumed count");
                warm_end_cycle=sys_cycles; epoch_active=0; reset_epochs=reset_epochs+1;
            end
            if(previous_wr && !wr_n) begin
                if(native_ticks-last_data_release<required_guard) $fatal(1,"manual guard after WR release");
                active_ticks=0; writes=writes+1;
                if(!core_addr[0]) selected[core_addr[1]]=core_din;
            end
            if(!previous_wr && wr_n && !memory_fault) begin
                if(active_ticks!=32) $fatal(1,"WR consumed hold count %0d",active_ticks);
                if(core_addr[0]) begin
                    last_data_release=native_ticks;
                    required_guard=core_addr==1 && selected[0]==16 ? 1152 : 166;
                end
            end
            if(previous_rd && !rd_n) begin active_ticks=0; reads=reads+1; end
            if(!previous_rd && rd_n && !memory_fault && active_ticks!=32)
                $fatal(1,"RD consumed hold count");
        end
        for(integer bitno=0;bitno<51;bitno=bitno+1)
            if(old_sources[bitno]!==sources[bitno]) begin
                last_change[bitno]=sys_cycles; source_changes=source_changes+1;
            end
        previous_resetn=old_resetn; previous_wr=wr_n; previous_rd=rd_n;
    end

    task send_aw(input [11:0] a);
        @(negedge clk); s_awaddr=a; s_awvalid=1;
        do @(posedge clk); while(!s_awready);
        @(negedge clk); s_awvalid=0;
    endtask
    task send_w(input [31:0] d,input [3:0] strobes);
        @(negedge clk); s_wdata=d; s_wstrb=strobes; s_wvalid=1;
        do @(posedge clk); while(!s_wready);
        @(negedge clk); s_wvalid=0;
    endtask
    task response;
        wait(s_bvalid);
        if(s_bresp!==0) $fatal(1,"boundary BRESP");
        @(negedge clk); s_bready=1; @(negedge clk); s_bready=0;
    endtask
    task write32(input [11:0] a,input [31:0] d,input [3:0] strobes,input integer order);
        if(order==0) begin send_aw(a); repeat(3) @(posedge clk); send_w(d,strobes); end
        else begin send_w(d,strobes); repeat(3) @(posedge clk); send_aw(a); end
        response();
    endtask
    task read_byte(input [1:0] port);
        @(negedge clk); s_araddr=port; s_arvalid=1;
        do @(posedge clk); while(!s_arready);
        @(negedge clk); s_arvalid=0;
        wait(s_rvalid);
        if(s_rresp!==0 || s_rdata!==(32'(8'ha0+port)<<(port*8))) $fatal(1,"boundary RDATA lane");
        @(negedge clk); s_rready=1; @(negedge clk); s_rready=0;
    endtask
    function automatic integer due_cycle(input integer cycle);
        due_cycle=((4*(cycle-release_cycle))%25)>=21;
    endfunction
    task reset_at(input integer offset,run_requested,fault_before);
        integer next_due,target;
        write32(4,run_requested,15,0);
        next_due=sys_cycles+6;
        while(!due_cycle(next_due)) next_due=next_due+1;
        target=next_due+offset;
        while(sys_cycles<target-2) @(negedge clk);
        s_awaddr=4; s_awvalid=1; s_wdata=run_requested|2; s_wstrb=15; s_wvalid=1;
        memory_fault=fault_before;
        @(posedge clk); @(negedge clk); s_awvalid=0; s_wvalid=0;
        response(); wait(!resetting); #2;
        if(ctrl_cycle!=target || ic_commit_cycle<=ctrl_cycle || first_low_cycle-ic_commit_cycle<6)
            $fatal(1,"reset actual boundary matrix target%0d CTRL%0d commit%0d firstlow%0d",target,ctrl_cycle,ic_commit_cycle,first_low_cycle);
        if(run_enable!==1'(run_requested) || memory_fault) $fatal(1,"reset RUN/fault completion");
        $display("RESET_BOUNDARY offset=%0d run_requested=%0d fault_before=%0d control_sys=%0d ic_commit_sys=%0d first_low_sys=%0d first_high_sys=%0d warm_end_sys=%0d consumed_low=%0d consumed_high=%0d",offset,run_requested,fault_before,ctrl_cycle,ic_commit_cycle,first_low_cycle,first_high_cycle,warm_end_cycle,low_count,high_count);
    endtask
    task fault_during_bus(input integer reading_bus);
        if(reading_bus) begin
            fork
                begin
                    @(negedge clk); s_araddr=3; s_arvalid=1;
                    do @(posedge clk); while(!s_arready);
                    @(negedge clk); s_arvalid=0;
                    wait(s_rvalid);
                    if(s_rresp!==0 || s_rdata!==0) $fatal(1,"fault native read response");
                    @(negedge clk); s_rready=1; @(negedge clk); s_rready=0;
                end
                begin wait(!rd_n); repeat(2) @(negedge clk); memory_fault=1; end
            join
        end else begin
            fork
                begin write32(3,32'h55000000,8,1); end
                begin wait(!wr_n); repeat(2) @(negedge clk); memory_fault=1; end
            join
        end
        wait(cs_n && wr_n && rd_n);
        write32(4,3,15,0); wait(!resetting); #2;
        if(memory_fault || !run_enable) $fatal(1,"fault reset recovery");
        $display("BUS_FAULT_BOUNDARY reading=%0d control_sys=%0d ic_commit_sys=%0d first_low_sys=%0d",reading_bus,ctrl_cycle,ic_commit_cycle,first_low_cycle);
    endtask
    initial begin
        repeat(4) @(posedge clk); @(negedge clk); resetn=1; wait(!resetting);
        for(integer run_case=0;run_case<2;run_case=run_case+1)
            for(integer fault_case=0;fault_case<2;fault_case=fault_case+1)
                for(integer phase_case=-1;phase_case<=1;phase_case=phase_case+1)
                    reset_at(phase_case,run_case,fault_case);
        write32(4,1,15,0);
        write32(0,32'hdeadbeef,15,0);
        write32(3,32'h42000000,8,1);
        for(integer port=0;port<4;port=port+1) read_byte(port);
        write32(0,16,1,0); write32(1,32'h00003f00,2,0); write32(0,17,1,0);
        write32(4,0,15,0);
        write32(12,32'h01200000,15,1); write32(16,2,15,0);
        if(run_enable || memory_type!=2 || ddr_base!=32'h01200000) $fatal(1,"RUN0 raw config");
        write32(4,1,15,0);
        fault_during_bus(0); fault_during_bus(1);
        if(reset_epochs!=15 || minimum_source_gap<6 || writes!=9 || reads!=5)
            $fatal(1,"boundary coverage epochs%0d writes%0d reads%0d",reset_epochs,writes,reads);
        $display("HOST_BOUNDARY_METRICS reset_matrix=12 reset_epochs=%0d source_changes=%0d min_source_to_consumed_sys=%0d raw_config_run0=1 writes=%0d reads=%0d",reset_epochs,source_changes,minimum_source_gap,writes,reads);
        $display("HOST_BOUNDARY_PASS"); $finish;
    end
    initial begin #5000000; $fatal(1,"host boundary timeout"); end
endmodule
