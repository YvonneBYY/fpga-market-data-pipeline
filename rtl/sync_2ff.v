module sync_2ff #(
    parameter WIDTH = 4
) (
    input                   clk,      // the DESTINATION domain's clock
    input                   rst,
    input      [WIDTH-1:0]  async_in, // signal coming FROM the other clock domain
    output reg [WIDTH-1:0]  sync_out  // safely synchronized, usable in THIS domain
);
    reg [WIDTH-1:0] sync_mid;
    always @(posedge clk) begin
        if (rst) begin
            sync_mid <= 0;
            sync_out <= 0;
        end
        else begin
            sync_mid <= async_in;
            sync_out <= sync_mid;
        end
    end
endmodule