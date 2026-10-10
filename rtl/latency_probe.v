//// Latency probe with TX-path split.
////
//// Free-running cycle counter (clk100mhz, 10 ns/cycle) with timestamps:
////   T0 = sys_rx_frame_start
////   T1 = echo_rx_matched_done
////   T2 = echo_tx_start
////   T3 = udp_tx_req
////   TS = UDP-specific MAC start, synchronized from eth_tx_clk
////   T4 = UDP-specific MAC TX completion, synchronized from eth_tx_clk
////
//// Reported deltas:
////   delta_rx       = T1 - T0
////   delta_decide   = T2 - T1
////   delta_build    = T3 - T2
////   delta_tx       = T4 - T3       (complete TX contribution)
////   delta_tx_queue = TS - T3       (builder/queue/arbiter/CDC/start delay)
////   delta_tx_wire  = T4 - TS       (MAC start through MAC completion)
////   delta_total    = T4 - T0
////
//// Both TX-domain events use identical toggle synchronizers. Therefore
//// delta_tx_queue + delta_tx_wire equals delta_tx in the clk100mhz domain,
//// apart from saturation. The absolute split includes CDC observation delay,
//// but that delay is only a few 10 ns cycles and is negligible relative to
//// the microsecond-scale TX stages being characterized.

//module latency_probe (
//    input  wire clk,
//    input  wire rst,

//    input  wire t0_pulse,
//    input  wire t1_pulse,
//    input  wire t2_pulse,
//    input  wire t3_pulse,

//    // TX-domain event inputs.
//    input  wire tx_clk,
//    input  wire tx_rst,
//    input  wire tx_start_pulse_txclk,
//    input  wire tx_done_pulse_txclk,

//    output reg         report_valid,
//    output reg [15:0]  delta_rx,
//    output reg [15:0]  delta_decide,
//    output reg [15:0]  delta_build,
//    output reg [15:0]  delta_tx,
//    output reg [15:0]  delta_tx_queue,
//    output reg [15:0]  delta_tx_wire,
//    output reg [15:0]  delta_total
//);

//    // -------------------------------------------------------------------------
//    // Free-running 100 MHz timestamp counter
//    // -------------------------------------------------------------------------
//    reg [31:0] cycle_counter;

//    always @(posedge clk) begin
//        if (rst)
//            cycle_counter <= 32'd0;
//        else
//            cycle_counter <= cycle_counter + 1'b1;
//    end


//    // -------------------------------------------------------------------------
//    // Cross UDP-specific MAC START into clk domain using a toggle.
//    // -------------------------------------------------------------------------
//    reg tx_start_toggle_txclk = 1'b0;

//    always @(posedge tx_clk) begin
//        if (tx_rst)
//            tx_start_toggle_txclk <= 1'b0;
//        else if (tx_start_pulse_txclk)
//            tx_start_toggle_txclk <= ~tx_start_toggle_txclk;
//    end

//    reg [1:0] tx_start_toggle_sync;

//    always @(posedge clk) begin
//        if (rst)
//            tx_start_toggle_sync <= 2'b00;
//        else
//            tx_start_toggle_sync <= {
//                tx_start_toggle_sync[0],
//                tx_start_toggle_txclk
//            };
//    end

//    wire tx_start_sys_pulse =
//        (tx_start_toggle_sync[1] != tx_start_toggle_sync[0]);


//    // -------------------------------------------------------------------------
//    // Cross UDP-specific MAC DONE into clk domain using the same technique.
//    // -------------------------------------------------------------------------
//    reg tx_done_toggle_txclk = 1'b0;

//    always @(posedge tx_clk) begin
//        if (tx_rst)
//            tx_done_toggle_txclk <= 1'b0;
//        else if (tx_done_pulse_txclk)
//            tx_done_toggle_txclk <= ~tx_done_toggle_txclk;
//    end

//    reg [1:0] tx_done_toggle_sync;

//    always @(posedge clk) begin
//        if (rst)
//            tx_done_toggle_sync <= 2'b00;
//        else
//            tx_done_toggle_sync <= {
//                tx_done_toggle_sync[0],
//                tx_done_toggle_txclk
//            };
//    end

//    wire t4_pulse =
//        (tx_done_toggle_sync[1] != tx_done_toggle_sync[0]);


//    // -------------------------------------------------------------------------
//    // Timestamp capture
//    // -------------------------------------------------------------------------
//    reg [31:0] ts0;
//    reg [31:0] ts1;
//    reg [31:0] ts2;
//    reg [31:0] ts3;
//    reg [31:0] ts_mac_start;

//    // ts0 must be protected from unrelated background Ethernet frame_start
//    // events after this request has been identified.
//    reg t0_locked;

