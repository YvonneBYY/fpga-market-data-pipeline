//Nibbles are assembled low nibble first, then high nibble 
//(matches MII convention: byte_out = {high_nibble, low_nibble})
//byte_valid pulses exactly once every 2 valid nibbles
//On rst, the module resets to expecting a low nibble next; any nibble mid-assembly is discarded

//NOTE:
//The module assembles every nibble it's given, in the order given. 
//The caller is responsible for only asserting nibble_valid when a nibble is genuinely meaningful
module nibble_to_byte(
    input            clk,
    input            rst,
    input [3:0]      nibble,
    input            nibble_valid,
    output reg [7:0] byte_out,
    output reg       byte_valid
);
    
    reg wait_for_high;
    reg [3:0] low_nibble_reg;

    always @(posedge clk) begin
        if (rst) begin
            wait_for_high <= 0;   // start expecting the LOW nibble first
            byte_valid <= 0;
            byte_out <= 0;
        end

        else begin
            byte_valid <= 0;   // default low every cycle - one-cycle pulse

            if (nibble_valid) begin
                if (!wait_for_high) begin
                    // this is the low nibble
                    low_nibble_reg <= nibble;
                    wait_for_high <= 1;
                end
                else begin
                    // this is the high nibble - combine and emit
                    byte_out <= { nibble, low_nibble_reg };
                    byte_valid <= 1;
                    wait_for_high <= 0;   // reset for the next byte
                end
            end
        end
    end
endmodule