// CRC32 generator for TX FCS computation.
// Mirrors the reflected CRC32 algorithm (poly 0xEDB88320) used in
// crc32_check.v, so a frame generated here will verify correctly against
// that module (or hopefully any standard CRC32/Ethernet FCS checker) on the RX side.
//
// Usage: pulse `start` for one cycle to reset the accumulator to 0xFFFFFFFF,
// then pulse `data_valid` once per byte as you stream the frame content
// Once the last byte's data_valid has been processed (one cycle after),
// crc_reg holds the running CRC. To get the actual FCS bytes to transmit,
// take ~crc_reg (one's complement) and send LSB byte first.

module crc32_gen (
    input        clk,
    input        rst,
    input        start,       // pulse: reset accumulator to FFFFFFFF
    input  [7:0] data,
    input        data_valid,  // pulse per byte to fold into the CRC
    output reg [31:0] crc_reg
);

    function [31:0] crc32_update;
        input [31:0] crc_in;
        input [7:0]  data_in;
        integer i;
        reg [31:0] crc;
        reg [7:0]  d;
        begin
            crc = crc_in;
            d = data_in;
            for (i = 0; i < 8; i = i + 1) begin
                if ((crc[0] ^ d[0]) == 1'b1)
                    crc = (crc >> 1) ^ 32'hEDB88320;
                else
                    crc = crc >> 1;
                d = d >> 1;
            end
            crc32_update = crc;
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            crc_reg <= 32'hFFFFFFFF;
        end else begin
            if (start)
                crc_reg <= 32'hFFFFFFFF;
            else if (data_valid)
                crc_reg <= crc32_update(crc_reg, data);
        end
    end

endmodule