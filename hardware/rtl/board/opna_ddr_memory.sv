// SPDX-License-Identifier: GPL-3.0-or-later
module opna_ddr_memory (
    input wire clk, resetn, invalidate,
    input wire [31:0] ddr_base,
    input wire [1:0] memory_type,
    input wire prime_valid, prime_resume,
    input wire [17:0] prime_address,
    output reg prime_done,
    input wire [7:0] dm,
    input wire a8, dm_d, ras_n, cas_n, we_n, romcs_n, mden,
    input wire sample_edge,
    output reg [7:0] memory_data,
    output wire memory_dt0,
    output wire memory_ready,
    output wire pending,
    output reg fault,
    output reg [31:0] faults,
    output reg [31:0] m_araddr,
    output reg m_arvalid,
    input wire m_arready,
    input wire [63:0] m_rdata,
    input wire [1:0] m_rresp,
    input wire m_rvalid, m_rlast,
    output wire m_rready,
    output reg [31:0] m_awaddr,
    output reg m_awvalid,
    input wire m_awready,
    output reg [63:0] m_wdata,
    output reg [7:0] m_wstrb,
    output reg m_wvalid,
    input wire m_wready,
    input wire m_bvalid,
    input wire [1:0] m_bresp,
    output wire m_bready
);
    // Four 64-byte lines per bank: streaming pair, loop start and LIMIT zero.
    // RAM1 uses eight 32 KiB bit banks, exactly as the native pin model.
    reg [63:0] data [0:7][0:31];
    reg [11:0] tags [0:31];
    reg [31:0] valid;
    reg old_ras, old_cas, old_we;
    reg [17:0] address;
    wire [8:0] address_bus={a8,dm};
    wire [17:0] pin_address={(!cas_n && old_cas) ? address_bus : address[17:9],
                           (!ras_n && old_ras) ? address_bus : address[8:0]};
    wire enabled=!romcs_n || mden;
    wire write_event=memory_type!=0 && !ras_n && !cas_n && !we_n && !dm_d &&
                     (old_we || old_cas);
    reg read_hit;
    reg [17:0] read_physical [0:7];
    integer read_slot [0:7];
    reg [63:0] read_word [0:7];
    integer b, s;
    function automatic integer cache_bank(input [17:0] physical, input [1:0] kind);
        cache_bank=kind==2 ? physical[17:15] : physical[8:6];
    endfunction
    function automatic integer find_slot(input [17:0] physical, input [1:0] kind);
        integer base_slot;
        begin
            base_slot=cache_bank(physical,kind)*4;
            find_slot=-1;
            for (integer i=0;i<4;i=i+1)
                if (valid[base_slot+i] && tags[base_slot+i]==physical[17:6])
                    find_slot=base_slot+i;
        end
    endfunction
    function automatic [17:0] next_line(input [17:0] physical, input [1:0] kind);
        if (kind==2) next_line={physical[17:15],(physical[14:6]+9'd1),6'b0};
        else next_line={physical[17:6]+12'd1,6'b0};
    endfunction
    assign memory_dt0=memory_data[0];
    assign memory_ready=!(enabled && dm_d) || read_hit;
    always_comb begin
        memory_data=0; read_hit=1;
        for (integer i=0;i<8;i=i+1) begin
            read_physical[i]=memory_type==2 ? {3'(i),pin_address[17:3]} :
                                            {pin_address[17:9],3'(i),pin_address[5:0]};
            read_slot[i]=find_slot(read_physical[i],memory_type);
            read_word[i]=0;
            if (read_slot[i]>=0)
                read_word[i]=data[i][(read_slot[i]-i*4)*8+read_physical[i][5:3]];
            if (memory_type==2) begin
                if (read_slot[i]<0) read_hit=0;
                else memory_data[i]=read_word[i][read_physical[i][2:0]*8+pin_address[2:0]];
            end else if (i==pin_address[8:6]) begin
                if (read_slot[i]<0) read_hit=0;
                else memory_data=read_word[i][pin_address[2:0]*8+:8];
            end
        end
    end
    localparam IDLE=0, READ_ADDRESS=1, READ_DATA=2, WRITE_CHANNELS=3, WRITE_RESPONSE=4;
    reg [2:0] state;
    reg priming;
    reg [5:0] prime_item;
    reg [17:0] prime_start, prime_current, last_read_address;
    reg resume_prime;
    wire [2:0] prime_stage=memory_type==2 ? prime_item[5:3] : prime_item[2:0];
    reg [17:0] fill_physical;
    reg [4:0] fill_slot;
    reg [2:0] fill_bank;
    reg [1:0] fill_line;
    reg [3:0] beat;
    reg [3:0] background_bank;
    reg write_pending;
    reg [17:0] write_address;
    reg [7:0] write_byte;
    reg [3:0] write_bank;
    reg [63:0] changed_word;
    reg [17:0] wanted;
    integer wanted_slot, target_slot;
    reg wanted_valid, wanted_start;
    reg [1:0] wanted_pin_line;
    reg [17:0] write_physical;
    integer write_slot;
    integer physical_write_bank, physical_write_line;
    assign pending=state!=IDLE || priming || write_pending;
    assign m_rready=state==READ_DATA;
    assign m_bready=state==WRITE_RESPONSE;
    always_comb begin
        wanted_valid=0; wanted_start=0; wanted=0;
        wanted_pin_line=2;
        if (priming) begin
            wanted=prime_stage>=3 ? prime_current : prime_start;
            if (prime_stage==0) wanted=0;
            if (memory_type==2) wanted={prime_item[2:0],wanted[17:3]};
            if (prime_stage==2 || prime_stage==4) wanted=next_line(wanted,memory_type);
            wanted[5:0]=0;
            wanted_valid=1;
            wanted_start=prime_stage<=1;
            wanted_pin_line=prime_stage==0 ? 3 : 2;
        end else if (enabled && dm_d) begin
            if (memory_type==2) wanted={background_bank[2:0],pin_address[17:3]};
            else wanted=pin_address;
            // A line already present is followed by the next line prefetch.
            if (find_slot(wanted,memory_type)>=0) wanted=next_line(wanted,memory_type);
            wanted[5:0]=0;
            wanted_valid=1;
        end
        wanted_slot=find_slot(wanted,memory_type);
        target_slot=cache_bank(wanted,memory_type)*4+
                    (wanted_start ? wanted_pin_line : (memory_type==2 ? wanted[6] : wanted[9]));
        if (priming && wanted_start)
            wanted_slot=(valid[target_slot] && tags[target_slot]==wanted[17:6]) ? target_slot : -1;
        write_physical=memory_type==2 ? {write_bank[2:0],write_address[17:3]} : write_address;
        write_slot=find_slot(write_physical,memory_type);
        physical_write_bank=cache_bank(write_physical,memory_type);
        physical_write_line=write_slot-physical_write_bank*4;
        changed_word=0;
        if (write_slot>=0) begin
            changed_word=data[physical_write_bank][physical_write_line*8+write_physical[5:3]];
            if (memory_type==2)
                changed_word[write_physical[2:0]*8+write_address[2:0]]=write_byte[write_bank[2:0]];
            else changed_word[write_physical[2:0]*8+:8]=write_byte;
        end
    end
    always @(posedge clk) begin
        if (!resetn) begin
            state<=IDLE; valid<=0; old_ras<=1; old_cas<=1; old_we<=1; address<=0;
            prime_done<=0; priming<=0; prime_item<=0; prime_start<=0;
            prime_current<=0; last_read_address<=0; resume_prime<=0;
            fault<=0; faults<=0; m_arvalid<=0; m_awvalid<=0; m_wvalid<=0;
            m_araddr<=0; m_awaddr<=0; m_wdata<=0; m_wstrb<=0;
            fill_physical<=0; fill_slot<=0; fill_bank<=0; fill_line<=0; beat<=0; background_bank<=0;
            write_pending<=0; write_address<=0; write_byte<=0; write_bank<=0;
        end else begin
            prime_done<=0;
            old_ras<=ras_n; old_cas<=cas_n; old_we<=we_n; address<=pin_address;
            if (invalidate) begin
                valid<=0; fault<=0;
            end
            if (prime_valid) begin
                priming<=1; prime_item<=0; prime_start<=prime_address;
                resume_prime<=prime_resume;
                prime_current<=enabled && dm_d ? pin_address : last_read_address+18'd1;
            end
            if (sample_edge && enabled && dm_d && read_hit && !fault) last_read_address<=pin_address;
            if (sample_edge && enabled && dm_d && !read_hit && !fault) begin
                fault<=1; faults<=faults+1'b1;
            end
            if (write_event) begin
                if (write_pending) begin fault<=1; faults<=faults+1'b1; end
                else begin
                    write_pending<=1; write_address<=pin_address; write_byte<=dm; write_bank<=0;
                end
            end
            case (state)
                IDLE: begin
                    if (write_pending) begin
                        if (write_slot<0) begin
                            fault<=1; faults<=faults+1'b1; write_pending<=0;
                        end else begin
                            data[physical_write_bank][physical_write_line*8+write_physical[5:3]]<=changed_word;
                            m_awaddr<=ddr_base+{14'b0,write_physical[17:3],3'b0};
                            m_wdata<=changed_word;
                            m_wstrb<=8'b1<<write_physical[2:0];
                            m_awvalid<=1; m_wvalid<=1; state<=WRITE_CHANNELS;
                        end
                    end else if (wanted_valid && !fault) begin
                        if (wanted_slot>=0) begin
                            if (priming) begin
                                if (prime_item==(memory_type==2 ? (resume_prime ? 39 : 23) : (resume_prime ? 4 : 2))) begin
                                    priming<=0; prime_done<=1;
                                end else prime_item<=prime_item+1'b1;
                            end else background_bank<=background_bank+1'b1;
                        end else begin
                            fill_physical<=wanted; fill_slot<=5'(target_slot); beat<=0;
                            fill_bank<=3'(cache_bank(wanted,memory_type));
                            fill_line<=wanted_start ? wanted_pin_line : (memory_type==2 ? wanted[6] : wanted[9]);
                            valid[target_slot]<=0;
                            m_araddr<=ddr_base+{14'b0,wanted}; m_arvalid<=1;
                            state<=READ_ADDRESS;
                        end
                    end
                end
                READ_ADDRESS: if (m_arvalid && m_arready) begin
                    m_arvalid<=0; state<=READ_DATA;
                end
                READ_DATA: if (m_rvalid && m_rready) begin
                    if (m_rresp!=0 || m_rlast!=(beat==7)) begin
                        fault<=1; faults<=faults+1'b1;
                    end
                    data[fill_bank][fill_line*8+beat]<=m_rdata;
                    if (beat==7 || m_rlast) begin
                        if (m_rresp==0 && beat==7 && m_rlast) begin
                            valid[fill_slot]<=1; tags[fill_slot]<=fill_physical[17:6];
                        end
                        state<=IDLE;
                    end else beat<=beat+1'b1;
                end
                WRITE_CHANNELS: begin
                    if (m_awvalid && m_awready) m_awvalid<=0;
                    if (m_wvalid && m_wready) m_wvalid<=0;
                    if ((!m_awvalid || m_awready) && (!m_wvalid || m_wready)) state<=WRITE_RESPONSE;
                end
                WRITE_RESPONSE: if (m_bvalid && m_bready) begin
                    if (m_bresp!=0) begin fault<=1; faults<=faults+1'b1; end
                    if (memory_type==2 && write_bank!=7) begin
                        write_bank<=write_bank+1'b1; state<=IDLE;
                    end else begin write_pending<=0; state<=IDLE; end
                end
                default: state<=IDLE;
            endcase
            if (fault) begin priming<=0; write_pending<=0; end
        end
    end
endmodule
