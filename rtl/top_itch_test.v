module top_itch_test (
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

    output wire [3:0] led,   // 0=mmcm_locked 1=phy_rst_n 2=arp_matched 3=itch_msg_decoded
    output wire uart_txd_out // ITCH decode report, one per decoded message
);

    localparam [15:0] ITCH_PORT = 16'd9002;   // distinct from Phase 4/5's ECHO_PORT (9000)

    // ---------------- Clocking / PHY reset (unchanged from Phase 2-5) ----------------
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

    // ---------------- ARP responder (still needed - Windows must be able
    // to resolve the FPGA's MAC before it can send any UDP/ITCH traffic
    // at all, even though ITCH itself needs no reply of its own) ----------------
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

    ip_udp_rx_parser udp_rx_inst (
        .clk(clk100mhz), .rst(sys_rst),
        .rx_data(sys_rx_data), .rx_data_valid(sys_rx_data_valid),
        .rx_frame_start(sys_rx_frame_start), .rx_frame_end(sys_rx_frame_end),
        .src_ip(udp_rx_src_ip), .dst_ip(udp_rx_dst_ip), .src_mac(udp_rx_src_mac),
        .src_port(udp_rx_src_port), .dst_port(udp_rx_dst_port), .udp_length(udp_rx_udp_length),
        .payload_valid(udp_rx_payload_valid), .payload_data(udp_rx_payload_data),
        .payload_last(udp_rx_payload_last), .packet_malformed(udp_rx_malformed)
    );

    // ---------------- Port filter: only feed itch_decoder packets
    // addressed to ITCH_PORT. dst_port is already latched (from the UDP
    // header, which streams by before the payload) by the time any
    // payload_valid pulse fires, so this gating is timing-safe with no
    // extra care needed - unlike the earlier Phase 5 T1 contamination bug,
    // which was about a signal that was NOT gated at all. ----------------
    wire itch_payload_valid = udp_rx_payload_valid && (udp_rx_dst_port == ITCH_PORT);

    wire        itch_msg_valid, itch_unknown_type;
    wire [7:0]  itch_msg_type;
    wire [15:0] itch_stock_locate, itch_tracking_number;
    wire [47:0] itch_timestamp;
    wire [63:0] itch_order_ref_number;
    wire        itch_buy_sell_indicator;
    wire [31:0] itch_shares;
    wire [63:0] itch_stock;
    wire [31:0] itch_price;
    wire [7:0]  itch_event_code;
    wire [63:0] itch_match_number;

    itch_decoder itch_inst (
        .clk(clk100mhz), .rst(sys_rst),
        .payload_valid(itch_payload_valid), .payload_data(udp_rx_payload_data),
        .payload_last(udp_rx_payload_last),
        .msg_valid(itch_msg_valid), .msg_type(itch_msg_type), .unknown_type(itch_unknown_type),
        .stock_locate(itch_stock_locate), .tracking_number(itch_tracking_number), .timestamp(itch_timestamp),
        .order_ref_number(itch_order_ref_number), .buy_sell_indicator(itch_buy_sell_indicator),
        .shares(itch_shares), .stock(itch_stock), .price(itch_price),
        .event_code(itch_event_code), .match_number(itch_match_number)
    );

    reg itch_decoded_sticky = 0;
    always @(posedge clk100mhz) begin
        if (sys_rst) itch_decoded_sticky <= 0;
        else if (itch_msg_valid) itch_decoded_sticky <= 1;
    end

    // ---------------- Shared TX path (ARP replies only) ----------------
    wire tx_fifo_full, tx_fifo_empty;
    wire [8:0] tx_fifo_rd_data;
    wire tx_fifo_rd_en;
    async_fifo #(.DATA_WIDTH(9), .ADDR_WIDTH(8)) tx_frame_fifo (
        .wr_clk(clk100mhz), .wr_rst(sys_rst), .wr_data(arp_fifo_wr_data), .wr_en(arp_fifo_wr_en), .full(tx_fifo_full),
        .rd_clk(eth_tx_clk), .rd_rst(tx_eth_rst), .rd_data(tx_fifo_rd_data), .rd_en(tx_fifo_rd_en), .empty(tx_fifo_empty)
    );

    // ---------------- TX local frame buffer + driver (eth_tx_clk domain) ----------------
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

    assign led[0] = mmcm_locked;
    assign led[1] = phy_rst_n;
    assign led[2] = arp_matched_sticky;
    assign led[3] = itch_decoded_sticky;

    // ---------------- ITCH decode report over UART, QUEUED ----------------
    // A single "snapshot at msg_valid" register set is NOT enough: each
    // 46-byte report takes ~4ms to transmit at 115200 baud (10 bits/byte x
    // 86.8ns/bit), but itch_decoder can decode several back-to-back
    // messages within microseconds of each other (e.g. multiple ITCH
    // messages packed into one UDP payload). Without a queue, every
    // msg_valid pulse that occurs while a previous report is still
    // draining out over UART is silently dropped - discovered on real
    // hardware, where sending 5 messages produced only 1 report. Fixed
    // with a small same-clock-domain FIFO (8 deep) that captures every
    // decoded message's fields the instant msg_valid fires, regardless of
    // whether the UART is still busy with an earlier one; the report FSM
    // drains it one entry at a time whenever it's free. 8 entries is a
    // generous margin for controlled test traffic; a real, continuously
    // decoding feed would need either a much deeper queue or a faster/
    // wider reporting path than a single UART line.
    localparam RPT_FIFO_DEPTH = 8;
    // Packed entry width: msg_type(8)+stock_locate(16)+tracking_number(16)
    // +timestamp(48)+order_ref_number(64)+buy_sell(8, one full byte for
    // simplicity)+shares(32)+stock(64)+price(32)+event_code(8)
    // +match_number(64) = 360 bits exactly.
    reg [359:0] rpt_fifo [0:RPT_FIFO_DEPTH-1];
    reg [3:0]   rpt_wr_ptr, rpt_rd_ptr;   // bit[3] is a wrap flag, bits[2:0] index the array
    wire rpt_fifo_empty = (rpt_wr_ptr == rpt_rd_ptr);
    wire rpt_fifo_full  = (rpt_wr_ptr[2:0] == rpt_rd_ptr[2:0]) && (rpt_wr_ptr[3] != rpt_rd_ptr[3]);

    always @(posedge clk100mhz) begin
        if (sys_rst) begin
            rpt_wr_ptr <= 0;
        end else if (itch_msg_valid && !rpt_fifo_full) begin
            rpt_fifo[rpt_wr_ptr[2:0]] <= {
                itch_msg_type, itch_stock_locate, itch_tracking_number, itch_timestamp,
                itch_order_ref_number, {7'b0, itch_buy_sell_indicator}, itch_shares,
                itch_stock, itch_price, itch_event_code, itch_match_number
            };
            rpt_wr_ptr <= rpt_wr_ptr + 1'b1;
        end
    end

    reg  [7:0]  rpt_msg_type;
    reg  [15:0] rpt_stock_locate, rpt_tracking_number;
    reg  [47:0] rpt_timestamp;
    reg  [63:0] rpt_order_ref_number;
    reg  [7:0]  rpt_buy_sell_byte;   // matches the packed FIFO entry's full-byte slot exactly
    reg  [31:0] rpt_shares;
    reg  [63:0] rpt_stock;
    reg  [31:0] rpt_price;
    reg  [7:0]  rpt_event_code;
    reg  [63:0] rpt_match_number;

    localparam RPT_IDLE = 6'd62, RPT_LAST = 6'd45;  // byte indices 0..45 are the report bytes
    reg [5:0] rpt_state;
    reg [5:0] rpt_next_state;
    localparam RPT_SEND_WAIT = 6'd63;

    reg  uart_tx_start;
    reg  [7:0] uart_tx_byte;
    wire uart_tx_busy;

    function [7:0] report_byte_for(input [5:0] idx);
        case (idx)
            0:  report_byte_for = 8'hDE;
            1:  report_byte_for = rpt_msg_type;
            2:  report_byte_for = rpt_stock_locate[15:8];
            3:  report_byte_for = rpt_stock_locate[7:0];
            4:  report_byte_for = rpt_tracking_number[15:8];
            5:  report_byte_for = rpt_tracking_number[7:0];
            6:  report_byte_for = rpt_timestamp[47:40];
            7:  report_byte_for = rpt_timestamp[39:32];
            8:  report_byte_for = rpt_timestamp[31:24];
            9:  report_byte_for = rpt_timestamp[23:16];
            10: report_byte_for = rpt_timestamp[15:8];
            11: report_byte_for = rpt_timestamp[7:0];
            12: report_byte_for = rpt_order_ref_number[63:56];
            13: report_byte_for = rpt_order_ref_number[55:48];
            14: report_byte_for = rpt_order_ref_number[47:40];
            15: report_byte_for = rpt_order_ref_number[39:32];
            16: report_byte_for = rpt_order_ref_number[31:24];
            17: report_byte_for = rpt_order_ref_number[23:16];
            18: report_byte_for = rpt_order_ref_number[15:8];
            19: report_byte_for = rpt_order_ref_number[7:0];
            20: report_byte_for = rpt_buy_sell_byte;
            21: report_byte_for = rpt_shares[31:24];
            22: report_byte_for = rpt_shares[23:16];
            23: report_byte_for = rpt_shares[15:8];
            24: report_byte_for = rpt_shares[7:0];
            25: report_byte_for = rpt_stock[63:56];
            26: report_byte_for = rpt_stock[55:48];
            27: report_byte_for = rpt_stock[47:40];
            28: report_byte_for = rpt_stock[39:32];
            29: report_byte_for = rpt_stock[31:24];
            30: report_byte_for = rpt_stock[23:16];
            31: report_byte_for = rpt_stock[15:8];
            32: report_byte_for = rpt_stock[7:0];
            33: report_byte_for = rpt_price[31:24];
            34: report_byte_for = rpt_price[23:16];
            35: report_byte_for = rpt_price[15:8];
            36: report_byte_for = rpt_price[7:0];
            37: report_byte_for = rpt_event_code;
            38: report_byte_for = rpt_match_number[63:56];
            39: report_byte_for = rpt_match_number[55:48];
            40: report_byte_for = rpt_match_number[47:40];
            41: report_byte_for = rpt_match_number[39:32];
            42: report_byte_for = rpt_match_number[31:24];
            43: report_byte_for = rpt_match_number[23:16];
            44: report_byte_for = rpt_match_number[15:8];
            45: report_byte_for = rpt_match_number[7:0];
            default: report_byte_for = 8'h00;
        endcase
    endfunction

    always @(posedge clk100mhz) begin
        uart_tx_start <= 0;
        if (sys_rst) begin
            rpt_state  <= RPT_IDLE;
            rpt_rd_ptr <= 0;
        end else begin
            if (rpt_state == RPT_IDLE) begin
                if (!rpt_fifo_empty) begin
                    {rpt_msg_type, rpt_stock_locate, rpt_tracking_number, rpt_timestamp,
                     rpt_order_ref_number, rpt_buy_sell_byte, rpt_shares,
                     rpt_stock, rpt_price, rpt_event_code, rpt_match_number}
                        <= rpt_fifo[rpt_rd_ptr[2:0]];
                    rpt_rd_ptr <= rpt_rd_ptr + 1'b1;
                    rpt_state  <= 6'd0;   // start sending from byte 0 (the marker) NEXT cycle
                end
            end else if (rpt_state == RPT_SEND_WAIT) begin
                if (!uart_tx_busy) rpt_state <= rpt_next_state;
            end else begin
                // rpt_state is a byte index 0..45
                if (!uart_tx_busy) begin
                    uart_tx_byte  <= report_byte_for(rpt_state);
                    uart_tx_start <= 1;
                    rpt_next_state <= (rpt_state == RPT_LAST) ? RPT_IDLE : (rpt_state + 1'b1);
                    rpt_state <= RPT_SEND_WAIT;
                end
            end
        end
    end

    UART_TX #(.CLKS_PER_BIT(868)) uart_tx_inst (
        .clk(clk100mhz), .rst(sys_rst),
        .tx_start(uart_tx_start), .tx_data(uart_tx_byte),
        .tx(uart_txd_out), .tx_busy(uart_tx_busy)
    );

endmodule