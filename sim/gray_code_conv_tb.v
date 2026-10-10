module gray_code_conv_tb;

    // parameters
    localparam WIDTH = 4;

    // signals - no clock needed, these are pure combinational modules
    reg [WIDTH-1:0] test_binary;
    wire [WIDTH-1:0] gray_out;
    wire [WIDTH-1:0] binary_out;

    integer errors = 0;
    integer i=0;

    // instantiate both modules, chained together
    bin_to_gray #(.WIDTH(WIDTH)) enc (
        .binary(test_binary),
        .gray(gray_out)
    );

    gray_to_bin #(.WIDTH(WIDTH)) dec (
        .gray(gray_out),
        .binary(binary_out)
    );
    
    function integer count_ones;
        input [WIDTH-1:0] value;
        integer j;
        begin
            count_ones = 0;
            for (j = 0; j < WIDTH; j = j + 1)
                if (value[j])
                    count_ones = count_ones + 1;
        end
    endfunction

    // ---- task: check one value round-trips correctly ----
    task check_value(input [WIDTH-1:0] val);
        begin
            test_binary = val;
            #1;   // small delay for output to update
    
            if (binary_out !== val) begin
                $display("round-trip mismatch: sent %h, got back %h (gray was %h)", val, binary_out, gray_out);
                errors = errors + 1;
            end
    
            $display("Check 0x%h, round trip okay", val);
        end
    endtask

    // ---- task: verify consecutive Gray values differ by exactly one bit ----
    task check_single_bit_change(input [WIDTH-1:0] val1, input [WIDTH-1:0] val2);
        reg [WIDTH-1:0] gray1, gray2, diff;
        integer bit_count;
        begin
    
            test_binary = val1;
            #1;
            gray1 = gray_out;
    
            test_binary = val2;
            #1;
            gray2 = gray_out;
    
            diff = gray1 ^ gray2;
            // count how many bits are set in diff - should be exactly 1
            bit_count = count_ones(diff);   // need a way to count set bits
    
            if (bit_count !== 1) begin
                $display("consecutive values differ by more than one Gray bit");
                errors = errors + 1;
            end
        end
    endtask

    // ---- main test sequence ----
    initial begin
        // test every value round-trips correctly
        for (i = 0; i < 2**WIDTH; i=i+1)
            check_value(i);

        // test that consecutive binary values produce single-bit-different Gray codes
        for (i = 0; i < 2**WIDTH-1; i=i+1)
            check_single_bit_change(i, i+1);

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d ERROR(S) FOUND", errors);
        $finish;
    end
endmodule