`timescale 1ns/1ps
module phase7_native_tb;
    reg sys_clk=0,audio_clk=0;
    always #5 sys_clk=~sys_clk;
    always #40.690104 audio_clk=~audio_clk;
    reg sys_resetn=0,audio_resetn=0;
    wire irq,i2s_sclk,i2s_ws,i2s_sd,ac_mute_n; wire[3:0] led;
    reg [11:0] S_AXI_AWADDR=0;
    reg [2:0] S_AXI_AWPROT=0;
    reg S_AXI_AWVALID=0;
    wire S_AXI_AWREADY;
    reg [31:0] S_AXI_WDATA=0;
    reg [3:0] S_AXI_WSTRB=0;
    reg S_AXI_WVALID=0;
    wire S_AXI_WREADY;
    wire [1:0] S_AXI_BRESP;
    wire S_AXI_BVALID;
    reg S_AXI_BREADY=0;
    reg [11:0] S_AXI_ARADDR=0;
    reg [2:0] S_AXI_ARPROT=0;
    reg S_AXI_ARVALID=0;
    wire S_AXI_ARREADY;
    wire [31:0] S_AXI_RDATA;
    wire [1:0] S_AXI_RRESP;
    wire S_AXI_RVALID;
    reg S_AXI_RREADY=0;
    wire [5:0] M_AXI_AWID;
    wire [31:0] M_AXI_AWADDR;
    wire [7:0] M_AXI_AWLEN;
    wire [2:0] M_AXI_AWSIZE;
    wire [1:0] M_AXI_AWBURST;
    wire M_AXI_AWLOCK;
    wire [3:0] M_AXI_AWCACHE;
    wire [2:0] M_AXI_AWPROT;
    wire [3:0] M_AXI_AWQOS;
    wire M_AXI_AWVALID;
    wire M_AXI_AWREADY;
    wire [63:0] M_AXI_WDATA;
    wire [7:0] M_AXI_WSTRB;
    wire M_AXI_WLAST;
    wire M_AXI_WVALID;
    wire M_AXI_WREADY;
    wire [5:0] M_AXI_BID;
    wire [1:0] M_AXI_BRESP;
    wire M_AXI_BVALID;
    wire M_AXI_BREADY;
    wire [5:0] M_AXI_ARID;
    wire [31:0] M_AXI_ARADDR;
    wire [7:0] M_AXI_ARLEN;
    wire [2:0] M_AXI_ARSIZE;
    wire [1:0] M_AXI_ARBURST;
    wire M_AXI_ARLOCK;
    wire [3:0] M_AXI_ARCACHE;
    wire [2:0] M_AXI_ARPROT;
    wire [3:0] M_AXI_ARQOS;
    wire M_AXI_ARVALID;
    wire M_AXI_ARREADY;
    wire [5:0] M_AXI_RID;
    wire [63:0] M_AXI_RDATA;
    wire [1:0] M_AXI_RRESP;
    wire M_AXI_RLAST;
    wire M_AXI_RVALID;
    wire M_AXI_RREADY;
    assign M_AXI_RID=0; assign M_AXI_BID=0;
    reg inject_error=0,stall_reads=0; reg[15:0] latency=24;
    opna_zybo_system dut(.*);
    phase7_ddr_model dram( .clk(sys_clk), .resetn(sys_resetn),
        .M_AXI_ARADDR(M_AXI_ARADDR), .M_AXI_AWADDR(M_AXI_AWADDR), .M_AXI_ARLEN(M_AXI_ARLEN), .M_AXI_AWLEN(M_AXI_AWLEN), .M_AXI_ARSIZE(M_AXI_ARSIZE), .M_AXI_AWSIZE(M_AXI_AWSIZE), .M_AXI_ARBURST(M_AXI_ARBURST), .M_AXI_AWBURST(M_AXI_AWBURST), .M_AXI_ARVALID(M_AXI_ARVALID), .M_AXI_AWVALID(M_AXI_AWVALID), .M_AXI_WVALID(M_AXI_WVALID), .M_AXI_WLAST(M_AXI_WLAST), .M_AXI_ARREADY(M_AXI_ARREADY), .M_AXI_AWREADY(M_AXI_AWREADY), .M_AXI_WREADY(M_AXI_WREADY), .M_AXI_WDATA(M_AXI_WDATA), .M_AXI_WSTRB(M_AXI_WSTRB), .M_AXI_RDATA(M_AXI_RDATA), .M_AXI_RRESP(M_AXI_RRESP), .M_AXI_BRESP(M_AXI_BRESP), .M_AXI_RVALID(M_AXI_RVALID), .M_AXI_RLAST(M_AXI_RLAST), .M_AXI_BVALID(M_AXI_BVALID), .M_AXI_RREADY(M_AXI_RREADY), .M_AXI_BREADY(M_AXI_BREADY),
.inject_error(inject_error),.stall_reads(stall_reads),.latency(latency));
    integer native_ticks=0, candidate_ticks=0, data_ticks=0, memory_writes=0;
    integer frame_count=0, rows=0, columns=0, loops=0;
    reg [7:0] expected[0:262143];
    reg prior_ras=1,prior_cas=1,prior_we=1;
    reg[17:0] external_address=0,previous_read_address=0;
    reg[7:0] expected_data;
    reg check_enable=0;
    integer physical;
    integer crossed_lines=0;
    integer sys_cycles=0,last_cas_cycle=0,last_ras_cycle=0,min_pin_budget=1000000;
    integer fill_cycle[0:4095],first_use[0:4095],min_prefetch_lead=1000000;
    reg[17:0] active_read_line;
    initial for(integer i=0;i<262144;i=i+1) expected[i]=(i*37+(i>>9)+8'h53)&255;
    initial for(integer i=0;i<4096;i=i+1) begin fill_cycle[i]=0; first_use[i]=0; end
    always @(posedge sys_clk) begin
        if(sys_resetn) begin
            sys_cycles=sys_cycles+1;
            if(M_AXI_ARVALID && M_AXI_ARREADY) active_read_line=M_AXI_ARADDR-32'h01000000;
            if(M_AXI_RVALID && M_AXI_RREADY && M_AXI_RLAST) begin
                fill_cycle[active_read_line>>6]=sys_cycles; first_use[active_read_line>>6]=0;
            end
            if(dut.half_due) candidate_ticks=candidate_ticks+1;
            if(dut.half_ce) native_ticks=native_ticks+1;
            if(prior_cas && !dut.memory_cas_n) begin
                external_address[17:9]={dut.memory_a8,dut.memory_dm}; columns=columns+1; last_cas_cycle=sys_cycles;
            end
            if(prior_ras && !dut.memory_ras_n) begin
                external_address[8:0]={dut.memory_a8,dut.memory_dm}; rows=rows+1; last_ras_cycle=sys_cycles;
            end
            if(dut.memory_type!=0 && !dut.memory_ras_n && !dut.memory_cas_n &&
               !dut.memory_we_n && !dut.memory_dm_d && (prior_we || prior_cas)) begin
                if(dut.memory_type==2) begin
                    for(integer b=0;b<8;b=b+1) begin
                        physical=b*32768+(external_address>>3);
                        expected[physical][external_address&7]=dut.memory_dm[b];
                    end
                end else expected[external_address]=dut.memory_dm;
                memory_writes=memory_writes+1;
            end
            if(check_enable && dut.half_ce && !dut.resetting && dut.memory_dm_d &&
               (!dut.memory_romcs_n || dut.memory_mden)) begin
                expected_data=0;
                if(dut.memory_type==2)
                    for(integer b=0;b<8;b=b+1) expected_data[b]=expected[b*32768+(external_address>>3)][external_address&7];
                else expected_data=expected[external_address];
                if(dut.memory_data!==expected_data)
                    $fatal(1,"native memory input tick%0d kind%0d addr%h got%h expected%h",native_ticks,dut.memory_type,external_address,dut.memory_data,expected_data);
                if(external_address<previous_read_address) loops=loops+1;
                if((external_address>> (dut.memory_type==2 ? 9 : 6))!=
                   (previous_read_address>> (dut.memory_type==2 ? 9 : 6))) crossed_lines=crossed_lines+1;
                previous_read_address=external_address; data_ticks=data_ticks+1;
                if(sys_cycles-(last_cas_cycle>last_ras_cycle ? last_cas_cycle : last_ras_cycle)<min_pin_budget)
                    min_pin_budget=sys_cycles-(last_cas_cycle>last_ras_cycle ? last_cas_cycle : last_ras_cycle);
                for(integer b=0;b<(dut.memory_type==2 ? 8 : 1);b=b+1) begin
                    physical=dut.memory_type==2 ? b*32768+(external_address>>3) : external_address;
                    if(!first_use[physical>>6] && fill_cycle[physical>>6]!=0) begin
                        first_use[physical>>6]=1;
                        if(sys_cycles-fill_cycle[physical>>6]<min_prefetch_lead)
                            min_prefetch_lead=sys_cycles-fill_cycle[physical>>6];
                    end
                end
            end
            prior_ras=dut.memory_ras_n; prior_cas=dut.memory_cas_n; prior_we=dut.memory_we_n;
            if(check_enable && dut.memory_fault) begin
                $display("FAULT_DETAIL primecurrent=%h lastread=%h pinaddr=%h valid=%h fill=%h slot=%0d state=%0d item=%0d tag4=%h tag5=%h tag6=%h tag7=%h",dut.memory.prime_current,dut.memory.last_read_address,dut.memory.pin_address,dut.memory.valid,dut.memory.fill_physical,dut.memory.fill_slot,dut.memory.state,dut.memory.prime_item,dut.memory.tags[4],dut.memory.tags[5],dut.memory.tags[6],dut.memory.tags[7]);
                $fatal(1,"native DDR fault at tick%0d kind%0d addr%h ready%0d",native_ticks,dut.memory_type,external_address,dut.memory_ready);
            end
        end
    end
    task write(input [11:0] a,input [31:0] d,input [3:0] mask,input[1:0] resp);
        fork
            begin
                @(negedge sys_clk); S_AXI_AWADDR=a; S_AXI_AWVALID=1;
                do @(posedge sys_clk); while(!S_AXI_AWREADY);
                @(negedge sys_clk); S_AXI_AWVALID=0;
            end
            begin
                repeat(3) @(posedge sys_clk);
                @(negedge sys_clk); S_AXI_WDATA=d; S_AXI_WSTRB=mask; S_AXI_WVALID=1;
                do @(posedge sys_clk); while(!S_AXI_WREADY);
                @(negedge sys_clk); S_AXI_WVALID=0;
            end
        join
        wait(S_AXI_BVALID);
        if(S_AXI_BRESP!==resp) $fatal(1,"native host BRESP addr%h got%h expected%h",a,S_AXI_BRESP,resp);
        @(negedge sys_clk); S_AXI_BREADY=1; @(negedge sys_clk); S_AXI_BREADY=0;
    endtask
    task read(input[11:0] a,output reg[31:0] value);
        @(negedge sys_clk); S_AXI_ARADDR=a; S_AXI_ARVALID=1;
        do @(posedge sys_clk); while(!S_AXI_ARREADY);
        @(negedge sys_clk); S_AXI_ARVALID=0;
        wait(S_AXI_RVALID); value=S_AXI_RDATA;
        if(S_AXI_RRESP!==0) $fatal(1,"native host RRESP");
        @(negedge sys_clk); S_AXI_RREADY=1; @(negedge sys_clk); S_AXI_RREADY=0;
    endtask
    task byte_write(input[1:0] port,input[7:0] d);
        write(port,32'(d)<<(port*8),4'b1<<port,0);
    endtask
    task audio_word(input reg channel,output reg[15:0] v);
        if(channel) @(posedge i2s_ws); else @(negedge i2s_ws);
        @(posedge i2s_sclk);
        v=0;
        repeat(16) begin @(posedge i2s_sclk); v={v[14:0],i2s_sd}; end
        repeat(15) begin @(posedge i2s_sclk); if(i2s_sd!==0) $fatal(1,"native I2S padding"); end
    endtask
    task reg_write(input integer bank,input[7:0] r,d);
        byte_write(bank*2,r); byte_write(bank*2+1,d);
    endtask
    task wait_ticks(input integer count);
        integer stop_tick;
        stop_tick=native_ticks+count; wait(native_ticks>=stop_tick);
    endtask
    task pause_phase(input integer phase,input integer kind);
        integer frozen,changed;
        reg frozen_ras,frozen_cas,frozen_input;
        case(phase)
            0: wait(dut.memory_dm_d==0 && dut.memory_ras_n && dut.memory_cas_n);
            1: wait(!dut.memory_ras_n && dut.memory_cas_n);
            2: wait(!dut.memory_cas_n && !dut.memory_dm_d);
            3: wait(dut.memory_dm_d && (!dut.memory_romcs_n || dut.memory_mden));
            4: wait(dut.memory.write_pending);
        endcase
        write(4,0,15,0); frozen=native_ticks;
        frozen_ras=dut.memory_ras_n; frozen_cas=dut.memory_cas_n; frozen_input=dut.memory_dm_d;
        if(phase==0 && !(frozen_ras && frozen_cas && !frozen_input)) $fatal(1,"pause before RAS stage absent");
        if(phase==1 && !(!frozen_ras && frozen_cas)) $fatal(1,"pause in RAS stage absent");
        if(phase==2 && !(!frozen_cas && !frozen_input)) $fatal(1,"pause in CAS stage absent");
        if(phase==3 && !(frozen_input && (!dut.memory_romcs_n || dut.memory_mden))) $fatal(1,"pause input stage absent");
        repeat(100) @(posedge sys_clk);
        if(native_ticks!=frozen) $fatal(1,"RUN pause changed native state kind%0d phase%0d",kind,phase);
        // Simulate PS cache-flushed DDR replacement while the native chip is paused.
        if(phase!=4) begin
            for(integer b=0;b<(kind==2 ? 8 : 1);b=b+1) begin
                changed=kind==2 ? b*32768+(external_address>>3) : external_address;
                dram.bytes[changed]=dram.bytes[changed] ^ (kind==2 ? (1<<(external_address&7)) : 8'h5a);
                expected[changed]=dram.bytes[changed];
            end
        end
        write(4,1,15,0);
        if(!dut.run_enable || dut.memory_fault) $fatal(1,"RUN resume prime kind%0d phase%0d",kind,phase);
        wait_ticks(4096);
        $display("PAUSE_PHASE kind=%0d phase=%0d ras=%0d cas=%0d input=%0d",kind,phase,frozen_ras,frozen_cas,frozen_input);
    endtask
    task configure(input integer kind,input[15:0] start,stop);
        check_enable=0;
        reg_write(1,0,1);
        write(4,0,15,0); wait(!dut.memory_pending);
        write(16,kind,15,0); write(4,3,15,0); wait(!dut.resetting);
        reg_write(1,0,1); reg_write(1,16,8'h13); reg_write(1,16,8'h80);
        reg_write(1,1,8'hc0 | (kind==0 ? 1 : (kind==1 ? 2 : 0)));
        reg_write(1,2,start[7:0]); reg_write(1,3,start[15:8]);
        reg_write(1,4,stop[7:0]); reg_write(1,5,stop[15:8]);
        reg_write(1,12,8'hff); reg_write(1,13,8'hff);
        reg_write(1,9,8'hff); reg_write(1,10,8'hff); reg_write(1,11,8'hff);
        check_enable=1;
    endtask
    reg[31:0] value;
    reg[15:0] audio_l,audio_r;
    integer baseline_ticks,baseline_candidates,baseline_data,baseline_lines,baseline_loops;
    initial begin
        repeat(5) @(posedge sys_clk); @(negedge sys_clk); sys_resetn=1;
        #271; audio_resetn=1; wait(!dut.resetting);
        reg_write(0,6,8'hff); byte_write(0,6); read(1,value);
        if(value[15:8]!==31) $fatal(1,"native GP0 register read mask");
        reg_write(0,7,63); reg_write(0,8,1); reg_write(0,9,2); reg_write(0,10,3);
        wait_ticks(4096); audio_word(0,audio_l); audio_word(1,audio_r);
        if(audio_l!==669 || audio_r!==669) $fatal(1,"native three SSG to I2S %0d/%0d",audio_l,audio_r);
        for(integer kind=0;kind<3;kind=kind+1) begin
            configure(kind,0,kind==2 ? 31 : 3);
            baseline_ticks=native_ticks; baseline_candidates=candidate_ticks; baseline_data=data_ticks;
            baseline_lines=crossed_lines; baseline_loops=loops;
            reg_write(1,0,8'hb0);
            wait_ticks(100000);
            if(data_ticks-baseline_data<100 || native_ticks-baseline_ticks!=candidate_ticks-baseline_candidates)
                $fatal(1,"native continuous clock/data kind%0d",kind);
            if(crossed_lines==baseline_lines || loops==baseline_loops) $fatal(1,"native cross-line/loop absent kind%0d",kind);
            $display("NATIVE_CASE kind=%0d data_ticks=%0d native_ticks=%0d candidate_ticks=%0d",kind,data_ticks-baseline_data,native_ticks-baseline_ticks,candidate_ticks-baseline_candidates);
            for(integer phase=0;phase<4;phase=phase+1) pause_phase(phase,kind);
            // A new sample start is primed while chip time continues, without IC.
            reg_write(1,0,1);
            reg_write(1,2,32); reg_write(1,3,0);
            reg_write(1,4,kind==2 ? 63 : 35); reg_write(1,5,0);
            baseline_ticks=native_ticks; baseline_candidates=candidate_ticks;
            reg_write(1,0,8'hb0); wait_ticks(100000);
            if(native_ticks-baseline_ticks!=candidate_ticks-baseline_candidates)
                $fatal(1,"native start switch altered clock kind%0d",kind);
            $display("START_SWITCH kind=%0d native_ticks=%0d candidate_ticks=%0d",kind,native_ticks-baseline_ticks,candidate_ticks-baseline_candidates);
            configure(kind,kind==2 ? 16'hffff : 16'h1fff,kind==2 ? 16'hffff : 16'h1fff);
            reg_write(1,0,8'h20); byte_write(2,8);
            read(3,value); read(3,value); wait_ticks(2048);
            for(integer i=0;i<(kind==2 ? 4 : 32);i=i+1) begin
                read(3,value);
                physical=(kind==2 ? 262140 : 262112)+i;
                if(value[31:24]!==expected[physical]) $fatal(1,"native CPU tail kind%0d i%0d got%h expected%h",kind,i,value[31:24],expected[physical]);
                wait_ticks(2048);
            end
        end
        configure(1,0,15); reg_write(1,0,8'h60); byte_write(2,8);
        for(integer i=0;i<8;i=i+1) begin byte_write(3,8'hb0+i); wait_ticks(2048); end
        wait(!dut.memory_pending);
        for(integer i=0;i<8;i=i+1) if(dram.bytes[i]!==8'hb0+i) $fatal(1,"native CPU DDR write payload");
        configure(2,0,15); reg_write(1,0,8'h60); byte_write(2,8);
        for(integer i=0;i<8;i=i+1) begin
            byte_write(3,8'hd0+i);
            if(i==0) pause_phase(4,2);
            wait_ticks(4096);
        end
        wait(!dut.memory_pending);
        for(integer i=0;i<8;i=i+1) if(dram.bytes[i]!==8'hd0+i) $fatal(1,"native RAM1 CPU DDR payload");
        configure(1,0,15); reg_write(1,0,8'hb0); check_enable=0; stall_reads=1;
        wait(dut.memory_fault);
        if(dut.memory_faults==0) $fatal(1,"underrun counter absent");
        baseline_ticks=native_ticks; repeat(200) @(posedge sys_clk);
        if(native_ticks!=baseline_ticks) $fatal(1,"underrun did not stop before bad data");
        stall_reads=0; wait(!dut.memory_pending); write(4,3,15,0); wait(!dut.resetting);
        configure(1,0,15); check_enable=0;
        inject_error=1; reg_write(1,2,8'h20); byte_write(2,0); write(3,32'h20000000,8,0);
        wait(dut.memory_fault);
        if(ac_mute_n) begin repeat(5) @(posedge audio_clk); if(ac_mute_n) $fatal(1,"DDR fault mute"); end
        baseline_ticks=native_ticks; repeat(200) @(posedge sys_clk);
        if(native_ticks!=baseline_ticks) $fatal(1,"DDR fault must stop native clock");
        read(8,value); if(!value[3]) $fatal(1,"DDR visible fault status");
        inject_error=0; wait(!dut.memory_pending); write(4,3,15,0); wait(!dut.resetting);
        read(8,value); if(value[3]) $fatal(1,"DDR fault reset recovery");
        write(4,0,15,0); inject_error=1; write(4,1,15,0);
        read(4,value); if(value[0]) $fatal(1,"CONTROL warm error resumed RUN");
        read(8,value); if(!value[3]) $fatal(1,"CONTROL warm error not visible");
        inject_error=0; wait(!dut.memory_pending); write(4,3,15,0); wait(!dut.resetting);
        @(negedge sys_clk); baseline_ticks=native_ticks; baseline_candidates=candidate_ticks;
        repeat(1000) @(negedge sys_clk);
        if(candidate_ticks-baseline_candidates!=160 || native_ticks-baseline_ticks!=160) $fatal(1,"4/25 frequency ratio");
        $display("METRICS native_data_ticks=%0d memory_writes=%0d loops=%0d crossed_lines=%0d ras=%0d cas=%0d half_ce_1000sys=160 fault_paths=%0d min_pin_to_input_sys=%0d min_prefetch_lead_sys=%0d",data_ticks,memory_writes,loops,crossed_lines,rows,columns,dut.memory_faults,min_pin_budget,min_prefetch_lead);
        $display("CHECK native_core_hp0_rom_ram8_ram1_data_ticks_zero_stalls");
        $display("CHECK native_memory_cross_line_loop_tail_cpu_read_write");
        $display("CHECK system_half_ce_4_of_25_continuous_clock");
        $display("CHECK ddr_underrun_stops_mutes_and_axi_errors_recover");
        $display("BOARD_NATIVE_PASS"); $finish;
    end
    initial begin #150000000; $fatal(1,"native board timeout"); end
endmodule
