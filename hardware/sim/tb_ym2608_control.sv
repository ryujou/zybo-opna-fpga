`timescale 1ns/1ps
module tb_ym2608_control #(parameter FM = 0, parameter SSG = 0, parameter RHYTHM = 0, parameter ADPCM = 0);
    logic clk = 0, chip_clk = 0;
    logic half_ce = 1;
    logic ic_n = 1, cs_n = 1, wr_n = 1, rd_n = 1;
    logic [1:0] addr = 0;
    logic [7:0] din = 0;
    wire [7:0] dout;
    wire irq_n, busy, six_channels;
    wire [1:0] prescaler, timer_overflow;
    wire [4:0] irq_enable;
    wire [1:0] pcm_valid;
    wire signed [15:0] pcm_left, pcm_right;
    wire [4:0] ssg_a, ssg_b, ssg_c;
    logic [7:0] memory_data = 0, adc_input = 0, adc_feedback = 0;
    logic memory_dt0 = 0;
    wire [7:0] memory_dm, adc_sample;
    wire memory_dm_d, memory_a8, memory_ras_n, memory_cas_n, memory_we_n;
    wire memory_romcs_n, memory_mden, adpcm_playing;
    wire [2:0] adpcm_status;
    byte unsigned memory [0:262143];
    string memory_path, memory_type;
    string adc_path;
    integer adc_file = 0, adc_count = 0, next_adc_value;
    longint unsigned next_adc_tick;
    integer memory_file, memory_count, memory_index, memory_value, bank, bit_address, data_value;
    integer feedback_mode = 0;
    logic previous_ras = 1, previous_cas = 1, previous_we = 1, previous_memory_enable = 0;
    logic [17:0] memory_address = 0, previous_memory_address = 0;
    logic [8:0] address_bus;
    logic memory_enable;
    integer last_memory_pin [0:7];
    integer last_adpcm_flags = -1, last_adpcm_busy = -1, last_adc = -1;
    integer last_limit [0:2];
    integer mix_trace = 0, last_mix [0:3];
    logic previous_load_left = 0, previous_load_right = 0;
    logic load_left, load_right;
    string trace_path, output_path;
    integer input_file, output_file, count;
    integer idle_cycles = 0, idle;
    longint unsigned duration, tick, next_tick;
    integer next_ic, next_cs, next_wr, next_rd, next_addr, next_data;
    integer last_irq = -1, last_busy = -1, last_prescaler = -1;
    integer last_sch = -1, last_mask = -1, last_ta = -1, last_tb = -1;
    integer last_ssg_a = -1, last_ssg_b = -1, last_ssg_c = -1;
    ym2608 #(.ENABLE_FM(FM), .ENABLE_RHYTHM(RHYTHM), .ENABLE_ADPCM(ADPCM)) dut (
        .clk(clk), .half_ce(half_ce), .chip_clk(chip_clk),
        .ic_n(ic_n), .cs_n(cs_n), .wr_n(wr_n), .rd_n(rd_n), .addr(addr), .din(din),
        .adpcm_flags(3'b0), .adpcm_dout(8'b0), .adpcm_read_valid(1'b0),
        .gpio_a(8'b0), .gpio_b(8'b0), .dout(dout), .irq_n(irq_n), .busy(busy),
        .prescaler(prescaler), .six_channels(six_channels), .irq_enable(irq_enable),
        .timer_overflow(timer_overflow), .pcm_valid(pcm_valid),
        .pcm_left(pcm_left), .pcm_right(pcm_right),
        .ssg_a(ssg_a), .ssg_b(ssg_b), .ssg_c(ssg_c),
        .memory_data(memory_data), .memory_dt0(memory_dt0), .adc_input(adc_input), .adc_feedback(adc_feedback),
        .memory_dm(memory_dm), .memory_dm_d(memory_dm_d), .memory_a8(memory_a8),
        .memory_ras_n(memory_ras_n), .memory_cas_n(memory_cas_n), .memory_we_n(memory_we_n),
        .memory_romcs_n(memory_romcs_n), .memory_mden(memory_mden),
        .adpcm_status(adpcm_status), .adpcm_playing(adpcm_playing), .adc_sample(adc_sample)
    );
    task observe(input string kind, input integer index, input integer value,
                 inout integer previous);
        if (value !== previous) begin
            $fdisplay(output_file, "%0d,%s,%0d,%0d", tick, kind, index, value);
            previous = value;
        end
    endtask
    task load_memory;
        for (memory_index = 0; memory_index < 262144; memory_index = memory_index + 1)
            memory[memory_index] = 0;
        memory_file = $fopen(memory_path, "r");
        if (!memory_file) $fatal(1, "memory file open failed");
        while (!$feof(memory_file)) begin
            memory_count = $fscanf(memory_file, "%d %d\n", memory_index, memory_value);
            if (memory_count == 2) memory[memory_index] = memory_value;
            else if (!$feof(memory_file)) $fatal(1, "invalid memory fixture");
        end
        $fclose(memory_file);
    endtask
    initial begin
        if (!$value$plusargs("TRACE=%s", trace_path)) $fatal(1, "TRACE missing");
        if (!$value$plusargs("OUTPUT=%s", output_path)) $fatal(1, "OUTPUT missing");
        count = $value$plusargs("IDLE=%d", idle_cycles);
        count = $value$plusargs("MIX_TRACE=%d", mix_trace);
        for (bank = 0; bank < 4; bank = bank + 1) last_mix[bank] = 262144;
        for (bank = 0; bank < 8; bank = bank + 1) last_memory_pin[bank] = -1;
        for (bank = 0; bank < 3; bank = bank + 1) last_limit[bank] = -1;
        if (ADPCM) begin
            if (!$value$plusargs("MEMORY=%s", memory_path)) $fatal(1, "MEMORY missing");
            if (!$value$plusargs("MEMTYPE=%s", memory_type)) $fatal(1, "MEMTYPE missing");
            memory_value = 0;
            count = $value$plusargs("ADC=%d", memory_value); adc_input = memory_value;
            count = $value$plusargs("FEEDBACK=%d", feedback_mode);
            adc_feedback = feedback_mode == 256 ? 128 : feedback_mode;
            if ($value$plusargs("ADC_TRACE=%s", adc_path)) begin
                adc_file = $fopen(adc_path,"r");
                if (!adc_file) $fatal(1,"ADC trace open failed");
                adc_count = $fscanf(adc_file,"%d %d\n",next_adc_tick,next_adc_value);
                if (adc_count != 2 || next_adc_tick != 0) $fatal(1,"invalid first ADC event");
            end
            load_memory();
        end
        input_file = $fopen(trace_path, "r");
        output_file = $fopen(output_path, "w");
        if (!input_file || !output_file) $fatal(1, "file open failed");
        $fdisplay(output_file, "tick,kind,index,value");
        count = $fscanf(input_file, "%d\n", duration);
        if (count != 1 || duration == 0) $fatal(1, "invalid duration");
        count = $fscanf(input_file, "%d %d %d %d %d %d %d\n",
            next_tick, next_ic, next_cs, next_wr, next_rd, next_addr, next_data);
        if (count != 7 || next_tick != 0) $fatal(1, "invalid first event");
        for (tick = 0; tick < duration; tick = tick + 1) begin
            if (adc_count == 2 && tick == next_adc_tick) begin
                adc_input = next_adc_value;
                adc_count = $fscanf(adc_file,"%d %d\n",next_adc_tick,next_adc_value);
                if (adc_count == 2 && (next_adc_tick <= tick || next_adc_tick >= duration))
                    $fatal(1,"invalid ADC event order");
                if (adc_count != 2 && !$feof(adc_file)) $fatal(1,"invalid ADC event");
            end
            if (count == 7 && tick == next_tick) begin
                if (tick > 3456 && ic_n && !cs_n && !rd_n &&
                    (next_cs || next_rd || next_addr != addr))
                    $fdisplay(output_file, "%0d,read,%0d,%0d", tick - 1, addr, dout);
                ic_n = next_ic; cs_n = next_cs; wr_n = next_wr; rd_n = next_rd;
                addr = next_addr; din = next_data;
                count = $fscanf(input_file, "%d %d %d %d %d %d %d\n",
                    next_tick, next_ic, next_cs, next_wr, next_rd, next_addr, next_data);
                if (count == 7 && (next_tick <= tick || next_tick >= duration))
                    $fatal(1, "invalid event order");
                if (count != 7 && !$feof(input_file)) $fatal(1, "incomplete event");
            end
            chip_clk = tick[0];
            half_ce = 0;
            for (idle = 0; idle < idle_cycles; idle = idle + 1) begin
                #1; clk = 1; #1; clk = 0;
            end
            half_ce = 1;
            #1; clk = 1; #1;
            if (mix_trace) begin
                load_left = dut.control.q.dac_sync_l && !dut.control.q.dac_load_l;
                load_right = dut.control.q.dac_sync_r && !dut.control.q.dac_load_r;
                if (tick >= 3456) begin
                    if (load_left && !previous_load_left)
                        $fdisplay(output_file,"%0d,mix_acc,0,%0d",tick,$signed(dut.control.q.fm_acc_left[1]));
                    if (load_right && !previous_load_right)
                        $fdisplay(output_file,"%0d,mix_acc,1,%0d",tick,$signed(dut.control.q.fm_acc_right[1]));
                    observe("mix_source",0,$signed(dut.control.q.fm_output),last_mix[0]);
                    observe("mix_source",1,$signed(dut.control.q.rhythm.sum_left),last_mix[1]);
                    observe("mix_source",2,$signed(dut.control.q.rhythm.sum_right),last_mix[2]);
                    observe("mix_source",3,$signed(dut.control.q.adpcm_output),last_mix[3]);
                end
                previous_load_left = load_left;
                previous_load_right = load_right;
            end
            if (tick >= 3456) begin
                if ($isunknown({dout, irq_n, busy, prescaler, six_channels, irq_enable, timer_overflow}))
                    $fatal(1, "unknown control output at tick %0d", tick);
                observe("irq", 0, !irq_n, last_irq);
                observe("busy", 0, busy, last_busy);
                observe("mode", 0, prescaler, last_prescaler);
                observe("mode", 1, six_channels, last_sch);
                observe("mode", 2, irq_enable, last_mask);
                observe("timer", 0, timer_overflow[0], last_ta);
                observe("timer", 1, timer_overflow[1], last_tb);
                if (FM || SSG || RHYTHM || ADPCM) begin
                    if ($isunknown({pcm_valid, pcm_left, pcm_right}))
                        $fatal(1, "unknown FM output at tick %0d", tick);
                    if (pcm_valid[0]) $fdisplay(output_file, "%0d,pcm,0,%0d", tick, pcm_left);
                    if (pcm_valid[1]) $fdisplay(output_file, "%0d,pcm,1,%0d", tick, pcm_right);
                end
                if (SSG) begin
                    if ($isunknown({ssg_a, ssg_b, ssg_c}))
                        $fatal(1, "unknown SSG output at tick %0d", tick);
                    observe("ssg", 0, ssg_a, last_ssg_a);
                    observe("ssg", 1, ssg_b, last_ssg_b);
                    observe("ssg", 2, ssg_c, last_ssg_c);
                end
            end
            if (ADPCM) begin
                address_bus = {memory_a8,memory_dm};
                if (previous_cas && !memory_cas_n) memory_address[17:9] = address_bus;
                if (previous_ras && !memory_ras_n) memory_address[8:0] = address_bus;
                memory_enable = !memory_romcs_n || memory_mden;
                if (tick == 3456) load_memory();
                if (tick >= 3456) begin
                    if ($isunknown({memory_dm,memory_dm_d,memory_a8,memory_ras_n,memory_cas_n,
                        memory_we_n,memory_romcs_n,memory_mden,adpcm_status,adpcm_playing,adc_sample}))
                        $fatal(1, "unknown ADPCM output at tick %0d", tick);
                    observe("mem_pin",0,memory_dm,last_memory_pin[0]);
                    observe("mem_pin",1,memory_dm_d,last_memory_pin[1]);
                    observe("mem_pin",2,memory_a8,last_memory_pin[2]);
                    observe("mem_pin",3,memory_ras_n,last_memory_pin[3]);
                    observe("mem_pin",4,memory_cas_n,last_memory_pin[4]);
                    observe("mem_pin",5,memory_we_n,last_memory_pin[5]);
                    observe("mem_pin",6,memory_romcs_n,last_memory_pin[6]);
                    observe("mem_pin",7,memory_mden,last_memory_pin[7]);
                    observe("adpcm",0,adpcm_status,last_adpcm_flags);
                    observe("adpcm",1,adpcm_playing,last_adpcm_busy);
                    observe("adpcm",2,adc_sample,last_adc);
                    observe("limit",0,dut.control.q.adpcm.limit_match2[1],last_limit[0]);
                    observe("limit",1,{dut.control.q.adpcm.address_count[2][1],
                        dut.control.q.adpcm.address_count[1][1],dut.control.q.adpcm.address_count[0][1]},last_limit[1]);
                    observe("limit",2,dut.control.q.adpcm.address_count[3][1],last_limit[2]);
                end
                if (memory_type != "rom" && !memory_ras_n && !memory_cas_n && !memory_we_n &&
                    !memory_dm_d && (previous_we || previous_cas)) begin
                    if (memory_type == "ram8") memory[memory_address] = memory_dm;
                    else for (bank = 0; bank < 8; bank = bank + 1) begin
                        bit_address = (bank << 18) | memory_address;
                        memory[bit_address >> 3][bit_address & 7] = memory_dm[bank];
                    end
                    if (tick >= 3456) $fdisplay(output_file,"%0d,mem_write,%0d,%0d",tick,memory_address,memory_dm);
                end
                if (memory_enable) begin
                    data_value = 0;
                    if (memory_type != "ram1") data_value = memory[memory_address];
                    else for (bank = 0; bank < 8; bank = bank + 1) begin
                        bit_address = (bank << 18) | memory_address;
                        data_value = data_value | (int'(memory[bit_address >> 3][bit_address & 7]) << bank);
                    end
                    memory_data = data_value;
                    memory_dt0 = memory_data[0];
                    if (tick >= 3456 && (!previous_memory_enable || previous_memory_address != memory_address))
                        $fdisplay(output_file,"%0d,mem_read,%0d,%0d",tick,memory_address,data_value);
                end
                previous_we = memory_we_n; previous_memory_enable = memory_enable;
                previous_memory_address = memory_address; previous_cas = memory_cas_n; previous_ras = memory_ras_n;
                if (feedback_mode == 256 && pcm_valid[0]) adc_feedback = (pcm_left ^ 16'h8000) >> 8;
            end
            clk = 0; #60.5;
        end
        if (count == 7) $fatal(1, "unconsumed input");
        if (adc_count == 2) $fatal(1,"unconsumed ADC input");
        if (adc_file) $fclose(adc_file);
        $fclose(input_file);
        $fclose(output_file);
        $display("YM2608_CONTROL_PASS");
        $finish;
    end
endmodule
