`timescale 1ns/1ps

module ip_udp_tx_builder_tb;

    reg clk = 0;
    always #5 clk = ~clk;

    reg        rst = 1;
    reg        in_start = 0;
    reg [47:0] in_dest_mac = 0;
    reg [31:0] in_dest_ip = 0;
    reg [15:0] in_src_port = 0;
    reg [15:0] in_dst_port = 0;
    reg [7:0]  in_data = 0;
    reg        in_data_valid = 0;
    reg        in_last = 0;

    wire       tx_valid, tx_last;
    wire [7:0] tx_byte;

    localparam [47:0] OUR_MAC = 48'h02_00_00_00_00_01;
    localparam [31:0] OUR_IP  = {8'd169, 8'd254, 8'd89, 8'd52};

    ip_udp_tx_builder #(.OUR_MAC(OUR_MAC), .OUR_IP(OUR_IP)) dut (
        .clk(clk), .rst(rst),
        .in_start(in_start), .in_dest_mac(in_dest_mac), .in_dest_ip(in_dest_ip),
        .in_src_port(in_src_port), .in_dst_port(in_dst_port),
        .in_data(in_data), .in_data_valid(in_data_valid), .in_last(in_last),
        .tx_valid(tx_valid), .tx_byte(tx_byte), .tx_last(tx_last)
    );

    // Proper synchronous capture (lesson from ip_udp_rx_parser's testbench)
    reg [7:0] cap [0:255];
    integer   cap_len;
    always @(posedge clk) begin
        if (rst) begin
            cap_len <= 0;
        end else if (tx_valid) begin
            cap[cap_len] <= tx_byte;
            cap_len <= cap_len + 1;
        end
    end

    task send_payload(input [31:0] dest_mac_hi, input [15:0] dest_mac_lo,
                       input [31:0] dest_ip, input [15:0] sport, input [15:0] dport,
                       input [31:0] payload_bytes, input integer payload_len);
        integer i;
        begin
            @(negedge clk);
            in_start = 1;
            in_dest_mac = {dest_mac_hi, dest_mac_lo};
            in_dest_ip = dest_ip;
            in_src_port = sport;
            in_dst_port = dport;
            @(negedge clk);
            in_start = 0;
            for (i = 0; i < payload_len; i = i + 1) begin
                @(negedge clk);
                in_data = payload_bytes[(payload_len-1-i)*8 +: 8];
                in_data_valid = 1;
                in_last = (i == payload_len - 1);
            end
            @(negedge clk);
            in_data_valid = 0;
            in_last = 0;
        end
    endtask

    integer errors = 0;
    integer base;
    integer wait_i;

    initial begin
        rst = 1;
        repeat (5) @(negedge clk);
        rst = 0;
        repeat (5) @(negedge clk);

        base = cap_len;
        send_payload(32'hAABBCCDD, 16'hEEFF, {8'd10,8'd0,8'd0,8'd77},
                     16'd5000, 16'd1500, "ITCH", 4);
        repeat (100) @(negedge clk);

        if ((cap_len - base) != 46) begin
            $display("FAIL: expected 46-byte frame (14+20+8+4), got %0d bytes", cap_len - base);
            errors = errors + 1;
        end else begin
            $display("PASS: frame length correct (46 bytes = 14 Eth + 20 IP + 8 UDP + 4 payload)");
        end

        // dump the frame as hex for external (Python) checksum verification
        $write("FRAME_HEX:");
        for (wait_i = 0; wait_i < (cap_len - base); wait_i = wait_i + 1)
            $write(" %02x", cap[base + wait_i]);
        $write("\n");

        if (cap[base+0]!==8'hAA || cap[base+5]!==8'hFF) begin
            $display("FAIL: dest MAC wrong"); errors = errors + 1;
        end
        if (cap[base+6]!==OUR_MAC[47:40] || cap[base+11]!==OUR_MAC[7:0]) begin
            $display("FAIL: src MAC wrong"); errors = errors + 1;
        end
        if (cap[base+12]!==8'h08 || cap[base+13]!==8'h00) begin
            $display("FAIL: EtherType wrong"); errors = errors + 1;
        end
        if (cap[base+14]!==8'h45) begin
            $display("FAIL: version/IHL wrong, got %02x", cap[base+14]); errors = errors + 1;
        end
        if (cap[base+16]!==8'h00 || cap[base+17]!==8'd32) begin  // 20+8+4=32
            $display("FAIL: IP total length wrong, got %02x%02x", cap[base+16], cap[base+17]); errors = errors + 1;
        end
        if (cap[base+23]!==8'h11) begin
            $display("FAIL: protocol wrong, got %02x", cap[base+23]); errors = errors + 1;
        end
        if (cap[base+26]!==OUR_IP[31:24] || cap[base+29]!==OUR_IP[7:0]) begin
            $display("FAIL: src IP wrong"); errors = errors + 1;
        end
        if (cap[base+30]!==8'd10 || cap[base+33]!==8'd77) begin
            $display("FAIL: dest IP wrong"); errors = errors + 1;
        end
        if (cap[base+34]!==8'h13 || cap[base+35]!==8'h88) begin  // 5000 = 0x1388
            $display("FAIL: src port wrong, got %02x%02x", cap[base+34], cap[base+35]); errors = errors + 1;
        end
        if (cap[base+36]!==8'h05 || cap[base+37]!==8'hDC) begin  // 1500 = 0x05DC
            $display("FAIL: dst port wrong, got %02x%02x", cap[base+36], cap[base+37]); errors = errors + 1;
        end
        if (cap[base+38]!==8'h00 || cap[base+39]!==8'd12) begin  // udp_len = 8+4=12
            $display("FAIL: UDP length wrong, got %02x%02x", cap[base+38], cap[base+39]); errors = errors + 1;
        end
        if (cap[base+42]!==8'h49 || cap[base+43]!==8'h54 || cap[base+44]!==8'h43 || cap[base+45]!==8'h48) begin
            $display("FAIL: payload wrong, got %02x %02x %02x %02x", cap[base+42],cap[base+43],cap[base+44],cap[base+45]);
            errors = errors + 1;
        end

        if (errors == 0) $display("\n=== HEADER FIELD CHECKS PASSED (checksum verified externally) ===");
        else $display("\n=== %0d CHECK(S) FAILED ===", errors);

        $finish;
    end

    initial begin
        #50000;
        $display("TIMEOUT");
        $finish;
    end

endmodule