//    // Track whether a MAC-start timestamp has been captured for the current
//    // request. This is mainly a sanity guard; normal traffic should always
//    // produce START before DONE.
//    reg tx_start_seen;

//    always @(posedge clk) begin
//        report_valid <= 1'b0;

//        if (rst) begin
//            ts0          <= 32'd0;
//            ts1          <= 32'd0;
//            ts2          <= 32'd0;
//            ts3          <= 32'd0;
//            ts_mac_start <= 32'd0;

//            delta_rx       <= 16'd0;
//            delta_decide   <= 16'd0;
//            delta_build    <= 16'd0;
//            delta_tx       <= 16'd0;
//            delta_tx_queue <= 16'd0;
//            delta_tx_wire  <= 16'd0;
//            delta_total    <= 16'd0;

//            t0_locked    <= 1'b0;
//            tx_start_seen <= 1'b0;
//        end else begin

//            if (t0_pulse && !t0_locked)
//                ts0 <= cycle_counter;

//            if (t1_pulse) begin
//                ts1       <= cycle_counter;
//                t0_locked <= 1'b1;
//            end

//            if (t2_pulse)
//                ts2 <= cycle_counter;

//            if (t3_pulse) begin
//                ts3           <= cycle_counter;
//                tx_start_seen <= 1'b0;
//            end

//            if (tx_start_sys_pulse) begin
//                ts_mac_start <= cycle_counter;
//                tx_start_seen <= 1'b1;
//            end

//            if (t4_pulse) begin
//                delta_rx <=
//                    ((ts1 - ts0) > 32'h0000_FFFF)
//                    ? 16'hFFFF
//                    : (ts1 - ts0);

//                delta_decide <=
//                    ((ts2 - ts1) > 32'h0000_FFFF)
//                    ? 16'hFFFF
//                    : (ts2 - ts1);

//                delta_build <=
//                    ((ts3 - ts2) > 32'h0000_FFFF)
//                    ? 16'hFFFF
//                    : (ts3 - ts2);

//                delta_tx <=
//                    ((cycle_counter - ts3) > 32'h0000_FFFF)
//                    ? 16'hFFFF
//                    : (cycle_counter - ts3);

//                // If DONE somehow arrives without the corresponding START,
//                // saturate both split fields so the bad sample is obvious.
//                if (tx_start_seen) begin
//                    delta_tx_queue <=
//                        ((ts_mac_start - ts3) > 32'h0000_FFFF)
//                        ? 16'hFFFF
//                        : (ts_mac_start - ts3);

//                    delta_tx_wire <=
//                        ((cycle_counter - ts_mac_start) > 32'h0000_FFFF)
//                        ? 16'hFFFF
//                        : (cycle_counter - ts_mac_start);
//                end else begin
//                    delta_tx_queue <= 16'hFFFF;
//                    delta_tx_wire  <= 16'hFFFF;
//                end

//                delta_total <=
//                    ((cycle_counter - ts0) > 32'h0000_FFFF)
//                    ? 16'hFFFF
//                    : (cycle_counter - ts0);

//                report_valid  <= 1'b1;
//                t0_locked     <= 1'b0;
//                tx_start_seen <= 1'b0;
//            end
//        end
//    end

//endmodule
// Latency probe using true Ethernet frame completion.
//
// 100 MHz timestamps:
//   T0 = sys_rx_frame_start
//   T1 = echo_rx_matched_done
//   T2 = echo_tx_start
//   T3 = udp_tx_req
//   TS = UDP-specific MAC start
//   T4 = UDP-specific MAC frame_done
//
// frame_done occurs immediately after the final frame nibble completes.
// The Ethernet IFG is still enforced by the MAC but is excluded from T4.
//
// Outputs:
//   delta_rx       = T1 - T0
//   delta_decide   = T2 - T1
//   delta_build    = T3 - T2
//   delta_tx       = T4 - T3
//   delta_tx_queue = TS - T3
//   delta_tx_frame = T4 - TS
//   delta_total    = T4 - T0

