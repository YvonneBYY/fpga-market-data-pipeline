module byte_to_nibble_tb;

    // parameters
    localparam CLK_PERIOD = 10;

    // signals
    reg clk = 0;
    reg rst = 0;
    reg [7:0] byte_in = 0;
    reg byte_valid = 0;
    wire [3:0] nibble;
    wire nibble_valid;
    wire busy;

    integer errors = 0;

    // instantiate DUT
    byte_to_nibble dut (
        .clk(clk),
        .rst(rst),
        .byte_in(byte_in),
        .byte_valid(byte_valid),
        .nibble(nibble),
        .nibble_valid(nibble_valid),
        .busy(busy)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- task: send one byte, verify both nibbles come out correctly in order ----
    task send_and_check(input [7:0] data);
        reg [3:0] expected_low, expected_high;
        begin
    
            expected_low  = data[3:0];
            expected_high = data[7:4];
    
            // Wait until falling edge before changing DUT inputs
            @(negedge clk);
    
            if (busy !== 0) begin
                $display("busy already high before send - testbench/DUT out of sync");
                errors = errors + 1;
            end
    
            byte_in    = data;
            byte_valid = 1;
    
            // Rising edge: DUT accepts byte and outputs LOW nibble
            @(posedge clk);
            #1;
    
            if (nibble_valid !== 1) begin
                $display("nibble_valid not asserted for low nibble");
                errors = errors + 1;
            end
    
            if (nibble !== expected_low) begin
                $display("low nibble mismatch: expected %h, got %h",
                         expected_low, nibble);
                errors = errors + 1;
            end
    
            if (busy !== 1) begin
                $display("busy not asserted after first nibble");
                errors = errors + 1;
            end
    
            // Stop asserting byte_valid safely between sampling edges
            @(negedge clk);
            byte_valid = 0;
    
            // Next rising edge: DUT outputs HIGH nibble
            @(posedge clk);
            #1;
    
            if (nibble_valid !== 1) begin
                $display("nibble_valid not asserted for high nibble");
                errors = errors + 1;
            end
    
            if (nibble !== expected_high) begin
                $display("high nibble mismatch: expected %h, got %h",
                         expected_high, nibble);
                errors = errors + 1;
            end
    
            if (busy !== 0) begin
                $display("busy still asserted after second nibble - should have cleared");
                errors = errors + 1;
            end
    
            $display("Sent 0x%h - check complete", data);
        end
    endtask

    // ---- main test sequence ----
    initial begin
        rst = 1;
    
        repeat(5) @(posedge clk);
    
        @(negedge clk);
        rst = 0;
    
        repeat(5) @(posedge clk);
    
        send_and_check(8'h00);
        send_and_check(8'hFF);
        send_and_check(8'hA5);
        send_and_check(8'h5A);
        send_and_check(8'h37);
        send_and_check(8'h9C);
    
        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d ERROR(S) FOUND", errors);
    
        $finish;
    end
endmodule