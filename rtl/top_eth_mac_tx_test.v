//module top_eth_mac_tx_test (
//    input  wire clk100mhz,
//    input  wire btn0,             // reset
//    input  wire btn1,             // "send current buffer as a frame"

//    // MII pins (from Digilent Arty-A7-100-Master.xdc)
//    output wire eth_ref_clk,
//    output wire eth_rstn,
//    input  wire eth_tx_clk,
//    output wire eth_tx_en,
//    output wire [3:0] eth_txd,

//    // UART in from laptop (host TX -> FPGA RX, pin A9)
//    input  wire uart_rxd_in,

//    output wire [3:0] led,         // 0=mmcm_locked 1=phy_rst_n 2=frame_sent_sticky 3=uart_rx_error_sticky
//    output wire led0_r             // DEBUG: lights if eth_tx_en ever asserts at all
//);

//    localparam HEADER_LEN       = 7'd14;
//    localparam PAD_MIN_PAYLOAD  = 7'd46;   // 14 + 46 = 60 bytes minimum before FCS
//    localparam BUF_SIZE         = 64;

//    // ---------------- Clocking / PHY reset ----------------
//    wire clk_out1, mmcm_locked;
//    clk_wiz_0 clk_wiz_inst (
//        .clk_in1  (clk100mhz),
//        .clk_out1 (clk_out1),   // 25MHz
//        .reset    (1'b0),
//        .locked   (mmcm_locked)
//    );
//    assign eth_ref_clk = clk_out1;

//    reg [23:0] rst_counter = 0;
//    reg phy_rst_n = 0;
//    always @(posedge clk_out1) begin
//        if (!mmcm_locked) begin
//            rst_counter <= 0;
//            phy_rst_n   <= 0;
//        end else if (rst_counter < 24'hFFFFFF) begin
//            rst_counter <= rst_counter + 1;
//        end else begin
//            phy_rst_n <= 1;
//        end
//    end
//    assign eth_rstn = phy_rst_n;

//    // ---------------- Reset synchronizers ----------------
//    wire sys_rst, tx_eth_rst;

//    sync_2ff #(.WIDTH(1)) sync_rst_sys (
//        .clk(clk100mhz), .rst(1'b0),
//        .async_in(btn0), .sync_out(sys_rst)
//    );

//    sync_2ff #(.WIDTH(1)) sync_rst_txeth (
//        .clk(eth_tx_clk), .rst(1'b0),
//        .async_in(btn0), .sync_out(tx_eth_rst)
//    );

//    // ---------------- btn1: debounce + rising-edge one-shot ----------------
//    wire btn1_sync;
//    sync_2ff #(.WIDTH(1)) sync_btn1 (
//        .clk(clk100mhz), .rst(sys_rst),
//        .async_in(btn1), .sync_out(btn1_sync)
//    );

//    reg [15:0] debounce_prescaler = 0;
//    wire sample_tick = (debounce_prescaler == 16'd50000); // ~0.5ms @ 100MHz
//    always @(posedge clk100mhz) begin
//        if (sys_rst || sample_tick) debounce_prescaler <= 0;
//        else debounce_prescaler <= debounce_prescaler + 1;
//    end

//    reg [7:0] btn1_shift = 0;
//    always @(posedge clk100mhz) begin
//        if (sys_rst) btn1_shift <= 0;
//        else if (sample_tick) btn1_shift <= {btn1_shift[6:0], btn1_sync};
//    end
//    wire btn1_debounced = &btn1_shift;   // ~4ms stable-high window

//    reg btn1_debounced_prev = 0;
//    always @(posedge clk100mhz) begin
//        if (sys_rst) btn1_debounced_prev <= 0;
//        else btn1_debounced_prev <= btn1_debounced;
//    end
//    wire tx_trigger = btn1_debounced && !btn1_debounced_prev;

//    // ---------------- UART RX -> payload buffer ----------------
//    wire [7:0] uart_rx_data;
//    wire uart_rx_valid, uart_rx_error;

//    UART_RX #(.CLKS_PER_BIT(868)) uart_rx_inst (
//        .clk      (clk100mhz),
//        .rst      (sys_rst),
//        .rx       (uart_rxd_in),
//        .rx_data  (uart_rx_data),
//        .rx_valid (uart_rx_valid),
//        .rx_error (uart_rx_error)
//    );
    

//    reg [7:0] payload_buf [0:BUF_SIZE-1];
//    reg [6:0] payload_len = 0;      // 0..64, live write pointer
//    reg [6:0] snapshot_len = 0;     // latched length at trigger time

