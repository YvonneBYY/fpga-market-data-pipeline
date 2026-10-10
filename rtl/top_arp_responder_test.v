module top_arp_responder_test (
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

    output wire [3:0] led    // 0=mmcm_locked 1=phy_rst_n 2=arp_matched(arp_responder itself saw a matching request) 3=reply_sent
);

    // ---------------- Clocking / PHY reset (unchanged from Phase 2) ----------------
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

    // ---------------- Reset synchronizers ----------------
    wire sys_rst, tx_eth_rst, rx_eth_rst;
    sync_2ff #(.WIDTH(1)) sync_rst_sys   (.clk(clk100mhz), .rst(1'b0), .async_in(btn0), .sync_out(sys_rst));
    sync_2ff #(.WIDTH(1)) sync_rst_txeth (.clk(eth_tx_clk), .rst(1'b0), .async_in(btn0), .sync_out(tx_eth_rst));
    sync_2ff #(.WIDTH(1)) sync_rst_rxeth (.clk(eth_rx_clk), .rst(1'b0), .async_in(btn0), .sync_out(rx_eth_rst));

    // ---------------- MAC RX (eth_rx_clk domain) ----------------
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

    // DEBUG: did arp_responder ITSELF decide a matching request arrived,
    // independent of whether the CRC/TX chain downstream actually works -
    // a much more specific signal than generic RX activity, which lights
    // from ordinary ambient broadcast traffic regardless of any real match.
    reg arp_matched_sticky = 0;
    always @(posedge clk100mhz) begin
        if (sys_rst) arp_matched_sticky <= 0;
        else if (arp_tx_req) arp_matched_sticky <= 1;
    end

    // ---------------- ARP responder (clk100mhz domain) ----------------
    wire arp_tx_valid, arp_tx_last, arp_tx_req;
    wire [7:0] arp_tx_byte;

    arp_responder #(.OUR_IP({8'd169, 8'd254, 8'd89, 8'd52})) arp_inst (
        .clk(clk100mhz), .rst(sys_rst),
        .rx_data(sys_rx_data), .rx_data_valid(sys_rx_data_valid),
        .rx_frame_start(sys_rx_frame_start), .rx_frame_end(sys_rx_frame_end),
        .tx_valid(arp_tx_valid), .tx_byte(arp_tx_byte), .tx_last(arp_tx_last), .tx_req(arp_tx_req)
    );

    // ---------------- ARP reply framer (attaches CRC32) ----------------
    wire [8:0] tx_fifo_wr_data;
    wire       tx_fifo_wr_en;

    arp_reply_framer framer_inst (
        .clk(clk100mhz), .rst(sys_rst),
        .arp_tx_req(arp_tx_req), .arp_tx_valid(arp_tx_valid),
        .arp_tx_byte(arp_tx_byte), .arp_tx_last(arp_tx_last),
        .fifo_wr_data(tx_fifo_wr_data), .fifo_wr_en(tx_fifo_wr_en)
    );

    // ---------------- TX CDC FIFO (clk100mhz -> eth_tx_clk) ----------------
    wire tx_fifo_full, tx_fifo_empty;
    wire [8:0] tx_fifo_rd_data;
    wire tx_fifo_rd_en;
    async_fifo #(.DATA_WIDTH(9), .ADDR_WIDTH(7)) tx_frame_fifo (
        .wr_clk(clk100mhz), .wr_rst(sys_rst), .wr_data(tx_fifo_wr_data), .wr_en(tx_fifo_wr_en), .full(tx_fifo_full),
        .rd_clk(eth_tx_clk), .rd_rst(tx_eth_rst), .rd_data(tx_fifo_rd_data), .rd_en(tx_fifo_rd_en), .empty(tx_fifo_empty)
    );

    // ---------------- TX local frame buffer + driver (eth_tx_clk domain) ----------------
    // Exact copy of the proven prefetch-buffer architecture from Phase 2's
    // TX-driver fix - drains the whole frame into local RAM before starting
    // the MAC, so there is zero risk of a mid-frame TX_EN gap.
    localparam TX_LOAD_WAIT = 3'd0, TX_LOAD_POP = 3'd1, TX_LOAD_CAPTURE = 3'd2,
               TX_START_MAC = 3'd3, TX_WAIT_READY = 3'd4, TX_SEND = 3'd5, TX_WAIT_DONE = 3'd6;
    reg [2:0] tx_state = TX_LOAD_WAIT;

    reg [8:0] tx_local_buf [0:127];
    reg [6:0] load_idx = 0;
    reg [6:0] send_idx = 0;

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

    assign led[0] = mmcm_locked;
    assign led[1] = phy_rst_n;
    assign led[2] = arp_matched_sticky;
    assign led[3] = frame_sent_sticky;

endmodule