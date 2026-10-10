// Price-level book: aggregates order_book's per-order event stream into a
// per-price-level view (the "depth" a real market-data consumer actually
// wants - total shares resting at each price on each side, not each
// individual order).
//
// Sits directly downstream of order_book, consuming its existing event
// output plus the one new field order_book was extended with for this
// purpose: event_shares_delta, the signed change in an order's resting
// shares caused by this event. A price level's total is a running sum
// of deltas across every order that has ever rested at that price, so
// order_book's OLD event_shares_remaining (one order's own new total)
// was not enough on its own - this module is exactly why that field was
// added.
//
// Like order_book itself, this is a small fixed-capacity CAM, keyed here
// by (side, price) instead of by order reference number. That's the same
// design choice for the same reason: real feed handlers need to look up
// "does a level already exist at this price" with no natural hash/index
// (price is an arbitrary 32-bit fixed-point value), so a fully parallel
// compare-every-entry CAM is the natural, low-latency hardware structure
// at the small, bounded depth this project targets.
//
// A level is created the first time shares arrive at a price (delta > 0,
// i.e. only ever from EVT_ADDED - EVT_REDUCED/REMOVED can only touch a
// level that already exists) and is torn down the moment its running
// total returns to exactly zero, so the table only ever holds price
// levels that currently have resting shares - the same "book" invariant
// order_book itself keeps for individual orders.

module price_level_book #(
    parameter LEVEL_DEPTH = 32
) (
    input  wire        clk,
    input  wire        rst,

    // order_book's event stream, taken directly as input.
    input  wire        event_valid,
    input  wire [2:0]  event_type,
    input  wire        event_side,
    input  wire signed [32:0] event_shares_delta,
    input  wire [31:0] event_price,

    // Downstream per-level market-data event, one pulse per price-level
    // change (a no-op event_type, e.g. a rejection, produces no pulse
    // here at all, since no level total is affected).
    output reg        level_event_valid,
    output reg        level_side,
    output reg [31:0] level_price,
    output reg [31:0] level_total_shares,  // new total resting at this price/side after the update
    output reg        level_removed        // 1 if this update brought the level's total to exactly zero
);

    localparam EVT_ADDED   = 3'd0;
    localparam EVT_REDUCED = 3'd1;
    localparam EVT_REMOVED = 3'd2;
    // EVT_REJECTED_NOMATCH (3'd3) and EVT_REJECTED_FULL (3'd4) carry
    // event_shares_delta == 0 by construction in order_book, so they are
    // naturally inert here too - no special-casing needed.

    reg                    lvl_valid [0:LEVEL_DEPTH-1];
    reg                    lvl_side  [0:LEVEL_DEPTH-1];
    reg [31:0]             lvl_price [0:LEVEL_DEPTH-1];
    reg [31:0]             lvl_shares[0:LEVEL_DEPTH-1];

    // Only Add/Execute/Cancel/Delete ever move a nonzero number of shares
    // into or out of a level; a rejection's delta is always zero, so
    // gating on delta != 0 (rather than enumerating event_type) is both
    // sufficient and future-proof against new zero-effect event types.
    wire relevant = event_valid && (event_shares_delta != 33'sd0);

    // Fully parallel search over (side, price), same CAM discipline as
    // order_book's own reference-number lookup.
    integer i;
    reg                match_found;
    reg [$clog2(LEVEL_DEPTH)-1:0] match_index;
    reg                free_found;
    reg [$clog2(LEVEL_DEPTH)-1:0] free_index;

    always @(*) begin
        match_found = 1'b0;
        match_index = 0;
        for (i = 0; i < LEVEL_DEPTH; i = i + 1) begin
            if (!match_found && lvl_valid[i] &&
                (lvl_side[i] == event_side) && (lvl_price[i] == event_price)) begin
                match_found = 1'b1;
                match_index = i[$clog2(LEVEL_DEPTH)-1:0];
            end
        end

        free_found = 1'b0;
        free_index = 0;
        for (i = 0; i < LEVEL_DEPTH; i = i + 1) begin
            if (!free_found && !lvl_valid[i]) begin
                free_found = 1'b1;
                free_index = i[$clog2(LEVEL_DEPTH)-1:0];
            end
        end
    end

    // New total this cycle would produce, for whichever slot the update
    // applies to (existing match, or a freshly allocated free slot).
    wire signed [32:0] existing_total_signed = $signed({1'b0, lvl_shares[match_index]});
    wire signed [32:0] new_total_signed      = existing_total_signed + event_shares_delta;
    wire [31:0]         new_total            = new_total_signed[31:0];

    always @(posedge clk) begin
        level_event_valid <= 1'b0;

        if (rst) begin
            for (i = 0; i < LEVEL_DEPTH; i = i + 1) lvl_valid[i] <= 1'b0;
        end else if (relevant) begin
            if (match_found) begin
                // An existing level is touched. A REDUCED/REMOVED delta can
                // only ever land here, since order_book cannot reduce or
                // remove an order at a price with no existing level; an
                // ADDED delta lands here too when a second order joins a
                // price that already has resting shares.
                if (new_total_signed <= 33'sd0) begin
                    // Level exhausted: every order that was resting here
                    // has now been fully executed/canceled/deleted.
                    lvl_valid[match_index] <= 1'b0;

                    level_event_valid   <= 1'b1;
                    level_side          <= event_side;
                    level_price         <= event_price;
                    level_total_shares  <= 32'd0;
                    level_removed       <= 1'b1;
                end else begin
                    lvl_shares[match_index] <= new_total;

                    level_event_valid   <= 1'b1;
                    level_side          <= event_side;
                    level_price         <= event_price;
                    level_total_shares  <= new_total;
                    level_removed       <= 1'b0;
                end
            end else if (event_shares_delta > 33'sd0) begin
                // No level exists yet at this price - can only happen on
                // an ADDED event (a positive delta with nowhere to land),
                // since order_book never generates a positive delta for
                // any other event type. Allocate a fresh level.
                if (free_found) begin
                    lvl_valid[free_index]  <= 1'b1;
                    lvl_side[free_index]   <= event_side;
                    lvl_price[free_index]  <= event_price;
                    lvl_shares[free_index] <= event_shares_delta[31:0];

                    level_event_valid   <= 1'b1;
                    level_side          <= event_side;
                    level_price         <= event_price;
                    level_total_shares  <= event_shares_delta[31:0];
                    level_removed       <= 1'b0;
                end
                // If no free slot is available, the new level is silently
                // dropped from the aggregate view (LEVEL_DEPTH exhausted).
                // This mirrors order_book's own EVT_REJECTED_FULL policy,
                // but is not separately reported here since the per-order
                // event stream already reports order_book's own rejection
                // in this case; the aggregate view is best-effort under
                // capacity exhaustion by design.
            end
            // A negative/zero delta with no matching level (match_found
            // false, event_shares_delta <= 0) cannot occur: order_book
            // only ever issues a negative delta against an order that
            // was previously ADDED, and any order that was ADDED always
            // has a corresponding level created at that moment - so no
            // else-branch is needed here.
        end
    end

endmodule