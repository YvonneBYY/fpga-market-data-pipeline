module eth_mac_rx_nibble_tb;

    // parameters
    localparam CLK_PERIOD = 10;

    // signals
    reg phy_rx_clk = 0;
    reg rst = 0;
    reg [3:0] phy_rxd = 0;
    reg phy_rx_dv = 0;
    reg phy_rx_er = 0;
    wire [7:0] data;
    wire data_valid;
    wire frame_start;
    wire frame_end;
    wire frame_error;

    integer errors = 0;

    // storage for a test frame's payload bytes
    reg [7:0] test_frame [0:63];
    integer test_frame_len;

    // storage for what the DUT actually produced
    reg [7:0] received_bytes [0:63];
    integer received_count;

    reg frame_start_seen;
    reg frame_end_seen;
    reg frame_error_latched;      // latches frame_error at the moment frame_end fires

    // instantiate DUT
    eth_mac_rx_nibble dut (
        .phy_rx_clk(phy_rx_clk),
        .rst(rst),
        .phy_rxd(phy_rxd),
        .phy_rx_dv(phy_rx_dv),
        .phy_rx_er(phy_rx_er),
        .data(data),
        .data_valid(data_valid),
        .frame_start(frame_start),
        .frame_end(frame_end),
        .frame_error(frame_error)
    );

    always #(CLK_PERIOD/2) phy_rx_clk = ~phy_rx_clk;

    // ---- task: send one nibble ----
    task send_nibble(input [3:0] val);
        begin
            phy_rxd = val;
            @(posedge phy_rx_clk);
        end
    endtask

    // ---- task: send preamble + SFD + test_frame[0..test_frame_len-1] ----
    task send_frame();
        integer i;
        begin
            phy_rx_dv = 1;

            for (i = 0; i < 7; i = i + 1) begin   // 7 preamble bytes
                send_nibble(4'h5);
                send_nibble(4'h5);
            end

            send_nibble(4'h5);                    // SFD low nibble
            send_nibble(4'hD);                    // SFD high nibble

            for (i = 0; i < test_frame_len; i = i + 1) begin
                send_nibble(test_frame[i][3:0]);
                send_nibble(test_frame[i][7:4]);
            end

            phy_rx_dv = 0;
            repeat (2) @(posedge phy_rx_clk);
        end
    endtask

    // ---- task: send a frame with phy_rx_er injected after a chosen byte ----
    task send_frame_with_error(input integer error_after_byte);
        integer i;
        begin
            phy_rx_dv = 1;

            for (i = 0; i < 7; i = i + 1) begin
                send_nibble(4'h5);
                send_nibble(4'h5);
            end

            send_nibble(4'h5);
            send_nibble(4'hD);

            for (i = 0; i < test_frame_len; i = i + 1) begin
                send_nibble(test_frame[i][3:0]);

                if (i == error_after_byte)
                    phy_rx_er = 1;

                send_nibble(test_frame[i][7:4]);

                if (i == error_after_byte)
                    phy_rx_er = 0;
            end

            phy_rx_dv = 0;
            repeat (2) @(posedge phy_rx_clk);
        end
    endtask

    // ---- task: capture every data_valid pulse until frame_end,
    //            latching frame_error at the moment frame_end fires ----
    task capture_frame();
        begin
            received_count = 0;
            frame_error_latched = 0;

            while (frame_end !== 1) begin
                @(posedge phy_rx_clk);

                if (data_valid) begin
                    received_bytes[received_count] = data;
                    received_count = received_count + 1;
                end

                if (frame_end && frame_error)
                    frame_error_latched = 1;
            end
        end
    endtask

    // ---- task: normal frame test ----
    task send_and_check_frame();
        integer i;
        begin
            fork
                send_frame();
                capture_frame();
            join

            if (received_count !== test_frame_len) begin
                $display("byte count mismatch: expected %0d, got %0d", test_frame_len, received_count);
                errors = errors + 1;
            end

            for (i = 0; i < test_frame_len; i = i + 1) begin
                if (received_bytes[i] !== test_frame[i]) begin
                    $display("byte %0d mismatch: expected %h, got %h", i, test_frame[i], received_bytes[i]);
                    errors = errors + 1;
                end
            end

            $display("Frame Check Complete");
        end
    endtask

    // ---- task: error-injection test ----
    task test_error_case();
        integer i;
        begin
            fork
                send_frame_with_error(1);
                capture_frame();
            join

            if (frame_error_latched !== 1) begin
                $display("frame_error not set despite phy_rx_er injection");
                errors = errors + 1;
            end

            if (received_count !== test_frame_len) begin
                $display("byte count mismatch: expected %0d, got %0d", test_frame_len, received_count);
                errors = errors + 1;
            end

            for (i = 0; i < test_frame_len; i = i + 1) begin
                if (received_bytes[i] !== test_frame[i]) begin
                    $display("byte %0d mismatch: expected %h, got %h", i, test_frame[i], received_bytes[i]);
                    errors = errors + 1;
                end
            end

            $display("Error-case check complete");
        end
    endtask

    // ---- task: abort mid-preamble ----
    task test_abort_mid_preamble();
        begin
            frame_start_seen = 0;

            fork : abort_watch
                begin
                    forever begin
                        @(posedge phy_rx_clk);
                        if (frame_start)
                            frame_start_seen = 1;
                    end
                end

                begin
                    phy_rx_dv = 1;

                    send_nibble(4'h5);
                    send_nibble(4'h5);
                    send_nibble(4'h5);
                    send_nibble(4'h5);

                    phy_rx_dv = 0;
                    repeat (6) @(posedge phy_rx_clk);

                    disable abort_watch;
                end
            join

            if (frame_start_seen !== 0) begin
                $display("frame_start incorrectly fired during aborted preamble");
                errors = errors + 1;
            end

            $display("Abort-mid-preamble check complete");
        end
    endtask

    // ---- task: abort mid-data ----
    task test_abort_mid_data();
        integer i;
        begin
            phy_rx_dv = 1;
            frame_end_seen = 0;
            received_count = 0;

            for (i = 0; i < 7; i = i + 1) begin
                send_nibble(4'h5);
                send_nibble(4'h5);
            end

            send_nibble(4'h5);
            send_nibble(4'hD);

            // send only the FIRST byte of test_frame, then abort
            send_nibble(test_frame[0][3:0]);
            send_nibble(test_frame[0][7:4]);

            phy_rx_dv = 0;

            repeat (5) begin
                @(posedge phy_rx_clk);
                if (frame_end)
                    frame_end_seen = 1;
                if (data_valid) begin
                    received_bytes[received_count] = data;
                    received_count = received_count + 1;
                end
            end

            if (frame_end_seen !== 1) begin
                $display("frame_end never fired after mid-data abort");
                errors = errors + 1;
            end

            if (received_count !== 1) begin
                $display("byte count mismatch: expected 1, got %0d", received_count);
                errors = errors + 1;
            end

            if (received_count >= 1 && received_bytes[0] !== test_frame[0]) begin
                $display("byte 0 mismatch: expected %h, got %h", test_frame[0], received_bytes[0]);
                errors = errors + 1;
            end

            $display("Abort-mid-data check complete");
        end
    endtask

    // ---- main test sequence ----
    initial begin
        rst = 1;
        repeat (3) @(posedge phy_rx_clk);
        rst = 0;
        @(posedge phy_rx_clk);

        test_frame_len = 3;
        test_frame[0] = 8'h00;
        test_frame[1] = 8'hFF;
        test_frame[2] = 8'hA5;

        send_and_check_frame();
        test_error_case();
        test_abort_mid_preamble();
        test_abort_mid_data();

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d ERROR(S) FOUND", errors);

        $finish;
    end

endmodule