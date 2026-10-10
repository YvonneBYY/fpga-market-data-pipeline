// UDP TX framer - attaches CRC32 to ip_udp_tx_builder's raw frame output.

// Real frame bytes → passed through to the FIFO exactly as they arrive
// (out_byte = udp_tx_byte in FR_STREAM)
// After the last real byte → no more real bytes to forward at all - it's 
// now generating four brand-new bytes (crc_to_send[7:0] through [31:24])

module udp_tx_framer (
    input  wire clk,
    input  wire rst,

    input  wire        udp_tx_req,     // pulses once, one cycle before udp_tx_valid first goes high
    input  wire        udp_tx_valid,
    input  wire [7:0]  udp_tx_byte,
    input  wire        udp_tx_last,

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
    wire [31:0] crc_to_send = ~crc_result; //final transmitted value is the inverted running CRC register

    wire [7:0] out_byte =
        (fr_state == FR_STREAM) ? udp_tx_byte      :
        (fr_state == FR_CRC0)   ? crc_to_send[7:0]   :
        (fr_state == FR_CRC1)   ? crc_to_send[15:8]  :
        (fr_state == FR_CRC2)   ? crc_to_send[23:16] :
        (fr_state == FR_CRC3)   ? crc_to_send[31:24] :
        8'h00;
    wire out_last = (fr_state == FR_CRC3);
    wire out_wr_en = ((fr_state == FR_STREAM) && udp_tx_valid) ||
                     (fr_state == FR_CRC0) || (fr_state == FR_CRC1) ||
                     (fr_state == FR_CRC2) || (fr_state == FR_CRC3);

    assign fifo_wr_data = {out_last, out_byte};
    assign fifo_wr_en   = out_wr_en;

    always @(posedge clk) begin
        crc_start <= 0;
        crc_data_valid <= 0;
        if (rst) begin
            fr_state <= FR_IDLE;
        end else begin
            case (fr_state)
                FR_IDLE: if (udp_tx_req) begin
                    crc_start <= 1;
                    fr_state  <= FR_STREAM;
                end
                FR_STREAM: if (udp_tx_valid) begin
                    crc_data <= udp_tx_byte;
                    crc_data_valid <= 1;
                    if (udp_tx_last) fr_state <= FR_SETTLE;
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