module latency_probe (
    input  wire clk,
    input  wire rst,

    input  wire t0_pulse,
    input  wire t1_pulse,
    input  wire t2_pulse,
    input  wire t3_pulse,

    input  wire tx_clk,
    input  wire tx_rst,
    input  wire tx_start_pulse_txclk,
    input  wire tx_frame_done_pulse_txclk,

    output reg         report_valid,
    output reg [15:0]  delta_rx,
    output reg [15:0]  delta_decide,
    output reg [15:0]  delta_build,
    output reg [15:0]  delta_tx,
    output reg [15:0]  delta_tx_queue,
    output reg [15:0]  delta_tx_frame,
    output reg [15:0]  delta_total
);

    reg [31:0] cycle_counter;

    always @(posedge clk) begin
        if (rst)
            cycle_counter <= 32'd0;
        else
            cycle_counter <= cycle_counter + 1'b1;
    end

    // ---------------- MAC-start CDC ----------------
    reg tx_start_toggle_txclk = 1'b0;

    always @(posedge tx_clk) begin
        if (tx_rst)
            tx_start_toggle_txclk <= 1'b0;
        else if (tx_start_pulse_txclk)
            tx_start_toggle_txclk <= ~tx_start_toggle_txclk;
    end

    reg [1:0] tx_start_toggle_sync;

    always @(posedge clk) begin
        if (rst)
            tx_start_toggle_sync <= 2'b00;
        else
            tx_start_toggle_sync <= {
                tx_start_toggle_sync[0],
                tx_start_toggle_txclk
            };
    end

    wire tx_start_sys_pulse =
        (tx_start_toggle_sync[1] != tx_start_toggle_sync[0]);

    // ---------------- frame_done CDC ----------------
    reg tx_frame_done_toggle_txclk = 1'b0;

    always @(posedge tx_clk) begin
        if (tx_rst)
            tx_frame_done_toggle_txclk <= 1'b0;
        else if (tx_frame_done_pulse_txclk)
            tx_frame_done_toggle_txclk <= ~tx_frame_done_toggle_txclk;
    end

    reg [1:0] tx_frame_done_toggle_sync;

    always @(posedge clk) begin
        if (rst)
            tx_frame_done_toggle_sync <= 2'b00;
        else
            tx_frame_done_toggle_sync <= {
                tx_frame_done_toggle_sync[0],
                tx_frame_done_toggle_txclk
            };
    end

    wire t4_pulse =
        (tx_frame_done_toggle_sync[1] != tx_frame_done_toggle_sync[0]);

    // ---------------- Timestamps ----------------
    reg [31:0] ts0;
    reg [31:0] ts1;
    reg [31:0] ts2;
    reg [31:0] ts3;
    reg [31:0] ts_mac_start;

    reg t0_locked;
    reg tx_start_seen;

    always @(posedge clk) begin
        report_valid <= 1'b0;

        if (rst) begin
            ts0          <= 32'd0;
            ts1          <= 32'd0;
            ts2          <= 32'd0;
            ts3          <= 32'd0;
            ts_mac_start <= 32'd0;

            delta_rx       <= 16'd0;
            delta_decide   <= 16'd0;
            delta_build    <= 16'd0;
            delta_tx       <= 16'd0;
            delta_tx_queue <= 16'd0;
            delta_tx_frame <= 16'd0;
            delta_total    <= 16'd0;

            t0_locked     <= 1'b0;
            tx_start_seen <= 1'b0;
        end else begin

            if (t0_pulse && !t0_locked)
                ts0 <= cycle_counter;

            if (t1_pulse) begin
                ts1       <= cycle_counter;
                t0_locked <= 1'b1;
            end

            if (t2_pulse)
                ts2 <= cycle_counter;

            if (t3_pulse) begin
                ts3           <= cycle_counter;
                tx_start_seen <= 1'b0;
            end

            if (tx_start_sys_pulse) begin
                ts_mac_start <= cycle_counter;
                tx_start_seen <= 1'b1;
            end

            if (t4_pulse) begin
                delta_rx <=
                    ((ts1 - ts0) > 32'h0000_FFFF)
                    ? 16'hFFFF : (ts1 - ts0);

                delta_decide <=
                    ((ts2 - ts1) > 32'h0000_FFFF)
                    ? 16'hFFFF : (ts2 - ts1);

                delta_build <=
                    ((ts3 - ts2) > 32'h0000_FFFF)
                    ? 16'hFFFF : (ts3 - ts2);

                delta_tx <=
                    ((cycle_counter - ts3) > 32'h0000_FFFF)
                    ? 16'hFFFF : (cycle_counter - ts3);

                if (tx_start_seen) begin
                    delta_tx_queue <=
                        ((ts_mac_start - ts3) > 32'h0000_FFFF)
                        ? 16'hFFFF : (ts_mac_start - ts3);

                    delta_tx_frame <=
                        ((cycle_counter - ts_mac_start) > 32'h0000_FFFF)
                        ? 16'hFFFF : (cycle_counter - ts_mac_start);
                end else begin
                    delta_tx_queue <= 16'hFFFF;
                    delta_tx_frame <= 16'hFFFF;
                end

                delta_total <=
                    ((cycle_counter - ts0) > 32'h0000_FFFF)
                    ? 16'hFFFF : (cycle_counter - ts0);

                report_valid  <= 1'b1;
                t0_locked     <= 1'b0;
                tx_start_seen <= 1'b0;
            end
        end
    end

endmodule
