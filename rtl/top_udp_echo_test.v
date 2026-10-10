module top_udp_echo_test (
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

    output wire [3:0] led,   // 0=mmcm_locked 1=phy_rst_n 2=arp_matched 3=frame_actually_sent

    // DEBUG: raw echo of exactly what udp_tx_framer writes into the shared
    // TX FIFO - lets a hex-read script directly compare against a
    // simultaneous Wireshark capture, same technique that found the
    // frame_end timing bug during ARP debugging
    output wire uart_txd_out
);

    // ---------------- Clocking / PHY reset (unchanged from Phase 2/3) ----------------
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

    // ---------------- ARP responder (unchanged from Phase 3) ----------------
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

    // ---------------- IPv4/UDP RX parser (Phase 4), watching the SAME byte
    // stream as arp_responder in parallel - each acts only on its own EtherType ----------------
    wire [31:0] udp_rx_src_ip, udp_rx_dst_ip;
    wire [47:0] udp_rx_src_mac;
    wire [15:0] udp_rx_src_port, udp_rx_dst_port, udp_rx_udp_length;
    wire        udp_rx_payload_valid, udp_rx_payload_last, udp_rx_malformed;
    wire [7:0]  udp_rx_payload_data;

    ip_udp_rx_parser udp_rx_inst (
        .clk(clk100mhz), .rst(sys_rst),
        .rx_data(sys_rx_data), .rx_data_valid(sys_rx_data_valid),
        .rx_frame_start(sys_rx_frame_start), .rx_frame_end(sys_rx_frame_end),
        .src_ip(udp_rx_src_ip), .dst_ip(udp_rx_dst_ip), .src_mac(udp_rx_src_mac),
        .src_port(udp_rx_src_port), .dst_port(udp_rx_dst_port), .udp_length(udp_rx_udp_length),
        .payload_valid(udp_rx_payload_valid), .payload_data(udp_rx_payload_data),
        .payload_last(udp_rx_payload_last), .packet_malformed(udp_rx_malformed)
    );

    // ---------------- UDP echo glue (Phase 4 hardware test behavior) ----------------
    wire        echo_tx_start, echo_tx_data_valid, echo_tx_last;
    wire [47:0] echo_tx_dest_mac;
    wire [31:0] echo_tx_dest_ip;
    wire [15:0] echo_tx_src_port, echo_tx_dst_port;
    wire [7:0]  echo_tx_data;

    udp_echo_responder echo_inst (
        .clk(clk100mhz), .rst(sys_rst),
        .rx_src_mac(udp_rx_src_mac), .rx_src_ip(udp_rx_src_ip), .rx_src_port(udp_rx_src_port),
        .rx_payload_valid(udp_rx_payload_valid), .rx_payload_data(udp_rx_payload_data),
        .rx_payload_last(udp_rx_payload_last),
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

    // ---------------- Shared TX path ----------------
    // NOTE: naive OR of the two framers' write streams - correct as long as
    // an ARP reply and a UDP echo never happen to transmit in the exact
    // same cycle. Acceptable for this hardware bring-up test; a real
    // arbiter (grant one framer exclusive access to the shared FIFO write
    // port at a time) would be needed before this design carries real,
    // concurrent multi-protocol traffic.
    wire [8:0] tx_fifo_wr_data = arp_fifo_wr_en ? arp_fifo_wr_data : udp_fifo_wr_data;
    wire       tx_fifo_wr_en   = arp_fifo_wr_en || udp_fifo_wr_en;

    wire tx_fifo_full, tx_fifo_empty;
    wire [8:0] tx_fifo_rd_data;
    wire tx_fifo_rd_en;
    async_fifo #(.DATA_WIDTH(9), .ADDR_WIDTH(8)) tx_frame_fifo (
        .wr_clk(clk100mhz), .wr_rst(sys_rst), .wr_data(tx_fifo_wr_data), .wr_en(tx_fifo_wr_en), .full(tx_fifo_full),
        .rd_clk(eth_tx_clk), .rd_rst(tx_eth_rst), .rd_data(tx_fifo_rd_data), .rd_en(tx_fifo_rd_en), .empty(tx_fifo_empty)
    );

    // ---------------- TX local frame buffer + driver (eth_tx_clk domain) ----------------
    // Exact copy of the proven prefetch-buffer architecture from Phase 2/3.
    localparam TX_LOAD_WAIT = 3'd0, TX_LOAD_POP = 3'd1, TX_LOAD_CAPTURE = 3'd2,
               TX_START_MAC = 3'd3, TX_WAIT_READY = 3'd4, TX_SEND = 3'd5, TX_WAIT_DONE = 3'd6;
    reg [2:0] tx_state = TX_LOAD_WAIT;

    reg [8:0] tx_local_buf [0:255];
    reg [7:0] load_idx = 0;
    reg [7:0] send_idx = 0;

    reg        mac_tx_start;
    wire [7:0] mac_tx_data;
    wire       mac_tx_data_valid, mac_tx_last, mac_tx_ready, mac_tx_busy;

    assign tx_fifo_rd_en = (tx_state == TX_LOAD_POP);
    assign mac_tx_data = tx_local_buf[send_idx][7:0];
    assign mac_tx_last = tx_local_buf[send_idx][8];
    assign mac_tx_data_valid =
        ((tx_state == TX_WAIT_READY) || (tx_state == TX_SEND)) && mac_tx_ready;

    eth_mac_tx_nibble mac_tx_inst (
        .phy_tx_clk(eth_tx_clk), .rst(tx_eth_rst),
        .tx_start(mac_tx_start), .tx_data(mac_tx_data),
        .tx_data_valid(mac_tx_data_valid), .tx_last(mac_tx_last),
        .phy_txd(eth_txd), .phy_tx_en(eth_tx_en),
        .tx_ready(mac_tx_ready), .tx_busy(mac_tx_busy)
    );

    always @(posedge eth_tx_clk) begin
        mac_tx_start <= 1'b0;
        if (tx_eth_rst) begin
            tx_state <= TX_LOAD_WAIT;
            load_idx <= 0;
            send_idx <= 0;
        end else begin
            case (tx_state)
                TX_LOAD_WAIT: if (!tx_fifo_empty) tx_state <= TX_LOAD_POP;
                TX_LOAD_POP:  tx_state <= TX_LOAD_CAPTURE;
                TX_LOAD_CAPTURE: begin
                    tx_local_buf[load_idx] <= tx_fifo_rd_data;
                    if (tx_fifo_rd_data[8]) begin
                        send_idx <= 0;
                        tx_state <= TX_START_MAC;
                    end else begin
                        load_idx <= load_idx + 1'b1;
                        tx_state <= TX_LOAD_WAIT;
                    end
                end
                TX_START_MAC: begin
                    mac_tx_start <= 1'b1;
                    tx_state <= TX_WAIT_READY;
                end
                TX_WAIT_READY: if (mac_tx_ready) begin
                    if (tx_local_buf[send_idx][8]) tx_state <= TX_WAIT_DONE;
                    else begin send_idx <= send_idx + 1'b1; tx_state <= TX_SEND; end
                end
                TX_SEND: if (mac_tx_ready) begin
                    if (tx_local_buf[send_idx][8]) tx_state <= TX_WAIT_DONE;
                    else send_idx <= send_idx + 1'b1;
                end
                TX_WAIT_DONE: if (!mac_tx_busy) begin
                    load_idx <= 0;
                    send_idx <= 0;
                    tx_state <= TX_LOAD_WAIT;
                end
                default: begin
                    load_idx <= 0;
                    send_idx <= 0;
                    tx_state <= TX_LOAD_WAIT;
                end
            endcase
        end
    end

    // Genuine TX-completion tracking (unlike udp_tx_req, which only proves
    // ip_udp_tx_builder STARTED - this proves a frame actually left
    // eth_mac_tx_nibble, same pattern as every prior real-hardware test in
    // this project). Fires for ANY frame (ARP reply or UDP echo).
    reg frame_sent_sticky = 0;
    reg mac_tx_busy_prev = 0;
    always @(posedge eth_tx_clk) begin
        if (tx_eth_rst) begin
            frame_sent_sticky <= 0;
            mac_tx_busy_prev  <= 0;
        end else begin
            mac_tx_busy_prev <= mac_tx_busy;
            if (mac_tx_busy_prev && !mac_tx_busy) frame_sent_sticky <= 1;
        end
    end

    // UDP-specific completion tracking: frame_sent_sticky alone can't tell
    // us whether a completion was the ARP reply or the UDP echo, since both
    // share the same TX driver. Cross udp_tx_req into eth_tx_clk via
    // toggle-synchronization (a plain 2FF sync would risk missing a
    // single-cycle 100MHz pulse in the 4x-slower 25MHz domain), then only
    // latch completion if it follows a UDP request specifically.
    reg udp_pending_toggle = 0;
    always @(posedge clk100mhz) begin
        if (sys_rst) udp_pending_toggle <= 0;
        else if (udp_tx_req) udp_pending_toggle <= ~udp_pending_toggle;
    end

    wire udp_pending_toggle_sync;
    sync_2ff #(.WIDTH(1)) sync_udp_pending (
        .clk(eth_tx_clk), .rst(tx_eth_rst), .async_in(udp_pending_toggle), .sync_out(udp_pending_toggle_sync));

    reg udp_pending_toggle_sync_prev;
    always @(posedge eth_tx_clk) begin
        if (tx_eth_rst) udp_pending_toggle_sync_prev <= 0;
        else udp_pending_toggle_sync_prev <= udp_pending_toggle_sync;
    end
    wire udp_req_pulse_txclk = (udp_pending_toggle_sync != udp_pending_toggle_sync_prev);

    reg udp_frame_pending = 0;
    reg udp_echo_confirmed_sticky = 0;
    always @(posedge eth_tx_clk) begin
        if (tx_eth_rst) begin
            udp_frame_pending <= 0;
            udp_echo_confirmed_sticky <= 0;
        end else begin
            if (udp_req_pulse_txclk) udp_frame_pending <= 1;
            else if (mac_tx_busy_prev && !mac_tx_busy) begin
                udp_frame_pending <= 0;
                if (udp_frame_pending) udp_echo_confirmed_sticky <= 1;
            end
        end
    end

    assign led[0] = mmcm_locked;
    assign led[1] = phy_rst_n;
    assign led[2] = arp_matched_sticky;
    assign led[3] = udp_echo_confirmed_sticky;

    // ---------------- DEBUG: raw dump of the SHARED sys_rx_data stream
    // (the exact same wires both arp_responder and ip_udp_rx_parser read),
    // with no processing/interpretation at all - lets us count byte offsets
    // by eye against a Wireshark dissection of the same real frame, the
    // same technique that found the real frame_end timing bug in Phase 3.
    // Marker 0x9E once per frame_start, then the first 48 raw bytes exactly
    // as they arrive.
    localparam RAWDUMP_LEN = 48;
    reg        raw_dumping;
    reg [5:0]  raw_dump_count;
    reg        raw_marker_pending;

    always @(posedge clk100mhz) begin
        if (sys_rst) begin
            raw_dumping <= 0;
            raw_dump_count <= 0;
            raw_marker_pending <= 0;
        end else begin
            raw_marker_pending <= 0;
            if (sys_rx_frame_start) begin
                raw_dumping <= 1;
                raw_dump_count <= 0;
                raw_marker_pending <= 1;
            end else if (raw_dumping && sys_rx_data_valid) begin
                if (raw_dump_count == RAWDUMP_LEN - 1) raw_dumping <= 0;
                raw_dump_count <= raw_dump_count + 1;
            end
        end
    end

    wire raw_byte_now = raw_dumping && sys_rx_data_valid && (raw_dump_count < RAWDUMP_LEN);

    wire [8:0] dbg_wr_data = raw_marker_pending ? {1'b0, 8'h9E} :
                              raw_byte_now       ? {1'b0, sys_rx_data} :
                              udp_fifo_wr_en      ? udp_fifo_wr_data : 9'h000;
    wire dbg_wr_en = raw_marker_pending || raw_byte_now || udp_fifo_wr_en;

    wire [8:0] dbg_fifo_rd_data;
    wire       dbg_fifo_empty, dbg_fifo_full, dbg_fifo_rd_en;
    async_fifo #(.DATA_WIDTH(9), .ADDR_WIDTH(9)) dbg_uart_fifo (
        .wr_clk(clk100mhz), .wr_rst(sys_rst), .wr_data(dbg_wr_data), .wr_en(dbg_wr_en), .full(dbg_fifo_full),
        .rd_clk(clk100mhz), .rd_rst(sys_rst), .rd_data(dbg_fifo_rd_data), .rd_en(dbg_fifo_rd_en), .empty(dbg_fifo_empty)
    );

    localparam RD_IDLE = 0, RD_POP = 1, RD_CAPTURE = 2, RD_SEND = 3;
    reg [1:0]  dbg_rd_state = RD_IDLE;
    reg        dbg_uart_tx_start;
    reg  [7:0] dbg_uart_tx_byte;
    wire       dbg_uart_tx_busy;

    assign dbg_fifo_rd_en = (dbg_rd_state == RD_POP);

    UART_TX #(.CLKS_PER_BIT(868)) uart_tx_dbg_inst (
        .clk(clk100mhz), .rst(sys_rst),
        .tx_start(dbg_uart_tx_start), .tx_data(dbg_uart_tx_byte),
        .tx(uart_txd_out), .tx_busy(dbg_uart_tx_busy)
    );

    always @(posedge clk100mhz) begin
        dbg_uart_tx_start <= 0;
        if (sys_rst) begin
            dbg_rd_state <= RD_IDLE;
        end else begin
            case (dbg_rd_state)
                RD_IDLE: if (!dbg_fifo_empty && !dbg_uart_tx_busy) dbg_rd_state <= RD_POP;
                RD_POP:  dbg_rd_state <= RD_CAPTURE;
                RD_CAPTURE: begin
                    // dbg_fifo_rd_data[7:0] = the actual byte; bit 8 (last)
                    // isn't echoed separately here to keep the UART stream
                    // simple - the LAST 4 bytes of any run are always the CRC.
                    dbg_uart_tx_byte  <= dbg_fifo_rd_data[7:0];
                    dbg_uart_tx_start <= 1;
                    dbg_rd_state <= RD_SEND;
                end
                RD_SEND: if (!dbg_uart_tx_busy) dbg_rd_state <= RD_IDLE;
                default: dbg_rd_state <= RD_IDLE;
            endcase
        end
    end

endmodule