//    always @(posedge clk100mhz) begin
//        if (sys_rst) begin
//            payload_len <= 0;
//        end else if (tx_trigger) begin
//            payload_len <= 0;       // start collecting the next message immediately
//        end else if (uart_rx_valid && !uart_rx_error && payload_len < BUF_SIZE) begin
//            payload_buf[payload_len] <= uart_rx_data;
//            payload_len <= payload_len + 1;
//        end
//    end

//    always @(posedge clk100mhz) begin
//        if (sys_rst) snapshot_len <= 0;
//        else if (tx_trigger) snapshot_len <= payload_len;  // pre-reset value, same edge
//    end

//    reg uart_rx_error_sticky = 0;
//    always @(posedge clk100mhz) begin
//        if (sys_rst) uart_rx_error_sticky <= 0;
//        else if (uart_rx_error) uart_rx_error_sticky <= 1;
//    end
//    assign led[3] = uart_rx_error_sticky;

//    // ---------------- CRC32 generator (clk100mhz domain, runs during build) ----------------
//    wire [31:0] crc_result;
//    reg  crc_start, crc_data_valid;
//    reg  [7:0] crc_data;

//    crc32_gen crc_gen_inst (
//        .clk        (clk100mhz),
//        .rst        (sys_rst),
//        .start      (crc_start),
//        .data       (crc_data),
//        .data_valid (crc_data_valid),
//        .crc_reg    (crc_result)
//    );
//    wire [31:0] crc_to_send = ~crc_result;

//    // ---------------- Frame builder FSM (clk100mhz domain) ----------------
//    localparam TB_IDLE = 0, TB_LATCH = 1, TB_BUILD = 2, TB_CRC_SETTLE = 3,
//               TB_CRC0 = 4, TB_CRC1 = 5, TB_CRC2 = 6, TB_CRC3 = 7;
//    reg [3:0] tb_state = TB_IDLE;
//    reg [6:0] byte_idx = 0;
//    reg [6:0] total_len_before_crc = 0;

//    // Combinational per-index byte generator: broadcast dest MAC, placeholder
//    // src MAC, EtherType 0x88B5 (IEEE-reserved for local experimental use),
//    // then payload bytes, then zero-padding out to the minimum frame size.
//    wire [7:0] payload_byte_at_idx =
//        (byte_idx >= HEADER_LEN && byte_idx < HEADER_LEN + snapshot_len)
//            ? payload_buf[byte_idx - HEADER_LEN] : 8'h00;

//    wire [7:0] current_frame_byte =
//        (byte_idx < 7'd6)  ? 8'hFF :
//        (byte_idx == 7'd6) ? 8'h02 :
//        (byte_idx == 7'd7) ? 8'h00 :
//        (byte_idx == 7'd8) ? 8'h00 :
//        (byte_idx == 7'd9) ? 8'h00 :
//        (byte_idx == 7'd10)? 8'h00 :
//        (byte_idx == 7'd11)? 8'h01 :
//        (byte_idx == 7'd12)? 8'h88 :
//        (byte_idx == 7'd13)? 8'hB5 :
//        payload_byte_at_idx;

//    always @(posedge clk100mhz) begin
//        if (sys_rst) begin
//            tb_state <= TB_IDLE;
//            byte_idx <= 0;
//            crc_start <= 0;
//            crc_data_valid <= 0;
//            total_len_before_crc <= 0;
//        end else begin
//            crc_start <= 0;
//            crc_data_valid <= 0;

//            case (tb_state)
//                TB_IDLE: begin
//                    byte_idx <= 0;
//                    if (tx_trigger) tb_state <= TB_LATCH;
//                end

//                TB_LATCH: begin
//                    total_len_before_crc <= HEADER_LEN +
//                        ((snapshot_len < PAD_MIN_PAYLOAD) ? PAD_MIN_PAYLOAD : snapshot_len);
//                    crc_start <= 1;
//                    byte_idx  <= 0;
//                    tb_state  <= TB_BUILD;
//                end

//                TB_BUILD: begin
//                    crc_data       <= current_frame_byte;
//                    crc_data_valid <= 1;
//                    byte_idx       <= byte_idx + 1;
//                    if (byte_idx == total_len_before_crc - 1)
//                        tb_state <= TB_CRC_SETTLE;
//                end

//                TB_CRC_SETTLE: tb_state <= TB_CRC0;  // let crc_result settle one cycle
//                TB_CRC0:       tb_state <= TB_CRC1;
//                TB_CRC1:       tb_state <= TB_CRC2;
//                TB_CRC2:       tb_state <= TB_CRC3;
//                TB_CRC3:       tb_state <= TB_IDLE;

