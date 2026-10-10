//// UDP echo responder glue.
////
//// Sits between ip_udp_rx_parser and ip_udp_tx_builder. Buffers a received
//// UDP packet's payload as it streams by, and once the packet is confirmed
//// complete and valid AND addressed to ECHO_PORT, triggers ip_udp_tx_builder
//// to send the exact same payload straight back to whoever sent it.
////
//// Reply addressing:
////   destination MAC  = sender's MAC
////   destination IP   = sender's IP
////   source UDP port  = ECHO_PORT
////   destination port = sender's original source port
////
//// Using ECHO_PORT as the reply source port makes the UDP exchange symmetric:
////
////   PC:<ephemeral>  -> FPGA:ECHO_PORT
////   PC:<ephemeral>  <- FPGA:ECHO_PORT
////
//// Filtering by destination port matters in practice: without it, this
//// module echoes every valid UDP packet it sees, including unrelated ambient
//// traffic. Only packets sent to ECHO_PORT are echoed.
////
//// This module is used as a hardware-testable request/reply path for the
//// Ethernet/IPv4/UDP pipeline.

//// UDP echo responder glue.
////
//// Sits between ip_udp_rx_parser and ip_udp_tx_builder.
////
//// The parser has already validated the IPv4/UDP packet before asserting
//// rx_payload_valid. This responder performs only the service-level filter:
//// it starts collecting a payload when the first valid payload byte is for
//// ECHO_PORT. Once that payload completes, RX_DONE itself means that a
//// matched echo request has completed.
////
//// IMPORTANT RELIABILITY CHANGE:
//// The previous version separately latched a port_matched register on the
//// first payload byte and later required:
////
////     (rx_state == RX_DONE) && port_matched
////
//// for rx_matched_done. The fine-grained RX counters showed that failed
//// requests reached a complete port-9000 payload but occasionally did not
//// produce rx_matched_done. This version removes that redundant remembered
//// port-match state. A packet can enter RX_COLLECT only if rx_dst_port equals
//// ECHO_PORT, so reaching RX_DONE inherently means "matched request complete".
////
//// Reply addressing:
////   destination MAC  = sender's MAC
////   destination IP   = sender's IP
////   source UDP port  = ECHO_PORT
////   destination port = sender's original source port
////
//// Exchange:
////   PC:<ephemeral>  -> FPGA:ECHO_PORT
////   PC:<ephemeral>  <- FPGA:ECHO_PORT

//module udp_echo_responder #(
//    parameter [15:0] ECHO_PORT = 16'd9000
//) (
//    input  wire        clk,
//    input  wire        rst,

//    // From ip_udp_rx_parser
//    input  wire [47:0] rx_src_mac,
//    input  wire [31:0] rx_src_ip,
//    input  wire [15:0] rx_src_port,
//    input  wire [15:0] rx_dst_port,
//    input  wire        rx_payload_valid,
//    input  wire [7:0]  rx_payload_data,
//    input  wire        rx_payload_last,

//    // To ip_udp_tx_builder
//    output wire        rx_matched_done,
//    output wire        tx_start,
//    output wire [47:0] tx_dest_mac,
//    output wire [31:0] tx_dest_ip,
//    output wire [15:0] tx_src_port,
//    output wire [15:0] tx_dst_port,
//    output wire [7:0]  tx_data,
//    output wire        tx_data_valid,
//    output wire        tx_last
//);

//    localparam MAX_PAYLOAD = 200;

//    reg [7:0] payload_buf [0:MAX_PAYLOAD-1];

//    reg [8:0] collect_idx;
//    reg [8:0] payload_len;

//    reg [47:0] latched_mac;
//    reg [31:0] latched_ip;
//    reg [15:0] latched_port;


//    // =========================================================================
//    // RX SIDE
//    //
//    // Only packets whose valid payload stream is addressed to ECHO_PORT are
//    // allowed to enter RX_COLLECT.
//    //
//    // Therefore:
//    //
//    //     RX_DONE == complete matched echo request
//    //
//    // No separate port_matched register is required.
//    // =========================================================================

//    localparam RX_IDLE    = 2'd0;
//    localparam RX_COLLECT = 2'd1;
//    localparam RX_DONE    = 2'd2;

