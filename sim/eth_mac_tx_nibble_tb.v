module eth_mac_tx_nibble_tb;

    // parameters
    localparam CLK_PERIOD = 10;

    // signals
    reg phy_tx_clk = 0;
    reg rst = 0;
    reg tx_start = 0;
    reg [7:0] tx_data = 0;
    reg tx_data_valid = 0;
    reg tx_last = 0;
    wire [3:0] phy_txd;
    wire phy_tx_en;
    wire tx_ready;
    wire tx_busy;

    integer errors = 0;
    integer i=0;

    // storage for expected nibble sequence (preamble + SFD + data, fully expanded)
    reg [3:0] expected_nibbles [0:127];
    integer expected_len;

    // storage for what the DUT actually produced
    reg [3:0] captured_nibbles [0:127];
    integer captured_len;
    
    integer frame_len;
    reg [7:0] frame_bytes [0:63];

    // instantiate DUT
    eth_mac_tx_nibble dut (
        .phy_tx_clk(phy_tx_clk),
        .rst(rst),
        .tx_start(tx_start),
        .tx_data(tx_data),
        .tx_data_valid(tx_data_valid),
        .tx_last(tx_last),
        .phy_txd(phy_txd),
        .phy_tx_en(phy_tx_en),
        .tx_ready(tx_ready),
        .tx_busy(tx_busy)
    );

    always #(CLK_PERIOD/2) phy_tx_clk = ~phy_tx_clk;

    // ---- task: build the expected nibble sequence for a given frame ----
    task build_expected();
        integer i;
        begin
            expected_len = 0;
    
            for (i=0; i<7; i=i+1) begin                     // 7 preamble bytes
                expected_nibbles[expected_len] = 4'h5; 
                expected_len = expected_len + 1;
                expected_nibbles[expected_len] = 4'h5; 
                expected_len = expected_len + 1;
            end
    
            expected_nibbles[expected_len] = 4'h5; 
            expected_len = expected_len + 1;   // SFD low
            expected_nibbles[expected_len] = 4'hD; 
            expected_len = expected_len + 1;  // SFD high
    
            for (i=0; i<frame_len; i=i+1) begin
                expected_nibbles[expected_len] = frame_bytes[i][3:0]; 
                expected_len = expected_len + 1;
                expected_nibbles[expected_len] = frame_bytes[i][7:4]; 
                expected_len = expected_len + 1;
            end
        end
    endtask

    // ---- task: capture every nibble while phy_tx_en is high ----
    task capture_frame();
        begin : capture_block
            captured_len = 0;
    
            forever begin
                @(posedge phy_tx_clk);
                #1;
    
                if (phy_tx_en) begin
                    captured_nibbles[captured_len] = phy_txd;
                    captured_len = captured_len + 1;
                end
    
                // Once we've captured something and TX_EN goes low,
                // the frame is over.
                else if (captured_len > 0) begin
                    disable capture_block;
                end
            end
        end
    endtask

    // ---- task: drive tx_start, then feed bytes via the ready/valid handshake ----
    task send_frame();
        integer i;
        begin
            @(negedge phy_tx_clk);
            tx_start = 1;
            @(negedge phy_tx_clk);
            tx_start = 0;

            for (i=0; i<frame_len; i=i+1) begin
                // wait for tx_ready before presenting each byte
                while (!tx_ready) begin
                    @(posedge phy_tx_clk);
                    #1;
                end

                @(negedge phy_tx_clk);
                tx_data = frame_bytes[i];
                tx_data_valid = 1;
                tx_last = (i == frame_len - 1);

                @(negedge phy_tx_clk);
                tx_data_valid = 0;
                tx_last = 0;
            end
        end
    endtask

    // ---- task: run one full test - send + capture concurrently, then compare ----
    task test_frame();
        integer i;
        begin
            build_expected();

            fork
                send_frame();
                capture_frame();
            join

            if (captured_len !== expected_len) begin
                $display("nibble count mismatch: expected %h, got %h", expected_len, captured_len);
                errors = errors + 1;
            end

            for (i=0; i<expected_len; i=i+1) begin
                if (captured_nibbles[i] !== expected_nibbles[i]) begin
                    $display("nibble %h mismatch: expected %h, got %h", i, expected_nibbles[i], captured_nibbles[i]);
                    errors = errors + 1;
                end
            end

            $display("Frame check completed");
        end
    endtask
    
    // ---- task: measure how long tx_busy stays high after phy_tx_en drops ----
    task check_ifg_duration();
        integer cycles_waited;
        begin
            // wait for the frame to end (phy_tx_en drops)
            @(negedge phy_tx_en);
    
            cycles_waited = 0;
            while (tx_busy) begin
                @(posedge phy_tx_clk);
                #1;
                cycles_waited = cycles_waited + 1;
            end
    
            if (cycles_waited !== 24) begin   // IFG_CYCLES, hardcoded here for clarity
                $display("IFG duration mismatch: expected 24 cycles, got %0d", cycles_waited);
                errors = errors + 1;
            end
    
            $display("IFG duration check complete");
        end
    endtask
    
    // ---- task: try asserting tx_start WHILE tx_busy is still high, confirm it's ignored ----
    task test_early_tx_start_ignored();
        begin
            // assumes we're called right after a frame just finished sending,
            // while tx_busy should still be high (mid-IFG)
            @(negedge phy_tx_en);
            
            if (!tx_busy) begin
                $display("tx_busy dropped too early at start of IFG");
                errors = errors + 1;
            end
    
            // try to start a new frame too early
            repeat(3) @(posedge phy_tx_clk);
            
            @(negedge phy_tx_clk);
            tx_start = 1;
    
            @(negedge phy_tx_clk);
            tx_start = 0;
    
            if (phy_tx_en !== 0) begin
                $display("phy_tx_en incorrectly went high during IFG");
                errors = errors + 1;
            end
    
            if (!tx_busy) begin
                $display("tx_busy unexpectedly low during IFG");
                errors = errors + 1;
            end
    
            $display("Early tx_start-during-IFG check complete");
        end
    endtask
    
    // ---- main test sequence ----
    initial begin
        rst = 1;
        repeat(5) @(posedge phy_tx_clk);
        rst = 0;
        repeat(5) @(posedge phy_tx_clk);

        // test 1: normal 3-byte frame
        frame_len = 3;
        frame_bytes[0] = 8'h00; 
        frame_bytes[1] = 8'hFF; 
        frame_bytes[2] = 8'hA5;
        build_expected();
        
        fork
            send_frame();
            capture_frame();
            check_ifg_duration();
            test_early_tx_start_ignored();
        join
    
        if (captured_len !== expected_len) begin
            $display("nibble count mismatch: expected %0d, got %0d", expected_len, captured_len);
            errors = errors + 1;
        end
        
        for (i = 0; i < expected_len; i = i + 1) begin
            if (captured_nibbles[i] !== expected_nibbles[i]) begin
                $display(
                    "nibble %0d mismatch: expected %h, got %h",i,expected_nibbles[i],captured_nibbles[i]);
                errors = errors + 1;
            end
        end
        
        // test 2: back-to-back single-byte-gap-free frame (different data,
        // confirms tx_ready timing works for a different length too)
        frame_len = 2;
        frame_bytes[0] = 8'h11; 
        frame_bytes[1] = 8'h22;
        test_frame();

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d ERROR(S) FOUND", errors);
        $finish;
    end
endmodule