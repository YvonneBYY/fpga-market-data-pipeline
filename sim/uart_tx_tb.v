`timescale 1ns/1ps

module UART_TX_tb;

    // small value so simulation doesn't take forever - real design uses 868
    localparam CLKS_PER_BIT = 4;
    localparam CLK_PERIOD   = 10; // 10ns -> 100MHz, arbitrary for sim

    reg clk = 0;
    reg rst = 0;
    reg tx_start = 0;
    reg [7:0] tx_data = 0;
    wire tx;
    wire tx_busy;

    integer errors = 0;

    // instantiate the DUT (device under test)
    UART_TX #(.CLKS_PER_BIT(CLKS_PER_BIT)) dut (
        .clk(clk),
        .rst(rst),
        .tx_start(tx_start),
        .tx_data(tx_data),
        .tx(tx),
        .tx_busy(tx_busy)
    );

    // clock generation
    always #(CLK_PERIOD/2) clk = ~clk;

    // task: send one byte and check the serial output bit-by-bit
    task send_and_check(input [7:0] data);
        integer i;
        begin
            @(posedge clk);
            tx_data  = data;
            tx_start = 1;
            @(posedge clk);
            tx_start = 0;

            // tx_busy should be high now
            if (tx_busy !== 1'b1) begin
                $display("ERROR: tx_busy not asserted after tx_start, data=%h", data);
                errors = errors + 1;
            end

            // wait to middle of START bit, check it's 0
            //sampling right at a bit transition risks catching the signal during the clock edge itself
            repeat (CLKS_PER_BIT/2) @(posedge clk);
            if (tx !== 1'b0) begin
                $display("ERROR: start bit wrong, expected 0 got %b, data=%h", tx, data);
                errors = errors + 1;
            end

            // check each data bit, LSB first
            for (i = 0; i < 8; i = i + 1) begin
                repeat (CLKS_PER_BIT) @(posedge clk); // advance to middle of next bit
                if (tx !== data[i]) begin
                    $display("ERROR: bit %0d wrong, expected %b got %b, data=%h", i, data[i], tx, data);
                    errors = errors + 1;
                end
            end

            // check stop bit
            repeat (CLKS_PER_BIT) @(posedge clk);
            if (tx !== 1'b1) begin
                $display("ERROR: stop bit wrong, expected 1 got %b, data=%h", tx, data);
                errors = errors + 1;
            end

            // tx_busy should drop back to 0 shortly after
            repeat (CLKS_PER_BIT) @(posedge clk);
            if (tx_busy !== 1'b0) begin
                $display("ERROR: tx_busy still high after transmission done, data=%h", data);
                errors = errors + 1;
            end

            $display("Sent 0x%h - check complete", data);
        end
    endtask

    initial begin
        // reset sequence
        rst = 1;
        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // check idle state after reset
        if (tx !== 1'b1) begin
            $display("ERROR: tx not idle-high after reset");
            errors = errors + 1;
        end

        // test a few bytes, including edge cases
        send_and_check(8'h00);   // all zeros
        send_and_check(8'hFF);   // all ones
        send_and_check(8'hA5);   // alternating pattern
        send_and_check(8'h55);   // alternating, inverted
        send_and_check(8'h37);   // arbitrary

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d ERROR(S) FOUND", errors);

        $finish;
    end

endmodule