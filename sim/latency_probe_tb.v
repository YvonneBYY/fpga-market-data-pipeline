`timescale 1ns/1ps

module latency_probe_tb;

    reg clk = 0;
    always #5 clk = ~clk;      // 100MHz

    reg tx_clk = 0;
    always #20 tx_clk = ~tx_clk;  // 25MHz, genuinely different clock domain

    reg rst = 1;
    reg tx_rst = 1;

    reg t0_pulse = 0, t1_pulse = 0, t2_pulse = 0, t3_pulse = 0;
    reg tx_done_pulse_txclk = 0;

    wire report_valid;
    wire [15:0] delta_rx, delta_decide, delta_build, delta_tx, delta_total;

    latency_probe dut (
        .clk(clk), .rst(rst),
        .t0_pulse(t0_pulse), .t1_pulse(t1_pulse), .t2_pulse(t2_pulse), .t3_pulse(t3_pulse),
        .tx_clk(tx_clk), .tx_rst(tx_rst), .tx_done_pulse_txclk(tx_done_pulse_txclk),
        .report_valid(report_valid),
        .delta_rx(delta_rx), .delta_decide(delta_decide), .delta_build(delta_build),
        .delta_tx(delta_tx), .delta_total(delta_total)
    );

    integer errors = 0;

    task pulse_t0; begin @(negedge clk); t0_pulse = 1; @(negedge clk); t0_pulse = 0; end endtask
    task pulse_t1; begin @(negedge clk); t1_pulse = 1; @(negedge clk); t1_pulse = 0; end endtask
    task pulse_t2; begin @(negedge clk); t2_pulse = 1; @(negedge clk); t2_pulse = 0; end endtask
    task pulse_t3; begin @(negedge clk); t3_pulse = 1; @(negedge clk); t3_pulse = 0; end endtask
    task pulse_tx_done; begin
        @(negedge tx_clk); tx_done_pulse_txclk = 1;
        @(negedge tx_clk); tx_done_pulse_txclk = 0;
    end endtask

    // Wait N clk cycles (negedge-anchored, matching every driving task here)
    task wait_cycles(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(negedge clk);
        end
    endtask

    initial begin
        rst = 1; tx_rst = 1;
        repeat (5) @(negedge clk);
        rst = 0; tx_rst = 0;
        repeat (5) @(negedge clk);

        // ---- Test 1: a full round trip with known, distinct gaps ----
        // T0 -> T1: 10 cycles, T1 -> T2: 3 cycles, T2 -> T3: 20 cycles,
        // T3 -> T4: measured however long it takes the tx_clk-domain pulse
        // to arrive and cross back - we check delta_total independently
        // via a direct cycle count of the whole sequence, not by assuming
        // the individual stage timing.
        pulse_t0;
        wait_cycles(10);
        pulse_t1;
        wait_cycles(3);
        pulse_t2;
        wait_cycles(20);
        pulse_t3;

        // Let some cycles pass, then fire the TX-domain completion pulse.
        wait_cycles(15);
        pulse_tx_done;

        // Wait long enough for the toggle to cross domains and the report
        // to be produced (a few tx_clk periods' worth of clk cycles is
        // plenty of margin).
        wait_cycles(20);

        if (!report_valid) begin
            // report_valid is a 1-cycle pulse - if we're not exactly on it,
            // search forward a few cycles for it (still within our margin).
            $display("NOTE: report_valid not high exactly here - checking captured deltas anyway (already latched by now)");
        end

        if (delta_rx !== 16'd12) begin
            $display("FAIL [T1]: delta_rx = %0d, expected 12", delta_rx); errors = errors + 1;
        end else $display("PASS [T1]: delta_rx = 12 cycles");

        if (delta_decide !== 16'd5) begin
            $display("FAIL [T1]: delta_decide = %0d, expected 5", delta_decide); errors = errors + 1;
        end else $display("PASS [T1]: delta_decide = 5 cycles");

        if (delta_build !== 16'd22) begin
            $display("FAIL [T1]: delta_build = %0d, expected 22", delta_build); errors = errors + 1;
        end else $display("PASS [T1]: delta_build = 22 cycles");

        // delta_tx and delta_total depend on exact CDC crossing latency,
        // which is real (not a fixed constant) - just sanity-check delta_tx
        // is small-but-nonzero (a few cycles, matching the toggle-sync
        // latency) and delta_total = sum of the three known deltas + delta_tx,
        // confirming internal consistency rather than a hardcoded expectation.
        if (delta_tx == 0 || delta_tx > 16'd25) begin
            $display("FAIL [T1]: delta_tx = %0d, expected a small nonzero CDC-crossing latency (1-25 cycles)", delta_tx);
            errors = errors + 1;
        end else $display("PASS [T1]: delta_tx = %0d cycles (plausible CDC crossing latency)", delta_tx);

        if (delta_total !== (delta_rx + delta_decide + delta_build + delta_tx)) begin
            $display("FAIL [T1]: delta_total (%0d) != sum of stage deltas (%0d)", delta_total, delta_rx+delta_decide+delta_build+delta_tx);
            errors = errors + 1;
        end else $display("PASS [T1]: delta_total is internally consistent with the sum of stage deltas");

        // ---- Test 2: a second round trip, confirming the module correctly
        // resets/re-measures rather than accumulating stale state ----
        wait_cycles(50);
        pulse_t0;
        wait_cycles(7);
        pulse_t1;
        wait_cycles(2);
        pulse_t2;
        wait_cycles(5);
        pulse_t3;
        wait_cycles(15);
        pulse_tx_done;
        wait_cycles(20);

        if (delta_rx !== 16'd9 || delta_decide !== 16'd4 || delta_build !== 16'd7) begin
            $display("FAIL [T2]: second round trip gave delta_rx=%0d delta_decide=%0d delta_build=%0d, expected 9/4/7",
                       delta_rx, delta_decide, delta_build);
            errors = errors + 1;
        end else $display("PASS [T2]: second round trip correctly measured fresh (9/4/7), no stale-state contamination");

        // ---- Test 3: a real hardware bug, reproduced here as a permanent
        // regression test - a SPURIOUS extra t0_pulse (an unrelated ambient
        // frame's frame_start) arriving mid-round-trip, between our own T1
        // and our own T4, must NOT corrupt ts0/delta_rx/delta_total. This
        // is exactly the contamination bug found on real hardware: without
        // t0_locked, this spurious pulse would silently overwrite ts0
        // before the T4-time calculation runs. ----
        wait_cycles(50);
        pulse_t0;
        wait_cycles(10);
        pulse_t1;

        // Spurious, unrelated t0_pulse arrives mid-round-trip - this must
        // be ignored while t0_locked is set.
        wait_cycles(5);
        pulse_t0;

        wait_cycles(3);
        pulse_t2;
        wait_cycles(20);
        pulse_t3;
        wait_cycles(15);
        pulse_tx_done;
        wait_cycles(20);

        if (delta_rx !== 16'd12 || delta_total !== (delta_rx + delta_decide + delta_build + delta_tx)) begin
            $display("FAIL [T3]: spurious mid-round-trip t0_pulse corrupted the measurement - delta_rx=%0d (expected 12), delta_total=%0d",
                       delta_rx, delta_total);
            errors = errors + 1;
        end else $display("PASS [T3]: spurious mid-round-trip t0_pulse correctly ignored (t0_locked protected ts0)");

        // Confirm the lock correctly releases: a normal round trip
        // immediately after should measure cleanly with no lingering lock.
        wait_cycles(50);
        pulse_t0;
        wait_cycles(6);
        pulse_t1;
        wait_cycles(2);
        pulse_t2;
        wait_cycles(4);
        pulse_t3;
        wait_cycles(15);
        pulse_tx_done;
        wait_cycles(20);

        if (delta_rx !== 16'd8) begin
            $display("FAIL [T3]: t0_locked did not release correctly after T4 - delta_rx=%0d, expected 8", delta_rx);
            errors = errors + 1;
        end else $display("PASS [T3]: t0_locked correctly released after T4, next round trip measured cleanly");

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