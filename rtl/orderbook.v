// Order book: a fixed-capacity, fully-parallel content-addressable memory
// (CAM) keyed by ITCH order reference number.
//
// Real ITCH Execute/Cancel/Delete/Replace messages reference an existing
// order purely by its 64-bit order reference number - there is no price
// or side information in those messages at all, so a feed handler MUST
// be able to look up "which order is this" by reference number alone.
// A CAM (parallel comparison against every stored entry, all in one
// cycle) is the natural hardware structure for this, and is practical
// here specifically because CAM_DEPTH is small and fixed (unlike a
// software hash table, which would be the natural choice at much larger
// scale, but isn't what real low-latency feed handlers use).
//
// Consumes itch_decoder's outputs directly. 'S' (System Event) and any
// unsupported/unknown type produce no order-book action.
//
// event_shares_delta: signed change in this order's resting-share total
// caused by this event (positive on Add, negative or zero on Execute/
// Cancel/Delete). This is the piece a price-level aggregator needs and
// that event_shares_remaining alone can't give it: event_shares_remaining
// is just this one order's NEW total, but a price level is a sum across
// many orders at the same price, so the aggregator has to accumulate
// deltas, not overwrite with a single order's remaining total. Zero on
// any rejection (no book state changed).

module order_book #(
    parameter CAM_DEPTH = 64
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        msg_valid,
    input  wire [7:0]  msg_type,
    input  wire [63:0] order_ref_number,
    input  wire        buy_sell_indicator,
    input  wire [31:0] shares,   // total (A), executed (E), or canceled (X) - matches itch_decoder's own reuse convention
    input  wire [31:0] price,    // only meaningful for 'A'
    input  wire [15:0] stock_locate,

    // Downstream market-data event, one pulse per processed message.
    output reg        event_valid,
    output reg [2:0]  event_type,   // see localparams below
    output reg [63:0] event_order_ref,
    output reg        event_side,
    output reg [31:0] event_shares_remaining,  // 0 if the order was removed
    output reg signed [32:0] event_shares_delta, // change in this order's resting shares (see header note)
    output reg [31:0] event_price,
    output reg [15:0] event_stock_locate
);

    localparam EVT_ADDED           = 3'd0;
    localparam EVT_REDUCED         = 3'd1;
    localparam EVT_REMOVED         = 3'd2;
    localparam EVT_REJECTED_NOMATCH= 3'd3;  // E/X/D referenced an order_ref not currently in the book
    localparam EVT_REJECTED_FULL   = 3'd4;  // 'A' arrived with no free slot available

    reg                    cam_valid  [0:CAM_DEPTH-1];
    reg [63:0]             cam_ref    [0:CAM_DEPTH-1];
    reg                    cam_side   [0:CAM_DEPTH-1];
    reg [31:0]             cam_shares [0:CAM_DEPTH-1];
    reg [31:0]             cam_price  [0:CAM_DEPTH-1];
    reg [15:0]             cam_stock  [0:CAM_DEPTH-1];

    // Fully parallel search: every entry is compared in the same cycle,
    // the way a real CAM operates - this is a for-loop only for RTL
    // authoring convenience, not a sequential/iterative search.
    integer i;
    reg                match_found;
    reg [$clog2(CAM_DEPTH)-1:0] match_index;
    reg                free_found;
    reg [$clog2(CAM_DEPTH)-1:0] free_index;

    always @(*) begin
        match_found = 1'b0;
        match_index = 0;
        for (i = 0; i < CAM_DEPTH; i = i + 1) begin
            if (!match_found && cam_valid[i] && (cam_ref[i] == order_ref_number)) begin
                match_found = 1'b1;
                match_index = i[$clog2(CAM_DEPTH)-1:0];
            end
        end

        free_found = 1'b0;
        free_index = 0;
        for (i = 0; i < CAM_DEPTH; i = i + 1) begin
            if (!free_found && !cam_valid[i]) begin
                free_found = 1'b1;
                free_index = i[$clog2(CAM_DEPTH)-1:0];
            end
        end
    end

    wire [31:0] reduced_shares =
        (shares >= cam_shares[match_index]) ? 32'd0 : (cam_shares[match_index] - shares);

    always @(posedge clk) begin
        event_valid <= 1'b0;
        event_shares_delta <= 33'sd0;

        if (rst) begin
            for (i = 0; i < CAM_DEPTH; i = i + 1) cam_valid[i] <= 1'b0;
        end else if (msg_valid) begin
            case (msg_type)
                "A": begin
                    if (free_found) begin
                        cam_valid[free_index]  <= 1'b1;
                        cam_ref[free_index]    <= order_ref_number;
                        cam_side[free_index]   <= buy_sell_indicator;
                        cam_shares[free_index] <= shares;
                        cam_price[free_index]  <= price;
                        cam_stock[free_index]  <= stock_locate;

                        event_valid            <= 1'b1;
                        event_type             <= EVT_ADDED;
                        event_order_ref        <= order_ref_number;
                        event_side             <= buy_sell_indicator;
                        event_shares_remaining <= shares;
                        event_shares_delta     <= $signed({1'b0, shares});  // full new order size enters the level
                        event_price            <= price;
                        event_stock_locate     <= stock_locate;
                    end else begin
                        event_valid     <= 1'b1;
                        event_type      <= EVT_REJECTED_FULL;
                        event_order_ref <= order_ref_number;
                    end
                end

                "E", "X": begin  // mechanically identical: decrement remaining shares
                    if (match_found) begin
                        if (reduced_shares == 0) cam_valid[match_index] <= 1'b0;
                        else                     cam_shares[match_index] <= reduced_shares;

                        event_valid            <= 1'b1;
                        event_type              <= (reduced_shares == 0) ? EVT_REMOVED : EVT_REDUCED;
                        event_order_ref         <= order_ref_number;
                        event_side              <= cam_side[match_index];
                        event_shares_remaining  <= reduced_shares;
                        // amount leaving the level this event = old resting shares - new resting shares,
                        // reported as a negative delta (reduced_shares - cam_shares[match_index] <= 0)
                        event_shares_delta      <= $signed({1'b0, reduced_shares}) - $signed({1'b0, cam_shares[match_index]});
                        event_price             <= cam_price[match_index];
                        event_stock_locate      <= cam_stock[match_index];
                    end else begin
                        event_valid     <= 1'b1;
                        event_type      <= EVT_REJECTED_NOMATCH;
                        event_order_ref <= order_ref_number;
                    end
                end

                "D": begin
                    if (match_found) begin
                        cam_valid[match_index] <= 1'b0;

                        event_valid            <= 1'b1;
                        event_type             <= EVT_REMOVED;
                        event_order_ref        <= order_ref_number;
                        event_side             <= cam_side[match_index];
                        event_shares_remaining <= 32'd0;
                        // the order's whole remaining size leaves the level
                        event_shares_delta     <= -$signed({1'b0, cam_shares[match_index]});
                        event_price            <= cam_price[match_index];
                        event_stock_locate     <= cam_stock[match_index];
                    end else begin
                        event_valid     <= 1'b1;
                        event_type      <= EVT_REJECTED_NOMATCH;
                        event_order_ref <= order_ref_number;
                    end
                end

                default: ; // 'S' or any unsupported/unknown type: no order-book action
            endcase
        end
    end

endmodule