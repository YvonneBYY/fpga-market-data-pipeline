`timescale 1ns/1ps

module UART_RX_tb;

    // small value so simulation doesn't take forever - real design uses 868
    localparam CLKS_PER_BIT = 4;
    localparam CLK_PERIOD   = 10; // 10ns -> 100MHz, arbitrary for sim
    // signals
    reg  clk = 0;
    reg  rst = 0;
    reg  rx  = 1;     // idle-high, matches real UART idle state
    wire [7:0] rx_data;
    wire rx_valid;
    wire rx_error;

    integer errors = 0;           // running count for pass/fail summary

    // instantiate DUT
    UART_RX #(.CLKS_PER_BIT(CLKS_PER_BIT)) dut (
        .clk(clk),
        .rst(rst),
        .rx(rx),
        .rx_data(rx_data),
        .rx_valid(rx_valid),
        .rx_error(rx_error)
    );

    // clock generation
    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- task: drive one full UART frame onto rx, bit by bit ----
    task send_byte_on_rx(input [7:0] data);
        integer i; 
        begin
            rx = 0; //start bit
            repeat (CLKS_PER_BIT) @(posedge clk);
            
            for(i=0; i<8; i=i+1) begin
                rx = data[i];    //load each rx to data
                repeat (CLKS_PER_BIT) @(posedge clk);
            end
            
            rx = 1; //stop bit
            repeat (CLKS_PER_BIT) @(posedge clk);
        end

    endtask

    // ---- task: send a byte and check the DUT decoded it correctly ----
    task send_and_check(input [7:0] data);
        begin
            fork
                send_byte_on_rx(data);
                begin
                    @(posedge rx_valid);   // waits concurrently, can't miss the pulse
                    #1;                    // let NBA settle before reading rx_data
                    if (rx_data !== data) begin
                        $display("ERROR: rx_data mismatch: expected %h, got %h", data, rx_data);
                        errors = errors + 1;
                    end
                    if (rx_error) begin
                        $display("ERROR: unexpected rx_error on clean frame, data=%h", data);
                        errors = errors + 1;
                    end
                end
            join
    
            $display("Sent 0x%h - check complete", data);
        end
    endtask


    // ---- task: send a frame with a bad stop bit, check rx_error fires ----
    task send_bad_frame();
        integer i;
        begin
            rx = 1'b0;
            repeat (CLKS_PER_BIT) @(posedge clk);
            
            for (i=0; i<8; i=i+1) begin
                rx = 1'b0;    // arbitrary data bits
                repeat (CLKS_PER_BIT) @(posedge clk);
            end
            
            rx = 1'b0;   // BAD stop bit - should be 1
            repeat (CLKS_PER_BIT) @(posedge clk);
            
            repeat (3) @(posedge clk);
            
            if (!rx_error) begin
                $display("ERROR: rx_error not asserted on bad stop bit");
                errors = errors + 1;
            end
            
        end
    endtask

    // ---- main test sequence ----
    initial begin
        rst = 1;
        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // check idle state after reset
        if (rx_valid |  rx_error ) begin
            $display("ERROR:  not idle after reset");
            errors = errors + 1;
        end

        // typical + edge-case bytes, same spirit as the TX testbench
        send_and_check(8'h00);
        send_and_check(8'hFF);
        send_and_check(8'hA5);
        send_and_check(8'h55);
        send_and_check(8'h37);

        // error-path check
        send_bad_frame();

        // summary
        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d ERROR(S) FOUND", errors);

        $finish;
    end
endmodule