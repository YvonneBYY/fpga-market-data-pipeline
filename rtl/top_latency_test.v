module top_latency_test (
    input  wire clk100mhz,
    input  wire btn0,              // reset

    // MII pins
    output wire eth_ref_clk,
    output wire eth_rstn,
    input  wire eth_tx_clk,
    output wire eth_tx_en,
    output wire [3:0] eth_txd,
    input  wire eth_rx_clk,
    input  wire eth_rx_dv,
    input  wire [3:0] eth_rxd,
    input  wire eth_rxerr,

    output wire [3:0] led,    // 0=mmcm_locked 1=phy_rst_n 2=arp_matched 3=udp_echo_sent
    output wire uart_txd_out  // 76-byte true-frame-end latency diagnostic report
);

    // ---------------- Clocking / PHY reset (unchanged from Phase 2-4) ----------------
    wire clk_out1, mmcm_locked;
    clk_wiz_0 clk_wiz_inst (
        .clk_in1(clk100mhz), .clk_out1(clk_out1), .reset(1'b0), .locked(mmcm_locked)
    );
    assign eth_ref_clk = clk_out1;

    reg [23:0] rst_counter = 0;
    reg phy_rst_n = 0;
    always @(posedge clk_out1) begin
        if (!mmcm_locked) begin
            rst_counter <= 0;
            phy_rst_n   <= 0;
        end else if (rst_counter < 24'hFFFFFF) begin
            rst_counter <= rst_counter + 1;
        end else begin
            phy_rst_n <= 1;
        end
    end
    assign eth_rstn = phy_rst_n;

    wire sys_rst, tx_eth_rst, rx_eth_rst;
    sync_2ff #(.WIDTH(1)) sync_rst_sys   (.clk(clk100mhz), .rst(1'b0), .async_in(btn0), .sync_out(sys_rst));
    sync_2ff #(.WIDTH(1)) sync_rst_txeth (.clk(eth_tx_clk), .rst(1'b0), .async_in(btn0), .sync_out(tx_eth_rst));
    sync_2ff #(.WIDTH(1)) sync_rst_rxeth (.clk(eth_rx_clk), .rst(1'b0), .async_in(btn0), .sync_out(rx_eth_rst));

    // ---------------- MAC RX ----------------
    wire frame_start, frame_end, frame_error;
    wire [7:0] rx_data;
    wire rx_data_valid;

    eth_mac_rx_nibble mac_rx_inst (
        .phy_rx_clk(eth_rx_clk), .rst(rx_eth_rst),
        .phy_rxd(eth_rxd), .phy_rx_dv(eth_rx_dv), .phy_rx_er(eth_rxerr),
        .data(rx_data), .data_valid(rx_data_valid),
        .frame_start(frame_start), .frame_end(frame_end), .frame_error(frame_error)
    );

    // ---------------- RX frame-tagged CDC bridge ----------------
    wire [7:0] sys_rx_data;
    wire       sys_rx_data_valid, sys_rx_frame_start, sys_rx_frame_end, sys_rx_overflow;

    rx_frame_cdc rx_cdc_inst (
        .phy_rx_clk(eth_rx_clk), .phy_rx_rst(rx_eth_rst),
        .phy_rx_data(rx_data), .phy_rx_data_valid(rx_data_valid),
        .phy_rx_frame_start(frame_start), .phy_rx_frame_end(frame_end),
        .sys_clk(clk100mhz), .sys_rst(sys_rst),
        .sys_rx_data(sys_rx_data), .sys_rx_data_valid(sys_rx_data_valid),
        .sys_rx_frame_start(sys_rx_frame_start), .sys_rx_frame_end(sys_rx_frame_end),
        .sys_rx_overflow(sys_rx_overflow)
    );

    // ---------------- ARP responder ----------------
    localparam [31:0] OUR_IP = {8'd169, 8'd254, 8'd89, 8'd52};

    wire arp_tx_valid, arp_tx_last, arp_tx_req;
    wire [7:0] arp_tx_byte;

    arp_responder #(.OUR_IP(OUR_IP)) arp_inst (
        .clk(clk100mhz), .rst(sys_rst),
        .rx_data(sys_rx_data), .rx_data_valid(sys_rx_data_valid),
        .rx_frame_start(sys_rx_frame_start), .rx_frame_end(sys_rx_frame_end),
        .tx_valid(arp_tx_valid), .tx_byte(arp_tx_byte), .tx_last(arp_tx_last), .tx_req(arp_tx_req)
    );

    wire [8:0] arp_fifo_wr_data;
    wire       arp_fifo_wr_en;
    arp_reply_framer arp_framer_inst (
        .clk(clk100mhz), .rst(sys_rst),
        .arp_tx_req(arp_tx_req), .arp_tx_valid(arp_tx_valid),
        .arp_tx_byte(arp_tx_byte), .arp_tx_last(arp_tx_last),
        .fifo_wr_data(arp_fifo_wr_data), .fifo_wr_en(arp_fifo_wr_en)
    );

    reg arp_matched_sticky = 0;
    always @(posedge clk100mhz) begin
        if (sys_rst) arp_matched_sticky <= 0;
        else if (arp_tx_req) arp_matched_sticky <= 1;
    end

    // ---------------- IPv4/UDP RX parser ----------------
    wire [31:0] udp_rx_src_ip, udp_rx_dst_ip;
    wire [47:0] udp_rx_src_mac;
    wire [15:0] udp_rx_src_port, udp_rx_dst_port, udp_rx_udp_length;
    wire        udp_rx_payload_valid, udp_rx_payload_last, udp_rx_malformed;
    wire [7:0]  udp_rx_payload_data;

    // Fine-grained debug pulses exported by ip_udp_rx_parser_rx_debug.v.
    wire udp_dbg_header_ready;
    wire udp_dbg_ipv4_udp_header;
    wire udp_dbg_ip_checksum_good;
    wire udp_dbg_ip_checksum_bad;
    wire udp_dbg_udp_header_latched;

    ip_udp_rx_parser udp_rx_inst (
        .clk(clk100mhz), .rst(sys_rst),
        .rx_data(sys_rx_data), .rx_data_valid(sys_rx_data_valid),
        .rx_frame_start(sys_rx_frame_start), .rx_frame_end(sys_rx_frame_end),
        .src_ip(udp_rx_src_ip), .dst_ip(udp_rx_dst_ip), .src_mac(udp_rx_src_mac),
        .src_port(udp_rx_src_port), .dst_port(udp_rx_dst_port), .udp_length(udp_rx_udp_length),
        .payload_valid(udp_rx_payload_valid), .payload_data(udp_rx_payload_data),
        .payload_last(udp_rx_payload_last), .packet_malformed(udp_rx_malformed),
        .dbg_header_ready_pulse(udp_dbg_header_ready),
        .dbg_ipv4_udp_header_pulse(udp_dbg_ipv4_udp_header),
        .dbg_ip_checksum_good_pulse(udp_dbg_ip_checksum_good),
        .dbg_ip_checksum_bad_pulse(udp_dbg_ip_checksum_bad),
        .dbg_udp_header_latched_pulse(udp_dbg_udp_header_latched)
    );

    // ---------------- UDP echo glue ----------------
    wire        echo_tx_start, echo_tx_data_valid, echo_tx_last, echo_rx_matched_done;
    wire [47:0] echo_tx_dest_mac;
    wire [31:0] echo_tx_dest_ip;
    wire [15:0] echo_tx_src_port, echo_tx_dst_port;
    wire [7:0]  echo_tx_data;

    udp_echo_responder #(.ECHO_PORT(16'd9000)) echo_inst (
        .clk(clk100mhz), .rst(sys_rst),
        .rx_src_mac(udp_rx_src_mac), .rx_src_ip(udp_rx_src_ip), .rx_src_port(udp_rx_src_port),
        .rx_dst_port(udp_rx_dst_port),
        .rx_payload_valid(udp_rx_payload_valid), .rx_payload_data(udp_rx_payload_data),
        .rx_payload_last(udp_rx_payload_last),
        .rx_matched_done(echo_rx_matched_done),
        .tx_start(echo_tx_start), .tx_dest_mac(echo_tx_dest_mac), .tx_dest_ip(echo_tx_dest_ip),
        .tx_src_port(echo_tx_src_port), .tx_dst_port(echo_tx_dst_port),
        .tx_data(echo_tx_data), .tx_data_valid(echo_tx_data_valid), .tx_last(echo_tx_last)
    );

    // ---------------- IPv4/UDP TX builder + framer ----------------
    wire udp_tx_valid, udp_tx_last, udp_tx_req;
    wire [7:0] udp_tx_byte;

    ip_udp_tx_builder #(.OUR_MAC(48'h02_00_00_00_00_01), .OUR_IP(OUR_IP)) udp_tx_inst (
        .clk(clk100mhz), .rst(sys_rst),
        .in_start(echo_tx_start), .in_dest_mac(echo_tx_dest_mac), .in_dest_ip(echo_tx_dest_ip),
        .in_src_port(echo_tx_src_port), .in_dst_port(echo_tx_dst_port),
        .in_data(echo_tx_data), .in_data_valid(echo_tx_data_valid), .in_last(echo_tx_last),
        .tx_req(udp_tx_req), .tx_valid(udp_tx_valid), .tx_byte(udp_tx_byte), .tx_last(udp_tx_last)
    );

    wire [8:0] udp_fifo_wr_data;
    wire       udp_fifo_wr_en;
    udp_tx_framer udp_framer_inst (
        .clk(clk100mhz), .rst(sys_rst),
        .udp_tx_req(udp_tx_req), .udp_tx_valid(udp_tx_valid),
        .udp_tx_byte(udp_tx_byte), .udp_tx_last(udp_tx_last),
        .fifo_wr_data(udp_fifo_wr_data), .fifo_wr_en(udp_fifo_wr_en)
    );

    // =========================================================================
    // FRAME-ATOMIC TX QUEUES + ARBITER
    //
    // Each framer writes into its own queue. The arbiter chooses ONE source
    // for an entire frame and does not switch until that source's {last} bit
    // is forwarded. This prevents ARP and UDP bytes from ever interleaving.
    //
    // Shared-word format after arbitration:
    //   bit 9   = is_udp
    //   bit 8   = last
    //   bits7:0 = data byte
    // =========================================================================

    // ---------------- ARP source queue (clk100mhz domain) ----------------
    wire [8:0] arp_q_rd_data;
    wire       arp_q_empty;
    wire       arp_q_full;
    wire       arp_q_rd_en;

    sync_fifo_simple #(
        .DATA_WIDTH(9),
        .ADDR_WIDTH(8)      // 256 words
    ) arp_source_queue (
        .clk     (clk100mhz),
        .rst     (sys_rst),
        .wr_data (arp_fifo_wr_data),
        .wr_en   (arp_fifo_wr_en),
        .full    (arp_q_full),
        .rd_data (arp_q_rd_data),
        .rd_en   (arp_q_rd_en),
        .empty   (arp_q_empty)
    );

    // ---------------- UDP source queue (clk100mhz domain) ----------------
    wire [8:0] udp_q_rd_data;
    wire       udp_q_empty;
    wire       udp_q_full;
    wire       udp_q_rd_en;

    sync_fifo_simple #(
        .DATA_WIDTH(9),
        .ADDR_WIDTH(9)      // 512 words
    ) udp_source_queue (
        .clk     (clk100mhz),
        .rst     (sys_rst),
        .wr_data (udp_fifo_wr_data),
        .wr_en   (udp_fifo_wr_en),
        .full    (udp_q_full),
        .rd_data (udp_q_rd_data),
        .rd_en   (udp_q_rd_en),
        .empty   (udp_q_empty)
    );

    // ---------------- Frame-level arbiter ----------------
    wire [9:0] tx_arb_data;
    wire       tx_arb_wr_en;

    wire       tx_fifo_full;
    wire       tx_fifo_empty;

    // One launch descriptor is generated exactly once per granted frame.
    // It crosses into eth_tx_clk independently of the frame-byte FIFO so the
    // MAC can begin preamble transmission before byte 0 reaches the elastic
    // data buffer.
    wire       tx_arb_launch_wr_en;
    wire       tx_arb_launch_is_udp;

    wire       tx_launch_fifo_full;
    wire       tx_launch_fifo_empty;
    wire [0:0] tx_launch_fifo_rd_data;
    wire       tx_launch_fifo_rd_en;

    tx_frame_arbiter tx_arb_inst (
        .clk       (clk100mhz),
        .rst       (sys_rst),

        .arp_data  (arp_q_rd_data),
        .arp_empty (arp_q_empty),
        .arp_rd_en (arp_q_rd_en),

        .udp_data  (udp_q_rd_data),
        .udp_empty (udp_q_empty),
        .udp_rd_en (udp_q_rd_en),

        .out_full  (tx_fifo_full),
        .out_data  (tx_arb_data),
        .out_wr_en (tx_arb_wr_en),

        .launch_full   (tx_launch_fifo_full),
        .launch_wr_en  (tx_arb_launch_wr_en),
        .launch_is_udp (tx_arb_launch_is_udp)
    );

    // ---------------- Per-frame launch descriptor CDC ----------------
    //
    // The byte FIFO is 512 words deep, so at most eight minimum-size
    // Ethernet frames can be resident there at once. A 16-entry launch FIFO
    // therefore has comfortable headroom while keeping launch ordering atomic
    // with arbiter grant ordering.
    async_fifo #(
        .DATA_WIDTH(1),
        .ADDR_WIDTH(4)
    ) tx_launch_fifo (
        .wr_clk  (clk100mhz),
        .wr_rst  (sys_rst),
        .wr_data ({tx_arb_launch_is_udp}),
        .wr_en   (tx_arb_launch_wr_en),
        .full    (tx_launch_fifo_full),

        .rd_clk  (eth_tx_clk),
        .rd_rst  (tx_eth_rst),
        .rd_data (tx_launch_fifo_rd_data),
        .rd_en   (tx_launch_fifo_rd_en),
        .empty   (tx_launch_fifo_empty)
    );

    // ---------------- Shared TX data CDC FIFO (clk100mhz -> eth_tx_clk) ----------------
    // Word format remains {is_udp, last, data[7:0]}.
    wire [9:0] tx_fifo_rd_data;
    wire       tx_fifo_rd_en;

    async_fifo #(
        .DATA_WIDTH(10),
        .ADDR_WIDTH(9)
    ) tx_frame_fifo (
        .wr_clk  (clk100mhz),
        .wr_rst  (sys_rst),
        .wr_data (tx_arb_data),
        .wr_en   (tx_arb_wr_en),
        .full    (tx_fifo_full),

        .rd_clk  (eth_tx_clk),
        .rd_rst  (tx_eth_rst),
        .rd_data (tx_fifo_rd_data),
        .rd_en   (tx_fifo_rd_en),
        .empty   (tx_fifo_empty)
    );

    // =========================================================================
    // SPECULATIVE-PREAMBLE CUT-THROUGH TX (eth_tx_clk domain)
    //
    // Previous cut-through policy:
    //   wait until >=1 Ethernet data byte reaches the local elastic buffer
    //   -> assert tx_start
    //   -> MAC sends preamble/SFD
    //
    // New policy:
    //   frame arbiter grants a complete ARP or UDP frame
    //   -> push one 1-bit launch descriptor into a parallel async FIFO
    //   -> TX domain receives descriptor
    //   -> assert tx_start immediately, even if byte 0 has not arrived yet
    //   -> use the 640 ns preamble/SFD interval to hide data CDC latency
    //
    // Safety properties:
    //   * Descriptor order is exactly arbiter grant order.
    //   * Arbiter will not grant a frame if the launch FIFO OR data FIFO is
    //     full, so a launch descriptor can never get arbitrarily far ahead of
    //     the first data byte.
    //   * The existing elastic buffer continues filling during preamble/SFD.
    //   * tx_stream_underrun_sticky detects any MAC starvation.
    //   * tx_first_byte_not_ready_sticky specifically detects byte 0 missing
    //     when the MAC first requests frame data.
    //   * tx_launch_tag_mismatch_sticky verifies descriptor ordering against
    //     the is_udp tag carried on the first data word.
    // =========================================================================

    localparam ELASTIC_DEPTH       = 16;
    localparam ELASTIC_ADDR_WIDTH  = 4;

    localparam TX_STREAM_IDLE       = 3'd0,
               TX_STREAM_WAIT_READY = 3'd1,
               TX_STREAM_SEND       = 3'd2,
               TX_STREAM_WAIT_DONE  = 3'd3;

    reg [2:0] tx_state = TX_STREAM_IDLE;

    // ---------------- Data elastic buffer ----------------
    reg [9:0] tx_elastic_mem [0:ELASTIC_DEPTH-1];

    reg [ELASTIC_ADDR_WIDTH-1:0] elastic_wr_ptr = 0;
    reg [ELASTIC_ADDR_WIDTH-1:0] elastic_rd_ptr = 0;
    reg [ELASTIC_ADDR_WIDTH:0]   elastic_count  = 0;

    reg tx_fifo_read_pending = 1'b0;

    wire elastic_empty = (elastic_count == 0);
    wire elastic_full  = (elastic_count == ELASTIC_DEPTH);

    wire [9:0] elastic_front =
        tx_elastic_mem[elastic_rd_ptr];

    wire elastic_has_read_room =
        (elastic_count + (tx_fifo_read_pending ? 1'b1 : 1'b0))
        < ELASTIC_DEPTH;

    assign tx_fifo_rd_en =
        (!tx_eth_rst) &&
        (!tx_fifo_empty) &&
        elastic_has_read_room;

    wire elastic_push_from_fifo = tx_fifo_read_pending;

    // ---------------- Launch-descriptor prefetch ----------------
    reg launch_read_pending = 1'b0;
    reg launch_desc_valid   = 1'b0;
    reg launch_desc_is_udp  = 1'b0;

    assign tx_launch_fifo_rd_en =
        (!tx_eth_rst) &&
        (!tx_launch_fifo_empty) &&
        (!launch_desc_valid) &&
        (!launch_read_pending);

    wire launch_desc_arriving =
        launch_read_pending;

    wire launch_desc_available =
        launch_desc_valid || launch_desc_arriving;

    wire launch_desc_value =
        launch_desc_valid
        ? launch_desc_is_udp
        : tx_launch_fifo_rd_data[0];

    // TX_STREAM_IDLE is entered only after mac_tx_busy has dropped, so the
    // state itself is sufficient to guarantee the MAC is available.
    wire launch_desc_take =
        (tx_state == TX_STREAM_IDLE) &&
        launch_desc_available;

    always @(posedge eth_tx_clk) begin
        if (tx_eth_rst) begin
            launch_read_pending <= 1'b0;
            launch_desc_valid   <= 1'b0;
            launch_desc_is_udp  <= 1'b0;
        end else begin
            launch_read_pending <= tx_launch_fifo_rd_en;

            if (launch_desc_arriving && !launch_desc_take) begin
                launch_desc_is_udp <= tx_launch_fifo_rd_data[0];
                launch_desc_valid  <= 1'b1;
            end
            else if (launch_desc_take && launch_desc_valid) begin
                launch_desc_valid <= 1'b0;
            end
        end
    end

    // ---------------- MAC-facing signals ----------------
    reg current_frame_is_udp = 1'b0;

    reg        mac_tx_start;
    wire [7:0] mac_tx_data;
    wire       mac_tx_data_valid;
    wire       mac_tx_last;
    wire       mac_tx_ready;
    wire       mac_tx_busy;
    wire       mac_tx_frame_done;

    assign mac_tx_data = elastic_front[7:0];
    assign mac_tx_last = elastic_front[8];

    assign mac_tx_data_valid =
        ((tx_state == TX_STREAM_WAIT_READY) ||
         (tx_state == TX_STREAM_SEND)) &&
        mac_tx_ready &&
        !elastic_empty;

    wire elastic_pop_to_mac = mac_tx_data_valid;

    // ---------------- Safety diagnostics ----------------
    reg tx_stream_underrun_sticky        = 1'b0;
    reg tx_launch_tag_mismatch_sticky    = 1'b0;
    reg tx_first_byte_not_ready_sticky   = 1'b0;
    reg first_byte_pending               = 1'b0;

    eth_mac_tx_nibble mac_tx_inst (
        .phy_tx_clk    (eth_tx_clk),
        .rst           (tx_eth_rst),
        .tx_start      (mac_tx_start),
        .tx_data       (mac_tx_data),
        .tx_data_valid (mac_tx_data_valid),
        .tx_last       (mac_tx_last),
        .phy_txd       (eth_txd),
        .phy_tx_en     (eth_tx_en),
        .tx_ready      (mac_tx_ready),
        .tx_busy       (mac_tx_busy),
        .frame_done    (mac_tx_frame_done)
    );

    // -------------------------------------------------------------------------
    // Elastic-buffer fill / drain
    // -------------------------------------------------------------------------
    always @(posedge eth_tx_clk) begin
        if (tx_eth_rst) begin
            elastic_wr_ptr       <= 0;
            elastic_rd_ptr       <= 0;
            elastic_count        <= 0;
            tx_fifo_read_pending <= 1'b0;
        end else begin
            tx_fifo_read_pending <= tx_fifo_rd_en;

            if (elastic_push_from_fifo) begin
                tx_elastic_mem[elastic_wr_ptr] <= tx_fifo_rd_data;
                elastic_wr_ptr <= elastic_wr_ptr + 1'b1;
            end

            if (elastic_pop_to_mac)
                elastic_rd_ptr <= elastic_rd_ptr + 1'b1;

            case ({elastic_push_from_fifo, elastic_pop_to_mac})
                2'b10: elastic_count <= elastic_count + 1'b1;
                2'b01: elastic_count <= elastic_count - 1'b1;
                default: elastic_count <= elastic_count;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // MAC control
    //
    // tx_start is driven by the frame descriptor, not elastic_count.
    // -------------------------------------------------------------------------
    always @(posedge eth_tx_clk) begin
        mac_tx_start <= 1'b0;

        if (tx_eth_rst) begin
            tx_state                       <= TX_STREAM_IDLE;
            current_frame_is_udp           <= 1'b0;
            tx_stream_underrun_sticky      <= 1'b0;
            tx_launch_tag_mismatch_sticky  <= 1'b0;
            tx_first_byte_not_ready_sticky <= 1'b0;
            first_byte_pending             <= 1'b0;
        end else begin

            if (((tx_state == TX_STREAM_WAIT_READY) ||
                 (tx_state == TX_STREAM_SEND)) &&
                mac_tx_ready &&
                elastic_empty)
                tx_stream_underrun_sticky <= 1'b1;

            if ((tx_state == TX_STREAM_WAIT_READY) &&
                mac_tx_ready &&
                elastic_empty)
                tx_first_byte_not_ready_sticky <= 1'b1;

            if (elastic_pop_to_mac && first_byte_pending) begin
                if (elastic_front[9] != current_frame_is_udp)
                    tx_launch_tag_mismatch_sticky <= 1'b1;
                first_byte_pending <= 1'b0;
            end

            case (tx_state)

                TX_STREAM_IDLE: begin
                    if (launch_desc_take) begin
                        current_frame_is_udp <= launch_desc_value;
                        mac_tx_start <= 1'b1;
                        first_byte_pending <= 1'b1;
                        tx_state <= TX_STREAM_WAIT_READY;
                    end
                end

                TX_STREAM_WAIT_READY: begin
                    if (elastic_pop_to_mac) begin
                        if (elastic_front[8])
                            tx_state <= TX_STREAM_WAIT_DONE;
                        else
                            tx_state <= TX_STREAM_SEND;
                    end
                end

                TX_STREAM_SEND: begin
                    if (elastic_pop_to_mac && elastic_front[8])
                        tx_state <= TX_STREAM_WAIT_DONE;
                end

                TX_STREAM_WAIT_DONE: begin
                    if (!mac_tx_busy)
                        tx_state <= TX_STREAM_IDLE;
                end

                default: begin
                    tx_state <= TX_STREAM_IDLE;
                end
            endcase
        end
    end


    // ---------------- TX completion events ----------------
    //
    // True latency endpoint: frame_done occurs immediately after the final
    // Ethernet frame nibble completes. IFG remains enforced by tx_busy and the
    // TX state machine, but is no longer included in the response-latency T4.
    reg mac_tx_busy_prev = 1'b0;

    always @(posedge eth_tx_clk) begin
        if (tx_eth_rst)
            mac_tx_busy_prev <= 1'b0;
        else
            mac_tx_busy_prev <= mac_tx_busy;
    end

    // End of mandatory IFG; retained only as an internal/reference event.
    wire tx_ifg_done_pulse_txclk =
        mac_tx_busy_prev && !mac_tx_busy;

    // True frame completion for this UDP response.
    wire udp_tx_frame_done_pulse_txclk =
        mac_tx_frame_done && current_frame_is_udp;

    // UDP-specific MAC START event.
    wire udp_tx_start_pulse_txclk =
        mac_tx_start && current_frame_is_udp;

    // ---------------- LEDs ----------------
    reg udp_echo_confirmed_sticky = 1'b0;

    always @(posedge eth_tx_clk) begin
        if (tx_eth_rst)
            udp_echo_confirmed_sticky <= 1'b0;
        else if (udp_tx_frame_done_pulse_txclk)
            udp_echo_confirmed_sticky <= 1'b1;
    end

    assign led[0] = mmcm_locked;
    assign led[1] = phy_rst_n;
    assign led[2] = arp_matched_sticky;
    assign led[3] = udp_echo_confirmed_sticky;

    // =========================================================================
    // FINE-GRAINED RX + TX RELIABILITY COUNTERS
    //
    // The RX side is now split into enough milestones to determine whether a
    // missing request was lost at the physical/MAC boundary, in the CDC,
    // during IPv4/UDP validation, at the UDP port/payload boundary, or later.
    //
    // Counters:
    //   mac_frame_start       - frame_start observed in eth_rx_clk domain
    //   mac_frame_error       - rising edge of MAC frame_error
    //   sys_frame_start       - frame_start after rx_frame_cdc
    //   our_ip_header         - parser reached header-check point and dst_ip=OUR_IP
    //   our_ipv4_udp          - same frame recognized as IPv4/UDP
    //   our_csum_good         - IPv4/UDP header checksum accepted
    //   our_csum_bad          - IPv4/UDP header checksum rejected
    //   our_udp_header        - good UDP header latched
    //   our_payload_start     - first payload byte of a valid UDP packet to OUR_IP
    //   port9000_start        - first payload byte and dst_port == 9000
    //   port9000_last         - final payload byte for a port-9000 request
    //   udp_match             - echo responder completed a matched request
    //   udp_tx_req            - UDP reply builder completed its frame request
    //   udp_arb               - complete UDP frame passed frame arbiter
    //   udp_tx_done           - UDP frame completed MAC transmission
    //
    // All counts are cumulative 32-bit values.
    // =========================================================================

    // -------------------------------------------------------------------------
    // eth_rx_clk -> clk100mhz debug event crossings.
    //
    // Toggle CDC is safe here because Ethernet frame-start/error events are
    // separated by far more than the few 100 MHz cycles required to
    // synchronize a toggle.
    // -------------------------------------------------------------------------
    reg mac_start_toggle_rxclk = 1'b0;
    reg mac_error_toggle_rxclk = 1'b0;
    reg mac_frame_error_prev_rxclk = 1'b0;

    always @(posedge eth_rx_clk) begin
        if (rx_eth_rst) begin
            mac_start_toggle_rxclk    <= 1'b0;
            mac_error_toggle_rxclk    <= 1'b0;
            mac_frame_error_prev_rxclk <= 1'b0;
        end else begin
            if (frame_start)
                mac_start_toggle_rxclk <= ~mac_start_toggle_rxclk;

            // Count one event per assertion of frame_error even if the MAC
            // holds the signal high for more than one RX clock.
            if (frame_error && !mac_frame_error_prev_rxclk)
                mac_error_toggle_rxclk <= ~mac_error_toggle_rxclk;

            mac_frame_error_prev_rxclk <= frame_error;
        end
    end

    reg [2:0] mac_start_toggle_sync = 3'b000;
    reg [2:0] mac_error_toggle_sync = 3'b000;

    always @(posedge clk100mhz) begin
        if (sys_rst) begin
            mac_start_toggle_sync <= 3'b000;
            mac_error_toggle_sync <= 3'b000;
        end else begin
            mac_start_toggle_sync <= {
                mac_start_toggle_sync[1:0],
                mac_start_toggle_rxclk
            };

            mac_error_toggle_sync <= {
                mac_error_toggle_sync[1:0],
                mac_error_toggle_rxclk
            };
        end
    end

    wire mac_frame_start_sys_pulse =
        mac_start_toggle_sync[2] ^ mac_start_toggle_sync[1];

    wire mac_frame_error_sys_pulse =
        mac_error_toggle_sync[2] ^ mac_error_toggle_sync[1];

    // -------------------------------------------------------------------------
    // UDP TX-completion toggle crossing back into clk100mhz.
    // -------------------------------------------------------------------------
    reg udp_done_count_toggle_txclk = 1'b0;

    always @(posedge eth_tx_clk) begin
        if (tx_eth_rst)
            udp_done_count_toggle_txclk <= 1'b0;
        else if (udp_tx_frame_done_pulse_txclk)
            udp_done_count_toggle_txclk <= ~udp_done_count_toggle_txclk;
    end

    reg [2:0] udp_done_count_toggle_sync = 3'b000;

    always @(posedge clk100mhz) begin
        if (sys_rst)
            udp_done_count_toggle_sync <= 3'b000;
        else
            udp_done_count_toggle_sync <= {
                udp_done_count_toggle_sync[1:0],
                udp_done_count_toggle_txclk
            };
    end

    wire udp_tx_done_sys_pulse =
        udp_done_count_toggle_sync[2] ^ udp_done_count_toggle_sync[1];

    // -------------------------------------------------------------------------
    // Cumulative counters
    // -------------------------------------------------------------------------
    reg [31:0] dbg_mac_frame_start_count      = 32'd0;
    reg [31:0] dbg_mac_frame_error_count      = 32'd0;
    reg [31:0] dbg_sys_frame_start_count      = 32'd0;

    reg [31:0] dbg_our_ip_header_count        = 32'd0;
    reg [31:0] dbg_our_ipv4_udp_count         = 32'd0;
    reg [31:0] dbg_our_csum_good_count        = 32'd0;
    reg [31:0] dbg_our_csum_bad_count         = 32'd0;
    reg [31:0] dbg_our_udp_header_count       = 32'd0;

    reg [31:0] dbg_our_payload_start_count    = 32'd0;
    reg [31:0] dbg_port9000_start_count       = 32'd0;
    reg [31:0] dbg_port9000_last_count        = 32'd0;

    reg [31:0] dbg_udp_match_count            = 32'd0;
    reg [31:0] dbg_udp_tx_req_count           = 32'd0;
    reg [31:0] dbg_udp_arb_count              = 32'd0;
    reg [31:0] dbg_udp_tx_done_count          = 32'd0;

    // Track first payload byte once per Ethernet frame.
    reg dbg_payload_seen_this_frame = 1'b0;

    // Source-queue overflow flags. These should remain zero.
    reg dbg_udp_q_overflow_sticky = 1'b0;
    reg dbg_arp_q_overflow_sticky = 1'b0;

    always @(posedge clk100mhz) begin
        if (sys_rst) begin
            dbg_mac_frame_start_count       <= 32'd0;
            dbg_mac_frame_error_count       <= 32'd0;
            dbg_sys_frame_start_count       <= 32'd0;

            dbg_our_ip_header_count         <= 32'd0;
            dbg_our_ipv4_udp_count          <= 32'd0;
            dbg_our_csum_good_count         <= 32'd0;
            dbg_our_csum_bad_count          <= 32'd0;
            dbg_our_udp_header_count        <= 32'd0;

            dbg_our_payload_start_count     <= 32'd0;
            dbg_port9000_start_count        <= 32'd0;
            dbg_port9000_last_count         <= 32'd0;

            dbg_udp_match_count             <= 32'd0;
            dbg_udp_tx_req_count            <= 32'd0;
            dbg_udp_arb_count               <= 32'd0;
            dbg_udp_tx_done_count           <= 32'd0;

            dbg_payload_seen_this_frame     <= 1'b0;
            dbg_udp_q_overflow_sticky       <= 1'b0;
            dbg_arp_q_overflow_sticky       <= 1'b0;
        end else begin
            if (mac_frame_start_sys_pulse)
                dbg_mac_frame_start_count <=
                    dbg_mac_frame_start_count + 1'b1;

            if (mac_frame_error_sys_pulse)
                dbg_mac_frame_error_count <=
                    dbg_mac_frame_error_count + 1'b1;

            if (sys_rx_frame_start) begin
                dbg_sys_frame_start_count <=
                    dbg_sys_frame_start_count + 1'b1;
                dbg_payload_seen_this_frame <= 1'b0;
            end

            // Parser milestone counters are gated by OUR_IP whenever dst_ip
            // is already settled. This removes most unrelated background UDP
            // traffic from the diagnosis.
            if (udp_dbg_header_ready && (udp_rx_dst_ip == OUR_IP))
                dbg_our_ip_header_count <=
                    dbg_our_ip_header_count + 1'b1;

            if (udp_dbg_ipv4_udp_header && (udp_rx_dst_ip == OUR_IP))
                dbg_our_ipv4_udp_count <=
                    dbg_our_ipv4_udp_count + 1'b1;

            if (udp_dbg_ip_checksum_good && (udp_rx_dst_ip == OUR_IP))
                dbg_our_csum_good_count <=
                    dbg_our_csum_good_count + 1'b1;

            if (udp_dbg_ip_checksum_bad && (udp_rx_dst_ip == OUR_IP))
                dbg_our_csum_bad_count <=
                    dbg_our_csum_bad_count + 1'b1;

            if (udp_dbg_udp_header_latched && (udp_rx_dst_ip == OUR_IP))
                dbg_our_udp_header_count <=
                    dbg_our_udp_header_count + 1'b1;

            // First valid payload byte for a frame.
            if (udp_rx_payload_valid && !dbg_payload_seen_this_frame) begin
                dbg_payload_seen_this_frame <= 1'b1;

                if (udp_rx_dst_ip == OUR_IP) begin
                    dbg_our_payload_start_count <=
                        dbg_our_payload_start_count + 1'b1;

                    if (udp_rx_dst_port == 16'd9000)
                        dbg_port9000_start_count <=
                            dbg_port9000_start_count + 1'b1;
                end
            end

            // Count the end of the target request payload.
            if (udp_rx_payload_last &&
                (udp_rx_dst_ip == OUR_IP) &&
                (udp_rx_dst_port == 16'd9000))
                dbg_port9000_last_count <=
                    dbg_port9000_last_count + 1'b1;

            if (echo_rx_matched_done)
                dbg_udp_match_count <=
                    dbg_udp_match_count + 1'b1;

            if (udp_tx_req)
                dbg_udp_tx_req_count <=
                    dbg_udp_tx_req_count + 1'b1;

            // Count a UDP frame once, when its LAST tagged word is accepted
            // by the shared TX CDC FIFO.
            if (tx_arb_wr_en && tx_arb_data[9] && tx_arb_data[8])
                dbg_udp_arb_count <=
                    dbg_udp_arb_count + 1'b1;

            if (udp_tx_done_sys_pulse)
                dbg_udp_tx_done_count <=
                    dbg_udp_tx_done_count + 1'b1;

            if (udp_fifo_wr_en && udp_q_full)
                dbg_udp_q_overflow_sticky <= 1'b1;

            if (arp_fifo_wr_en && arp_q_full)
                dbg_arp_q_overflow_sticky <= 1'b1;
        end
    end

    // ---------------- Latency probe with TX split ----------------
    wire        lp_report_valid;
    wire [15:0] lp_delta_rx;
    wire [15:0] lp_delta_decide;
    wire [15:0] lp_delta_build;
    wire [15:0] lp_delta_tx;
    wire [15:0] lp_delta_tx_queue;
    wire [15:0] lp_delta_tx_frame;
    wire [15:0] lp_delta_total;

    latency_probe latency_inst (
        .clk(clk100mhz),
        .rst(sys_rst),

        .t0_pulse(sys_rx_frame_start),
        .t1_pulse(echo_rx_matched_done),
        .t2_pulse(echo_tx_start),
        .t3_pulse(udp_tx_req),

        .tx_clk(eth_tx_clk),
        .tx_rst(tx_eth_rst),
        .tx_start_pulse_txclk(udp_tx_start_pulse_txclk),
        .tx_frame_done_pulse_txclk(udp_tx_frame_done_pulse_txclk),

        .report_valid(lp_report_valid),
        .delta_rx(lp_delta_rx),
        .delta_decide(lp_delta_decide),
        .delta_build(lp_delta_build),
        .delta_tx(lp_delta_tx),
        .delta_tx_queue(lp_delta_tx_queue),
        .delta_tx_frame(lp_delta_tx_frame),
        .delta_total(lp_delta_total)
    );

    // =========================================================================
    // UART LATENCY + TX-SPLIT + RELIABILITY REPORT
    //
    // Fixed 76-byte report, big-endian multi-byte fields.
    //
    // byte 0      : 0xB0 marker
    //
    // 16-bit latency fields:
    //   bytes  1..2  : RX              = T1 - T0
    //   bytes  3..4  : decision        = T2 - T1
    //   bytes  5..6  : build           = T3 - T2
    //   bytes  7..8  : TX total        = T4 - T3
    //   bytes  9..10 : TX queue/start  = MAC_START - T3
    //   bytes 11..12 : TX frame        = FRAME_DONE - MAC_START
    //   bytes 13..14 : total           = T4 - T0
    //
    // 15 cumulative 32-bit counters:
    //   15..18 : mac_frame_start
    //   19..22 : mac_frame_error
    //   23..26 : sys_frame_start
    //   27..30 : our_ip_header
    //   31..34 : our_ipv4_udp
    //   35..38 : our_csum_good
    //   39..42 : our_csum_bad
    //   43..46 : our_udp_header
    //   47..50 : our_payload_start
    //   51..54 : port9000_start
    //   55..58 : port9000_last
    //   59..62 : udp_match
    //   63..66 : udp_tx_req
    //   67..70 : udp_arb
    //   71..74 : udp_tx_done
    //
    // byte 75 flags:
    //   bit 0 = RX CDC overflow seen
    //   bit 1 = UDP source queue overflow seen
    //   bit 2 = ARP source queue overflow seen
    //   bit 3 = TX elastic-buffer underrun seen
    //   bit 4 = launch-descriptor/data-tag mismatch seen
    //   bit 5 = first Ethernet byte was not ready after preamble/SFD
    // =========================================================================

    localparam RPT_IDLE = 2'd0;
    localparam RPT_SEND = 2'd1;
    localparam RPT_WAIT = 2'd2;

    reg [1:0] rpt_state = RPT_IDLE;
    reg [6:0] rpt_idx   = 7'd0;

    reg [15:0] rpt_rx;
    reg [15:0] rpt_dec;
    reg [15:0] rpt_bld;
    reg [15:0] rpt_tx;
    reg [15:0] rpt_tx_queue;
    reg [15:0] rpt_tx_frame;
    reg [15:0] rpt_tot;

    reg [31:0] rpt_mac_frame_start_count;
    reg [31:0] rpt_mac_frame_error_count;
    reg [31:0] rpt_sys_frame_start_count;

    reg [31:0] rpt_our_ip_header_count;
    reg [31:0] rpt_our_ipv4_udp_count;
    reg [31:0] rpt_our_csum_good_count;
    reg [31:0] rpt_our_csum_bad_count;
    reg [31:0] rpt_our_udp_header_count;

    reg [31:0] rpt_our_payload_start_count;
    reg [31:0] rpt_port9000_start_count;
    reg [31:0] rpt_port9000_last_count;

    reg [31:0] rpt_udp_match_count;
    reg [31:0] rpt_udp_tx_req_count;
    reg [31:0] rpt_udp_arb_count;
    reg [31:0] rpt_udp_tx_done_count;

    reg [7:0]  rpt_flags;

    reg        uart_tx_start;
    reg [7:0]  uart_tx_byte;
    wire       uart_tx_busy;

    function [7:0] report_byte_at;
        input [6:0] idx;
        begin
            case (idx)
                7'd0:  report_byte_at = 8'hB0;

                7'd1:  report_byte_at = rpt_rx[15:8];
                7'd2:  report_byte_at = rpt_rx[7:0];

                7'd3:  report_byte_at = rpt_dec[15:8];
                7'd4:  report_byte_at = rpt_dec[7:0];

                7'd5:  report_byte_at = rpt_bld[15:8];
                7'd6:  report_byte_at = rpt_bld[7:0];

                7'd7:  report_byte_at = rpt_tx[15:8];
                7'd8:  report_byte_at = rpt_tx[7:0];

                7'd9:  report_byte_at = rpt_tx_queue[15:8];
                7'd10: report_byte_at = rpt_tx_queue[7:0];

                7'd11: report_byte_at = rpt_tx_frame[15:8];
                7'd12: report_byte_at = rpt_tx_frame[7:0];

                7'd13: report_byte_at = rpt_tot[15:8];
                7'd14: report_byte_at = rpt_tot[7:0];

                7'd15: report_byte_at = rpt_mac_frame_start_count[31:24];
                7'd16: report_byte_at = rpt_mac_frame_start_count[23:16];
                7'd17: report_byte_at = rpt_mac_frame_start_count[15:8];
                7'd18: report_byte_at = rpt_mac_frame_start_count[7:0];

                7'd19: report_byte_at = rpt_mac_frame_error_count[31:24];
                7'd20: report_byte_at = rpt_mac_frame_error_count[23:16];
                7'd21: report_byte_at = rpt_mac_frame_error_count[15:8];
                7'd22: report_byte_at = rpt_mac_frame_error_count[7:0];

                7'd23: report_byte_at = rpt_sys_frame_start_count[31:24];
                7'd24: report_byte_at = rpt_sys_frame_start_count[23:16];
                7'd25: report_byte_at = rpt_sys_frame_start_count[15:8];
                7'd26: report_byte_at = rpt_sys_frame_start_count[7:0];

                7'd27: report_byte_at = rpt_our_ip_header_count[31:24];
                7'd28: report_byte_at = rpt_our_ip_header_count[23:16];
                7'd29: report_byte_at = rpt_our_ip_header_count[15:8];
                7'd30: report_byte_at = rpt_our_ip_header_count[7:0];

                7'd31: report_byte_at = rpt_our_ipv4_udp_count[31:24];
                7'd32: report_byte_at = rpt_our_ipv4_udp_count[23:16];
                7'd33: report_byte_at = rpt_our_ipv4_udp_count[15:8];
                7'd34: report_byte_at = rpt_our_ipv4_udp_count[7:0];

                7'd35: report_byte_at = rpt_our_csum_good_count[31:24];
                7'd36: report_byte_at = rpt_our_csum_good_count[23:16];
                7'd37: report_byte_at = rpt_our_csum_good_count[15:8];
                7'd38: report_byte_at = rpt_our_csum_good_count[7:0];

                7'd39: report_byte_at = rpt_our_csum_bad_count[31:24];
                7'd40: report_byte_at = rpt_our_csum_bad_count[23:16];
                7'd41: report_byte_at = rpt_our_csum_bad_count[15:8];
                7'd42: report_byte_at = rpt_our_csum_bad_count[7:0];

                7'd43: report_byte_at = rpt_our_udp_header_count[31:24];
                7'd44: report_byte_at = rpt_our_udp_header_count[23:16];
                7'd45: report_byte_at = rpt_our_udp_header_count[15:8];
                7'd46: report_byte_at = rpt_our_udp_header_count[7:0];

                7'd47: report_byte_at = rpt_our_payload_start_count[31:24];
                7'd48: report_byte_at = rpt_our_payload_start_count[23:16];
                7'd49: report_byte_at = rpt_our_payload_start_count[15:8];
                7'd50: report_byte_at = rpt_our_payload_start_count[7:0];

                7'd51: report_byte_at = rpt_port9000_start_count[31:24];
                7'd52: report_byte_at = rpt_port9000_start_count[23:16];
                7'd53: report_byte_at = rpt_port9000_start_count[15:8];
                7'd54: report_byte_at = rpt_port9000_start_count[7:0];

                7'd55: report_byte_at = rpt_port9000_last_count[31:24];
                7'd56: report_byte_at = rpt_port9000_last_count[23:16];
                7'd57: report_byte_at = rpt_port9000_last_count[15:8];
                7'd58: report_byte_at = rpt_port9000_last_count[7:0];

                7'd59: report_byte_at = rpt_udp_match_count[31:24];
                7'd60: report_byte_at = rpt_udp_match_count[23:16];
                7'd61: report_byte_at = rpt_udp_match_count[15:8];
                7'd62: report_byte_at = rpt_udp_match_count[7:0];

                7'd63: report_byte_at = rpt_udp_tx_req_count[31:24];
                7'd64: report_byte_at = rpt_udp_tx_req_count[23:16];
                7'd65: report_byte_at = rpt_udp_tx_req_count[15:8];
                7'd66: report_byte_at = rpt_udp_tx_req_count[7:0];

                7'd67: report_byte_at = rpt_udp_arb_count[31:24];
                7'd68: report_byte_at = rpt_udp_arb_count[23:16];
                7'd69: report_byte_at = rpt_udp_arb_count[15:8];
                7'd70: report_byte_at = rpt_udp_arb_count[7:0];

                7'd71: report_byte_at = rpt_udp_tx_done_count[31:24];
                7'd72: report_byte_at = rpt_udp_tx_done_count[23:16];
                7'd73: report_byte_at = rpt_udp_tx_done_count[15:8];
                7'd74: report_byte_at = rpt_udp_tx_done_count[7:0];

                7'd75: report_byte_at = rpt_flags;

                default: report_byte_at = 8'h00;
            endcase
        end
    endfunction

    always @(posedge clk100mhz) begin
        uart_tx_start <= 1'b0;

        if (sys_rst) begin
            rpt_state <= RPT_IDLE;
            rpt_idx   <= 7'd0;
        end else begin
            case (rpt_state)

                RPT_IDLE: begin
                    if (lp_report_valid) begin
                        rpt_rx       <= lp_delta_rx;
                        rpt_dec      <= lp_delta_decide;
                        rpt_bld      <= lp_delta_build;
                        rpt_tx       <= lp_delta_tx;
                        rpt_tx_queue <= lp_delta_tx_queue;
                        rpt_tx_frame <= lp_delta_tx_frame;
                        rpt_tot      <= lp_delta_total;

                        rpt_mac_frame_start_count <=
                            dbg_mac_frame_start_count;
                        rpt_mac_frame_error_count <=
                            dbg_mac_frame_error_count;
                        rpt_sys_frame_start_count <=
                            dbg_sys_frame_start_count;

                        rpt_our_ip_header_count <=
                            dbg_our_ip_header_count;
                        rpt_our_ipv4_udp_count <=
                            dbg_our_ipv4_udp_count;
                        rpt_our_csum_good_count <=
                            dbg_our_csum_good_count;
                        rpt_our_csum_bad_count <=
                            dbg_our_csum_bad_count;
                        rpt_our_udp_header_count <=
                            dbg_our_udp_header_count;

                        rpt_our_payload_start_count <=
                            dbg_our_payload_start_count;
                        rpt_port9000_start_count <=
                            dbg_port9000_start_count;
                        rpt_port9000_last_count <=
                            dbg_port9000_last_count;

                        rpt_udp_match_count <=
                            dbg_udp_match_count;
                        rpt_udp_tx_req_count <=
                            dbg_udp_tx_req_count;
                        rpt_udp_arb_count <=
                            dbg_udp_arb_count;
                        rpt_udp_tx_done_count <=
                            dbg_udp_tx_done_count;

                        rpt_flags <= {
                            2'b00,
                            tx_first_byte_not_ready_sticky,
                            tx_launch_tag_mismatch_sticky,
                            tx_stream_underrun_sticky,
                            dbg_arp_q_overflow_sticky,
                            dbg_udp_q_overflow_sticky,
                            sys_rx_overflow
                        };

                        rpt_idx   <= 7'd0;
                        rpt_state <= RPT_SEND;
                    end
                end

                RPT_SEND: begin
                    if (!uart_tx_busy) begin
                        uart_tx_byte  <= report_byte_at(rpt_idx);
                        uart_tx_start <= 1'b1;
                        rpt_state     <= RPT_WAIT;
                    end
                end

                RPT_WAIT: begin
                    if (!uart_tx_busy) begin
                        if (rpt_idx == 7'd75) begin
                            rpt_state <= RPT_IDLE;
                        end else begin
                            rpt_idx   <= rpt_idx + 1'b1;
                            rpt_state <= RPT_SEND;
                        end
                    end
                end

                default: begin
                    rpt_state <= RPT_IDLE;
                    rpt_idx   <= 7'd0;
                end

            endcase
        end
    end

    UART_TX #(
        .CLKS_PER_BIT(868)
    ) uart_tx_inst (
        .clk      (clk100mhz),
        .rst      (sys_rst),
        .tx_start (uart_tx_start),
        .tx_data  (uart_tx_byte),
        .tx       (uart_txd_out),
        .tx_busy  (uart_tx_busy)
    );

endmodule

// =============================================================================
// Simple synchronous FIFO for ARP/UDP source queues.
// Registered read data: rd_data updates on the rising edge where rd_en is high.
// =============================================================================
module sync_fifo_simple #(
    parameter DATA_WIDTH = 9,
    parameter ADDR_WIDTH = 8
) (
    input  wire                  clk,
    input  wire                  rst,

    input  wire [DATA_WIDTH-1:0] wr_data,
    input  wire                  wr_en,
    output wire                  full,

    output reg  [DATA_WIDTH-1:0] rd_data,
    input  wire                  rd_en,
    output wire                  empty
);

    localparam DEPTH = (1 << ADDR_WIDTH);

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_WIDTH-1:0] wr_ptr;
    reg [ADDR_WIDTH-1:0] rd_ptr;
    reg [ADDR_WIDTH:0]   count;

    assign empty = (count == 0);
    assign full  = (count == DEPTH);

    wire do_write = wr_en && !full;
    wire do_read  = rd_en && !empty;

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr  <= 0;
            rd_ptr  <= 0;
            count   <= 0;
            rd_data <= 0;
        end else begin
            if (do_write) begin
                mem[wr_ptr] <= wr_data;
                wr_ptr <= wr_ptr + 1'b1;
            end

            if (do_read) begin
                rd_data <= mem[rd_ptr];
                rd_ptr <= rd_ptr + 1'b1;
            end

            case ({do_write, do_read})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end

endmodule


// =============================================================================
// Frame-level ARP/UDP arbiter.
//
// Input word:  {last, data[7:0]}
// Output word: {is_udp, last, data[7:0]}
//
// Once a source wins, it owns the output until its LAST word is forwarded.
// If both sources are waiting at a frame boundary, arbitration is round-robin.
// =============================================================================
module tx_frame_arbiter (
    input  wire       clk,
    input  wire       rst,

    input  wire [8:0] arp_data,
    input  wire       arp_empty,
    output wire       arp_rd_en,

    input  wire [8:0] udp_data,
    input  wire       udp_empty,
    output wire       udp_rd_en,

    input  wire       out_full,
    output reg  [9:0] out_data,
    output reg        out_wr_en,

    input  wire       launch_full,
    output reg        launch_wr_en,
    output reg        launch_is_udp
);

    localparam SEL_NONE = 2'd0;
    localparam SEL_ARP  = 2'd1;
    localparam SEL_UDP  = 2'd2;

    localparam ST_IDLE    = 2'd0;
    localparam ST_POP     = 2'd1;
    localparam ST_CAPTURE = 2'd2;

    reg [1:0] state;
    reg [1:0] selected;
    reg       last_grant_udp;

    assign arp_rd_en =
        (state == ST_POP) && (selected == SEL_ARP) && !out_full;

    assign udp_rd_en =
        (state == ST_POP) && (selected == SEL_UDP) && !out_full;

    wire [8:0] selected_data =
        (selected == SEL_ARP) ? arp_data :
        (selected == SEL_UDP) ? udp_data :
                                9'h000;

    always @(posedge clk) begin
        out_wr_en    <= 1'b0;
        launch_wr_en <= 1'b0;

        if (rst) begin
            state          <= ST_IDLE;
            selected       <= SEL_NONE;
            last_grant_udp <= 1'b0;
            out_data       <= 10'h000;
            launch_wr_en   <= 1'b0;
            launch_is_udp  <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    selected <= SEL_NONE;

                    // Only commit a speculative launch when both descriptor
                    // and data paths have room.
                    if (!launch_full && !out_full) begin
                        if (!arp_empty && !udp_empty) begin
                            if (last_grant_udp) begin
                                selected      <= SEL_ARP;
                                launch_is_udp <= 1'b0;
                            end else begin
                                selected      <= SEL_UDP;
                                launch_is_udp <= 1'b1;
                            end
                            launch_wr_en <= 1'b1;
                            state <= ST_POP;
                        end else if (!arp_empty) begin
                            selected      <= SEL_ARP;
                            launch_is_udp <= 1'b0;
                            launch_wr_en  <= 1'b1;
                            state <= ST_POP;
                        end else if (!udp_empty) begin
                            selected      <= SEL_UDP;
                            launch_is_udp <= 1'b1;
                            launch_wr_en  <= 1'b1;
                            state <= ST_POP;
                        end
                    end
                end

                ST_POP: begin
                    // Source FIFO rd_en is asserted combinationally here.
                    // Its registered rd_data is available in ST_CAPTURE.
                    if (!out_full)
                        state <= ST_CAPTURE;
                end

                ST_CAPTURE: begin
                    if (!out_full) begin
                        out_data <= {
                            (selected == SEL_UDP),
                            selected_data[8],
                            selected_data[7:0]
                        };
                        out_wr_en <= 1'b1;

                        if (selected_data[8]) begin
                            last_grant_udp <= (selected == SEL_UDP);
                            selected <= SEL_NONE;
                            state <= ST_IDLE;
                        end else begin
                            // Do NOT arbitrate again; remain on this source.
                            state <= ST_POP;
                        end
                    end
                end

                default: begin
                    state <= ST_IDLE;
                    selected <= SEL_NONE;
                end
            endcase
        end
    end

endmodule

