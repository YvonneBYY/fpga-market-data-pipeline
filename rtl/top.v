module top (
    input  clk,
    input  btn,
    output [7:0] led
);
    localparam CLKS_PER_BIT = 868;

    wire tx_serial;
    wire tx_busy;
    wire [7:0] rx_data;
    wire rx_valid;
    wire rx_error;

    reg rst = 0;
    reg tx_start = 0;
    reg [7:0] tx_data = 8'hA5;
    reg [7:0] rx_data_latched = 0;
    reg rx_error_latched = 0;

    reg btn_d1 = 0, btn_d2 = 0;
    wire btn_pressed = btn_d1 & ~btn_d2;

    always @(posedge clk) begin
        btn_d2 <= btn_d1;
        btn_d1 <= btn;
    end

    UART_TX #(.CLKS_PER_BIT(CLKS_PER_BIT)) tx_dut (
        .clk(clk), .rst(rst), .tx_start(tx_start), .tx_data(tx_data),
        .tx(tx_serial), .tx_busy(tx_busy)
    );

    UART_RX #(.CLKS_PER_BIT(CLKS_PER_BIT)) rx_dut (
        .clk(clk), .rst(rst), .rx(tx_serial),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_error(rx_error)
    );

    always @(posedge clk) begin
        tx_start <= 1'b0;
        if (btn_pressed && !tx_busy)
            tx_start <= 1'b1;
        if (rx_valid) begin
            rx_data_latched <= rx_data;
            rx_error_latched <= rx_error;
        end
    end

    assign led = rx_data_latched;

endmodule