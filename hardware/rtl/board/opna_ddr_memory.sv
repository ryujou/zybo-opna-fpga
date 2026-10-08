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
    reg [7:0] read_present;
    wire [63:0] read_word [0:7];
    reg [4:0] read_index [0:7];
    reg [4:0] read_index_next [0:7];
    reg read_ready;
    wire [63:0] write_word [0:7];
    integer b, s;
    function automatic integer cache_bank(input [17:0] physical, input [1:0] kind);
        cache_bank=kind==2 ? physical[17:15] : physical[8:6];
    endfunction
    function automatic integer find_slot_bank(input [17:0] physical, input integer bank);
        begin
            find_slot_bank=-1;
            for (integer i=0;i<4;i=i+1)
                if (valid[bank*4+i] && tags[bank*4+i]==physical[17:6])
                    find_slot_bank=bank*4+i;
        end
    endfunction
    function automatic integer find_slot(input [17:0] physical, input [1:0] kind);
        integer slots [0:7];
        begin
            for (integer bank=0;bank<8;bank=bank+1)
                slots[bank]=find_slot_bank(physical,bank);
            case (cache_bank(physical,kind))
                0: find_slot=slots[0];
                1: find_slot=slots[1];
                2: find_slot=slots[2];
                3: find_slot=slots[3];
                4: find_slot=slots[4];
                5: find_slot=slots[5];
                6: find_slot=slots[6];
                7: find_slot=slots[7];
                default: find_slot=-1;
            endcase
        end
    endfunction
    function automatic has_line_bank(input [17:0] physical, input integer bank);
        reg [3:0] line_hits;
        begin
            line_hits=0;
            for (integer i=0;i<4;i=i+1)
                if (valid[bank*4+i] && tags[bank*4+i]==physical[17:6])
                    line_hits[i]=1;
            has_line_bank=|line_hits;
        end
    endfunction
    function automatic has_line(input [17:0] physical, input [1:0] kind);
        reg [7:0] hits;
        begin
            for (integer bank=0;bank<8;bank=bank+1)
                hits[bank]=has_line_bank(physical,bank);
            case (cache_bank(physical,kind))
                0: has_line=hits[0];
                1: has_line=hits[1];
                2: has_line=hits[2];
                3: has_line=hits[3];
                4: has_line=hits[4];
                5: has_line=hits[5];
                6: has_line=hits[6];
                7: has_line=hits[7];
                default: has_line=0;
            endcase
        end
    endfunction
    function automatic [17:0] next_line(input [17:0] physical, input [1:0] kind);
        if (kind==2) next_line={physical[17:15],(physical[14:6]+9'd1),6'b0};
        else next_line={physical[17:6]+12'd1,6'b0};
    endfunction
    assign memory_dt0=memory_data[0];
    assign memory_ready=!(enabled && dm_d) || read_ready;
    // Pin address, tag lookup and RAM access settle before the next native
    // consumption edge; the shortest measured pin-to-input budget is 30 SYS.
    always @(posedge clk) begin
        read_ready<=resetn && read_hit;
        for (integer i=0;i<8;i=i+1) read_index[i]<=read_index_next[i];
    end
    always_comb begin
        memory_data=0; read_hit=1;
        for (integer i=0;i<8;i=i+1) begin
            read_physical[i]=memory_type==2 ? {3'(i),address[17:3]} :
                                            {address[17:9],3'(i),address[5:0]};
            case (memory_type)
                0,1,2,3: begin
                    read_slot[i]=find_slot_bank(read_physical[i],i);
                    read_present[i]=has_line_bank(read_physical[i],i);
                end
                default: begin
                    read_slot[i]=find_slot(read_physical[i],memory_type);
                    read_present[i]=has_line(read_physical[i],memory_type);
                end
            endcase
            read_index_next[i]={read_slot[i][1:0],read_physical[i][5:3]};
            if (memory_type==2) begin
                if (read_slot[i]>=0) memory_data[i]=read_word[i][read_physical[i][2:0]*8+address[2:0]];
            end else if (i==address[8:6]) begin
                if (read_slot[i]>=0) memory_data=read_word[i][address[2:0]*8+:8];
            end
        end
        if (memory_type==2) read_hit=&read_present;
        else case (address[8:6])
            0: read_hit=read_present[0];
            1: read_hit=read_present[1];
            2: read_hit=read_present[2];
            3: read_hit=read_present[3];
            4: read_hit=read_present[4];
            5: read_hit=read_present[5];
            6: read_hit=read_present[6];
            7: read_hit=read_present[7];
            default: read_hit=1;
        endcase
    end
    localparam IDLE=0, READ_ADDRESS=1, READ_DATA=2, WRITE_CHANNELS=3, WRITE_RESPONSE=4, LOOKUP=5, PLAN=6, WRITE_COMMIT=7;
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
    reg [17:0] wanted, planned;
    integer target_slot, lookup_slot;
    reg wanted_valid, wanted_start;
    reg [1:0] wanted_pin_line;
    reg [17:0] lookup_physical;
    reg [4:0] lookup_target;
    reg [2:0] lookup_bank;
    reg [1:0] lookup_line;
    reg lookup_priming, lookup_start;
    wire [2:0] prepare_write_bank=(state==WRITE_CHANNELS || state==WRITE_RESPONSE) ?
                                  write_bank[2:0]+3'd1 : write_bank[2:0];
    reg [17:0] write_physical;
    integer write_slot;
    integer physical_write_bank;
    reg [17:0] write_physical_q;
    reg [4:0] write_slot_q;
    reg [2:0] write_bank_q;
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
            wanted[5:0]=0;
            wanted_valid=1;
        end
        // Choose prefetch from the registered address, then recheck live tags in LOOKUP.
        planned=lookup_physical;
        if (!lookup_priming && has_line(lookup_physical,memory_type))
            planned=next_line(lookup_physical,memory_type);
        target_slot=cache_bank(planned,memory_type)*4+
                    (lookup_start ? lookup_line : (memory_type==2 ? planned[6] : planned[9]));
        // The second lookup uses live tags after the request decision was registered.
        lookup_slot=find_slot(lookup_physical,memory_type);
        if (lookup_priming && lookup_start)
            lookup_slot=(valid[lookup_target] && tags[lookup_target]==lookup_physical[17:6]) ? lookup_target : -1;
        write_physical=memory_type==2 ? {prepare_write_bank,write_address[17:3]} : write_address;
        write_slot=find_slot(write_physical,memory_type);
        physical_write_bank=cache_bank(write_physical,memory_type);
        changed_word=0;
        if (state==WRITE_COMMIT) begin
            changed_word=write_word[write_bank_q];
            if (memory_type==2)
                changed_word[write_physical_q[2:0]*8+write_address[2:0]]=write_byte[write_bank[2:0]];
            else changed_word[write_physical_q[2:0]*8+:8]=write_byte;
        end
    end
    wire fill_write=resetn && state==READ_DATA && m_rvalid && m_rready;
    wire cpu_write=resetn && !fault && state==WRITE_COMMIT;
    wire [4:0] cpu_index={write_slot_q[1:0],write_physical_q[5:3]};
    wire [4:0] write_index=fill_write ? {fill_line,beat[2:0]} : cpu_index;
    wire [63:0] write_value=fill_write ? m_rdata : changed_word;
    // Fixed read ports and one write process preserve distributed RAM inference.
    for (genvar bank=0;bank<8;bank=bank+1) begin : cache
        (* ram_style="distributed" *) reg [63:0] data [0:31];
        assign read_word[bank]=data[read_index[bank]];
        assign write_word[bank]=data[cpu_index];
        always @(posedge clk)
            if ((fill_write && fill_bank==bank) ||
                (cpu_write && write_bank_q==bank))
                data[write_index]<=write_value;
    end
    always @(posedge clk) begin
        if (!resetn) begin
            state<=IDLE; valid<=0; old_ras<=1; old_cas<=1; old_we<=1; address<=0;
            prime_done<=0; priming<=0; prime_item<=0; prime_start<=0;
            prime_current<=0; last_read_address<=0; resume_prime<=0;
            fault<=0; faults<=0; m_arvalid<=0; m_awvalid<=0; m_wvalid<=0;
            m_araddr<=0; m_awaddr<=0; m_wdata<=0; m_wstrb<=0;
            fill_physical<=0; fill_slot<=0; fill_bank<=0; fill_line<=0; beat<=0; background_bank<=0;
            lookup_physical<=0; lookup_target<=0; lookup_bank<=0; lookup_line<=0;
            lookup_priming<=0; lookup_start<=0;
            write_pending<=0; write_address<=0; write_byte<=0; write_bank<=0;
            write_physical_q<=0; write_slot_q<=0; write_bank_q<=0;
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
            // Prepare the next RAM1 bank while the current AXI write drains.
            if (state==WRITE_CHANNELS || state==WRITE_RESPONSE) begin
                write_physical_q<=write_physical; write_slot_q<=5'(write_slot);
                write_bank_q<=3'(physical_write_bank);
            end
            case (state)
                IDLE: begin
                    if (write_pending) begin
                        if (write_slot<0) begin
                            fault<=1; faults<=faults+1'b1; write_pending<=0;
                        end else begin
                            write_physical_q<=write_physical; write_slot_q<=5'(write_slot);
                            write_bank_q<=3'(physical_write_bank); state<=WRITE_COMMIT;
                        end
                    end else if (wanted_valid && !fault && !invalidate && !prime_valid && !write_event) begin
                        lookup_physical<=wanted; lookup_line<=wanted_pin_line;
                        lookup_priming<=priming; lookup_start<=wanted_start;
                        state<=PLAN;
                    end
                end
                WRITE_COMMIT: if (fault) state<=IDLE;
                else begin
                    m_awaddr<=ddr_base+{14'b0,write_physical_q[17:3],3'b0};
                    m_wdata<=changed_word;
                    m_wstrb<=8'b1<<write_physical_q[2:0];
                    m_awvalid<=1; m_wvalid<=1; state<=WRITE_CHANNELS;
                end
                PLAN: begin
                    if (invalidate || prime_valid || write_event || fault || write_pending) state<=IDLE;
                    else begin
                        lookup_physical<=planned; lookup_target<=5'(target_slot);
                        lookup_bank<=3'(cache_bank(planned,memory_type));
                        lookup_line<=lookup_start ? lookup_line : (memory_type==2 ? planned[6] : planned[9]);
                        state<=LOOKUP;
                    end
                end
                LOOKUP: begin
                    if (invalidate || prime_valid || write_event || fault || write_pending) state<=IDLE;
                    else if (lookup_slot>=0) begin
                        if (lookup_priming) begin
                            if (prime_item==(memory_type==2 ? (resume_prime ? 39 : 23) : (resume_prime ? 4 : 2))) begin
                                priming<=0; prime_done<=1;
                            end else prime_item<=prime_item+1'b1;
                        end else background_bank<=background_bank+1'b1;
                        state<=IDLE;
                    end else begin
                        fill_physical<=lookup_physical; fill_slot<=lookup_target; beat<=0;
                        fill_bank<=lookup_bank; fill_line<=lookup_line;
                        valid[lookup_target]<=0;
                        m_araddr<=ddr_base+{14'b0,lookup_physical}; m_arvalid<=1;
                        state<=READ_ADDRESS;
                    end
                end
                READ_ADDRESS: if (m_arvalid && m_arready) begin
                    m_arvalid<=0; state<=READ_DATA;
                end
                READ_DATA: if (m_rvalid && m_rready) begin
                    if (m_rresp!=0 || m_rlast!=(beat==7)) begin
                        fault<=1; faults<=faults+1'b1;
                    end
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
                    if (memory_type==2 && write_bank!=7 && m_bresp==0 && !fault) begin
                        if (write_slot<0) begin
                            fault<=1; faults<=faults+1'b1; write_pending<=0; state<=IDLE;
                        end else begin write_bank<=write_bank+1'b1; state<=WRITE_COMMIT; end
                    end else begin write_pending<=0; state<=IDLE; end
                end
                default: state<=IDLE;
            endcase
            if (fault) begin priming<=0; write_pending<=0; end
        end
    end
endmodule