//    reg [1:0] rx_state;

//    always @(posedge clk) begin
//        if (rst) begin
//            rx_state     <= RX_IDLE;
//            collect_idx  <= 9'd0;
//            payload_len  <= 9'd0;

//            latched_mac  <= 48'd0;
//            latched_ip   <= 32'd0;
//            latched_port <= 16'd0;
//        end else begin
//            case (rx_state)

//                // -------------------------------------------------------------
//                // Wait for the first payload byte of a valid UDP packet sent
//                // specifically to ECHO_PORT.
//                // -------------------------------------------------------------
//                RX_IDLE: begin
//                    collect_idx <= 9'd0;

//                    if (rx_payload_valid &&
//                        (rx_dst_port == ECHO_PORT)) begin

//                        // Latch the sender information once, on the first
//                        // payload byte. These values are used for the reply.
//                        latched_mac  <= rx_src_mac;
//                        latched_ip   <= rx_src_ip;
//                        latched_port <= rx_src_port;

//                        // First byte always goes into location zero.
//                        payload_buf[0] <= rx_payload_data;
//                        collect_idx    <= 9'd1;

//                        if (rx_payload_last)
//                            rx_state <= RX_DONE;
//                        else
//                            rx_state <= RX_COLLECT;
//                    end
//                end


//                // -------------------------------------------------------------
//                // Collect the remainder of the already-matched payload.
//                // -------------------------------------------------------------
//                RX_COLLECT: begin
//                    if (rx_payload_valid) begin

//                        // Preserve the behavior of the previous implementation:
//                        // store bytes while they fit in the local buffer.
//                        if (collect_idx < MAX_PAYLOAD)
//                            payload_buf[collect_idx] <= rx_payload_data;

//                        collect_idx <= collect_idx + 1'b1;

//                        if (rx_payload_last)
//                            rx_state <= RX_DONE;
//                    end
//                end


//                // -------------------------------------------------------------
//                // One-cycle matched-request-complete state.
//                //
//                // collect_idx is now the number of payload bytes received.
//                // RX_DONE itself is also exported as rx_matched_done.
//                // -------------------------------------------------------------
//                RX_DONE: begin
//                    payload_len <= collect_idx;
//                    rx_state    <= RX_IDLE;
//                end


//                default: begin
//                    rx_state <= RX_IDLE;
//                end

//            endcase
//        end
//    end


//    // =========================================================================
//    // TX SIDE
//    //
//    // Keep the existing one-cycle send_pending pipeline so the TX timing stays
//    // as close as possible to the previous measured design.
//    // =========================================================================

//    reg       send_pending;
//    reg [8:0] send_idx;

//    localparam TX_IDLE   = 2'd0;
//    localparam TX_START  = 2'd1;
//    localparam TX_STREAM = 2'd2;

//    reg [1:0] tx_state;

//    always @(posedge clk) begin
//        if (rst) begin
//            send_pending <= 1'b0;
//            send_idx     <= 9'd0;
//            tx_state     <= TX_IDLE;
//        end else begin

//            // RX_DONE can only occur for a packet that was accepted at
//            // ECHO_PORT, so no separate port-match condition is needed.
//            send_pending <= (rx_state == RX_DONE);

//            case (tx_state)

//                TX_IDLE: begin
//                    if (send_pending) begin
//                        send_idx <= 9'd0;
//                        tx_state <= TX_START;
//                    end
//                end


//                // One-cycle start pulse to ip_udp_tx_builder.
//                TX_START: begin
//                    tx_state <= TX_STREAM;
//                end


//                // Replay the buffered payload one byte per cycle.
//                TX_STREAM: begin
//                    if (send_idx == payload_len - 1'b1) begin
//                        tx_state <= TX_IDLE;
//                    end else begin
//                        send_idx <= send_idx + 1'b1;
//                    end
//                end


//                default: begin
//                    tx_state <= TX_IDLE;
//                end

//            endcase
//        end
//    end


//    // =========================================================================
//    // OUTPUTS
//    // =========================================================================

//    // One-cycle pulse: a complete request to ECHO_PORT has been received.
//    //
//    // This remains T1 for latency_probe.
//    assign rx_matched_done =
//        (rx_state == RX_DONE);


