module nibble_to_byte_tb;

    localparam CLK_PERIOD   = 10;

    // signals
    reg clk = 0;
    reg rst = 0;
    reg [3:0] nibble = 0;
    reg nibble_valid = 0;
    wire [7:0] byte_out;
    wire byte_valid;

    integer errors = 0;

    // instantiate DUT
    nibble_to_byte dut (
        .clk(clk),
        .rst(rst),
        .nibble(nibble),
        .nibble_valid(nibble_valid),
        .byte_out(byte_out),
        .byte_valid(byte_valid)
    );

    // clock generation
    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- task: feed one low+high nibble pair, verify the resulting byte ----
    task send_and_check(input [3:0] low_nibble, input [3:0] high_nibble);
        reg [7:0] expected_byte; 
        
        begin
            expected_byte = {high_nibble, low_nibble};
    
            // send low nibble
            @(posedge clk);
            nibble = low_nibble;
            nibble_valid = 1;
            @(negedge clk);        // deassert cleanly, well before the next posedge
            nibble_valid = 0;
    
            if (byte_valid !== 0) begin
                $display("byte_valid fired early, after only 1 nibble");
                errors = errors + 1;
            end
    
            // send high nibble
            @(posedge clk);
            nibble = high_nibble;
            nibble_valid = 1;
            @(negedge clk);
            nibble_valid = 0;
    
            // NOW byte_valid should be high, with the correct byte
            if (byte_valid !== 1) begin
                $display("byte_valid never asserted after 2nd nibble");
                errors = errors + 1;
            end
            if (byte_out !== expected_byte) begin
                $display("byte_out mismatch: expected %h, got %h", expected_byte, byte_out);
                errors = errors + 1;
            end
    
            $display("Sent nibbles low/high -- check complete");
        end
    endtask

    // ---- task: verify reset mid-assembly discards the partial byte ----
    task check_reset_midway();
        // send only a low nibble (never send the high one)
        begin
            @(posedge clk);
            nibble = 4'hA;
            nibble_valid = 1;
            @(posedge clk);
            #1;
            nibble_valid = 0;
    
            // now reset
            rst = 1;
            @(posedge clk);
            rst = 0;
            @(posedge clk);
    
            // send a fresh low+high pair - should assemble correctly,
            // NOT combine with the discarded 0xA from before reset
            send_and_check(4'h1, 4'h2);
        end
    endtask

    // ---- main test sequence ----
    initial begin
        rst = 1;
        repeat(3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // typical + edge-case nibble pairs
        send_and_check(4'h0, 4'h0);
        send_and_check(4'hF, 4'hF);
        send_and_check(4'h5, 4'hA);
        send_and_check(4'hA, 4'h5);

        // verify reset behavior mid-assembly
        check_reset_midway();

        // back-to-back bytes, no gaps - makes sure the module doesn't
        // need idle cycles between bytes to work correctly
        send_and_check(4'h3, 4'h7);
        send_and_check(4'h9, 4'hC);

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d ERROR(S) FOUND", errors);

        $finish;
    end
endmodule