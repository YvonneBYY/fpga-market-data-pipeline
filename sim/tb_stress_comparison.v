`timescale 1ns/1ps
// Side-by-side capacity stress test: drives the IDENTICAL synthetic event
// stream into the CAM-based price_level_book (LEVEL_DEPTH=32, this
// project's current hardware configuration) and the BRAM-based
// price_level_book_bram (ADDR_WIDTH=10), and counts how many distinct new
// price levels each one actually tracks vs. silently drops once it runs
// out of capacity.
module tb_stress_comparison;

    reg clk = 0;
    reg rst;
    reg event_valid;
    reg [2:0] event_type;
    reg event_side;
    reg signed [32:0] event_shares_delta;
    reg [31:0] event_price;

    wire cam_level_event_valid, cam_level_side, cam_level_removed;
    wire [31:0] cam_level_price, cam_level_total_shares;

    wire bram_level_event_valid, bram_level_side, bram_level_removed;
    wire [31:0] bram_level_price, bram_level_total_shares;

    price_level_book #(.LEVEL_DEPTH(32)) dut_cam (
        .clk(clk), .rst(rst),
        .event_valid(event_valid), .event_type(event_type),
        .event_side(event_side), .event_shares_delta(event_shares_delta),
        .event_price(event_price),
        .level_event_valid(cam_level_event_valid), .level_side(cam_level_side),
        .level_price(cam_level_price), .level_total_shares(cam_level_total_shares),
        .level_removed(cam_level_removed)
    );

    price_level_book_bram #(.ADDR_WIDTH(10), .TICK_UNITS(100), .FIFO_DEPTH_LOG2(2)) dut_bram (
        .clk(clk), .rst(rst),
        .event_valid(event_valid), .event_type(event_type),
        .event_side(event_side), .event_shares_delta(event_shares_delta),
        .event_price(event_price),
        .level_event_valid(bram_level_event_valid), .level_side(bram_level_side),
        .level_price(bram_level_price), .level_total_shares(bram_level_total_shares),
        .level_removed(bram_level_removed)
    );

    always #5 clk = ~clk;

    integer cam_accepted = 0;
    integer bram_accepted = 0;
    always @(posedge clk) begin
        if (cam_level_event_valid && !cam_level_removed)  cam_accepted  = cam_accepted + 1;
        if (bram_level_event_valid && !bram_level_removed) bram_accepted = bram_accepted + 1;
    end

    localparam NUM_LEVELS = 50;     // more than the CAM's 32-entry capacity
    localparam BASE_PRICE = 32'd200000;
    localparam STEP       = 32'd100; // 1 cent apart -> well inside BRAM's collision-free window

    integer i;

    task send_event(input s, input signed [32:0] d, input [31:0] p);
        begin
            @(negedge clk);
            event_valid = 1'b1; event_type = 3'd0;
            event_side = s; event_shares_delta = d; event_price = p;
            @(negedge clk);
            event_valid = 1'b0;
        end
    endtask

    initial begin
        rst = 1; event_valid = 0; event_type = 0; event_side = 1'b1;
        event_shares_delta = 0; event_price = 0;
        repeat (3) @(posedge clk);
        rst = 0;
        repeat (1040) @(posedge clk);  // let the BRAM version's reset sweep finish (ADDR_WIDTH=10 -> 1024 entries)

        $display("Driving %0d distinct new price levels (1 cent apart, well within a single", NUM_LEVELS);
        $display("BRAM address window) into both architectures...\n");

        for (i = 0; i < NUM_LEVELS; i = i + 1) begin
            send_event(1'b1, 33'sd10, BASE_PRICE + i * STEP);
        end

        repeat (40) @(posedge clk);  // let both pipelines fully drain

        $display("CAM  (price_level_book.v,      LEVEL_DEPTH=32): %0d / %0d levels accepted (%0d dropped)",
                  cam_accepted, NUM_LEVELS, NUM_LEVELS - cam_accepted);
        $display("BRAM (price_level_book_bram.v, ADDR_WIDTH=10):  %0d / %0d levels accepted (%0d dropped)",
                  bram_accepted, NUM_LEVELS, NUM_LEVELS - bram_accepted);

        // --------------------------------------------------------------
        // Where is the BRAM version's OWN ceiling? It isn't infinite,
        // just 2**ADDR_WIDTH = 1024 instead of 32. Reset and push exactly
        // that many distinct, collision-free levels, then one more.
        // --------------------------------------------------------------
        rst = 1; @(posedge clk); @(posedge clk); rst = 0; @(posedge clk);
        cam_accepted = 0; bram_accepted = 0;

        $display("\nDriving 1025 distinct new price levels into the BRAM version alone");
        $display("(2**ADDR_WIDTH = 1024 -- one more than its own real capacity)...\n");

        for (i = 0; i < 1025; i = i + 1) begin
            send_event(1'b1, 33'sd10, BASE_PRICE + i * STEP);
        end
        repeat (40) @(posedge clk);

        $display("BRAM (ADDR_WIDTH=10, capacity 1024): %0d / 1025 levels accepted (%0d dropped)",
                  bram_accepted, 1025 - bram_accepted);

        // --------------------------------------------------------------
        // Real address collision at the deployed scale (ADDR_WIDTH=10):
        // two prices exactly 1024 * TICK_UNITS apart alias to the same slot.
        // --------------------------------------------------------------
        rst = 1; @(posedge clk); @(posedge clk); rst = 0; @(posedge clk);
        bram_accepted = 0;

        $display("\nReal collision at ADDR_WIDTH=10 scale: two prices 1024*TICK_UNITS apart...\n");
        send_event(1'b1, 33'sd77, 32'd500000);            // creates a level
        send_event(1'b1, 33'sd99, 32'd500000 + 1024*100); // aliases to the same slot, different tag
        repeat (10) @(posedge clk);
        send_event(1'b1, -33'sd20, 32'd500000);           // reduce the original -- still correct if not corrupted

        repeat (20) @(posedge clk);
        $display("Final accepted-event count for this sequence: %0d (expect 2: the original Add and the later reduce;",
                  bram_accepted);
        $display("the colliding Add at the aliased price should NOT have produced a 3rd event)");

        $finish;
    end

endmodule