//                default: tb_state <= TB_IDLE;
//            endcase
//        end
//    end

//    // fifo write-side mux: frame bytes during BUILD, then the 4 FCS bytes
//    wire [7:0] tx_fifo_byte =
//        (tb_state == TB_BUILD) ? current_frame_byte :
//        (tb_state == TB_CRC0)  ? crc_to_send[7:0]    :
//        (tb_state == TB_CRC1)  ? crc_to_send[15:8]   :
//        (tb_state == TB_CRC2)  ? crc_to_send[23:16]  :
//        (tb_state == TB_CRC3)  ? crc_to_send[31:24]  :
//        8'h00;

//    wire tx_fifo_last  = (tb_state == TB_CRC3);
//    wire tx_fifo_wr_en = (tb_state == TB_BUILD) || (tb_state == TB_CRC0) ||
//                         (tb_state == TB_CRC1)  || (tb_state == TB_CRC2) ||
//                         (tb_state == TB_CRC3);
//    wire [8:0] tx_fifo_wr_data = {tx_fifo_last, tx_fifo_byte};

//    // ---------------- CDC: 9-bit async_fifo (clk100mhz -> eth_tx_clk) ----------------
//    wire fifo_full, fifo_empty;
//    wire [8:0] fifo_rd_data;
//    wire fifo_rd_en;

//    async_fifo #(.DATA_WIDTH(9), .ADDR_WIDTH(7)) tx_frame_fifo (
//        .wr_clk   (clk100mhz),
//        .wr_rst   (sys_rst),
//        .wr_data  (tx_fifo_wr_data),
//        .wr_en    (tx_fifo_wr_en),
//        .full     (fifo_full),

//        .rd_clk   (eth_tx_clk),
//        .rd_rst   (tx_eth_rst),
//        .rd_data  (fifo_rd_data),
//        .rd_en    (fifo_rd_en),
//        .empty    (fifo_empty)
//    );

//    // ---------------- TX driver FSM (eth_tx_clk domain) ----------------
//    localparam TX_IDLE = 0, TX_WAIT_TXREADY = 1, TX_POP = 2, TX_CAPTURE = 3,
//               TX_PRESENT = 4, TX_WAIT_ACCEPT = 5, TX_WAIT_DONE = 6;
//    reg [2:0] tx_state = TX_IDLE;
//    reg [7:0] data_byte;
//    reg       data_last;

//    reg mac_tx_start;
//    reg [7:0] mac_tx_data;
//    reg mac_tx_data_valid;
//    reg mac_tx_last;
//    wire mac_tx_ready, mac_tx_busy;

//    assign fifo_rd_en = (tx_state == TX_POP);

//    eth_mac_tx_nibble mac_tx_inst (
//        .phy_tx_clk    (eth_tx_clk),
//        .rst           (tx_eth_rst),
//        .tx_start      (mac_tx_start),
//        .tx_data       (mac_tx_data),
//        .tx_data_valid (mac_tx_data_valid),
//        .tx_last       (mac_tx_last),
//        .phy_txd       (eth_txd),
//        .phy_tx_en     (eth_tx_en),
//        .tx_ready      (mac_tx_ready),
//        .tx_busy       (mac_tx_busy)
//    );
    
////    // ---------------- ILA Debug ----------------
////    // Changes state on every eth_tx_clk rising edge
////    reg eth_clk_toggle = 1'b0;
    
////    always @(posedge eth_tx_clk) begin
////        eth_clk_toggle <= ~eth_clk_toggle;
////    end
    
////    // Synchronize it into the known-good 100 MHz domain
////    reg eth_clk_sync1 = 1'b0;
////    reg eth_clk_sync2 = 1'b0;
    
////    always @(posedge clk100mhz) begin
////        eth_clk_sync1 <= eth_clk_toggle;
////        eth_clk_sync2 <= eth_clk_sync1;
////    end
    
    
    
////    ila_0 debug_ila (
////        .clk    (clk100mhz),
    
////        .probe0 (eth_clk_sync2),
////        .probe1 (mmcm_locked),
////        .probe2 (phy_rst_n)
////    );
    

//    always @(posedge eth_tx_clk) begin
//        mac_tx_start       <= 0;
//        mac_tx_data_valid  <= 0;

