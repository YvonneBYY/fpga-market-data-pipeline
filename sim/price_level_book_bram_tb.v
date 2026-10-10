`timescale 1ns/1ps

module price_level_book_bram_tb;

    reg clk = 0;
    reg rst;
    reg event_valid;
    reg [2:0] event_type;
    reg event_side;
    reg signed [32:0] event_shares_delta;
    reg [31:0] event_price;

    wire level_event_valid;
    wire level_side;
    wire [31:0] level_price;
    wire [31:0] level_total_shares;
    wire level_removed;

    integer pass_count = 0;
    integer fail_count = 0;

    price_level_book_bram #(
        .ADDR_WIDTH(4),        // 16 entries/side -> window = 16*100 = 1600 price units
        .TICK_UNITS(100),
        .FIFO_DEPTH_LOG2(2)    // 4-deep
    ) dut (
        .clk(clk), .rst(rst),
        .event_valid(event_valid), .event_type(event_type),
        .event_side(event_side), .event_shares_delta(event_shares_delta),
        .event_price(event_price),
        .level_event_valid(level_event_valid), .level_side(level_side),
        .level_price(level_price), .level_total_shares(level_total_shares),
        .level_removed(level_removed)
    );

    always #5 clk = ~clk;

    // Drive one event for exactly one cycle
    task send_event(input s, input signed [32:0] d, input [31:0] p);
        begin
            @(negedge clk);
            event_valid = 1'b1; event_type = 3'd0;
            event_side = s; event_shares_delta = d; event_price = p;
            @(negedge clk);
            event_valid = 1'b0;
        end
    endtask

    // Wait (with timeout) for the next level_event_valid pulse and latch its fields
    reg        seen_side;
    reg [31:0] seen_price;
    reg [31:0] seen_shares;
    reg        seen_removed;
    reg        timed_out;

    task wait_for_event(input integer max_cycles);
        integer c;
        begin
            timed_out = 1'b1;
            for (c = 0; c < max_cycles; c = c + 1) begin
                @(posedge clk);
                if (level_event_valid) begin
                    seen_side    = level_side;
                    seen_price   = level_price;
                    seen_shares  = level_total_shares;
                    seen_removed = level_removed;
                    timed_out    = 1'b0;
                    c = max_cycles; // break
                end
            end
        end
    endtask

    task check(input cond, input [511:0] name);
        begin
            if (cond) begin
                pass_count = pass_count + 1;
                $display("PASS: %0s", name);
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s", name);
            end
        end
    endtask

    // Continuous background capture of every level_event_valid pulse, so a burst test can't
    // race against sequential wait_for_event polling.
    reg [31:0] capture_shares [0:63];
    integer capture_count = 0;
    integer burst_start_idx;
    always @(posedge clk) begin
        if (level_event_valid) begin
            capture_shares[capture_count] <= level_total_shares;
            capture_count <= capture_count + 1;
        end
    end

    localparam CP_A = 32'd10000;   // addr (10000/100)%16 = 4
    localparam CP_B = 32'd11600;   // addr (11600/100)%16 = 4  -> collides with CP_A
    localparam P1   = 32'd20000;   // addr (20000/100)%16 = 8
    localparam P2   = 32'd30000;   // addr (30000/100)%16 = 12

    initial begin
        rst = 1; event_valid = 0; event_type = 0; event_side = 0;
        event_shares_delta = 0; event_price = 0;
        repeat (3) @(posedge clk);
        rst = 0;
        repeat (20) @(posedge clk);  // let the reset sweep finish (ADDR_WIDTH=4 -> 16-entry sweep)

        // ---------------- Test 1: collision handling ----------------
        send_event(1'b1, 33'sd50, CP_A);
        wait_for_event(10);
        check(!timed_out && seen_side==1'b1 && seen_price==CP_A && seen_shares==32'd50 && !seen_removed,
              "T1a: new level created at CP_A, 50 shares");

        send_event(1'b1, 33'sd80, CP_B); // aliases to same address as CP_A, different tag -> should be DROPPED
        wait_for_event(10);
        check(timed_out, "T1b: colliding Add at CP_B produces no level event (dropped)");

        send_event(1'b1, -33'sd10, CP_A); // reduce CP_A; if collision had corrupted it this would misbehave
        wait_for_event(10);
        check(!timed_out && seen_price==CP_A && seen_shares==32'd40 && !seen_removed,
              "T1c: CP_A still correct (40) after dropped collision at CP_B");

        // ---------------- Test 2: add / aggregate / reduce / remove lifecycle ----------------
        send_event(1'b1, 33'sd100, P1);
        wait_for_event(10);
        check(!timed_out && seen_price==P1 && seen_shares==32'd100 && !seen_removed, "T2a: Add 100 @ P1");

        send_event(1'b1, 33'sd50, P1);
        wait_for_event(10);
        check(!timed_out && seen_shares==32'd150, "T2b: second Add aggregates to 150");

        send_event(1'b1, -33'sd30, P1);
        wait_for_event(10);
        check(!timed_out && seen_shares==32'd120 && !seen_removed, "T2c: partial reduce to 120");

        send_event(1'b1, -33'sd120, P1);
        wait_for_event(10);
        check(!timed_out && seen_removed && seen_shares==32'd0, "T2d: full reduce removes level");

        // ---------------- Test 3: independent side (sell table separate from bid table) ----------------
        send_event(1'b0, 33'sd200, P1);
        wait_for_event(10);
        check(!timed_out && seen_side==1'b0 && seen_price==P1 && seen_shares==32'd200 && !seen_removed,
              "T3: Sell @ P1 tracked independently of (already-emptied) Buy @ P1");

        // ---------------- Test 4: independent price ----------------
        send_event(1'b1, 33'sd75, P2);
        wait_for_event(10);
        check(!timed_out && seen_side==1'b1 && seen_price==P2 && seen_shares==32'd75 && !seen_removed,
              "T4: independent price level P2 unaffected by P1 activity");

        // ---------------- Test 5: burst of 4 back-to-back events (exactly fills the FIFO) ----------------
        // Capture every pulse continuously from here on, since the pipeline starts draining
        // the queue as soon as the first entry lands -- it doesn't wait for the whole burst
        // to finish arriving, so a pulse can occur while later events are still being pushed.
        @(negedge clk);  // let the previous test's capture_count update fully settle first
        burst_start_idx = capture_count;

        @(negedge clk);
        event_valid = 1'b1; event_type = 0; event_side = 1'b1; event_price = P2;
        event_shares_delta = 33'sd10; @(negedge clk);
        event_shares_delta = 33'sd10; @(negedge clk);
        event_shares_delta = 33'sd10; @(negedge clk);
        event_shares_delta = 33'sd10; @(negedge clk);
        event_valid = 1'b0;

        repeat (20) @(posedge clk);  // let the queue fully drain

        check((capture_count - burst_start_idx) == 4, "T5: all 4 burst events produced a level event (none dropped)");
        check(capture_shares[burst_start_idx+0] == 32'd85,  "T5a: burst event 1/4 -> 85");
        check(capture_shares[burst_start_idx+1] == 32'd95,  "T5b: burst event 2/4 -> 95");
        check(capture_shares[burst_start_idx+2] == 32'd105, "T5c: burst event 3/4 -> 105");
        check(capture_shares[burst_start_idx+3] == 32'd115, "T5d: burst event 4/4 -> 115");

        $display("\n%0d passed, %0d failed", pass_count, fail_count);
        $finish;
    end

endmodule