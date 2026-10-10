module crc32_check_tb;

    // parameters
    localparam CLK_PERIOD = 10;

    // signals
    reg clk = 0;
    reg rst = 0;
    reg [7:0] data = 0;
    reg data_valid = 0;
    reg frame_start = 0;
    reg frame_end = 0;
    wire crc_valid;
    wire crc_ok;

    integer errors = 0;
    
    reg [7:0] frame_bytes [0:63];
    integer   frame_len;

    // instantiate DUT
    crc32_check dut (
        .clk(clk),
        .rst(rst),
        .data(data),
        .data_valid(data_valid),
        .frame_start(frame_start),
        .frame_end(frame_end),
        .crc_valid(crc_valid),
        .crc_ok(crc_ok)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- task: feed one byte, with optional frame_start/frame_end flags ----
    task send_byte(input [7:0] val, input is_first);
        begin
            data = val;
            data_valid = 1;
            frame_start = is_first;
            frame_end = 0;            // frame_end is driven separately, see send_frame_bytes
            @(posedge clk);
            @(negedge clk);
            data_valid = 0;
            frame_start = 0;
        end
    endtask

    // ---- task: send a full sequence of bytes (data + FCS already combined),
    //            then pulse frame_end one cycle after the last byte ----
    task send_frame_bytes();
        integer i;
        begin
            for (i=0; i<frame_len; i=i+1) begin
                send_byte(frame_bytes[i], (i==0));
            end
            
            // frame_end fires the cycle AFTER the last byte's data_valid,
            // matching how eth_mac_rx_nibble actually generates it
            @(posedge clk);
            frame_end = 1;
            @(posedge clk);
            frame_end = 0;
        end
    endtask

    // ---- task: send a frame, wait for crc_valid, check crc_ok against expected ----
    task test_frame(input expected_ok);
        begin
            fork
                send_frame_bytes();
                @(posedge crc_valid);   // wait for the result to be ready
            join

            if (crc_ok !== expected_ok) begin
                $display("crc_ok mismatch: expected %h, got %h", expected_ok ,crc_ok);
                errors = errors + 1;
            end
            $display("Frame Check Complete");
        end
    endtask

    // ---- main test sequence ----
    initial begin
        rst = 1;
        repeat(3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // test 1: valid frame 1
        frame_len = 7;
        frame_bytes[0] = 8'h00; 
        frame_bytes[1] = 8'hFF; 
        frame_bytes[2] = 8'hA5;
        frame_bytes[3] = 8'h07; 
        frame_bytes[4] = 8'h73; 
        frame_bytes[5] = 8'hD9; 
        frame_bytes[6] = 8'hCA;
        test_frame(1);
        
        // test 2: valid frame 2
        frame_len = 9;
        frame_bytes[0] = 8'h11; 
        frame_bytes[1] = 8'h22; 
        frame_bytes[2] = 8'h33;
        frame_bytes[3] = 8'h44; 
        frame_bytes[4] = 8'h55; 
        frame_bytes[5] = 8'h29;
        frame_bytes[6] = 8'h5A; 
        frame_bytes[7] = 8'hA0; 
        frame_bytes[8] = 8'h38;
        test_frame(1);
        
        // test 3: corrupted frame - flip test 1's first byte
        frame_len = 7;
        frame_bytes[0] = 8'h01;  // was 0x00
        frame_bytes[1] = 8'hFF; 
        frame_bytes[2] = 8'hA5;
        frame_bytes[3] = 8'h07; 
        frame_bytes[4] = 8'h73; 
        frame_bytes[5] = 8'hD9; 
        frame_bytes[6] = 8'hCA;
        test_frame(0);

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d ERROR(S) FOUND", errors);
        $finish;
    end
endmodule