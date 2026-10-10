module sync_2ff_tb;

    // parameters
    localparam WIDTH = 4;
    localparam SRC_CLK_PERIOD = 7;    // different period from destination clock,
    localparam DST_CLK_PERIOD = 10;

    // signals
    reg src_clk = 0;
    reg dst_clk = 0;
    reg rst = 0;
    reg [WIDTH-1:0] async_signal = 0;  // driven in the SOURCE domain
    wire [WIDTH-1:0] sync_out;      // read in the DESTINATION domain

    integer errors = 0;

    // instantiate DUT - note: clk here is the DESTINATION clock
    sync_2ff #(.WIDTH(WIDTH)) dut (
        .clk(dst_clk),
        .rst(rst),
        .async_in(async_signal),
        .sync_out(sync_out)
    );

    // two independent, differently-timed clocks
    always #(SRC_CLK_PERIOD/2) src_clk = ~src_clk;
    always #(DST_CLK_PERIOD/2) dst_clk = ~dst_clk;

    // ---- task: change async_signal in the SOURCE domain, then check it
    //            eventually appears correctly in the DESTINATION domain ----
    task check_value(input [WIDTH-1:0] val);
        begin
            @(posedge src_clk);
            async_signal = val;
    
            // wait enough DESTINATION clock cycles for the 2-flop chain to
            // fully propagate - 2 cycles minimum, give a few extra for margin
            repeat(4) @(posedge dst_clk);
            #1;
    
            if (sync_out !== val) begin
                $display("sync_out mismatch: expected %h, got %h", val, sync_out);
                errors = errors + 1;
            end
    
            $display("Checked value %h - synchronized correctly", val);
        end
    endtask

    // ---- main test sequence ----
    initial begin
        rst = 1;
        repeat(3) @(posedge dst_clk);
        rst = 0;
        repeat(3) @(posedge dst_clk);

        check_value(4'h5);
        check_value(4'hA);
        check_value(4'hF);
        check_value(4'h0);

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d ERROR(S) FOUND", errors);
        $finish;
    end
endmodule