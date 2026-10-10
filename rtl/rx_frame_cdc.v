// RX frame-tagged CDC bridge.
//
// Sits directly downstream of eth_mac_rx_nibble (phy_rx_clk domain) and
// upstream of protocol modules (ARP, IP/UDP, ITCH decoder) in the system
// clock domain.
//
// IMPORTANT CHANGE FROM THE PREVIOUS VERSION:
// frame_start/frame_end are allowed to cross the FIFO even on cycles where
// phy_rx_data_valid == 0.  This matters because some RX MACs pulse frame_end
// one cycle after the final data byte.  The old implementation used
// wr_en = phy_rx_data_valid, which would silently drop such a standalone
// frame_end pulse.
//
// Each FIFO word is:
//     {has_data, frame_start, frame_end, data[7:0]}
//
// Therefore the CDC can represent both normal data bytes and standalone
// frame-boundary events while keeping all tags aligned after the crossing.
//
// Both phy_rx_rst and sys_rst are expected to already be synchronized into
// their respective clock domains upstream.

module rx_frame_cdc (
    // ---- write side: phy_rx_clk domain ----
    input  wire       phy_rx_clk,
    input  wire       phy_rx_rst,
    input  wire [7:0] phy_rx_data,
    input  wire       phy_rx_data_valid,
    input  wire       phy_rx_frame_start,
    input  wire       phy_rx_frame_end,

    // ---- read side: system clock domain ----
    input  wire       sys_clk,
    input  wire       sys_rst,
    output wire [7:0] sys_rx_data,
    output wire       sys_rx_data_valid,
    output wire       sys_rx_frame_start,
    output wire       sys_rx_frame_end,
    output wire       sys_rx_overflow
);

    // ---------------------------------------------------------------------
    // Write side
    // ---------------------------------------------------------------------
    // Bit layout:
    //   [10]   has_data
    //   [9]    frame_start
    //   [8]    frame_end
    //   [7:0]  data byte
    //
    // Write an entry for any real data byte OR any frame-boundary event.
    // This preserves a frame_end pulse even if it occurs when data_valid=0.
    wire [10:0] wr_data = {
        phy_rx_data_valid,
        phy_rx_frame_start,
        phy_rx_frame_end,
        phy_rx_data
    };

    wire wr_en = phy_rx_data_valid ||
                 phy_rx_frame_start ||
                 phy_rx_frame_end;

    wire fifo_full;

    // ---------------------------------------------------------------------
    // CDC FIFO
    // ---------------------------------------------------------------------
    wire [10:0] rd_data;
    wire        rd_en;
    wire        fifo_empty;

    async_fifo #(
        .DATA_WIDTH(11),
        .ADDR_WIDTH(8)
    ) rx_frame_fifo (
        .wr_clk  (phy_rx_clk),
        .wr_rst  (phy_rx_rst),
        .wr_data (wr_data),
        .wr_en   (wr_en),
        .full    (fifo_full),

        .rd_clk  (sys_clk),
        .rd_rst  (sys_rst),
        .rd_data (rd_data),
        .rd_en   (rd_en),
        .empty   (fifo_empty)
    );

    // Sticky overflow indicator for debug/status.
    reg overflow_sticky = 1'b0;
    always @(posedge phy_rx_clk) begin
        if (phy_rx_rst)
            overflow_sticky <= 1'b0;
        else if (wr_en && fifo_full)
            overflow_sticky <= 1'b1;
    end

    // This status flag is intentionally asynchronous but sticky, matching
    // the previous debug/status behavior.
    assign sys_rx_overflow = overflow_sticky;

    // ---------------------------------------------------------------------
    // Read side: pop then capture
    // ---------------------------------------------------------------------
    // async_fifo rd_data has one-cycle registered latency, so keep POP and
    // CAPTURE as separate states.
    localparam RD_IDLE    = 2'd0,
               RD_POP     = 2'd1,
               RD_CAPTURE = 2'd2;

    reg [1:0]  rd_state = RD_IDLE;
    reg [10:0] captured_word = 11'd0;
    reg        captured_valid = 1'b0;

    assign rd_en = (rd_state == RD_POP);

    always @(posedge sys_clk) begin
        captured_valid <= 1'b0;

        if (sys_rst) begin
            rd_state       <= RD_IDLE;
            captured_word  <= 11'd0;
            captured_valid <= 1'b0;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    if (!fifo_empty)
                        rd_state <= RD_POP;
                end

                RD_POP: begin
                    rd_state <= RD_CAPTURE;
                end

                RD_CAPTURE: begin
                    captured_word  <= rd_data;
                    captured_valid <= 1'b1;
                    rd_state       <= RD_IDLE;
                end

                default: begin
                    rd_state <= RD_IDLE;
                end
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // System-domain outputs
    // ---------------------------------------------------------------------
    assign sys_rx_data        = captured_word[7:0];
    assign sys_rx_frame_end   = captured_valid && captured_word[8];
    assign sys_rx_frame_start = captured_valid && captured_word[9];

    // Only assert data_valid for FIFO entries that actually contain a byte.
    // A standalone frame_end event will therefore produce:
    //   sys_rx_frame_end  = 1
    //   sys_rx_data_valid = 0
    assign sys_rx_data_valid  = captured_valid && captured_word[10];

endmodule
