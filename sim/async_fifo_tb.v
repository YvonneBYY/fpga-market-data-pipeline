module async_fifo_tb;

    // parameters
    localparam DATA_WIDTH = 8;
    localparam ADDR_WIDTH = 4;     // 16-entry FIFO
    localparam WR_CLK_PERIOD = 7;   // different periods, genuinely asynchronous
    localparam RD_CLK_PERIOD = 10;

    // signals
    reg wr_clk = 0, wr_rst = 0;
    reg [DATA_WIDTH-1:0] wr_data = 0;
    reg wr_en = 0;
    wire full;

    reg rd_clk = 0, rd_rst = 0;
    wire [DATA_WIDTH-1:0] rd_data;
    reg rd_en = 0;
    wire empty;

    integer errors = 0;

    // storage for expected data (what we wrote, in order)
    reg [DATA_WIDTH-1:0] expected_data [0:255];
    integer expected_count;

    // storage for what we actually read back
    reg [DATA_WIDTH-1:0] actual_data [0:255];
    integer actual_count;

    // instantiate DUT
    async_fifo #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) dut (
        .wr_clk(wr_clk),
        .wr_rst(wr_rst),
        .wr_data(wr_data),
        .wr_en(wr_en),
        .full(full),
        
        .rd_clk(rd_clk),
        .rd_rst(rd_rst),
        .rd_data(rd_data),
        .rd_en(rd_en),
        .empty(empty)
    );

    always #(WR_CLK_PERIOD/2) wr_clk = ~wr_clk;
    always #(RD_CLK_PERIOD/2) rd_clk = ~rd_clk;

    // ---- task: write one byte, waiting if full ----
    task write_byte(input [DATA_WIDTH-1:0] val);
        begin
            while (full) begin
                @(posedge wr_clk);
                #1;
            end
    
            @(negedge wr_clk);
            wr_data = val;
            wr_en = 1;
            @(negedge wr_clk);
            wr_en = 0;
    
            expected_data[expected_count] = val;
            expected_count = expected_count + 1;
        end
    endtask

    // ---- task: read one byte, waiting if empty ----
    task read_byte();
        begin
            while (empty) @(posedge rd_clk);
    
            @(negedge rd_clk);
            rd_en = 1;
            @(negedge rd_clk);
            rd_en = 0;
            @(posedge rd_clk);   // wait one more cycle - registered read, data valid AFTER rd_en
            #1;
    
            actual_data[actual_count] = rd_data;
            actual_count = actual_count + 1;
        end
    endtask

    // ---- test 1: basic write-then-read, small count ----
    task test_basic();
        integer i;
        begin
            expected_count = 0;
            actual_count = 0;
    
            for (i=0; i<5; i=i+1)
                write_byte(i * 10);
    
            for (i=0; i<5; i=i+1)
                read_byte();
                
            for (i=0; i<5; i=i+1) begin
                if (actual_data[i] !== expected_data[i]) begin
                    $display("data mismatch at %h: expected %h, got %h", i, expected_data[i], actual_data[i]);
                    errors = errors + 1;
                end
            end
        end
    endtask

    // ---- test 2: fill the FIFO completely, verify full asserts ----
    task test_fill_to_full();
        integer i;
        begin
            expected_count = 0;
    
            for (i=0; i<16; i=i+1)  // DEPTH = 16
                write_byte(i);
    
            if (!full) begin
                $display("full not asserted after writing DEPTH bytes");
                errors = errors + 1;
            end
        end
    endtask

    // ---- test 3: drain the full FIFO, verify empty asserts at the end ----
    task test_drain_to_empty();
        integer i;
        begin
            actual_count = 0;
    
            for (i=0; i<16; i=i+1)
                read_byte();
    
            if (!empty) begin
                $display("empty not asserted after reading all bytes");
                errors = errors + 1;
            end
            
            for (i=0; i<16; i=i+1) begin
                if(actual_data[i] !== expected_data[i]) begin
                    $display("data mismatch at depth %h: expected %h, got %h", i, expected_data[i], actual_data[i]);
                    errors = errors + 1;
                end
            end
        end
    endtask

    // ---- main test sequence ----
    initial begin
        wr_rst = 1; 
        rd_rst = 1;
        repeat(5) @(posedge wr_clk);
        wr_rst = 0; 
        rd_rst = 0;
        repeat(5) @(posedge wr_clk);

        if (!empty)
            $display("FIFO not empty immediately after reset");

        test_basic();
        test_fill_to_full();
        test_drain_to_empty();

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d ERROR(S) FOUND", errors);
        $finish;
    end
endmodule