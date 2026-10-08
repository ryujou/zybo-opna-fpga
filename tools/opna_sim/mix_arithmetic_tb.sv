`timescale 1ns/1ps
module mix_arithmetic_tb;
    reg sys_clk=0; always #5 sys_clk=~sys_clk;
    reg sys_resetn=0, audio_resetn=0, audio_clk=0, mute=0;
    reg [1:0] pcm_valid=3, clip_clear=0;
    reg signed [15:0] pcm_left=0, pcm_right=0;
    reg [4:0] ssg_a=0, ssg_b=0, ssg_c=0;
    reg [31:0] pcm_gain=65536, ssg_gain=65536, master_gain=65536;
    wire [31:0] clip_left, clip_right;
    wire i2s_sclk,i2s_ws,i2s_sd,ac_mute_n,ready;
    opna_audio_output dut(.*);
    integer file, count, code, pl, pr, a, b, c, gp, gs, gm, expected_l, expected_r, cl, cr;
    reg toggle=0;
    initial begin
        // Isolate the arithmetic mailbox; the board test independently exercises I2S/CDC.
        force dut.request_sync=0;
        repeat(4) @(negedge sys_clk); sys_resetn=1;
        file=$fopen("vectors.txt","r");
        if (!file) $fatal(1,"missing integer vectors");
        count=0;
        while (!$feof(file)) begin
            code=$fscanf(file,"%d %d %d %d %d %h %h %h %d %d %d %d\n",pl,pr,a,b,c,gp,gs,gm,expected_l,expected_r,cl,cr);
            if(code!=12) $fatal(1,"vector input");
            pcm_left=pl; pcm_right=pr; ssg_a=a; ssg_b=b; ssg_c=c;
            pcm_gain=gp; ssg_gain=gs; master_gain=gm; clip_clear=3;
            repeat(4) @(negedge sys_clk); clip_clear=0;
            toggle=~toggle;
            force dut.request_sync={2{toggle}};
            wait(dut.mix_stage==1); @(negedge sys_clk);
            // Both channels must use the gain snapshot, even if inputs change mid-sample.
            pcm_gain=0; ssg_gain=0; master_gain=0;
            wait(dut.mix_stage==0); @(negedge sys_clk);
            if($signed(dut.mailbox[31:16])!=expected_l || $signed(dut.mailbox[15:0])!=expected_r || clip_left!=cl || clip_right!=cr)
                $fatal(1,"vector %0d mailbox=%h expected=%0d,%0d clips=%0d,%0d expected=%0d,%0d",count,dut.mailbox,expected_l,expected_r,clip_left,clip_right,cl,cr);
            if ((cl || cr) && count%37==0) begin
                pcm_gain=gp; ssg_gain=gs; master_gain=gm;
                repeat(2) @(negedge sys_clk); toggle=~toggle;
                force dut.request_sync={2{toggle}};
                wait(dut.mix_stage==1); wait(dut.mix_stage==0); @(negedge sys_clk);
                if(clip_left!=2*cl || clip_right!=2*cr) $fatal(1,"clip accumulation");
                mute=1; repeat(2) @(negedge sys_clk); toggle=~toggle;
                force dut.request_sync={2{toggle}};
                wait(dut.mix_stage==1); wait(dut.mix_stage==0); @(negedge sys_clk);
                if(dut.mailbox!=0 || clip_left!=2*cl || clip_right!=2*cr) $fatal(1,"muted clip exclusion");
                mute=0;
            end
            count=count+1;
        end
        $display("MIX_ARITHMETIC_PASS vectors=%0d snapshot=1 clear=1",count); $finish;
    end
    initial begin #10000000; $fatal(1,"mix timeout"); end
endmodule
