module byte_to_nibble(
    input clk, 
    input rst, 
    input [7:0] byte_in,
    input byte_valid,
    output reg [3:0] nibble, // high whenever `nibble` holds a nibble to send
    output reg nibble_valid, // high while still sending the second nibble -
    output reg busy,
    output reg sending_high
);

    // internal state
    reg [7:0] byte_reg;     // latched copy of byte_in

    always @(posedge clk) begin
        if (rst) begin
            nibble_valid <= 0;
            busy <= 0;
            sending_high <= 0;
        end

        else begin
            if (byte_valid && !busy) begin
                byte_reg <= byte_in;
                nibble <= byte_in[3:0];     // present low nibble immediately
                nibble_valid <= 1;
                busy <= 1;
                sending_high <= 1;      // next cycle sends the high nibble
            end

            else if (busy && sending_high) begin
                nibble <= byte_reg[7:4];    // present high nibble
                nibble_valid <= 1;
                sending_high <= 0;
                busy <= 0;                  // done after this cycle
            end

            else
                nibble_valid <= 0;          // idle, nothing to present
        end
    end
endmodule