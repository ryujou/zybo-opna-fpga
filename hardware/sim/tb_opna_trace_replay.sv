`timescale 1ns/1ps
module tb_opna_trace_replay;
    logic clk = 0;
    logic ic = 1, cs_n = 1, wr_n = 1, rd_n = 1;
    logic [1:0] address = 0;
    logic [7:0] data = 0;
    wire [7:0] dout;
    wire irq_n;
    string trace_path, output_path;
    integer input_file, pin_file, read_file, count;
    longint unsigned duration, tick, next_tick;
    integer next_ic, next_cs, next_wr, next_rd, next_address, next_data;

    // Phase 1 checks elaboration and stimulus replay, not OPNA conformance.
    jt10b dut (
        .rst(!ic), .clk(clk), .cen(1'b1), .din(data), .addr(address),
        .cs_n(cs_n), .wr_n(wr_n), .dout(dout), .irq_n(irq_n),
        .adpcma_data(8'h00), .adpcmb_data(8'h00), .ch_enable(6'h3f)
    );

    initial begin
        if (!$value$plusargs("TRACE=%s", trace_path)) $fatal(1, "TRACE missing");
        if (!$value$plusargs("OUTPUT=%s", output_path)) $fatal(1, "OUTPUT missing");
        input_file = $fopen(trace_path, "r");
        pin_file = $fopen({output_path, "/replayed.bus"}, "w");
        read_file = $fopen({output_path, "/read-ticks.csv"}, "w");
        if (!input_file || !pin_file || !read_file) $fatal(1, "file open failed");
        count = $fscanf(input_file, "%d\n", duration);
        if (count != 1 || duration == 0) $fatal(1, "invalid duration");
        $fdisplay(pin_file, "%0d", duration);
        count = $fscanf(input_file, "%d %d %d %d %d %d %d\n",
            next_tick, next_ic, next_cs, next_wr, next_rd, next_address, next_data);
        if (count != 7 || next_tick != 0) $fatal(1, "invalid first event");
        for (tick = 0; tick < duration; tick = tick + 1) begin
            if (count == 7 && tick == next_tick) begin
                if (ic && !cs_n && !rd_n &&
                    (next_cs || next_rd || next_address != address))
                    $fdisplay(read_file, "%0d,%0d", tick - 1, address);
                ic = next_ic; cs_n = next_cs; wr_n = next_wr; rd_n = next_rd;
                address = next_address; data = next_data;
                $fdisplay(pin_file, "%0d %0d %0d %0d %0d %0d %0d",
                    tick, ic, cs_n, wr_n, rd_n, address, data);
                count = $fscanf(input_file, "%d %d %d %d %d %d %d\n",
                    next_tick, next_ic, next_cs, next_wr, next_rd, next_address, next_data);
                if (count == 7 && (next_tick <= tick || next_tick >= duration))
                    $fatal(1, "invalid event order");
                if (count != 7 && !$feof(input_file)) $fatal(1, "incomplete event");
            end
            clk = tick[0];
            #62.5;
        end
        if (count == 7) $fatal(1, "unconsumed input");
        $fclose(input_file);
        $fclose(pin_file);
        $fclose(read_file);
        $display("OPNA_REPLAY_PASS");
        $finish;
    end
endmodule
