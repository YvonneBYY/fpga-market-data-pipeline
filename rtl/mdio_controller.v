// Bit-banged MDIO (clause 22) controller. One transaction (read or write)
// per pulse of `start`. MDC is generated here at ~1MHz (well under the
// 2.5MHz spec max), so timing margins are generous - this is a diagnostic
// tool, not a throughput-critical interface.
//
// NOTE: unlike every other module in this project, this one has NOT been
// verified in simulation - building a behavioral PHY model to test the
// MDIO turnaround protocol against was more than this diagnostic step
// warranted. Going straight to hardware here; treat with proportionally
// more suspicion if something looks wrong.
//
// Frame layout driven onto tx_shift_reg[63:0], MSB first:
//   [63:32] preamble (32 x 1)
//   [31:30] ST  = 01
//   [29:28] OP  = 10 (read) or 01 (write)
//   [27:23] PHYAD (5 bits)
//   [22:18] REGAD (5 bits)
//   [17:16] TA  = driven "10" for write; don't-care/released for read
//   [15:0]  DATA - driven for write, released (PHY drives, we sample) for read

module mdio_controller (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,         // pulse to begin one transaction
    input  wire        op_is_write,   // sampled at start: 0=read, 1=write
    input  wire [4:0]  phy_addr,
    input  wire [4:0]  reg_addr,
    input  wire [15:0] write_data,    // used only if op_is_write

    output reg         mdc,
    output wire        mdio_out,
    output wire        mdio_oe,       // 1 = we are driving mdio_out
    input  wire        mdio_in,

    output reg [15:0]  read_data,
    output reg         busy,
    output reg         done
);

    localparam HALF = 7'd50;  // ~1MHz MDC (100MHz / (2*50))

    reg [6:0]  phase_cnt;
    reg [6:0]  bit_idx;        // 0..63
    reg [63:0] tx_shift_reg;
    reg        op_is_write_latched;

    wire [6:0] drive_bits = op_is_write_latched ? 7'd64 : 7'd46;

    assign mdio_out = tx_shift_reg[63 - bit_idx];
    assign mdio_oe  = (bit_idx < drive_bits);

    always @(posedge clk) begin
        if (rst) begin
            busy <= 0;
            done <= 0;
            phase_cnt <= 0;
            mdc <= 0;
            bit_idx <= 0;
            read_data <= 0;
        end else begin
            done <= 0;

            if (start && !busy) begin
                busy <= 1;
                bit_idx <= 0;
                phase_cnt <= 0;
                mdc <= 0;
                op_is_write_latched <= op_is_write;
                tx_shift_reg <= {
                    32'hFFFFFFFF,               // preamble
                    2'b01,                      // ST
                    (op_is_write ? 2'b01 : 2'b10), // OP
                    phy_addr,                   // PHYAD
                    reg_addr,                   // REGAD
                    (op_is_write ? 2'b10 : 2'b00), // TA
                    (op_is_write ? write_data : 16'h0000)
                };
            end else if (busy) begin
                if (phase_cnt == HALF - 1) begin
                    phase_cnt <= 0;
                    if (mdc == 1'b0) begin
                        // rising edge now: sample PHY-driven data bits
                        mdc <= 1'b1;
                        if (!op_is_write_latched && bit_idx >= 48)
                            read_data <= {read_data[14:0], mdio_in};
                    end else begin
                        // falling edge now: advance to next bit (or finish)
                        mdc <= 1'b0;
                        if (bit_idx == 63) begin
                            busy <= 0;
                            done <= 1;
                        end else begin
                            bit_idx <= bit_idx + 1;
                        end
                    end
                end else begin
                    phase_cnt <= phase_cnt + 1;
                end
            end
        end
    end

endmodule