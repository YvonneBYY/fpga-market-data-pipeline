// ARP reply framer.
//
// Sits between arp_responder and the TX-side async_fifo. Takes the raw
// 60-byte (pre-CRC, pre-preamble) reply arp_responder produces, computes
// its CRC32 via crc32_gen, and emits the combined 64-byte result as
// 9-bit tagged {last, data[7:0]} words - exactly the format the TX-side
// async_fifo already expects, matching Phase 2's convention.
//
// State sequencing mirrors the proven TB_BUILD/TB_CRC0..3 pattern from
// the Phase 2 TX-test frame builders: crc_start is pulsed one cycle before
// data actually starts streaming (matching arp_responder's own tx_req/
// tx_valid staggering - tx_req pulses exactly one cycle before tx_valid
// first goes high), then each byte is fed to crc32_gen as it passes
// through, then the 4 FCS bytes are appended once the reply completes.

module arp_reply_framer (
    input  wire       clk,
    input  wire       rst,

    // from arp_responder
    input  wire        arp_tx_req,
    input  wire        arp_tx_valid,
    input  wire [7:0]  arp_tx_byte,
    input  wire        arp_tx_last,

    // to the TX-side 9-bit tagged async_fifo (write side)
    output wire [8:0]  fifo_wr_data,
    output wire        fifo_wr_en
);

    localparam FR_IDLE = 0, FR_STREAM = 1, FR_SETTLE = 2,
               FR_CRC0 = 3, FR_CRC1 = 4, FR_CRC2 = 5, FR_CRC3 = 6;
    reg [2:0] fr_state = FR_IDLE;

    wire [31:0] crc_result;
    reg  crc_start, crc_data_valid;
    reg  [7:0] crc_data;
    crc32_gen crc_gen_inst (
        .clk(clk), .rst(rst),
        .start(crc_start), .data(crc_data), .data_valid(crc_data_valid),
        .crc_reg(crc_result)
    );
    wire [31:0] crc_to_send = ~crc_result;

    wire [7:0] out_byte =
        (fr_state == FR_STREAM) ? arp_tx_byte      :
        (fr_state == FR_CRC0)   ? crc_to_send[7:0]   :
        (fr_state == FR_CRC1)   ? crc_to_send[15:8]  :
        (fr_state == FR_CRC2)   ? crc_to_send[23:16] :
        (fr_state == FR_CRC3)   ? crc_to_send[31:24] :
        8'h00;
    wire out_last = (fr_state == FR_CRC3);
    wire out_wr_en = ((fr_state == FR_STREAM) && arp_tx_valid) ||
                     (fr_state == FR_CRC0) || (fr_state == FR_CRC1) ||
                     (fr_state == FR_CRC2) || (fr_state == FR_CRC3);

    assign fifo_wr_data = {out_last, out_byte};
    assign fifo_wr_en   = out_wr_en;

    always @(posedge clk) begin
        crc_start      <= 0;
        crc_data_valid <= 0;
        if (rst) begin
            fr_state <= FR_IDLE;
        end else begin
            case (fr_state)
                FR_IDLE: if (arp_tx_req) begin
                    crc_start <= 1;
                    fr_state  <= FR_STREAM;
                end
                FR_STREAM: if (arp_tx_valid) begin
                    crc_data       <= arp_tx_byte;
                    crc_data_valid <= 1;
                    if (arp_tx_last) fr_state <= FR_SETTLE;
                end
                FR_SETTLE: fr_state <= FR_CRC0;
                FR_CRC0:   fr_state <= FR_CRC1;
                FR_CRC1:   fr_state <= FR_CRC2;
                FR_CRC2:   fr_state <= FR_CRC3;
                FR_CRC3:   fr_state <= FR_IDLE;
                default:   fr_state <= FR_IDLE;
            endcase
        end
    end

endmodule