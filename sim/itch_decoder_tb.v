`timescale 1ns/1ps

module itch_decoder_tb;

    reg clk = 0;
    always #5 clk = ~clk;

    reg rst = 1;
    reg payload_valid = 0;
    reg [7:0] payload_data = 0;
    reg payload_last = 0;

    wire msg_valid;
    wire [7:0] msg_type;
    wire unknown_type;
    wire [15:0] stock_locate, tracking_number;
    wire [47:0] timestamp;
    wire [63:0] order_ref_number;
    wire buy_sell_indicator;
    wire [31:0] shares;
    wire [63:0] stock;
    wire [31:0] price;
    wire [7:0] event_code;
    wire [63:0] match_number;

    itch_decoder dut (
        .clk(clk), .rst(rst),
        .payload_valid(payload_valid), .payload_data(payload_data), .payload_last(payload_last),
        .msg_valid(msg_valid), .msg_type(msg_type), .unknown_type(unknown_type),
        .stock_locate(stock_locate), .tracking_number(tracking_number), .timestamp(timestamp),
        .order_ref_number(order_ref_number), .buy_sell_indicator(buy_sell_indicator),
        .shares(shares), .stock(stock), .price(price),
        .event_code(event_code), .match_number(match_number)
    );

    integer errors = 0;

    // Drive one byte, held valid for one clock cycle. is_last asserts
    // payload_last alongside the final byte of a message/packet.
    task drive_byte(input [7:0] b, input is_last);
        begin
            @(negedge clk);
            payload_data  = b;
            payload_valid = 1;
            payload_last  = is_last;
            @(negedge clk);
            payload_valid = 0;
            payload_last  = 0;
        end
    endtask

    // Wait for msg_valid, with a bounded timeout per call.
    task wait_msg_valid;
        integer i;
        begin
            for (i = 0; i < 20 && !msg_valid; i = i + 1) @(posedge clk);
        end
    endtask

    initial begin
        rst = 1;
        repeat (5) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        // ---- Test 1: System Event ('S', 12 bytes) ----
        // Type='S' StockLocate=0x0000 Tracking=0x0001 Timestamp=0x000000123456 EventCode='Q'
        drive_byte(8'h53, 0); drive_byte(8'h00, 0); drive_byte(8'h00, 0);
        drive_byte(8'h00, 0); drive_byte(8'h01, 0);
        drive_byte(8'h00, 0); drive_byte(8'h00, 0); drive_byte(8'h00, 0);
        drive_byte(8'h12, 0); drive_byte(8'h34, 0); drive_byte(8'h56, 0);
        drive_byte(8'h51, 1);
        wait_msg_valid;
        if (!msg_valid || msg_type !== "S" || stock_locate !== 16'h0000 ||
            tracking_number !== 16'h0001 || timestamp !== 48'h000000123456 ||
            event_code !== "Q") begin
            $display("FAIL [T1]: System Event decode wrong (msg_valid=%b type=%c locate=%h track=%h ts=%h evt=%c)",
                       msg_valid, msg_type, stock_locate, tracking_number, timestamp, event_code);
            errors = errors + 1;
        end else $display("PASS [T1]: System Event ('S') decoded correctly");

        // ---- Test 2: Add Order ('A', 36 bytes) ----
        // OrderRef=0x1234 BuySell='B' Shares=100 Stock="AAPL    " Price=100.0000(=1000000)
        drive_byte(8'h41,0); drive_byte(8'h00,0); drive_byte(8'h01,0);
        drive_byte(8'h00,0); drive_byte(8'h02,0);
        drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h01,0);
        drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h12,0); drive_byte(8'h34,0);
        drive_byte(8'h42,0); // 'B'
        drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h64,0); // 100
        drive_byte("A",0); drive_byte("A",0); drive_byte("P",0); drive_byte("L",0);
        drive_byte(" ",0); drive_byte(" ",0); drive_byte(" ",0); drive_byte(" ",0);
        drive_byte(8'h00,0); drive_byte(8'h0F,0); drive_byte(8'h42,0); drive_byte(8'h40,1); // price 1000000
        wait_msg_valid;
        if (!msg_valid || msg_type !== "A" || order_ref_number !== 64'h0000000000001234 ||
            buy_sell_indicator !== 1'b1 || shares !== 32'd100 ||
            stock !== {"A","A","P","L"," "," "," "," "} || price !== 32'd1000000) begin
            $display("FAIL [T2]: Add Order decode wrong (ref=%h bs=%b shares=%0d stock=%s price=%0d)",
                       order_ref_number, buy_sell_indicator, shares, stock, price);
            errors = errors + 1;
        end else $display("PASS [T2]: Add Order ('A') decoded correctly");

        // ---- Test 3: Order Executed ('E', 31 bytes) ----
        // Same OrderRef=0x1234, ExecutedShares=50, MatchNumber=0x5678
        drive_byte(8'h45,0); drive_byte(8'h00,0); drive_byte(8'h01,0);
        drive_byte(8'h00,0); drive_byte(8'h02,0);
        drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h02,0);
        drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h12,0); drive_byte(8'h34,0);
        drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h32,0); // executed shares = 50
        drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h56,0); drive_byte(8'h78,1);
        wait_msg_valid;
        if (!msg_valid || msg_type !== "E" || order_ref_number !== 64'h0000000000001234 ||
            shares !== 32'd50 || match_number !== 64'h0000000000005678) begin
            $display("FAIL [T3]: Order Executed decode wrong (ref=%h shares=%0d match=%h)",
                       order_ref_number, shares, match_number);
            errors = errors + 1;
        end else $display("PASS [T3]: Order Executed ('E') decoded correctly");

        // ---- Test 4: Order Cancel ('X', 23 bytes) ----
        // OrderRef=0x1234, CanceledShares=10
        drive_byte(8'h58,0); drive_byte(8'h00,0); drive_byte(8'h01,0);
        drive_byte(8'h00,0); drive_byte(8'h03,0);
        drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h03,0);
        drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h12,0); drive_byte(8'h34,0);
        drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h0A,1); // canceled shares = 10
        wait_msg_valid;
        if (!msg_valid || msg_type !== "X" || order_ref_number !== 64'h0000000000001234 ||
            shares !== 32'd10) begin
            $display("FAIL [T4]: Order Cancel decode wrong (ref=%h shares=%0d)", order_ref_number, shares);
            errors = errors + 1;
        end else $display("PASS [T4]: Order Cancel ('X') decoded correctly");

        // ---- Test 5: Order Delete ('D', 19 bytes) ----
        drive_byte(8'h44,0); drive_byte(8'h00,0); drive_byte(8'h01,0);
        drive_byte(8'h00,0); drive_byte(8'h04,0);
        drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h04,0);
        drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h12,0); drive_byte(8'h34,1);
        wait_msg_valid;
        if (!msg_valid || msg_type !== "D" || order_ref_number !== 64'h0000000000001234) begin
            $display("FAIL [T5]: Order Delete decode wrong (ref=%h)", order_ref_number);
            errors = errors + 1;
        end else $display("PASS [T5]: Order Delete ('D') decoded correctly");

        // ---- Test 6: Multiple messages back-to-back in ONE payload ----
        // 'D' (19 bytes) immediately followed by 'S' (12 bytes) - only the
        // final byte of 'S' carries payload_last. Confirms multi-message
        // framing within a single payload, not just single-message packets.
        drive_byte(8'h44,0); drive_byte(8'h00,0); drive_byte(8'h09,0);
        drive_byte(8'h00,0); drive_byte(8'h09,0);
        drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h09,0);
        drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h99,0); drive_byte(8'h99,0);
        // no payload_last yet - immediately followed by 'S'. Check right
        // here, inline, since 'D's own msg_valid pulse is only observable
        // for a single cycle and would otherwise be missed while driving
        // 'S's bytes next.
        if (!msg_valid || msg_type !== "D" || order_ref_number !== 64'h0000000000009999) begin
            $display("FAIL [T6a]: first message ('D') in multi-message payload wrong (msg_valid=%b type=%c ref=%h)",
                       msg_valid, msg_type, order_ref_number);
            errors = errors + 1;
        end else $display("PASS [T6a]: first message ('D') in a multi-message payload decoded correctly");

        drive_byte(8'h53,0); drive_byte(8'h00,0); drive_byte(8'h00,0);
        drive_byte(8'h00,0); drive_byte(8'h01,0);
        drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0);
        drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0);
        drive_byte(8'h4F,1); // EventCode='O', last byte of packet
        if (!msg_valid || msg_type !== "S" || event_code !== "O") begin
            $display("FAIL [T6b]: second message ('S') in multi-message payload wrong (msg_valid=%b type=%c evt=%c)",
                       msg_valid, msg_type, event_code);
            errors = errors + 1;
        end else $display("PASS [T6b]: second message ('S') in the SAME payload also decoded correctly - multi-message framing works");

        // ---- Test 7: known-but-unsupported type ('R', Stock Directory,
        // 39 bytes) correctly skipped, followed by a real 'S' in the same
        // payload - confirms framing sync survives an unsupported type. ----
        drive_byte("R", 0);
        repeat (37) drive_byte(8'hAA, 0);
        drive_byte(8'hAA, 0); // 38 filler bytes total after the type byte = 39-byte message
        drive_byte(8'h53,0); drive_byte(8'h00,0); drive_byte(8'h00,0);
        drive_byte(8'h00,0); drive_byte(8'h01,0);
        drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0);
        drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0);
        drive_byte(8'h43,1); // EventCode='C', last byte
        wait_msg_valid;
        if (!msg_valid || msg_type !== "S" || event_code !== "C") begin
            $display("FAIL [T7]: 'S' after skipped 'R' wrong (type=%c evt=%c) - framing sync lost across unsupported type",
                       msg_type, event_code);
            errors = errors + 1;
        end else $display("PASS [T7]: known-but-unsupported type ('R') correctly skipped, framing sync maintained");

        // ---- Test 8: completely unknown type byte, then recovery on the
        // next (fresh) packet via payload_last resync ----
        drive_byte("Z", 1); // unknown type, immediately last byte of this packet
        if (!unknown_type) begin
            $display("FAIL [T8a]: unknown_type did not pulse for an unrecognized message type byte");
            errors = errors + 1;
        end else $display("PASS [T8a]: unknown_type correctly pulsed for an unrecognized type byte");

        drive_byte(8'h44,0); drive_byte(8'h00,0); drive_byte(8'h01,0);
        drive_byte(8'h00,0); drive_byte(8'h05,0);
        drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h05,0);
        drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'h00,0); drive_byte(8'hAB,0); drive_byte(8'hCD,1);
        wait_msg_valid;
        if (!msg_valid || msg_type !== "D" || order_ref_number !== 64'h000000000000ABCD) begin
            $display("FAIL [T8b]: fresh packet after an unknown-type packet did not decode correctly - resync failed (type=%c ref=%h)",
                       msg_type, order_ref_number);
            errors = errors + 1;
        end else $display("PASS [T8b]: a fresh packet after an unknown-type message decoded correctly - payload_last resync works");

        if (errors == 0) $display("\n=== ALL TESTS PASSED ===");
        else $display("\n=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end

    initial begin
        #50000;
        $display("TIMEOUT");
        $finish;
    end

endmodule