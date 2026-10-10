`timescale 1ns/1ps

module rx_frame_cdc_tb;

    // Two genuinely asynchronous clocks, matching the real system
    // (25MHz phy_rx_clk, 100MHz sys_clk).
    reg phy_rx_clk = 0;
    reg sys_clk    = 0;
    always #20 phy_rx_clk = ~phy_rx_clk;  // 40ns period = 25MHz
    always #5  sys_clk    = ~sys_clk;     // 10ns period = 100MHz

    reg        phy_rx_rst = 1;
    reg        sys_rst    = 1;
    reg  [7:0] phy_rx_data = 0;
    reg        phy_rx_data_valid = 0;
    reg        phy_rx_frame_start = 0;
    reg        phy_rx_frame_end   = 0;

    wire [7:0] sys_rx_data;
    wire       sys_rx_data_valid;
    wire       sys_rx_frame_start;
    wire       sys_rx_frame_end;
    wire       sys_rx_overflow;

    rx_frame_cdc dut (
        .phy_rx_clk(phy_rx_clk), .phy_rx_rst(phy_rx_rst),
        .phy_rx_data(phy_rx_data), .phy_rx_data_valid(phy_rx_data_valid),
        .phy_rx_frame_start(phy_rx_frame_start), .phy_rx_frame_end(phy_rx_frame_end),

        .sys_clk(sys_clk), .sys_rst(sys_rst),
        .sys_rx_data(sys_rx_data), .sys_rx_data_valid(sys_rx_data_valid),
        .sys_rx_frame_start(sys_rx_frame_start), .sys_rx_frame_end(sys_rx_frame_end),
        .sys_rx_overflow(sys_rx_overflow)
    );

    // ---------------- capture on the read side ----------------
    reg [7:0] cap_data  [0:1023];
    reg       cap_start [0:1023];
    reg       cap_end   [0:1023];
    integer   cap_idx = 0;

    always @(posedge sys_clk) begin
        if (sys_rx_data_valid) begin
            cap_data[cap_idx]  = sys_rx_data;
            cap_start[cap_idx] = sys_rx_frame_start;
            cap_end[cap_idx]   = sys_rx_frame_end;
            cap_idx = cap_idx + 1;
        end
    end

    // ---------------- drive helper: write one byte on phy_rx_clk ----------------
    task write_byte(input [7:0] data, input is_start, input is_end);
        begin
            @(negedge phy_rx_clk);
            phy_rx_data         = data;
            phy_rx_data_valid   = 1;
            phy_rx_frame_start  = is_start;
            phy_rx_frame_end    = is_end;
            @(negedge phy_rx_clk);
            phy_rx_data_valid  = 0;
            phy_rx_frame_start = 0;
            phy_rx_frame_end   = 0;
        end
    endtask

    integer errors = 0;

    task check(input [31:0] idx, input [7:0] exp_data, input exp_start, input exp_end, input [255:0] label);
        begin
            if (cap_data[idx] !== exp_data || cap_start[idx] !== exp_start || cap_end[idx] !== exp_end) begin
                $display("FAIL [%s] idx=%0d: got data=%02x start=%0d end=%0d, expected data=%02x start=%0d end=%0d",
                          label, idx, cap_data[idx], cap_start[idx], cap_end[idx], exp_data, exp_start, exp_end);
                errors = errors + 1;
            end else begin
                $display("PASS [%s] idx=%0d: data=%02x start=%0d end=%0d", label, idx, cap_data[idx], cap_start[idx], cap_end[idx]);
            end
        end
    endtask

    integer base;

    initial begin
        // ---- reset ----
        phy_rx_rst = 1; sys_rst = 1;
        repeat (5) @(negedge phy_rx_clk);
        phy_rx_rst = 0; sys_rst = 0;
        repeat (5) @(negedge phy_rx_clk);

        // ---- Test 1: single-byte frame (frame_start AND frame_end on the same byte) ----
        base = cap_idx;
        write_byte(8'hAA, 1, 1);
        repeat (20) @(negedge sys_clk);
        check(base+0, 8'hAA, 1, 1, "T1 single-byte frame");

        // ---- Test 2: normal multi-byte frame ----
        base = cap_idx;
        write_byte(8'h11, 1, 0);
        write_byte(8'h22, 0, 0);
        write_byte(8'h33, 0, 0);
        write_byte(8'h44, 0, 1);
        repeat (20) @(negedge sys_clk);
        check(base+0, 8'h11, 1, 0, "T2 byte0 (start)");
        check(base+1, 8'h22, 0, 0, "T2 byte1");
        check(base+2, 8'h33, 0, 0, "T2 byte2");
        check(base+3, 8'h44, 0, 1, "T2 byte3 (end)");

        // ---- Test 3: back-to-back frames, no gap, tags must not bleed across ----
        base = cap_idx;
        write_byte(8'hA1, 1, 0);
        write_byte(8'hA2, 0, 1);   // end of frame A
        write_byte(8'hB1, 1, 0);   // start of frame B, immediately next
        write_byte(8'hB2, 0, 0);
        write_byte(8'hB3, 0, 1);
        repeat (20) @(negedge sys_clk);
        check(base+0, 8'hA1, 1, 0, "T3 frameA byte0");
        check(base+1, 8'hA2, 0, 1, "T3 frameA byte1 (end)");
        check(base+2, 8'hB1, 1, 0, "T3 frameB byte0 (start)");
        check(base+3, 8'hB2, 0, 0, "T3 frameB byte1");
        check(base+4, 8'hB3, 0, 1, "T3 frameB byte2 (end)");

        // ---- Test 4: overflow detection ----
        // Hold sys_rst asserted so the read side never drains, then flood
        // the write side past the FIFO's depth (2^8 = 256 entries).
        sys_rst = 1;
        repeat (300) begin
            @(negedge phy_rx_clk);
            phy_rx_data = 8'hFF;
            phy_rx_data_valid = 1;
        end
        @(negedge phy_rx_clk);
        phy_rx_data_valid = 0;
        if (sys_rx_overflow !== 1) begin
            $display("FAIL [T4 overflow]: sys_rx_overflow did not assert after flooding past FIFO depth");
            errors = errors + 1;
        end else begin
            $display("PASS [T4 overflow]: sys_rx_overflow correctly asserted");
        end
        sys_rst = 0;
        repeat (10) @(negedge phy_rx_clk);

        // ---- summary ----
        if (errors == 0) $display("\n=== ALL TESTS PASSED ===");
        else $display("\n=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end

    initial begin
        #20000;
        $display("TIMEOUT - simulation did not finish in time");
        $finish;
    end

endmodule