//        if (tx_eth_rst) begin
//            tx_state <= TX_IDLE;
//        end else begin
//            case (tx_state)
//                TX_IDLE: begin
//                    if (!fifo_empty) begin
//                        mac_tx_start <= 1;
//                        tx_state <= TX_WAIT_TXREADY;
//                    end
//                end

//                TX_WAIT_TXREADY: begin
//                    if (mac_tx_ready) tx_state <= TX_POP;
//                end

//                TX_POP: begin
//                    tx_state <= TX_CAPTURE;   // fifo_rd_en high this cycle
//                end

//                TX_CAPTURE: begin
//                    data_byte <= fifo_rd_data[7:0];
//                    data_last <= fifo_rd_data[8];
//                    tx_state  <= TX_PRESENT;
//                end

//                TX_PRESENT: begin
//                    mac_tx_data       <= data_byte;
//                    mac_tx_data_valid <= 1;
//                    mac_tx_last       <= data_last;
//                    tx_state          <= TX_WAIT_ACCEPT;
//                end

//                TX_WAIT_ACCEPT: begin
//                    if (data_last) begin
//                        tx_state <= TX_WAIT_DONE;
//                    end else if (mac_tx_ready) begin
//                        tx_state <= TX_POP;
//                    end
//                end

//                TX_WAIT_DONE: begin
//                    if (!mac_tx_busy) tx_state <= TX_IDLE;
//                end

//                default: tx_state <= TX_IDLE;
//            endcase
//        end
//    end

//    reg frame_sent_sticky = 0;
//    reg mac_tx_busy_prev = 0;
//    always @(posedge eth_tx_clk) begin
//        if (tx_eth_rst) begin
//            frame_sent_sticky <= 0;
//            mac_tx_busy_prev  <= 0;
//        end else begin
//            mac_tx_busy_prev <= mac_tx_busy;
//            if (mac_tx_busy_prev && !mac_tx_busy) frame_sent_sticky <= 1;
//        end
//    end

//    // DEBUG: does eth_tx_en (and therefore phy_txd) ever actually assert
//    // at the pin level, regardless of whether the PHY does anything with it
//    reg tx_en_activity_sticky = 0;
//    always @(posedge eth_tx_clk) begin
//        if (tx_eth_rst) tx_en_activity_sticky <= 0;
//        else if (eth_tx_en) tx_en_activity_sticky <= 1;
//    end
//    assign led0_r = tx_en_activity_sticky;
//    assign led[0] = mmcm_locked;
//    assign led[1] = phy_rst_n;
//    assign led[2] = frame_sent_sticky;

//endmodule

