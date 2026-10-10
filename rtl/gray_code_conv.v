module bin_to_gray #(
    parameter WIDTH = 4
) (
    input  [WIDTH-1:0] binary,
    output [WIDTH-1:0] gray
);
    assign gray = (binary>>1)^binary;
endmodule


module gray_to_bin #(
    parameter WIDTH = 4
) (
    input [WIDTH-1:0] gray,
    output reg [WIDTH-1:0] binary
);
    integer i;
    always @(*) begin
        binary[WIDTH-1] = gray[WIDTH-1];
        for(i=WIDTH-2; i>=0; i=i-1) begin
            binary[i] = binary[i+1]^gray[i];
        end
    end
endmodule
