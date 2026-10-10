module crc32_check (
    input        clk,
    input        rst,
    input  [7:0] data,
    input        data_valid,
    input        frame_start,
    input        frame_end,
    output reg   crc_valid,
    output reg   crc_ok
);

    reg [31:0] crc_reg;
    reg frame_end_delayed;

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
            crc_reg   <= 32'hFFFFFFFF;
            crc_valid <= 0;
            crc_ok    <= 0;
            frame_end_delayed <= 0;
        end
        else begin
            frame_end_delayed <= frame_end;
            crc_valid <= 0;

            if (frame_start) begin
                crc_reg <= crc32_update(32'hFFFFFFFF, data);
            end

            else if (data_valid)
                crc_reg <= crc32_update(crc_reg, data);

            if (frame_end_delayed) begin
                crc_ok <= (crc_reg == 32'hDEBB20E3);
                crc_valid <= 1;
            end
        end
    end

endmodule