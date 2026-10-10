//one worker writes into the shared memory array), and a completely different worker reads from that 
//on their own independent schedule (clock)

//rx_fifo: wr_clk = phy_rx_clk, rd_clk = system clock domain
//tx_fifo: rd_clk = phy_tx_clk, wr_clk = system clock domain

//Metastability -- sample across 2 cycles using 2 flop flops
//Mid-bit tearing -- using gray code to avoid having a "half old, half new combinatino"

//binary pointer -- directly indexes the memory
//Gray pointer -- gets synchronized and compared for full/empty

//empty -- reader has caught up completely to the writer
//      -- all five bit of the two gray pointer are the same
//full -- write pointer has actually wrapped around exactly one full lap more than the read pointer
//      -- In binary, full means the write pointer is exactly one FIFO depth ahead of the read pointer.

//if pointer is at maximum value, adding 1 in fixed-width unsigned arithmetic naturally overflows back to 
//all zeros (verilog registers)
module async_fifo #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 4
) (
    input wr_clk,
    input wr_rst,
    input [DATA_WIDTH-1:0]  wr_data,
    input wr_en,
    output reg full,

    input rd_clk,
    input rd_rst,
    output [DATA_WIDTH-1:0]  rd_data,
    input rd_en,
    output reg empty
);

    //number of storage slots (bytes) the FIFO's internal memory array can hold at once
    localparam DEPTH = 1 << ADDR_WIDTH;   // 2**ADDR_WIDTH

    // ---- shared memory ----
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // ---- write-side pointers ----
    reg  [ADDR_WIDTH:0] wr_ptr_bin;      // one bit wider than ADDR_WIDTH
    reg [ADDR_WIDTH:0] wr_ptr_gray;
    wire [ADDR_WIDTH:0] wr_ptr_bin_next;
    wire [ADDR_WIDTH:0] wr_ptr_gray_next;
    
    assign wr_ptr_bin_next = wr_ptr_bin + ((wr_en && !full) ? 1'b1 : 1'b0);
    
    assign wr_ptr_gray_next = (wr_ptr_bin_next >> 1) ^ wr_ptr_bin_next;
    
    // ---- read-side pointers ----
    reg  [ADDR_WIDTH:0] rd_ptr_bin;      // one bit wider than ADDR_WIDTH
    reg  [ADDR_WIDTH:0] rd_ptr_gray;

    wire [ADDR_WIDTH:0] rd_ptr_bin_next;
    wire [ADDR_WIDTH:0] rd_ptr_gray_next;
    
    assign rd_ptr_bin_next =
        rd_ptr_bin + ((rd_en && !empty) ? 1'b1 : 1'b0);
    
    assign rd_ptr_gray_next =
        (rd_ptr_bin_next >> 1) ^ rd_ptr_bin_next;

    // ---- synchronizer: bring WRITE pointer's gray code into READ domain ----
    wire [ADDR_WIDTH:0] wr_ptr_gray_sync;

    sync_2ff #(.WIDTH(ADDR_WIDTH+1)) sync_wr_to_rd (
        .clk(rd_clk),
        .rst(rd_rst),
        .async_in(wr_ptr_gray),
        .sync_out(wr_ptr_gray_sync)
    );
    
    // ---- synchronizer: bring READ pointer's gray code into WRITE domain ----
    wire [ADDR_WIDTH:0] rd_ptr_gray_sync;

    sync_2ff #(.WIDTH(ADDR_WIDTH+1)) sync_rd_to_wr (
        .clk(wr_clk),
        .rst(wr_rst),
        .async_in(rd_ptr_gray),
        .sync_out(rd_ptr_gray_sync)
    );
    
    // ---------- empty -----------------
    wire empty_next;
    assign empty_next = (rd_ptr_gray_next == wr_ptr_gray_sync);
    
    // ----------- full ---------------------------
    wire full_next;
    assign full_next = (wr_ptr_gray_next ==
            {~rd_ptr_gray_sync[ADDR_WIDTH:ADDR_WIDTH-1], rd_ptr_gray_sync[ADDR_WIDTH-2:0]});

    // ---- read-side sequential logic ----
    reg [DATA_WIDTH-1:0] rd_data_reg;
    
    always @(posedge rd_clk) begin
        if (rd_rst) begin
            rd_ptr_bin  <= 0;
            rd_ptr_gray <= 0;
            rd_data_reg <= 0;
            empty <= 1'b1;
        end
        else begin
            if (rd_en && !empty)
                rd_data_reg <= mem[rd_ptr_bin[ADDR_WIDTH-1:0]];
    
            rd_ptr_bin  <= rd_ptr_bin_next;
            rd_ptr_gray <= rd_ptr_gray_next;
            empty <= empty_next;
        end
    end
    assign rd_data = rd_data_reg;
    // ---- write-side sequential logic ----
    always @(posedge wr_clk) begin
        if (wr_rst) begin
            wr_ptr_bin  <= 0;
            wr_ptr_gray <= 0;
            full <= 1'b0;
        end
        else begin
            if (wr_en && !full)
                mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= wr_data;
    
            wr_ptr_bin  <= wr_ptr_bin_next;
            wr_ptr_gray <= wr_ptr_gray_next;
            full <= full_next;
        end
    end
endmodule