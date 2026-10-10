module eth_mac_rx_nibble (
    input        phy_rx_clk,
    input        rst,           // synchronized to phy_rx_clk
    input  [3:0] phy_rxd,
    input        phy_rx_dv,
    input        phy_rx_er,

    output reg [7:0] data,
    output reg       data_valid,
    output reg       frame_start,   // pulses on first real data byte (post-SFD)
    output reg       frame_end,     // pulses on last byte (phy_rx_dv drops)
    output reg       frame_error    // phy_rx_er seen mid-frame
);

    localparam IDLE = 3'd0;
    localparam PREAMBLE = 3'd1;
    localparam DATA = 3'd2;

    reg [2:0] state = IDLE;
    reg error_seen;
    reg SFD_detected; // flag for SFD being detected

    // driven only by nibble_to_byte
    wire [7:0] assembled_byte;
    wire       assembled_byte_valid;
    wire nibble_assembler_rst = rst || !phy_rx_dv;

    nibble_to_byte nibble_assembler (
        .clk          (phy_rx_clk),
        .rst          (nibble_assembler_rst),
        .nibble       (phy_rxd),
        .nibble_valid (phy_rx_dv),
        .byte_out     (assembled_byte),
        .byte_valid   (assembled_byte_valid)
    );

    always @(posedge phy_rx_clk) begin
        if (rst) begin
            state        <= IDLE;
            data         <= 8'h00;
            frame_error  <= 1'b0;
            error_seen   <= 1'b0;
            data_valid   <= 1'b0;
            frame_start  <= 1'b0;
            frame_end    <= 1'b0;
            SFD_detected <= 1'b0;
        end
        else begin
            data_valid   <= 1'b0;
            frame_start  <= 1'b0;
            frame_end    <= 1'b0;

            case (state)
                IDLE: begin
                    frame_error  <= 1'b0;
                    error_seen   <= 1'b0;
                    SFD_detected <= 1'b0;   // guard against a stale flag from an aborted previous frame

                    if (phy_rx_dv)
                        state <= PREAMBLE;
                end

                PREAMBLE: begin
                    if (!phy_rx_dv) // dropped mid-preamble - treat as aborted frame, bail to IDLE
                        state <= IDLE;
                    else begin
                        if (assembled_byte_valid) begin
                            if (assembled_byte == 8'hD5) begin
                                state <= DATA;
                                SFD_detected <= 1'b1;
                            end
                            // else: just another preamble byte (0x55) - stay in PREAMBLE,
                            // no state change needed
                        end
                        // else: assembled_byte_valid not high yet (still waiting on the
                        // second nibble of this byte) - stay in PREAMBLE, nothing to do
                    end
                end

                DATA: begin
                    if (assembled_byte_valid) begin
                        data       <= assembled_byte;
                        data_valid <= 1'b1;
                        if (SFD_detected) begin
                            frame_start  <= 1'b1;
                            SFD_detected <= 1'b0;
                        end
                    end

                    if (!phy_rx_dv) begin
                        frame_end   <= 1'b1;
                        frame_error <= error_seen;
                        state       <= IDLE;
                    end

                    if (phy_rx_er)
                        error_seen <= 1'b1;
                end
                default: state <= IDLE;
            endcase
        end
    end

endmodule