//    // One-cycle request to begin constructing the reply.
//    assign tx_start =
//        (tx_state == TX_START);


//    // Reply to the original sender.
//    assign tx_dest_mac = latched_mac;
//    assign tx_dest_ip  = latched_ip;

//    // Reply FROM the echo service port.
//    assign tx_src_port = ECHO_PORT;

//    // Reply TO the sender's original ephemeral source port.
//    assign tx_dst_port = latched_port;


//    // Buffered payload replay.
//    assign tx_data =
//        payload_buf[send_idx];

//    assign tx_data_valid =
//        (tx_state == TX_STREAM);

//    assign tx_last =
//        (tx_state == TX_STREAM) &&
//        (send_idx == payload_len - 1'b1);

//endmodule

// UDP echo responder glue.
//
// Sits between ip_udp_rx_parser and ip_udp_tx_builder.
//
// The parser has already validated the IPv4/UDP packet before asserting
// rx_payload_valid. This responder performs only the service-level filter:
// it starts collecting a payload when the first valid payload byte is for
// ECHO_PORT. Once that payload completes, RX_DONE itself means that a
// matched echo request has completed.
//
// IMPORTANT RELIABILITY CHANGE:
// The previous version separately latched a port_matched register on the
// first payload byte and later required:
//
//     (rx_state == RX_DONE) && port_matched
//
// for rx_matched_done. The fine-grained RX counters showed that failed
// requests reached a complete port-9000 payload but occasionally did not
// produce rx_matched_done. This version removes that redundant remembered
// port-match state. A packet can enter RX_COLLECT only if rx_dst_port equals
// ECHO_PORT, so reaching RX_DONE inherently means "matched request complete".
//
// Reply addressing:
//   destination MAC  = sender's MAC
//   destination IP   = sender's IP
//   source UDP port  = ECHO_PORT
//   destination port = sender's original source port
//
// Exchange:
//   PC:<ephemeral>  -> FPGA:ECHO_PORT
//   PC:<ephemeral>  <- FPGA:ECHO_PORT