module top_eth_mac_tx_test (
    input  wire clk100mhz,
    input  wire btn0,             // reset
    input  wire btn1,             // "send current buffer as a frame"
    input  wire btn2,             // "run MDIO diagnostic (read + maybe clear Isolate bit)"

    // MII pins (from Digilent Arty-A7-100-Master.xdc)
    output wire eth_ref_clk,
    output wire eth_rstn,
    input  wire eth_tx_clk,
    output wire eth_tx_en,
    output wire [3:0] eth_txd,

    // MDIO management pins
    output wire eth_mdc,
    inout  wire eth_mdio,

    // UART in from laptop (host TX -> FPGA RX, pin A9)
    input  wire uart_rxd_in,
    // UART out to laptop (FPGA TX -> host RX, pin D10) - used only for
    // the MDIO diagnostic readback, not the main TX-test data path
    output wire uart_txd_out,

    output wire [3:0] led,         // 0=mmcm_locked 1=phy_rst_n 2=frame_sent_sticky 3=uart_rx_error_sticky
    output wire led0_r,            // DEBUG: lights if eth_tx_en ever asserts at all
    output wire led0_b             // DEBUG: lights once the MDIO diagnostic has run
);

    localparam HEADER_LEN       = 7'd14;
    localparam PAD_MIN_PAYLOAD  = 7'd46;   // 14 + 46 = 60 bytes minimum before FCS
    localparam BUF_SIZE         = 64;

    // ---------------- Clocking / PHY reset ----------------
    wire clk_out1, mmcm_locked;
    clk_wiz_0 clk_wiz_inst (
        .clk_in1  (clk100mhz),
        .clk_out1 (clk_out1),   // 25MHz
        .reset    (1'b0),
        .locked   (mmcm_locked)
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
    wire sys_rst, tx_eth_rst;

    sync_2ff #(.WIDTH(1)) sync_rst_sys (
        .clk(clk100mhz), .rst(1'b0),
        .async_in(btn0), .sync_out(sys_rst)
    );

    sync_2ff #(.WIDTH(1)) sync_rst_txeth (
        .clk(eth_tx_clk), .rst(1'b0),
        .async_in(btn0), .sync_out(tx_eth_rst)
    );

    // ---------------- btn1: debounce + rising-edge one-shot ----------------
    wire btn1_sync;
    sync_2ff #(.WIDTH(1)) sync_btn1 (
        .clk(clk100mhz), .rst(sys_rst),
        .async_in(btn1), .sync_out(btn1_sync)
    );

    reg [15:0] debounce_prescaler = 0;
    wire sample_tick = (debounce_prescaler == 16'd50000); // ~0.5ms @ 100MHz
    always @(posedge clk100mhz) begin
        if (sys_rst || sample_tick) debounce_prescaler <= 0;
        else debounce_prescaler <= debounce_prescaler + 1;
    end

    reg [7:0] btn1_shift = 0;
    always @(posedge clk100mhz) begin
        if (sys_rst) btn1_shift <= 0;
        else if (sample_tick) btn1_shift <= {btn1_shift[6:0], btn1_sync};
    end
    wire btn1_debounced = &btn1_shift;   // ~4ms stable-high window

    reg btn1_debounced_prev = 0;
    always @(posedge clk100mhz) begin
        if (sys_rst) btn1_debounced_prev <= 0;
        else btn1_debounced_prev <= btn1_debounced;
    end
    wire tx_trigger = btn1_debounced && !btn1_debounced_prev;

    // ---------------- btn2: debounce + rising-edge one-shot (MDIO diagnostic) ----------------
    wire btn2_sync;
    sync_2ff #(.WIDTH(1)) sync_btn2 (
        .clk(clk100mhz), .rst(sys_rst),
        .async_in(btn2), .sync_out(btn2_sync)
    );

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
    wire mdio_trigger = btn2_debounced && !btn2_debounced_prev;

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
        .clk         (clk100mhz),
        .rst         (sys_rst),
        .start       (mdio_start),
        .op_is_write (mdio_op_is_write),
        .phy_addr    (5'd1),      // PHY MDIO address = 00001, per schematic
        .reg_addr    (mdio_reg_addr),
        .write_data  (mdio_write_data),
        .mdc         (eth_mdc),
        .mdio_out    (mdio_out),
        .mdio_oe     (mdio_oe),
        .mdio_in     (mdio_in),
        .read_data   (mdio_read_data),
        .busy        (mdio_busy),
        .done        (mdio_done)
    );

    // ---------------- MDIO diagnostic sequencer: read BMCR (reg 0), clear
    // bit 10 (Isolate) if set, read BMSR (reg 1), read PHYSTS (reg 0x10,
    // DP83848 vendor-specific real-time status), then report all THREE
    // original values over UART (6 bytes) ----------------
    localparam MD_IDLE = 0, MD_READ_BMCR = 1, MD_READ_BMCR_WAIT = 2, MD_CHECK = 3,
               MD_WRITE = 4, MD_WRITE_WAIT = 5, MD_READ_BMSR = 6, MD_READ_BMSR_WAIT = 7,
               MD_READ_PHYSTS = 8, MD_READ_PHYSTS_WAIT = 9,
               MD_SEND0 = 10, MD_SEND0_WAIT = 11, MD_SEND1 = 12, MD_SEND1_WAIT = 13,
               MD_SEND2 = 14, MD_SEND2_WAIT = 15, MD_SEND3 = 16, MD_SEND3_WAIT = 17,
               MD_SEND4 = 18, MD_SEND4_WAIT = 19, MD_SEND5 = 20, MD_SEND5_WAIT = 21,
               MD_DONE = 22;
    reg [4:0] md_state = MD_IDLE;
    reg [15:0] bmcr_value;
    reg [15:0] bmsr_value;
    reg [15:0] physts_value;

    reg uart_tx_start;
    reg [7:0] uart_tx_byte;
    wire uart_tx_busy;

    UART_TX #(.CLKS_PER_BIT(868)) uart_tx_diag_inst (
        .clk      (clk100mhz),
        .rst      (sys_rst),
        .tx_start (uart_tx_start),
        .tx_data  (uart_tx_byte),
        .tx       (uart_txd_out),
        .tx_busy  (uart_tx_busy)
    );

    always @(posedge clk100mhz) begin
        mdio_start    <= 0;
        uart_tx_start <= 0;

        if (sys_rst) begin
            md_state <= MD_IDLE;
        end else begin
            case (md_state)
                MD_IDLE: begin
                    if (mdio_trigger) begin
                        mdio_reg_addr    <= 5'd0;   // BMCR
                        mdio_op_is_write <= 0;
                        mdio_start <= 1;
                        md_state <= MD_READ_BMCR_WAIT;
                    end
                end

                MD_READ_BMCR_WAIT: begin
                    if (mdio_done) begin
                        bmcr_value <= mdio_read_data;
                        md_state <= MD_CHECK;
                    end
                end

                MD_CHECK: begin
                    if (bmcr_value[10]) begin
                        mdio_reg_addr    <= 5'd0;
                        mdio_op_is_write <= 1;
                        mdio_write_data  <= bmcr_value & ~16'h0400;  // clear Isolate (bit 10)
                        mdio_start <= 1;
                        md_state <= MD_WRITE_WAIT;
                    end else begin
                        md_state <= MD_READ_BMSR;
                    end
                end

                MD_WRITE_WAIT: begin
                    if (mdio_done) md_state <= MD_READ_BMSR;
                end

                MD_READ_BMSR: begin
                    mdio_reg_addr    <= 5'd1;   // BMSR
                    mdio_op_is_write <= 0;
                    mdio_start <= 1;
                    md_state <= MD_READ_BMSR_WAIT;
                end

                MD_READ_BMSR_WAIT: begin
                    if (mdio_done) begin
                        bmsr_value <= mdio_read_data;
                        md_state <= MD_READ_PHYSTS;
                    end
                end

                MD_READ_PHYSTS: begin
                    mdio_reg_addr    <= 5'd16;  // PHYSTS = register 0x10
                    mdio_op_is_write <= 0;
                    mdio_start <= 1;
                    md_state <= MD_READ_PHYSTS_WAIT;
                end

                MD_READ_PHYSTS_WAIT: begin
                    if (mdio_done) begin
                        physts_value <= mdio_read_data;
                        md_state <= MD_SEND0;
                    end
                end

                MD_SEND0: begin
                    if (!uart_tx_busy) begin
                        uart_tx_byte  <= bmcr_value[15:8];
                        uart_tx_start <= 1;
                        md_state <= MD_SEND0_WAIT;
                    end
                end
                MD_SEND0_WAIT: if (!uart_tx_busy) md_state <= MD_SEND1;

                MD_SEND1: begin
                    if (!uart_tx_busy) begin
                        uart_tx_byte  <= bmcr_value[7:0];
                        uart_tx_start <= 1;
                        md_state <= MD_SEND1_WAIT;
                    end
                end
                MD_SEND1_WAIT: if (!uart_tx_busy) md_state <= MD_SEND2;

                MD_SEND2: begin
                    if (!uart_tx_busy) begin
                        uart_tx_byte  <= bmsr_value[15:8];
                        uart_tx_start <= 1;
                        md_state <= MD_SEND2_WAIT;
                    end
                end
                MD_SEND2_WAIT: if (!uart_tx_busy) md_state <= MD_SEND3;

                MD_SEND3: begin
                    if (!uart_tx_busy) begin
                        uart_tx_byte  <= bmsr_value[7:0];
                        uart_tx_start <= 1;
                        md_state <= MD_SEND3_WAIT;
                    end
                end
                MD_SEND3_WAIT: if (!uart_tx_busy) md_state <= MD_SEND4;

                MD_SEND4: begin
                    if (!uart_tx_busy) begin
                        uart_tx_byte  <= physts_value[15:8];
                        uart_tx_start <= 1;
                        md_state <= MD_SEND4_WAIT;
                    end
                end
                MD_SEND4_WAIT: if (!uart_tx_busy) md_state <= MD_SEND5;

                MD_SEND5: begin
                    if (!uart_tx_busy) begin
                        uart_tx_byte  <= physts_value[7:0];
                        uart_tx_start <= 1;
                        md_state <= MD_SEND5_WAIT;
                    end
                end
                MD_SEND5_WAIT: if (!uart_tx_busy) md_state <= MD_DONE;

                MD_DONE: md_state <= MD_IDLE;

                default: md_state <= MD_IDLE;
            endcase
        end
    end

    reg mdio_diag_done_sticky = 0;
    always @(posedge clk100mhz) begin
        if (sys_rst) mdio_diag_done_sticky <= 0;
        else if (md_state == MD_DONE) mdio_diag_done_sticky <= 1;
    end
    assign led0_b = mdio_diag_done_sticky;

    // ---------------- UART RX -> payload buffer ----------------
    wire [7:0] uart_rx_data;
    wire uart_rx_valid, uart_rx_error;

    UART_RX #(.CLKS_PER_BIT(868)) uart_rx_inst (
        .clk      (clk100mhz),
        .rst      (sys_rst),
        .rx       (uart_rxd_in),
        .rx_data  (uart_rx_data),
        .rx_valid (uart_rx_valid),
        .rx_error (uart_rx_error)
    );

    reg [7:0] payload_buf [0:BUF_SIZE-1];
    reg [6:0] payload_len = 0;      // 0..64, live write pointer
    reg [6:0] snapshot_len = 0;     // latched length at trigger time

    always @(posedge clk100mhz) begin
        if (sys_rst) begin
            payload_len <= 0;
        end else if (tx_trigger) begin
            payload_len <= 0;       // start collecting the next message immediately
        end else if (uart_rx_valid && !uart_rx_error && payload_len < BUF_SIZE) begin
            payload_buf[payload_len] <= uart_rx_data;
            payload_len <= payload_len + 1;
        end
    end

    always @(posedge clk100mhz) begin
        if (sys_rst) snapshot_len <= 0;
        else if (tx_trigger) snapshot_len <= payload_len;  // pre-reset value, same edge
    end

    reg uart_rx_error_sticky = 0;
    always @(posedge clk100mhz) begin
        if (sys_rst) uart_rx_error_sticky <= 0;
        else if (uart_rx_error) uart_rx_error_sticky <= 1;
    end
    assign led[3] = uart_rx_error_sticky;

    // ---------------- CRC32 generator (clk100mhz domain, runs during build) ----------------
    wire [31:0] crc_result;
    reg  crc_start, crc_data_valid;
    reg  [7:0] crc_data;

    crc32_gen crc_gen_inst (
        .clk        (clk100mhz),
        .rst        (sys_rst),
        .start      (crc_start),
        .data       (crc_data),
        .data_valid (crc_data_valid),
        .crc_reg    (crc_result)
    );
    wire [31:0] crc_to_send = ~crc_result;

    // ---------------- Frame builder FSM (clk100mhz domain) ----------------
    localparam TB_IDLE = 0, TB_LATCH = 1, TB_BUILD = 2, TB_CRC_SETTLE = 3,
               TB_CRC0 = 4, TB_CRC1 = 5, TB_CRC2 = 6, TB_CRC3 = 7;
    reg [3:0] tb_state = TB_IDLE;
    reg [6:0] byte_idx = 0;
    reg [6:0] total_len_before_crc = 0;

    // Combinational per-index byte generator: broadcast dest MAC, placeholder
    // src MAC, EtherType 0x88B5 (IEEE-reserved for local experimental use),
    // then payload bytes, then zero-padding out to the minimum frame size.
    wire [7:0] payload_byte_at_idx =
        (byte_idx >= HEADER_LEN && byte_idx < HEADER_LEN + snapshot_len)
            ? payload_buf[byte_idx - HEADER_LEN] : 8'h00;

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
                    total_len_before_crc <= HEADER_LEN +
                        ((snapshot_len < PAD_MIN_PAYLOAD) ? PAD_MIN_PAYLOAD : snapshot_len);
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

                TB_CRC_SETTLE: tb_state <= TB_CRC0;  // let crc_result settle one cycle
                TB_CRC0:       tb_state <= TB_CRC1;
                TB_CRC1:       tb_state <= TB_CRC2;
                TB_CRC2:       tb_state <= TB_CRC3;
                TB_CRC3:       tb_state <= TB_IDLE;

                default: tb_state <= TB_IDLE;
            endcase
        end
    end

    // fifo write-side mux: frame bytes during BUILD, then the 4 FCS bytes
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

    // ---------------- CDC: 9-bit async_fifo (clk100mhz -> eth_tx_clk) ----------------
    wire fifo_full, fifo_empty;
    wire [8:0] fifo_rd_data;
    wire fifo_rd_en;

    async_fifo #(.DATA_WIDTH(9), .ADDR_WIDTH(7)) tx_frame_fifo (
        .wr_clk   (clk100mhz),
        .wr_rst   (sys_rst),
        .wr_data  (tx_fifo_wr_data),
        .wr_en    (tx_fifo_wr_en),
        .full     (fifo_full),

        .rd_clk   (eth_tx_clk),
        .rd_rst   (tx_eth_rst),
        .rd_data  (fifo_rd_data),
        .rd_en    (fifo_rd_en),
        .empty    (fifo_empty)
    );

    // ---------------- TX local frame buffer + driver (eth_tx_clk domain) ----------------
    //
    // Drain the entire async FIFO frame into local RAM BEFORE starting the MAC.
    // Once TX_EN goes high at 100 Mb/s MII, the MAC needs a nibble every
    // eth_tx_clk cycle (equivalently one byte every two clocks). Reading the
    // async FIFO between every transmitted byte introduces bubbles, so we
    // prefetch the complete frame first and then stream it continuously.

    localparam TX_LOAD_WAIT    = 3'd0,
               TX_LOAD_POP     = 3'd1,
               TX_LOAD_CAPTURE = 3'd2,
               TX_START_MAC    = 3'd3,
               TX_WAIT_READY   = 3'd4,
               TX_SEND         = 3'd5,
               TX_WAIT_DONE    = 3'd6;

    reg [2:0] tx_state = TX_LOAD_WAIT;

    // {last, data[7:0]}. Max frame generated here is:
    // 14-byte header + 64-byte UART payload + 4-byte FCS = 82 bytes,
    // so 128 entries is sufficient.
    reg [8:0] tx_local_buf [0:127];
    reg [6:0] load_idx = 0;
    reg [6:0] send_idx = 0;

    reg        mac_tx_start;
    wire [7:0] mac_tx_data;
    wire       mac_tx_data_valid;
    wire       mac_tx_last;
    wire       mac_tx_ready;
    wire       mac_tx_busy;

    // async_fifo rd_data is captured one cycle after the POP state.
    assign fifo_rd_en = (tx_state == TX_LOAD_POP);

    // During transmission, every byte comes from local RAM rather than the FIFO.
    assign mac_tx_data = tx_local_buf[send_idx][7:0];
    assign mac_tx_last = tx_local_buf[send_idx][8];

    // Present the first byte as soon as tx_ready rises near the end of the SFD,
    // then present every following byte on each tx_ready pulse. This avoids a
    // gap between the preamble/SFD and the destination MAC.
    assign mac_tx_data_valid =
        ((tx_state == TX_WAIT_READY) || (tx_state == TX_SEND)) && mac_tx_ready;

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
        .tx_busy       (mac_tx_busy)
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
                // Wait until the frame builder has placed at least one word
                // into the async FIFO.
                TX_LOAD_WAIT: begin
                    if (!fifo_empty)
                        tx_state <= TX_LOAD_POP;
                end

                // fifo_rd_en is high for this state/cycle.
                TX_LOAD_POP: begin
                    tx_state <= TX_LOAD_CAPTURE;
                end

                // Capture the word returned by the async FIFO.
                TX_LOAD_CAPTURE: begin
                    tx_local_buf[load_idx] <= fifo_rd_data;

                    if (fifo_rd_data[8]) begin
                        // Last/FCS byte loaded: complete frame is now local.
                        send_idx <= 0;
                        tx_state <= TX_START_MAC;
                    end else begin
                        load_idx <= load_idx + 1'b1;
                        // The write side may still be building the frame, so
                        // go back and wait for the next FIFO word if necessary.
                        tx_state <= TX_LOAD_WAIT;
                    end
                end

                // Tell the MAC to begin preamble/SFD transmission.
                TX_START_MAC: begin
                    mac_tx_start <= 1'b1;
                    tx_state <= TX_WAIT_READY;
                end

                // mac_tx_data_valid is asserted combinationally when ready,
                // so byte 0 is accepted without creating a TX_EN gap.
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

                // Local RAM can supply each next byte immediately, sustaining
                // one byte every two MII clocks.
                TX_SEND: begin
                    if (mac_tx_ready) begin
                        if (tx_local_buf[send_idx][8]) begin
                            tx_state <= TX_WAIT_DONE;
                        end else begin
                            send_idx <= send_idx + 1'b1;
                        end
                    end
                end

                // eth_mac_tx_nibble keeps tx_busy asserted through its IFG.
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
            if (mac_tx_busy_prev && !mac_tx_busy) frame_sent_sticky <= 1;
        end
    end

    // DEBUG: does eth_tx_en (and therefore phy_txd) ever actually assert
    // at the pin level, regardless of whether the PHY does anything with it
    reg tx_en_activity_sticky = 0;
    always @(posedge eth_tx_clk) begin
        if (tx_eth_rst) tx_en_activity_sticky <= 0;
        else if (eth_tx_en) tx_en_activity_sticky <= 1;
    end
    assign led0_r = tx_en_activity_sticky;

    assign led[0] = mmcm_locked;
    assign led[1] = phy_rst_n;
    assign led[2] = frame_sent_sticky;

endmodule