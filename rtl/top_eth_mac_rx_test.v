module top_eth_mac_rx_test (
    input  wire clk100mhz,
    input  wire btn0,             // async reset button

    // MII pins (from Digilent Arty-A7-100-Master.xdc)
    output wire eth_ref_clk,
    output wire eth_rstn,
    input  wire eth_rx_clk,
    input  wire eth_rx_dv,
    input  wire [3:0] eth_rxd,
    input  wire eth_rxerr,

    // UART out to laptop (FPGA TX -> host RX, D10)
    output wire uart_txd_out,

    output wire [3:0] led         // 0=mmcm_locked 1=phy_rst_n 2=frame_seen 3=fifo_overflow_sticky
);

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

    // ---------------- Reset synchronizers (btn0 -> each clock domain) ----------------
    wire sys_rst, eth_rst;

    sync_2ff #(.WIDTH(1)) sync_rst_sys (
        .clk(clk100mhz), .rst(1'b0),
        .async_in(btn0), .sync_out(sys_rst)
    );

    sync_2ff #(.WIDTH(1)) sync_rst_eth (
        .clk(eth_rx_clk), .rst(1'b0),
        .async_in(btn0), .sync_out(eth_rst)
    );

    // ---------------- MAC RX (eth_rx_clk domain) ----------------
    wire frame_start, frame_end, frame_error;
    wire [7:0] data;
    wire data_valid;

    eth_mac_rx_nibble mac_rx_inst (
        .phy_rx_clk   (eth_rx_clk),
        .rst          (eth_rst),
        .phy_rxd      (eth_rxd),
        .phy_rx_dv    (eth_rx_dv),
        .phy_rx_er    (eth_rxerr),
        .data         (data),
        .data_valid   (data_valid),
        .frame_start  (frame_start),
        .frame_end    (frame_end),
        .frame_error  (frame_error)
    );

    reg frame_seen_sticky = 0;
    always @(posedge eth_rx_clk) begin
        if (eth_rst) frame_seen_sticky <= 0;
        else if (frame_start) frame_seen_sticky <= 1;
    end

    // ---------------- CDC: async_fifo (eth_rx_clk -> clk100mhz) ----------------
    wire fifo_full, fifo_empty;
    wire [7:0] fifo_rd_data;
    wire fifo_rd_en;

    async_fifo #(.DATA_WIDTH(8), .ADDR_WIDTH(8)) rx_cdc_fifo (
        .wr_clk   (eth_rx_clk),
        .wr_rst   (eth_rst),
        .wr_data  (data),
        .wr_en    (data_valid),
        .full     (fifo_full),

        .rd_clk   (clk100mhz),
        .rd_rst   (sys_rst),
        .rd_data  (fifo_rd_data),
        .rd_en    (fifo_rd_en),
        .empty    (fifo_empty)
    );

    reg fifo_overflow_sticky = 0;
    always @(posedge eth_rx_clk) begin
        if (eth_rst) fifo_overflow_sticky <= 0;
        else if (data_valid && fifo_full) fifo_overflow_sticky <= 1;
    end

    // ---------------- System-domain reader -> UART TX ----------------
    // NOTE: async_fifo's rd_data has 1-cycle latency after rd_en goes high
    // POP and CAPTURE must be separate states, not collapsed into one.
    localparam IDLE = 0, POP = 1, CAPTURE = 2, SEND = 3;
    reg [1:0] state = IDLE;
    reg [7:0] tx_byte;
    reg       tx_start;
    wire      tx_busy;

    assign fifo_rd_en = (state == POP);

    UART_TX #(.CLKS_PER_BIT(868)) uart_tx_inst (
        .clk      (clk100mhz),
        .rst      (sys_rst),
        .tx_start (tx_start),
        .tx_data  (tx_byte),
        .tx       (uart_txd_out),
        .tx_busy  (tx_busy)
    );

    always @(posedge clk100mhz) begin
        tx_start <= 0;
        if (sys_rst) begin
            state <= IDLE;
        end else begin
            case (state)
                IDLE:    if (!fifo_empty && !tx_busy) state <= POP;
                POP:     state <= CAPTURE;              // rd_en high this cycle
                CAPTURE: begin
                    tx_byte  <= fifo_rd_data;            // now valid after one cycle delay
                    tx_start <= 1;
                    state    <= SEND;
                end
                SEND:    if (!tx_busy) state <= IDLE;
            endcase
        end
    end

    assign led[0] = mmcm_locked;
    assign led[1] = phy_rst_n;
    assign led[2] = frame_seen_sticky;
    assign led[3] = fifo_overflow_sticky;

endmodule