`timescale 1ns/1ps

module order_book_tb;

    localparam CAM_DEPTH = 4;  // small on purpose, to make capacity-exhaustion testing quick

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

    wire        event_valid;
    wire [2:0]  event_type;
    wire [63:0] event_order_ref;
    wire        event_side;
    wire [31:0] event_shares_remaining;
    wire signed [32:0] event_shares_delta;
    wire [31:0] event_price;
    wire [15:0] event_stock_locate;

    order_book #(.CAM_DEPTH(CAM_DEPTH)) dut (
        .clk(clk), .rst(rst),
        .msg_valid(msg_valid), .msg_type(msg_type),
        .order_ref_number(order_ref_number), .buy_sell_indicator(buy_sell_indicator),
        .shares(shares), .price(price), .stock_locate(stock_locate),
        .event_valid(event_valid), .event_type(event_type), .event_order_ref(event_order_ref),
        .event_side(event_side), .event_shares_remaining(event_shares_remaining),
        .event_shares_delta(event_shares_delta),
        .event_price(event_price), .event_stock_locate(event_stock_locate)
    );

    localparam EVT_ADDED = 0, EVT_REDUCED = 1, EVT_REMOVED = 2,
               EVT_REJECTED_NOMATCH = 3, EVT_REJECTED_FULL = 4;

    integer errors = 0;

    // Drive one message, held for one clock cycle, and return the event
    // fields sampled the cycle right after (event_valid is a one-cycle
    // pulse, registered - visible the cycle following the input).
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
        end
    endtask

    initial begin
        rst = 1;
        repeat (3) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        // ---- Test 1: Add a new order ----
        send_msg("A", 64'h1001, 1'b1, 100, 1502500, 16'd7);  // Buy 100 @ $150.25, stock_locate=7
        if (!event_valid || event_type !== EVT_ADDED || event_order_ref !== 64'h1001 ||
            event_side !== 1'b1 || event_shares_remaining !== 100 ||
            event_shares_delta !== 33'sd100 ||
            event_price !== 1502500 || event_stock_locate !== 16'd7) begin
            $display("FAIL [T1]: Add did not produce correct EVT_ADDED (type=%0d ref=%h side=%b shares=%0d delta=%0d price=%0d loc=%0d)",
                       event_type, event_order_ref, event_side, event_shares_remaining, event_shares_delta, event_price, event_stock_locate);
            errors = errors + 1;
        end else $display("PASS [T1]: Add produces correct EVT_ADDED event, delta=+100");

        // ---- Test 2: partial Execute reduces shares ----
        send_msg("E", 64'h1001, 1'b0, 30, 0, 16'd0);  // execute 30 of the 100
        if (!event_valid || event_type !== EVT_REDUCED || event_shares_remaining !== 70 ||
            event_shares_delta !== -33'sd30 ||
            event_side !== 1'b1 || event_price !== 1502500) begin
            $display("FAIL [T2]: partial Execute did not correctly reduce shares (type=%0d remaining=%0d delta=%0d side=%b price=%0d)",
                       event_type, event_shares_remaining, event_shares_delta, event_side, event_price);
            errors = errors + 1;
        end else $display("PASS [T2]: partial Execute correctly reduces remaining shares to 70, delta=-30, preserves side/price");

        // ---- Test 3: Execute the remaining shares exactly to zero -> removed ----
        send_msg("E", 64'h1001, 1'b0, 70, 0, 16'd0);
        if (!event_valid || event_type !== EVT_REMOVED || event_shares_remaining !== 0 ||
            event_shares_delta !== -33'sd70) begin
            $display("FAIL [T3]: Executing to exactly zero did not produce EVT_REMOVED (type=%0d remaining=%0d delta=%0d)",
                       event_type, event_shares_remaining, event_shares_delta);
            errors = errors + 1;
        end else $display("PASS [T3]: Executing remaining shares to exactly zero correctly removes the order, delta=-70");

        // ---- Test 4: order_ref 0x1001 is now gone - Cancel on it should reject ----
        send_msg("X", 64'h1001, 1'b0, 10, 0, 16'd0);
        if (!event_valid || event_type !== EVT_REJECTED_NOMATCH || event_shares_delta !== 33'sd0) begin
            $display("FAIL [T4]: Cancel on a removed order did not reject (type=%0d delta=%0d)", event_type, event_shares_delta);
            errors = errors + 1;
        end else $display("PASS [T4]: Cancel on an already-removed order correctly rejects (no match), delta=0");

        // ---- Test 5: a freed slot can be reused by a new Add ----
        send_msg("A", 64'h2002, 1'b0, 200, 999900, 16'd12);  // Sell 200 @ $99.99
        if (!event_valid || event_type !== EVT_ADDED || event_order_ref !== 64'h2002 ||
            event_shares_delta !== 33'sd200) begin
            $display("FAIL [T5]: Add after a slot was freed did not succeed (type=%0d ref=%h delta=%0d)", event_type, event_order_ref, event_shares_delta);
            errors = errors + 1;
        end else $display("PASS [T5]: freed slot correctly reused by a new Add, delta=+200");

        // ---- Test 6: Delete removes regardless of remaining shares ----
        send_msg("D", 64'h2002, 0, 0, 0, 0);
        if (!event_valid || event_type !== EVT_REMOVED || event_shares_remaining !== 0 ||
            event_shares_delta !== -33'sd200 ||
            event_side !== 1'b0 || event_price !== 999900) begin
            $display("FAIL [T6]: Delete did not correctly remove the order (type=%0d remaining=%0d delta=%0d side=%b price=%0d)",
                       event_type, event_shares_remaining, event_shares_delta, event_side, event_price);
            errors = errors + 1;
        end else $display("PASS [T6]: Delete correctly removes the order (delta=-200) and reports its last known side/price");

        // ---- Test 7: multiple simultaneously open orders stay independent ----
        send_msg("A", 64'h3003, 1'b1, 50, 100000, 16'd1);
        send_msg("A", 64'h4004, 1'b0, 75, 200000, 16'd2);
        send_msg("E", 64'h3003, 0, 20, 0, 0);  // touch only order 3003
        if (!event_valid || event_order_ref !== 64'h3003 || event_shares_remaining !== 30 ||
            event_shares_delta !== -33'sd20) begin
            $display("FAIL [T7a]: Executing order 3003 gave wrong result (ref=%h remaining=%0d delta=%0d)",
                       event_order_ref, event_shares_remaining, event_shares_delta);
            errors = errors + 1;
        end else $display("PASS [T7a]: Executing order 3003 correctly reduces only that order, delta=-20");
        send_msg("D", 64'h4004, 0, 0, 0, 0);  // order 4004 should be untouched by the above
        if (!event_valid || event_type !== EVT_REMOVED || event_shares_remaining !== 0 ||
            event_shares_delta !== -33'sd75 ||
            event_price !== 200000) begin
            $display("FAIL [T7b]: order 4004 was corrupted by the earlier operation on 3003 (type=%0d price=%0d delta=%0d)",
                       event_type, event_price, event_shares_delta);
            errors = errors + 1;
        end else $display("PASS [T7b]: order 4004 remained fully independent and correct, delta=-75");

        // ---- Test 8: fill the (small, 4-entry) CAM to capacity, then reject ----
        // Current state: order 3003 still open (1 slot used). Fill the remaining 3.
        send_msg("A", 64'h5005, 1, 10, 1, 1);
        send_msg("A", 64'h6006, 1, 10, 1, 1);
        send_msg("A", 64'h7007, 1, 10, 1, 1);
        // CAM_DEPTH=4, now all 4 slots used (3003, 5005, 6006, 7007) - next Add must reject
        send_msg("A", 64'h8008, 1, 10, 1, 1);
        if (!event_valid || event_type !== EVT_REJECTED_FULL || event_order_ref !== 64'h8008 ||
            event_shares_delta !== 33'sd0) begin
            $display("FAIL [T8]: Add did not correctly reject when the CAM was full (type=%0d ref=%h delta=%0d)",
                       event_type, event_order_ref, event_shares_delta);
            errors = errors + 1;
        end else $display("PASS [T8]: Add correctly rejects with EVT_REJECTED_FULL when every CAM slot is occupied, delta=0");

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