module price_level_book_bram #(
    parameter ADDR_WIDTH      = 10,   // 2**ADDR_WIDTH levels per side
    parameter TICK_UNITS      = 100,  // price field units per min tick ($0.01 = 100, since price is x10000 fixed point)
    parameter FIFO_DEPTH_LOG2 = 2     // 4-deep input event queue
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        event_valid,
    input  wire [2:0]  event_type,      // unused (kept for drop-in compatibility with price_level_book.v)
    input  wire        event_side,
    input  wire signed [32:0] event_shares_delta,
    input  wire [31:0] event_price,

    output reg         level_event_valid,
    output reg         level_side,
    output reg [31:0]  level_price,
    output reg [31:0]  level_total_shares,
    output reg         level_removed
);

    localparam NUM_ENTRIES = (1 << ADDR_WIDTH);
    localparam FIFO_DEPTH  = (1 << FIFO_DEPTH_LOG2);
    localparam ENTRY_WIDTH = 65;   // valid(1) + price_tag(32) + shares(32), packed into ONE word per address

    // ------------------------------------------------------------------
    // Input event queue: absorbs back-to-back events from order_book
    // while the 2-cycle BRAM read-modify-write pipeline below drains.
    // Same same-clock-domain FIFO pattern used for every UART reporting
    // path elsewhere in this project, applied here to the write side
    // instead of a report-drain side.
    // ------------------------------------------------------------------
    reg                      fifo_side  [0:FIFO_DEPTH-1];
    reg  [31:0]              fifo_price [0:FIFO_DEPTH-1];
    reg  signed [32:0]       fifo_delta [0:FIFO_DEPTH-1];
    reg  [FIFO_DEPTH_LOG2:0] fifo_wr_ptr, fifo_rd_ptr;

    wire fifo_empty = (fifo_wr_ptr == fifo_rd_ptr);
    wire fifo_full  = (fifo_wr_ptr[FIFO_DEPTH_LOG2] != fifo_rd_ptr[FIFO_DEPTH_LOG2]) &&
                       (fifo_wr_ptr[FIFO_DEPTH_LOG2-1:0] == fifo_rd_ptr[FIFO_DEPTH_LOG2-1:0]);

    wire relevant_in = event_valid && (event_shares_delta != 33'sd0);

    wire                   head_side  = fifo_side [fifo_rd_ptr[FIFO_DEPTH_LOG2-1:0]];
    wire [31:0]            head_price = fifo_price[fifo_rd_ptr[FIFO_DEPTH_LOG2-1:0]];
    wire signed [32:0]     head_delta = fifo_delta[fifo_rd_ptr[FIFO_DEPTH_LOG2-1:0]];
    wire [ADDR_WIDTH-1:0]  head_addr  = (head_price / TICK_UNITS);  // low ADDR_WIDTH bits == mod 2**ADDR_WIDTH

    localparam S_RESET_SWEEP = 2'd0;
    localparam S_IDLE        = 2'd1;
    localparam S_READ        = 2'd2;
    reg [1:0] state;

    reg [ADDR_WIDTH-1:0] sweep_addr;

    reg                   p_side;
    reg  [31:0]           p_price;
    reg  signed [32:0]    p_delta;
    reg  [ADDR_WIDTH-1:0] p_addr;

    // ------------------------------------------------------------------
    // Vivado's synthesis log (confirmed via a real run) explicitly rejected
    // ram_style="block" on these arrays with "Infeasible attribute ... trying
    // to implement using LUTRAM". The earlier version wrote each array from
    // TWO different case-statement branches (the reset sweep, and the
    // steady-state read-modify-write) and read it from a third -- a memory
    // touched from several branches of an FSM's case statement is a known
    // pattern Vivado's inference heuristic does not reliably recognize as a
    // clean single-port RAM, independent of the attribute. The fix is
    // structural, not the attribute: merge every write source into ONE
    // muxed {enable, address, data} set per side, and every read into ONE
    // {enable, address} set per side, each updated in its own small,
    // canonical always block -- the template synthesis tools are built to
    // recognize as a true dual-port (1R+1W) Block RAM.
    // ------------------------------------------------------------------
    wire                   sweeping    = (state == S_RESET_SWEEP);
    wire [ENTRY_WIDTH-1:0] bid_rd_data, ask_rd_data;
    wire [ENTRY_WIDTH-1:0] rd_entry    = p_side ? bid_rd_data : ask_rd_data;

    wire         rd_valid  = rd_entry[64];
    wire [31:0]  rd_tag    = rd_entry[63:32];
    wire [31:0]  rd_shares = rd_entry[31:0];
    wire signed [32:0] rd_shares_signed = rd_valid ? $signed({1'b0, rd_shares}) : 33'sd0;

    wire                   do_write    = (state == S_READ) && (!rd_valid || rd_tag == p_price);
    wire signed [32:0]     write_total = rd_shares_signed + p_delta;
    wire                   write_clear = (write_total <= 33'sd0);
    wire [ENTRY_WIDTH-1:0] write_data  = write_clear ? {ENTRY_WIDTH{1'b0}}
                                                       : {1'b1, p_price, write_total[31:0]};

    // One merged write port per side: reset-sweep clear OR steady-state update, never both at once.
    wire                   bid_wr_en   = sweeping || (do_write && p_side);
    wire                   ask_wr_en   = sweeping || (do_write && !p_side);
    wire [ADDR_WIDTH-1:0]  bid_wr_addr = sweeping ? sweep_addr : p_addr;
    wire [ADDR_WIDTH-1:0]  ask_wr_addr = sweeping ? sweep_addr : p_addr;
    wire [ENTRY_WIDTH-1:0] bid_wr_data = sweeping ? {ENTRY_WIDTH{1'b0}} : write_data;
    wire [ENTRY_WIDTH-1:0] ask_wr_data = sweeping ? {ENTRY_WIDTH{1'b0}} : write_data;

    // One read port per side, shared address (only one side's result is actually used, via rd_entry's mux above).
    wire                   rd_en   = (state == S_IDLE) && !fifo_empty;
    wire [ADDR_WIDTH-1:0]  rd_addr = head_addr;

    (* ram_style = "block" *) reg [ENTRY_WIDTH-1:0] bid_mem [0:NUM_ENTRIES-1];
    (* ram_style = "block" *) reg [ENTRY_WIDTH-1:0] ask_mem [0:NUM_ENTRIES-1];

    reg [ENTRY_WIDTH-1:0] bid_rd_data_r, ask_rd_data_r;
    assign bid_rd_data = bid_rd_data_r;
    assign ask_rd_data = ask_rd_data_r;

    // Canonical simple-dual-port template: one write, one read, same clock, plain enables.
    always @(posedge clk) begin
        if (bid_wr_en) bid_mem[bid_wr_addr] <= bid_wr_data;
        if (rd_en)     bid_rd_data_r        <= bid_mem[rd_addr];
    end

    always @(posedge clk) begin
        if (ask_wr_en) ask_mem[ask_wr_addr] <= ask_wr_data;
        if (rd_en)     ask_rd_data_r        <= ask_mem[rd_addr];
    end

    always @(posedge clk) begin
        level_event_valid <= 1'b0;

        if (rst) begin
            fifo_wr_ptr <= 0;
            fifo_rd_ptr <= 0;
            state       <= S_RESET_SWEEP;
            sweep_addr  <= 0;
        end else begin
            // --- enqueue new event (always allowed, even mid-sweep -- harmless to buffer) ---
            if (relevant_in && !fifo_full) begin
                fifo_side [fifo_wr_ptr[FIFO_DEPTH_LOG2-1:0]] <= event_side;
                fifo_price[fifo_wr_ptr[FIFO_DEPTH_LOG2-1:0]] <= event_price;
                fifo_delta[fifo_wr_ptr[FIFO_DEPTH_LOG2-1:0]] <= event_shares_delta;
                fifo_wr_ptr <= fifo_wr_ptr + 1'b1;
            end

            case (state)
                S_RESET_SWEEP: begin
                    // bid_mem/ask_mem are actually cleared via bid_wr_en/ask_wr_en above
                    // (driven by `sweeping`), which is a single-point write for both the
                    // sweep and the steady-state case. This branch only advances the FSM.
                    if (sweep_addr == NUM_ENTRIES-1) state <= S_IDLE;
                    sweep_addr <= sweep_addr + 1'b1;
                end

                S_IDLE: begin
                    if (!fifo_empty) begin
                        p_side  <= head_side;
                        p_price <= head_price;
                        p_delta <= head_delta;
                        p_addr  <= head_addr;
                        fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
                        state <= S_READ;
                        // bid_rd_data_r / ask_rd_data_r are loaded by the memory always
                        // blocks above (rd_en is asserted this same cycle); by the next
                        // cycle (S_READ), rd_entry = p_side ? bid_rd_data : ask_rd_data
                        // reflects this address's contents, same latency as before.
                    end
                end

                S_READ: begin
                    // bid_mem[p_addr]/ask_mem[p_addr] are actually written via
                    // bid_wr_en/ask_wr_en above (driven by `do_write`). This branch
                    // only reports the resulting level event.
                    if (!rd_valid || rd_tag == p_price) begin
                        if (write_clear) begin
                            level_event_valid   <= 1'b1;
                            level_side          <= p_side;
                            level_price         <= p_price;
                            level_total_shares  <= 32'd0;
                            level_removed       <= 1'b1;
                        end else begin
                            level_event_valid   <= 1'b1;
                            level_side          <= p_side;
                            level_price         <= p_price;
                            level_total_shares  <= write_total[31:0];
                            level_removed       <= 1'b0;
                        end
                    end
                    // else: slot occupied by a genuinely different price (collision) ->
                    // drop this event (bid_wr_en/ask_wr_en already excludes it via
                    // do_write), leave the existing level untouched. No level_event
                    // emitted, same "drop rather than corrupt" policy used elsewhere.
                    state <= S_IDLE;
                end

                default: state <= S_RESET_SWEEP;
            endcase
        end
    end
endmodule