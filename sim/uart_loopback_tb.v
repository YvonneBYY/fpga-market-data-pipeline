`timescale 1ns/1ps
module UART_LOOPBACK_tb;

    // parameters
    localparam CLKS_PER_BIT = 4;
    localparam CLK_PERIOD   = 10; // 10ns -> 100MHz, arbitrary for sim

    // signals
    reg  clk = 0;
    reg  rst = 0;
    reg  tx_start = 0;
    reg  [7:0] tx_data = 0;
    wire tx_serial;    // TX's output - this IS the loopback wire, feeds straight into RX's input
    wire tx_busy;
    wire [7:0] rx_data;
    wire rx_valid;
    wire rx_error;

    integer errors = 0;

    // instantiate BOTH DUTs this time, not just one
    UART_TX #(.CLKS_PER_BIT(CLKS_PER_BIT)) tx_dut (
        .clk(clk), 
        .rst(rst), 
        .tx_start(tx_start), 
        .tx_data(tx_data),
        .tx(tx_serial), 
        .tx_busy(tx_busy)
    );

    UART_RX #(.CLKS_PER_BIT(CLKS_PER_BIT)) rx_dut (
        .clk(clk),
        .rst(rst),
        .rx(tx_serial),
        .rx_data(rx_data),
        .rx_valid(rx_valid),
        .rx_error(rx_error)
    );

    // clock generation - same as always
    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- task: send one byte through TX, verify RX receives it correctly ----
    task send_and_check(input [7:0] data);
        begin            
            fork
                // branch 1: drive TX's inputs to start transmission
                begin
                    @(posedge clk);
                    while (tx_busy) @(posedge clk);  
                    tx_data = data;
                      
                    //pull tx_start high for one clk cycle
                    @(posedge clk);
                    @(posedge clk);
                    tx_start = 1'b1;
                    @(posedge clk);
                    tx_start = 1'b0;
                end
        
                // branch 2: watch for RX to catch the byte, concurrently
                begin
                    @(posedge rx_valid); 
                    #1;
                    if(rx_data !== data) begin
                        $display("ERROR: rx_data mismatch: expected %h, got %h", data, rx_data);
                        errors = errors + 1;
                    end
                    
                    if (rx_error) begin
                        $display("ERROR: unexpected rx_error on clean loopback, data=%h", data);
                        errors = errors + 1;
                    end
                end
            join
    
            $display("Sent 0x%h - check complete", data);
        end
    endtask

    // ---- main test sequence ----
    initial begin
        rst = 1;
        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        send_and_check(8'h00);
        send_and_check(8'hFF);
        send_and_check(8'hA5);
        send_and_check(8'h55);
        send_and_check(8'h37);

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d ERROR(S) FOUND", errors);
        $finish;
    end
endmodule