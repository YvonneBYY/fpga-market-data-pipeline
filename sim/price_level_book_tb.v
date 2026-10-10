`timescale 1ns/1ps

// Integration testbench: chains order_book -> price_level_book exactly as
// they'll be wired on hardware, and drives price_level_book only through
// order_book's real event stream (never hand-crafted deltas), so this
// exercises the actual interface contract between the two modules.

module price_level_book_tb;

    localparam CAM_DEPTH   = 8;
    localparam LEVEL_DEPTH = 2;  // small on purpose, to make level-capacity exhaustion quick to test

    reg clk = 0;
    always #5 clk = ~clk;

    reg rst = 1;
    reg msg_valid = 0;
    reg [7:0] msg_type = 0;
    reg [63:0] order_ref_number = 0;
    reg buy_sell_indicator = 0;
    reg [31:0] shares = 0;
    reg [31:0] price = 0;
    reg [15:0] stock_locate = 0;

    wire        ob_event_valid;
    wire [2:0]  ob_event_type;
    wire [63:0] ob_event_order_ref;
    wire        ob_event_side;
    wire [31:0] ob_event_shares_remaining;
    wire signed [32:0] ob_event_shares_delta;
    wire [31:0] ob_event_price;
    wire [15:0] ob_event_stock_locate;

    order_book #(.CAM_DEPTH(CAM_DEPTH)) ob (
        .clk(clk), .rst(rst),
        .msg_valid(msg_valid), .msg_type(msg_type),
        .order_ref_number(order_ref_number), .buy_sell_indicator(buy_sell_indicator),
        .shares(shares), .price(price), .stock_locate(stock_locate),
        .event_valid(ob_event_valid), .event_type(ob_event_type), .event_order_ref(ob_event_order_ref),
        .event_side(ob_event_side), .event_shares_remaining(ob_event_shares_remaining),
        .event_shares_delta(ob_event_shares_delta),
        .event_price(ob_event_price), .event_stock_locate(ob_event_stock_locate)
    );

    wire        level_event_valid;
    wire        level_side;
    wire [31:0] level_price;
    wire [31:0] level_total_shares;
    wire        level_removed;

    price_level_book #(.LEVEL_DEPTH(LEVEL_DEPTH)) plb (
        .clk(clk), .rst(rst),
        .event_valid(ob_event_valid), .event_type(ob_event_type),
        .event_side(ob_event_side), .event_shares_delta(ob_event_shares_delta),
        .event_price(ob_event_price),
        .level_event_valid(level_event_valid), .level_side(level_side),
        .level_price(level_price), .level_total_shares(level_total_shares),
        .level_removed(level_removed)
    );

    integer errors = 0;

    // Drive one ITCH-style message. Both order_book's and price_level_book's
    // outputs are registered off the same clk, so the aggregate-level result
    // lands one cycle after order_book's own event - same one-cycle-later
    // pulse discipline as order_book's own testbench.
    task send_msg(
        input [7:0] mtype, input [63:0] ref_num, input side,
        input [31:0] sh, input [31:0] pr, input [15:0] loc
    );
        begin
            @(negedge clk);
            msg_type = mtype; order_ref_number = ref_num; buy_sell_indicator = side;
            shares = sh; price = pr; stock_locate = loc;
            msg_valid = 1;
            @(negedge clk);
            msg_valid = 0;
            @(negedge clk);  // let price_level_book's registered output settle
        end
    endtask

    initial begin
        rst = 1;
        repeat (3) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        // ---- Test 1: first order at a price creates a new level ----
        send_msg("A", 64'hA001, 1'b1, 100, 32'd100, 16'd1);  // Buy 100 @ 100
        if (!level_event_valid || level_side !== 1'b1 || level_price !== 32'd100 ||
            level_total_shares !== 32'd100 || level_removed !== 1'b0) begin
            $display("FAIL [T1]: first order at a price did not create a fresh level (valid=%b side=%b price=%0d total=%0d removed=%b)",
                       level_event_valid, level_side, level_price, level_total_shares, level_removed);
            errors = errors + 1;
        end else $display("PASS [T1]: first Add at price 100 creates level with total=100");

        // ---- Test 2: a second order at the SAME price aggregates into the same level ----
        send_msg("A", 64'hA002, 1'b1, 50, 32'd100, 16'd1);  // Buy 50 @ 100 (same side/price)
        if (!level_event_valid || level_side !== 1'b1 || level_price !== 32'd100 ||
            level_total_shares !== 32'd150 || level_removed !== 1'b0) begin
            $display("FAIL [T2]: second order at same price did not aggregate (total=%0d, expected 150)", level_total_shares);
            errors = errors + 1;
        end else $display("PASS [T2]: second Add at the same price aggregates, level total=100+50=150");

        // ---- Test 3: a different price creates an independent level ----
        send_msg("A", 64'hA003, 1'b1, 30, 32'd200, 16'd1);  // Buy 30 @ 200
        if (!level_event_valid || level_price !== 32'd200 || level_total_shares !== 32'd30) begin
            $display("FAIL [T3]: a different price did not create an independent level (price=%0d total=%0d)", level_price, level_total_shares);
            errors = errors + 1;
        end else $display("PASS [T3]: Add at a different price (200) creates its own independent level, total=30");

        // Confirm price 100's level is untouched by the price-200 add
        // (no direct observable here beyond the next event at 100 below,
        // which is exactly what Test 4 checks).

        // ---- Test 4: partial Execute reduces the level total (not remove it) ----
        send_msg("E", 64'hA001, 0, 40, 0, 0);  // execute 40 of order A001's 100
        if (!level_event_valid || level_side !== 1'b1 || level_price !== 32'd100 ||
            level_total_shares !== 32'd110 || level_removed !== 1'b0) begin
            $display("FAIL [T4]: partial Execute did not correctly reduce the level (total=%0d, expected 110)", level_total_shares);
            errors = errors + 1;
        end else $display("PASS [T4]: Executing 40 of order A001 reduces level 100 from 150 to 110");

        // ---- Test 5: Cancel removes an order's remaining shares, level shrinks (not removed) ----
        send_msg("X", 64'hA002, 0, 50, 0, 0);  // cancel all 50 of order A002
        if (!level_event_valid || level_total_shares !== 32'd60 || level_removed !== 1'b0) begin
            $display("FAIL [T5]: Cancel of A002 did not correctly shrink the level (total=%0d, expected 60)", level_total_shares);
            errors = errors + 1;
        end else $display("PASS [T5]: Canceling order A002 (50 shares) shrinks level 100 from 110 to 60, level not removed");

        // ---- Test 6: removing the LAST order at a price brings the level to exactly zero -> removed ----
        // Order A001 now has 60 shares resting (100 - 40 executed). Delete it.
        send_msg("D", 64'hA001, 0, 0, 0, 0);
        if (!level_event_valid || level_price !== 32'd100 || level_total_shares !== 32'd0 || level_removed !== 1'b1) begin
            $display("FAIL [T6]: deleting the last resting order at price 100 did not remove the level (total=%0d removed=%b)",
                       level_total_shares, level_removed);
            errors = errors + 1;
        end else $display("PASS [T6]: deleting the last order at price 100 exhausts the level, level_removed=1, total=0");

        // ---- Test 7: same price, opposite side is an independent level ----
        send_msg("A", 64'hB001, 1'b0, 75, 32'd100, 16'd2);  // Sell 75 @ 100 (same price as before, opposite side)
        if (!level_event_valid || level_side !== 1'b0 || level_price !== 32'd100 || level_total_shares !== 32'd75) begin
            $display("FAIL [T7]: sell side at price 100 was not independent of the (now-removed) buy level (side=%b price=%0d total=%0d)",
                       level_side, level_price, level_total_shares);
            errors = errors + 1;
        end else $display("PASS [T7]: Sell 75 @ 100 is tracked as its own level, independent of the buy side at the same price");

        // ---- Test 8: rejected order_book events (no match / full) produce NO level event ----
        // Cancel on a nonexistent order_ref -> order_book rejects (delta=0) -> price_level_book must stay silent.
        send_msg("X", 64'hDEAD, 0, 1, 0, 0);
        if (level_event_valid) begin
            $display("FAIL [T8]: a rejected (no-match) order_book event incorrectly produced a level event");
            errors = errors + 1;
        end else $display("PASS [T8]: a rejected order_book event (no match) correctly produces no level event");

        // ---- Test 9: price-level CAM capacity exhaustion (LEVEL_DEPTH=2) ----
        // Current live levels: buy@200 (from T3, still resting 30), sell@100 (from T7, 75).
        // That's already 2 levels = LEVEL_DEPTH. A third distinct (side,price) must be
        // silently dropped from the aggregate view without corrupting the existing levels.
        send_msg("A", 64'hC001, 1'b1, 999, 32'd300, 16'd3);  // Buy 999 @ 300 - brand new level, no room
        if (level_event_valid) begin
            $display("FAIL [T9]: a new price level was created despite LEVEL_DEPTH already being full (side=%b price=%0d total=%0d)",
                       level_side, level_price, level_total_shares);
            errors = errors + 1;
        end else $display("PASS [T9]: new price level correctly dropped (not reported) when LEVEL_DEPTH capacity is exhausted");

        // Confirm the existing buy@200 level is untouched by the capacity-exhaustion attempt:
        // add one more share to it and check it still aggregates correctly from 30.
        send_msg("A", 64'hC002, 1'b1, 5, 32'd200, 16'd1);  // Buy 5 more @ 200
        if (!level_event_valid || level_price !== 32'd200 || level_total_shares !== 32'd35) begin
            $display("FAIL [T9b]: existing level 200 was corrupted by the capacity-exhaustion attempt (total=%0d, expected 35)",
                       level_total_shares);
            errors = errors + 1;
        end else $display("PASS [T9b]: existing level 200 remained intact and correctly aggregates further (30+5=35)");

        if (errors == 0) $display("\n=== ALL TESTS PASSED ===");
        else $display("\n=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end

    initial begin
        #20000;
        $display("TIMEOUT");
        $finish;
    end

endmodule