module udp_echo_responder #(
    parameter [15:0] ECHO_PORT = 16'd9000
) (
    input  wire        clk,
    input  wire        rst,

    // From ip_udp_rx_parser
    input  wire [47:0] rx_src_mac,
    input  wire [31:0] rx_src_ip,
    input  wire [15:0] rx_src_port,
    input  wire [15:0] rx_dst_port,
    input  wire        rx_payload_valid,
    input  wire [7:0]  rx_payload_data,
    input  wire        rx_payload_last,

    // To ip_udp_tx_builder
    output wire        rx_matched_done,
    output wire        tx_start,
    output wire [47:0] tx_dest_mac,
    output wire [31:0] tx_dest_ip,
    output wire [15:0] tx_src_port,
    output wire [15:0] tx_dst_port,
    output wire [7:0]  tx_data,
    output wire        tx_data_valid,
    output wire        tx_last
);

    localparam MAX_PAYLOAD = 200;

    reg [7:0] payload_buf [0:MAX_PAYLOAD-1];

    reg [8:0] collect_idx;
    reg [8:0] payload_len;

    reg [47:0] latched_mac;
    reg [31:0] latched_ip;
    reg [15:0] latched_port;


    // =========================================================================
    // RX SIDE
    //
    // Only packets whose valid payload stream is addressed to ECHO_PORT are
    // allowed to enter RX_COLLECT.
    //
    // Therefore:
    //
    //     RX_DONE == complete matched echo request
    //
    // No separate port_matched register is required.
    // =========================================================================

    localparam RX_IDLE    = 2'd0;
    localparam RX_COLLECT = 2'd1;
    localparam RX_DONE    = 2'd2;

    reg [1:0] rx_state;

    always @(posedge clk) begin
        if (rst) begin
            rx_state     <= RX_IDLE;
            collect_idx  <= 9'd0;
            payload_len  <= 9'd0;

            latched_mac  <= 48'd0;
            latched_ip   <= 32'd0;
            latched_port <= 16'd0;
        end else begin
            case (rx_state)

                // -------------------------------------------------------------
                // Wait for the first payload byte of a valid UDP packet sent
                // specifically to ECHO_PORT.
                // -------------------------------------------------------------
                RX_IDLE: begin
                    collect_idx <= 9'd0;

                    if (rx_payload_valid &&
                        (rx_dst_port == ECHO_PORT)) begin

                        // Latch the sender information once, on the first
                        // payload byte. These values are used for the reply.
                        latched_mac  <= rx_src_mac;
                        latched_ip   <= rx_src_ip;
                        latched_port <= rx_src_port;

                        // First byte always goes into location zero.
                        payload_buf[0] <= rx_payload_data;
                        collect_idx    <= 9'd1;

                        if (rx_payload_last)
                            rx_state <= RX_DONE;
                        else
                            rx_state <= RX_COLLECT;
                    end
                end


                // -------------------------------------------------------------
                // Collect the remainder of the already-matched payload.
                // -------------------------------------------------------------
                RX_COLLECT: begin
                    if (rx_payload_valid) begin

                        // Preserve the behavior of the previous implementation:
                        // store bytes while they fit in the local buffer.
                        if (collect_idx < MAX_PAYLOAD)
                            payload_buf[collect_idx] <= rx_payload_data;

                        collect_idx <= collect_idx + 1'b1;

                        if (rx_payload_last)
                            rx_state <= RX_DONE;
                    end
                end


                // -------------------------------------------------------------
                // One-cycle matched-request-complete state.
                //
                // collect_idx is now the number of payload bytes received.
                // RX_DONE itself is also exported as rx_matched_done.
                // -------------------------------------------------------------
                RX_DONE: begin
                    payload_len <= collect_idx;
                    rx_state    <= RX_IDLE;
                end


                default: begin
                    rx_state <= RX_IDLE;
                end

            endcase
        end
    end


    // =========================================================================
    // TX SIDE
    //
    // Keep the existing one-cycle send_pending pipeline so the TX timing stays
    // as close as possible to the previous measured design.
    // =========================================================================

    reg       send_pending;
    reg [8:0] send_idx;

    localparam TX_IDLE   = 2'd0;
    localparam TX_START  = 2'd1;
    localparam TX_STREAM = 2'd2;

    reg [1:0] tx_state;

    always @(posedge clk) begin
        if (rst) begin
            send_pending <= 1'b0;
            send_idx     <= 9'd0;
            tx_state     <= TX_IDLE;
        end else begin

            // RX_DONE can only occur for a packet that was accepted at
            // ECHO_PORT, so no separate port-match condition is needed.
            send_pending <= (rx_state == RX_DONE);

            case (tx_state)

                TX_IDLE: begin
                    if (send_pending) begin
                        send_idx <= 9'd0;
                        tx_state <= TX_START;
                    end
                end


                // One-cycle start pulse to ip_udp_tx_builder.
                TX_START: begin
                    tx_state <= TX_STREAM;
                end


                // Replay the buffered payload one byte per cycle.
                TX_STREAM: begin
                    if (send_idx == payload_len - 1'b1) begin
                        tx_state <= TX_IDLE;
                    end else begin
                        send_idx <= send_idx + 1'b1;
                    end
                end


                default: begin
                    tx_state <= TX_IDLE;
                end

            endcase
        end
    end


    // =========================================================================
    // OUTPUTS
    // =========================================================================

    // One-cycle pulse: a complete request to ECHO_PORT has been received.
    //
    // This remains T1 for latency_probe.
    assign rx_matched_done =
        (rx_state == RX_DONE);


    // One-cycle request to begin constructing the reply.
    assign tx_start =
        (tx_state == TX_START);


    // Reply to the original sender.
    assign tx_dest_mac = latched_mac;
    assign tx_dest_ip  = latched_ip;

    // Reply FROM the echo service port.
    assign tx_src_port = ECHO_PORT;

    // Reply TO the sender's original ephemeral source port.
    assign tx_dst_port = latched_port;


    // Buffered payload replay.
    assign tx_data =
        payload_buf[send_idx];

    assign tx_data_valid =
        (tx_state == TX_STREAM);

    assign tx_last =
        (tx_state == TX_STREAM) &&
        (send_idx == payload_len - 1'b1);

endmodule
