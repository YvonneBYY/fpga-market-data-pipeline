module top_eth_loopback_test (
    input  wire clk100mhz,
    input  wire btn0,             // reset
    input  wire btn1,             // "send fixed test frame"
    input  wire btn2,             // "manually re-trigger loopback enable"

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

    // MDIO management pins
    output wire eth_mdc,
    inout  wire eth_mdio,

    // UART out to laptop - used to echo whatever comes back through loopback
    output wire uart_txd_out,

    output wire [3:0] led,     // 0=mmcm_locked 1=phy_rst_n 2=frame_sent 3=frame_received (LOOPBACK WORKED)
    output wire led0_r,        // loopback_enabled_sticky
    output wire led0_g,        // DEBUG: eth_rx_clk activity (toggles even after loopback engages?)
    output wire led0_b         // DEBUG: bmcr_readback_matches_sticky (write actually took effect on PHY)
);

    localparam HEADER_LEN      = 7'd14;
    localparam PAYLOAD_LEN     = 7'd13;   // "LOOPBACK TEST"
    localparam PAD_MIN_PAYLOAD = 7'd46;

    // ---------------- Clocking / PHY reset ----------------
    wire clk_out1, mmcm_locked;
    clk_wiz_0 clk_wiz_inst (
        .clk_in1  (clk100mhz),
        .clk_out1 (clk_out1),
        .reset    (1'b0),
        .locked   (mmcm_locked)
    );
    assign eth_ref_clk = clk_out1;

    reg [23:0] rst_counter = 0;
    reg phy_rst_n = 0;
    always @(posedge clk_out1) begin
        if (btn0 || !mmcm_locked) begin
            rst_counter <= 0;
            phy_rst_n   <= 0;
        end
        else if (rst_counter < 24'hFFFFFF) begin
            rst_counter <= rst_counter + 1;
            phy_rst_n   <= 0;
        end
        else begin
            phy_rst_n <= 1;
        end
    end
    assign eth_rstn = phy_rst_n;

    // DEBUG: does eth_rx_clk keep toggling once forced loopback engages?
    // (a stalled RX_CLK would explain "nothing at all", including ambient
    // traffic disappearing, since eth_mac_rx_nibble's whole clock domain
    // would freeze)
    reg [23:0] rx_clk_counter = 0;
    always @(posedge eth_rx_clk) begin
        rx_clk_counter <= rx_clk_counter + 1'b1;
    end
    assign led0_g = rx_clk_counter[23];

    // ---------------- Reset synchronizers ----------------
    wire sys_rst, tx_eth_rst, rx_eth_rst;

    sync_2ff #(.WIDTH(1)) sync_rst_sys (
        .clk(clk100mhz), .rst(1'b0), .async_in(btn0), .sync_out(sys_rst));
    sync_2ff #(.WIDTH(1)) sync_rst_txeth (
        .clk(eth_tx_clk), .rst(1'b0), .async_in(btn0), .sync_out(tx_eth_rst));
    sync_2ff #(.WIDTH(1)) sync_rst_rxeth (
        .clk(eth_rx_clk), .rst(1'b0), .async_in(btn0), .sync_out(rx_eth_rst));

    // ---------------- btn1: debounce + one-shot (send test frame) ----------------
    wire btn1_sync;
    sync_2ff #(.WIDTH(1)) sync_btn1 (
        .clk(clk100mhz), .rst(sys_rst), .async_in(btn1), .sync_out(btn1_sync));

    reg [15:0] debounce_prescaler = 0;
    wire sample_tick = (debounce_prescaler == 16'd50000);
    always @(posedge clk100mhz) begin
        if (sys_rst || sample_tick) debounce_prescaler <= 0;
        else debounce_prescaler <= debounce_prescaler + 1;
    end

    reg [7:0] btn1_shift = 0;
    always @(posedge clk100mhz) begin
        if (sys_rst) btn1_shift <= 0;
        else if (sample_tick) btn1_shift <= {btn1_shift[6:0], btn1_sync};
    end
    wire btn1_debounced = &btn1_shift;
    reg btn1_debounced_prev = 0;
    always @(posedge clk100mhz) begin
        if (sys_rst) btn1_debounced_prev <= 0;
        else btn1_debounced_prev <= btn1_debounced;
    end
    wire tx_trigger = btn1_debounced && !btn1_debounced_prev;

    // ---------------- btn2: debounce + one-shot (manual loopback re-enable) ----------------
    wire btn2_sync;
    sync_2ff #(.WIDTH(1)) sync_btn2 (
        .clk(clk100mhz), .rst(sys_rst), .async_in(btn2), .sync_out(btn2_sync));
    reg [7:0] btn2_shift = 0;
    always @(posedge clk100mhz) begin
        if (sys_rst) btn2_shift <= 0;
        else if (sample_tick) btn2_shift <= {btn2_shift[6:0], btn2_sync};
    end
    wire btn2_debounced = &btn2_shift;
    reg btn2_debounced_prev = 0;
    always @(posedge clk100mhz) begin
        if (sys_rst) btn2_debounced_prev <= 0;
        else btn2_debounced_prev <= btn2_debounced;
    end
    wire manual_loopback_trigger = btn2_debounced && !btn2_debounced_prev;

    // ---------------- MDIO controller + tri-state buffer ----------------
    wire mdio_out, mdio_oe, mdio_in;
    assign eth_mdio = mdio_oe ? mdio_out : 1'bz;
    assign mdio_in  = eth_mdio;

    reg  mdio_start, mdio_op_is_write;
    reg  [4:0] mdio_reg_addr;
    reg  [15:0] mdio_write_data;
    wire [15:0] mdio_read_data;
    wire mdio_busy, mdio_done;

    mdio_controller mdio_inst (
        .clk (clk100mhz), .rst (sys_rst),
        .start (mdio_start), .op_is_write (mdio_op_is_write),
        .phy_addr (5'd1), .reg_addr (mdio_reg_addr),
        .write_data (mdio_write_data),
        .mdc (eth_mdc), .mdio_out (mdio_out), .mdio_oe (mdio_oe), .mdio_in (mdio_in),
        .read_data (mdio_read_data), .busy (mdio_busy), .done (mdio_done)
    );

    // ---------------- Auto-trigger loopback-enable once PHY reset completes ----------------
    wire phy_rst_n_sync;
    sync_2ff #(.WIDTH(1)) sync_phyrstn (
        .clk(clk100mhz), .rst(sys_rst), .async_in(phy_rst_n), .sync_out(phy_rst_n_sync));
    reg phy_rst_n_sync_prev = 0;
    always @(posedge clk100mhz) begin
        if (sys_rst) phy_rst_n_sync_prev <= 0;
        else phy_rst_n_sync_prev <= phy_rst_n_sync;
    end
    wire phy_ready_pulse = phy_rst_n_sync && !phy_rst_n_sync_prev;

    // ---------------- Loopback-enable sequencer: force AutoNeg off, 100Mb,
    // full duplex, Loopback on - a fully explicit known-good BMCR value
    // rather than layering loopback on top of live auto-negotiation, THEN
    // read BMCR back and report it over UART to confirm the PHY actually
    // latched the write (mdio_done only confirms the transaction protocol
    // completed, not that the PHY accepted the value) ----------------
    localparam LB_IDLE = 0, LB_READ_WAIT = 1, LB_WRITE = 2, LB_WRITE_WAIT = 3,
               LB_VERIFY_READ = 4, LB_VERIFY_WAIT = 5,
               LB_SEND0 = 6, LB_SEND0_WAIT = 7, LB_SEND1 = 8, LB_SEND1_WAIT = 9,
               LB_DONE = 10;
    reg [3:0] lb_state = LB_IDLE;
    reg [15:0] bmcr_value;
    reg [15:0] bmcr_readback;
    reg lb_uart_tx_start;
    reg [7:0] lb_uart_tx_byte;

    always @(posedge clk100mhz) begin
        mdio_start <= 0;
        lb_uart_tx_start <= 0;
        if (sys_rst) begin
            lb_state <= LB_IDLE;
        end else begin
            case (lb_state)
                LB_IDLE: begin
                    if (manual_loopback_trigger) begin
                        mdio_reg_addr    <= 5'd0;
                        mdio_op_is_write <= 0;
                        mdio_start <= 1;
                        lb_state <= LB_READ_WAIT;
                    end
                end
                LB_READ_WAIT: if (mdio_done) begin
                    bmcr_value <= mdio_read_data;
                    lb_state <= LB_WRITE;
                end
                LB_WRITE: begin
                    mdio_reg_addr    <= 5'd0;
                    mdio_op_is_write <= 1;
                    // Forced: Loopback=1, Speed=100Mb, AutoNeg=0, Full Duplex=1,
                    // everything else 0 - explicit, unambiguous config rather
                    // than layering loopback on top of whatever AutoNeg left behind
                    mdio_write_data  <= 16'h6100;
                    mdio_start <= 1;
                    lb_state <= LB_WRITE_WAIT;
                end
                LB_WRITE_WAIT: if (mdio_done) lb_state <= LB_VERIFY_READ;

                LB_VERIFY_READ: begin
                    mdio_reg_addr    <= 5'd0;
                    mdio_op_is_write <= 0;
                    mdio_start <= 1;
                    lb_state <= LB_VERIFY_WAIT;
                end
                LB_VERIFY_WAIT: if (mdio_done) begin
                    bmcr_readback <= mdio_read_data;
                    lb_state <= LB_SEND0;
                end

                LB_SEND0: if (!uart_tx_busy) begin
                    lb_uart_tx_byte  <= bmcr_readback[15:8];
                    lb_uart_tx_start <= 1;
                    lb_state <= LB_SEND0_WAIT;
                end
                LB_SEND0_WAIT: if (!uart_tx_busy) lb_state <= LB_SEND1;

                LB_SEND1: if (!uart_tx_busy) begin
                    lb_uart_tx_byte  <= bmcr_readback[7:0];
                    lb_uart_tx_start <= 1;
                    lb_state <= LB_SEND1_WAIT;
                end
                LB_SEND1_WAIT: if (!uart_tx_busy) lb_state <= LB_DONE;

                LB_DONE: lb_state <= LB_IDLE;
                default: lb_state <= LB_IDLE;
            endcase
        end
    end

    reg loopback_enabled_sticky = 0;
    always @(posedge clk100mhz) begin
        if (sys_rst) loopback_enabled_sticky <= 0;
        else if (lb_state == LB_DONE) loopback_enabled_sticky <= 1;
    end
    assign led0_r = loopback_enabled_sticky;

    // DEBUG: did the PHY actually latch 0x6100, confirmed via readback?
    reg bmcr_write_verified_sticky = 0;
    always @(posedge clk100mhz) begin
        if (sys_rst) bmcr_write_verified_sticky <= 0;
        else if (lb_state == LB_SEND0 && bmcr_readback == 16'h6100)
            bmcr_write_verified_sticky <= 1;
    end
    assign led0_b = bmcr_write_verified_sticky;

    wire lb_uart_active = (lb_state != LB_IDLE) && (lb_state != LB_DONE);

    // ---------------- CRC32 generator ----------------
    wire [31:0] crc_result;
    reg  crc_start, crc_data_valid;
    reg  [7:0] crc_data;
    crc32_gen crc_gen_inst (
        .clk(clk100mhz), .rst(sys_rst),
        .start(crc_start), .data(crc_data), .data_valid(crc_data_valid),
        .crc_reg(crc_result)
    );
    wire [31:0] crc_to_send = ~crc_result;

    // ---------------- Frame builder (fixed "LOOPBACK TEST" payload) ----------------
    localparam TB_IDLE = 0, TB_LATCH = 1, TB_BUILD = 2, TB_CRC_SETTLE = 3,
               TB_CRC0 = 4, TB_CRC1 = 5, TB_CRC2 = 6, TB_CRC3 = 7;
    reg [3:0] tb_state = TB_IDLE;
    reg [6:0] byte_idx = 0;
    reg [6:0] total_len_before_crc = 0;

    wire [7:0] payload_byte_at_idx =
        (byte_idx == 14) ? 8'h4C :  // L
        (byte_idx == 15) ? 8'h4F :  // O
        (byte_idx == 16) ? 8'h4F :  // O
        (byte_idx == 17) ? 8'h50 :  // P
        (byte_idx == 18) ? 8'h42 :  // B
        (byte_idx == 19) ? 8'h41 :  // A
        (byte_idx == 20) ? 8'h43 :  // C
        (byte_idx == 21) ? 8'h4B :  // K
        (byte_idx == 22) ? 8'h20 :  // (space)
        (byte_idx == 23) ? 8'h54 :  // T
        (byte_idx == 24) ? 8'h45 :  // E
        (byte_idx == 25) ? 8'h53 :  // S
        (byte_idx == 26) ? 8'h54 :  // T
        8'h00;

    wire [7:0] current_frame_byte =
        (byte_idx < 7'd6)  ? 8'hFF :
        (byte_idx == 7'd6) ? 8'h02 :
        (byte_idx == 7'd7) ? 8'h00 :
        (byte_idx == 7'd8) ? 8'h00 :
        (byte_idx == 7'd9) ? 8'h00 :
        (byte_idx == 7'd10)? 8'h00 :
        (byte_idx == 7'd11)? 8'h01 :
        (byte_idx == 7'd12)? 8'h88 :
        (byte_idx == 7'd13)? 8'hB5 :
        payload_byte_at_idx;

    always @(posedge clk100mhz) begin
        if (sys_rst) begin
            tb_state <= TB_IDLE;
            byte_idx <= 0;
            crc_start <= 0;
            crc_data_valid <= 0;
            total_len_before_crc <= 0;
        end else begin
            crc_start <= 0;
            crc_data_valid <= 0;
            case (tb_state)
                TB_IDLE: begin
                    byte_idx <= 0;
                    if (tx_trigger) tb_state <= TB_LATCH;
                end
                TB_LATCH: begin
                    total_len_before_crc <= HEADER_LEN + PAD_MIN_PAYLOAD; // fixed payload < min, always padded
                    crc_start <= 1;
                    byte_idx  <= 0;
                    tb_state  <= TB_BUILD;
                end
                TB_BUILD: begin
                    crc_data       <= current_frame_byte;
                    crc_data_valid <= 1;
                    byte_idx       <= byte_idx + 1;
                    if (byte_idx == total_len_before_crc - 1)
                        tb_state <= TB_CRC_SETTLE;
                end
                TB_CRC_SETTLE: tb_state <= TB_CRC0;
                TB_CRC0:       tb_state <= TB_CRC1;
                TB_CRC1:       tb_state <= TB_CRC2;
                TB_CRC2:       tb_state <= TB_CRC3;
                TB_CRC3:       tb_state <= TB_IDLE;
                default: tb_state <= TB_IDLE;
            endcase
        end
    end

    wire [7:0] tx_fifo_byte =
        (tb_state == TB_BUILD) ? current_frame_byte :
        (tb_state == TB_CRC0)  ? crc_to_send[7:0]    :
        (tb_state == TB_CRC1)  ? crc_to_send[15:8]   :
        (tb_state == TB_CRC2)  ? crc_to_send[23:16]  :
        (tb_state == TB_CRC3)  ? crc_to_send[31:24]  :
        8'h00;
    wire tx_fifo_last  = (tb_state == TB_CRC3);
    wire tx_fifo_wr_en = (tb_state == TB_BUILD) || (tb_state == TB_CRC0) ||
                         (tb_state == TB_CRC1)  || (tb_state == TB_CRC2) ||
                         (tb_state == TB_CRC3);
    wire [8:0] tx_fifo_wr_data = {tx_fifo_last, tx_fifo_byte};

    // ---------------- TX CDC FIFO (clk100mhz -> eth_tx_clk) ----------------
    wire tx_fifo_full, tx_fifo_empty;
    wire [8:0] tx_fifo_rd_data;
    wire tx_fifo_rd_en;
    async_fifo #(.DATA_WIDTH(9), .ADDR_WIDTH(7)) tx_frame_fifo (
        .wr_clk(clk100mhz), .wr_rst(sys_rst), .wr_data(tx_fifo_wr_data), .wr_en(tx_fifo_wr_en), .full(tx_fifo_full),
        .rd_clk(eth_tx_clk), .rd_rst(tx_eth_rst), .rd_data(tx_fifo_rd_data), .rd_en(tx_fifo_rd_en), .empty(tx_fifo_empty)
    );

    // ---------------- TX local frame buffer + driver (eth_tx_clk domain) ----------------
    //
    // The async FIFO is intentionally drained into a local buffer BEFORE the MAC
    // starts transmitting. Once TX_EN is asserted, 100-Mb/s MII needs one nibble
    // every eth_tx_clk cycle. Prefetching the whole frame lets us feed the MAC
    // continuously without waiting on the async FIFO between bytes.

    localparam TX_LOAD_WAIT    = 3'd0,
               TX_LOAD_POP     = 3'd1,
               TX_LOAD_CAPTURE = 3'd2,
               TX_START_MAC    = 3'd3,
               TX_WAIT_READY   = 3'd4,
               TX_SEND         = 3'd5,
               TX_WAIT_DONE    = 3'd6;

    reg [2:0] tx_state = TX_LOAD_WAIT;

    // 9 bits per entry: {last, data[7:0]}.
    // The current fixed test frame is 64 bytes including FCS, so 128 entries
    // leaves plenty of margin.
    reg [8:0] tx_local_buf [0:127];
    reg [6:0] load_idx = 0;
    reg [6:0] send_idx = 0;

    reg  mac_tx_start;
    wire [7:0] mac_tx_data;
    wire       mac_tx_data_valid;
    wire       mac_tx_last;
    wire       mac_tx_ready;
    wire       mac_tx_busy;

    // The FIFO's registered rd_data becomes valid after the TX_LOAD_POP cycle,
    // so capture it in TX_LOAD_CAPTURE.
    assign tx_fifo_rd_en = (tx_state == TX_LOAD_POP);

    // The frame bytes are already local by the time transmission starts.
    assign mac_tx_data = tx_local_buf[send_idx][7:0];
    assign mac_tx_last = tx_local_buf[send_idx][8];

    // IMPORTANT: also present the FIRST data byte while we are still in
    // TX_WAIT_READY. eth_mac_tx_nibble raises tx_ready while D5 is being
    // serialized, so accepting the first byte here keeps TX_EN continuous
    // across the SFD -> destination-MAC boundary.
    assign mac_tx_data_valid =
        ((tx_state == TX_WAIT_READY) || (tx_state == TX_SEND)) && mac_tx_ready;

    eth_mac_tx_nibble mac_tx_inst (
        .phy_tx_clk(eth_tx_clk), .rst(tx_eth_rst),
        .tx_start(mac_tx_start),
        .tx_data(mac_tx_data),
        .tx_data_valid(mac_tx_data_valid),
        .tx_last(mac_tx_last),
        .phy_txd(eth_txd), .phy_tx_en(eth_tx_en),
        .tx_ready(mac_tx_ready), .tx_busy(mac_tx_busy)
    );

    always @(posedge eth_tx_clk) begin
        // tx_start is a one-cycle pulse.
        mac_tx_start <= 1'b0;

        if (tx_eth_rst) begin
            tx_state     <= TX_LOAD_WAIT;
            load_idx     <= 0;
            send_idx     <= 0;
            mac_tx_start <= 0;
        end else begin
            case (tx_state)
                // Wait for at least one word to arrive from the frame builder.
                TX_LOAD_WAIT: begin
                    if (!tx_fifo_empty)
                        tx_state <= TX_LOAD_POP;
                end

                // rd_en is high for this cycle.
                TX_LOAD_POP: begin
                    tx_state <= TX_LOAD_CAPTURE;
                end

                // Capture the word returned by the async FIFO.
                TX_LOAD_CAPTURE: begin
                    tx_local_buf[load_idx] <= tx_fifo_rd_data;

                    if (tx_fifo_rd_data[8]) begin
                        // Entire frame is now local.
                        send_idx <= 0;
                        tx_state <= TX_START_MAC;
                    end else begin
                        load_idx <= load_idx + 1'b1;
                        // Do not assume the next FIFO word has arrived yet.
                        tx_state <= TX_LOAD_WAIT;
                    end
                end

                // Request preamble/SFD transmission.
                TX_START_MAC: begin
                    mac_tx_start <= 1'b1;
                    tx_state <= TX_WAIT_READY;
                end

                // mac_tx_data_valid is combinationally asserted as soon as
                // mac_tx_ready goes high, so the first frame byte is accepted
                // while the SFD is still finishing.
                TX_WAIT_READY: begin
                    if (mac_tx_ready) begin
                        if (tx_local_buf[send_idx][8]) begin
                            tx_state <= TX_WAIT_DONE;
                        end else begin
                            send_idx <= send_idx + 1'b1;
                            tx_state <= TX_SEND;
                        end
                    end
                end

                // For every subsequent tx_ready pulse, the next local byte is
                // already available. This sustains one byte every two MII clocks.
                TX_SEND: begin
                    if (mac_tx_ready) begin
                        if (tx_local_buf[send_idx][8]) begin
                            tx_state <= TX_WAIT_DONE;
                        end else begin
                            send_idx <= send_idx + 1'b1;
                        end
                    end
                end

                // The MAC keeps tx_busy high through the IFG.
                TX_WAIT_DONE: begin
                    if (!mac_tx_busy) begin
                        load_idx <= 0;
                        send_idx <= 0;
                        tx_state <= TX_LOAD_WAIT;
                    end
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
            if (mac_tx_busy_prev && !mac_tx_busy)
                frame_sent_sticky <= 1;
        end
    end

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

    reg frame_received_sticky = 0;
    always @(posedge eth_rx_clk) begin
        if (rx_eth_rst) frame_received_sticky <= 0;
        else if (frame_start) frame_received_sticky <= 1;
    end
    assign led[3] = frame_received_sticky;

    // ---------------- RX CDC FIFO (eth_rx_clk -> clk100mhz) ----------------
    wire rx_fifo_full, rx_fifo_empty;
    wire [7:0] rx_fifo_rd_data;
    wire rx_fifo_rd_en;
    async_fifo #(.DATA_WIDTH(8), .ADDR_WIDTH(8)) rx_cdc_fifo (
        .wr_clk(eth_rx_clk), .wr_rst(rx_eth_rst), .wr_data(rx_data), .wr_en(rx_data_valid), .full(rx_fifo_full),
        .rd_clk(clk100mhz), .rd_rst(sys_rst), .rd_data(rx_fifo_rd_data), .rd_en(rx_fifo_rd_en), .empty(rx_fifo_empty)
    );

    reg rx_fifo_overflow_sticky = 0;
    always @(posedge eth_rx_clk) begin
        if (rx_eth_rst) rx_fifo_overflow_sticky <= 0;
        else if (rx_data_valid && rx_fifo_full) rx_fifo_overflow_sticky <= 1;
    end
    // (rx_fifo_overflow_sticky no longer driven to an LED - led0_g repurposed
    // for eth_rx_clk activity monitoring; kept as a signal in case useful later)


    // ---------------- RX reader -> UART TX (clk100mhz domain) ----------------
    localparam RD_IDLE = 0, RD_POP = 1, RD_CAPTURE = 2, RD_SEND = 3;
    reg [1:0] rd_state = RD_IDLE;
    reg rd_uart_tx_start;
    reg [7:0] rd_uart_tx_byte;
    wire uart_tx_busy;

    assign rx_fifo_rd_en = (rd_state == RD_POP);

    // Arbitrate: the loopback-verify sequencer only ever runs once, early,
    // long before any RX echo traffic would exist, so a simple priority
    // mux (verify wins if active) is sufficient - never actually contended.
    wire       uart_tx_start = lb_uart_active ? lb_uart_tx_start : rd_uart_tx_start;
    wire [7:0] uart_tx_byte  = lb_uart_active ? lb_uart_tx_byte  : rd_uart_tx_byte;

    UART_TX #(.CLKS_PER_BIT(868)) uart_tx_inst (
        .clk(clk100mhz), .rst(sys_rst),
        .tx_start(uart_tx_start), .tx_data(uart_tx_byte),
        .tx(uart_txd_out), .tx_busy(uart_tx_busy)
    );

    always @(posedge clk100mhz) begin
        rd_uart_tx_start <= 0;
        if (sys_rst) begin
            rd_state <= RD_IDLE;
        end else begin
            case (rd_state)
                RD_IDLE: if (!rx_fifo_empty && !uart_tx_busy && !lb_uart_active) rd_state <= RD_POP;
                RD_POP:  rd_state <= RD_CAPTURE;
                RD_CAPTURE: begin
                    rd_uart_tx_byte  <= rx_fifo_rd_data;
                    rd_uart_tx_start <= 1;
                    rd_state <= RD_SEND;
                end
                RD_SEND: if (!uart_tx_busy) rd_state <= RD_IDLE;
                default: rd_state <= RD_IDLE;
            endcase
        end
    end

    assign led[0] = mmcm_locked;
    assign led[1] = phy_rst_n;
    assign led[2] = frame_sent_sticky;

endmodule