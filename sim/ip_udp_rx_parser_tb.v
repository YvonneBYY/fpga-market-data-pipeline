`timescale 1ns/1ps

module ip_udp_rx_parser_tb;

    reg clk = 0;
    always #5 clk = ~clk;  // 100MHz

    reg        rst = 1;
    reg  [7:0] rx_data = 0;
    reg        rx_data_valid = 0;
    reg        rx_frame_start = 0;
    reg        rx_frame_end   = 0;

    wire [31:0] src_ip, dst_ip;
    wire [15:0] src_port, dst_port, udp_length;
    wire        payload_valid, payload_last, packet_malformed;
    wire [7:0]  payload_data;

    ip_udp_rx_parser dut (
        .clk(clk), .rst(rst),
        .rx_data(rx_data), .rx_data_valid(rx_data_valid),
        .rx_frame_start(rx_frame_start), .rx_frame_end(rx_frame_end),
        .src_ip(src_ip), .dst_ip(dst_ip), .src_port(src_port), .dst_port(dst_port), .udp_length(udp_length),
        .payload_valid(payload_valid), .payload_data(payload_data), .payload_last(payload_last),
        .packet_malformed(packet_malformed)
    );

    task drive_byte(input [7:0] data, input is_start, input is_end);
        begin
            @(negedge clk);
            rx_data        = data;
            rx_data_valid  = 1;
            rx_frame_start = is_start;
            rx_frame_end   = is_end;
            @(negedge clk);
            rx_data_valid  = 0;
            rx_frame_start = 0;
            rx_frame_end   = 0;
        end
    endtask

    // Proper synchronous capture of the payload stream, exactly as a real
    // downstream consumer would do (payload_valid/payload_data are meant
    // to be sampled at posedge clk, not polled from procedural code).
    always @(posedge clk) begin
        if (rst) begin
            cap_len <= 0;
        end else if (payload_valid) begin
            cap[cap_len] <= payload_data;
            cap_len <= cap_len + 1;
        end
    end

    // ---------------- capture payload on the RX side ----------------
    reg [7:0] cap [0:255];
    integer   cap_len;
    reg       cap_malformed_seen;

    task capture(input integer wait_cycles);
        integer i;
        begin
            cap_malformed_seen = 0;
            for (i = 0; i < wait_cycles; i = i + 1) begin
                @(negedge clk);
                if (packet_malformed) cap_malformed_seen = 1;
            end
        end
    endtask

    integer errors = 0;
    integer base;

    // ---------------- build + send a full Ethernet+IPv4+UDP frame ----------------
    // num_option_words: extra 32-bit words of IP options (0 = standard 20-byte header)
    // corrupt_checksum: XOR a bit into the checksum field after computing it correctly
    task send_udp_frame(
        input [47:0] dest_mac, input [47:0] src_mac,
        input integer num_option_words, input corrupt_checksum,
        input [7:0] protocol_byte,   // 8'h11 for UDP; pass something else to test non-UDP handling
        input [31:0] sip, input [31:0] dip,
        input [15:0] sport, input [15:0] dport,
        input [31:0] payload_bytes, input integer payload_len   // up to 4 payload bytes, packed MSB-first
    );
        integer ihl_words, ip_hdr_bytes, udp_start, total_len, i;
        reg [7:0] frame [0:127];
        reg [31:0] sum;
        reg [15:0] chk;
        begin
            ihl_words   = 5 + num_option_words;
            ip_hdr_bytes = ihl_words * 4;
            udp_start   = 14 + ip_hdr_bytes;
            total_len   = ip_hdr_bytes + 8 + payload_len;

            {frame[0], frame[1], frame[2], frame[3], frame[4], frame[5]} = dest_mac;
            {frame[6], frame[7], frame[8], frame[9], frame[10], frame[11]} = src_mac;
            frame[12] = 8'h08; frame[13] = 8'h00;               // EtherType = IPv4
            frame[14] = {4'h4, ihl_words[3:0]};                  // version=4, IHL
            frame[15] = 8'h00;                                    // DSCP/ECN
            frame[16] = total_len[15:8]; frame[17] = total_len[7:0];
            frame[18] = 8'h00; frame[19] = 8'h00;                // ID
            frame[20] = 8'h00; frame[21] = 8'h00;                // flags/frag
            frame[22] = 8'd64;                                    // TTL
            frame[23] = protocol_byte;
            frame[24] = 8'h00; frame[25] = 8'h00;                // checksum placeholder
            frame[26] = sip[31:24]; frame[27] = sip[23:16]; frame[28] = sip[15:8]; frame[29] = sip[7:0];
            frame[30] = dip[31:24]; frame[31] = dip[23:16]; frame[32] = dip[15:8]; frame[33] = dip[7:0];
            for (i = 0; i < num_option_words * 4; i = i + 1)
                frame[34 + i] = 8'hAB;   // arbitrary option bytes

            // Internet checksum over the IP header (checksum field = 0 during sum)
            sum = 0;
            for (i = 0; i < ip_hdr_bytes; i = i + 2)
                sum = sum + {frame[14 + i], frame[14 + i + 1]};
            sum = {16'b0, sum[15:0]} + {16'b0, sum[31:16]};
            sum = {16'b0, sum[15:0]} + {16'b0, sum[31:16]};
            chk = ~sum[15:0];
            if (corrupt_checksum) chk = chk ^ 16'h0001;
            frame[24] = chk[15:8]; frame[25] = chk[7:0];

            frame[udp_start + 0] = sport[15:8]; frame[udp_start + 1] = sport[7:0];
            frame[udp_start + 2] = dport[15:8]; frame[udp_start + 3] = dport[7:0];
            frame[udp_start + 4] = (payload_len + 8) >> 8; frame[udp_start + 5] = (payload_len + 8) & 8'hFF;
            frame[udp_start + 6] = 8'h00; frame[udp_start + 7] = 8'h00;  // UDP checksum (optional, unused here)
            for (i = 0; i < payload_len; i = i + 1)
                frame[udp_start + 8 + i] = payload_bytes[(payload_len-1-i)*8 +: 8];

            for (i = 0; i < udp_start + 8 + payload_len; i = i + 1)
                drive_byte(frame[i], (i == 0), (i == udp_start + 8 + payload_len - 1));
        end
    endtask

    localparam [31:0] ITCH_PAYLOAD = "ITCH";  // 0x49 0x54 0x43 0x48


    initial begin
        rst = 1;
        repeat (5) @(negedge clk);
        rst = 0;
        repeat (5) @(negedge clk);

        // ---- Test 1: valid, standard (IHL=5) UDP packet ----
        base = cap_len;
        send_udp_frame(
            48'hFF_FF_FF_FF_FF_FF, 48'hAA_BB_CC_DD_EE_FF, 0, 0, 8'h11,
            {8'd10,8'd0,8'd0,8'd5}, {8'd10,8'd0,8'd0,8'd1}, 16'd5000, 16'd1500,
            ITCH_PAYLOAD, 4
        );
        capture(60);
        if (cap_malformed_seen) begin
            $display("FAIL [T1]: valid packet incorrectly flagged malformed");
            errors = errors + 1;
        end else if ((cap_len-base) != 4 || cap[base+0]!==8'h49 || cap[base+1]!==8'h54 || cap[base+2]!==8'h43 || cap[base+3]!==8'h48) begin
            $display("FAIL [T1]: payload wrong, got %0d bytes: %02x %02x %02x %02x", cap_len-base, cap[base+0],cap[base+1],cap[base+2],cap[base+3]);
            errors = errors + 1;
        end else if (src_ip !== {8'd10,8'd0,8'd0,8'd5} || dst_ip !== {8'd10,8'd0,8'd0,8'd1} ||
                     src_port !== 16'd5000 || dst_port !== 16'd1500) begin
            $display("FAIL [T1]: header fields wrong: src_ip=%08x dst_ip=%08x sport=%0d dport=%0d",
                       src_ip, dst_ip, src_port, dst_port);
            errors = errors + 1;
        end else begin
            $display("PASS [T1]: valid standard UDP packet parsed correctly, payload=ITCH");
        end

        // ---- Test 2: bad IP checksum - should be flagged malformed, no payload ----
        base = cap_len;
        send_udp_frame(
            48'hFF_FF_FF_FF_FF_FF, 48'hAA_BB_CC_DD_EE_FF, 0, 1, 8'h11,
            {8'd10,8'd0,8'd0,8'd5}, {8'd10,8'd0,8'd0,8'd1}, 16'd5000, 16'd1500,
            ITCH_PAYLOAD, 4
        );
        capture(60);
        if (!cap_malformed_seen) begin
            $display("FAIL [T2]: bad IP checksum was not flagged malformed");
            errors = errors + 1;
        end else if ((cap_len-base) != 0) begin
            $display("FAIL [T2]: payload was streamed despite bad checksum (%0d bytes)", cap_len-base);
            errors = errors + 1;
        end else $display("PASS [T2]: bad IP checksum correctly flagged malformed, no payload streamed");

        // ---- Test 3: non-UDP protocol (e.g. TCP=6) - silently ignored, not "malformed" ----
        base = cap_len;
        send_udp_frame(
            48'hFF_FF_FF_FF_FF_FF, 48'hAA_BB_CC_DD_EE_FF, 0, 0, 8'h06,
            {8'd10,8'd0,8'd0,8'd5}, {8'd10,8'd0,8'd0,8'd1}, 16'd5000, 16'd1500,
            ITCH_PAYLOAD, 4
        );
        capture(60);
        if (cap_malformed_seen || (cap_len-base) != 0) begin
            $display("FAIL [T3]: non-UDP protocol should be silently ignored (no malformed flag, no payload)");
            errors = errors + 1;
        end else $display("PASS [T3]: non-UDP protocol correctly ignored");

        // ---- Test 4: IP header WITH options (IHL=7, 8 extra option bytes) - variable IHL handling ----
        base = cap_len;
        send_udp_frame(
            48'hFF_FF_FF_FF_FF_FF, 48'hAA_BB_CC_DD_EE_FF, 2, 0, 8'h11,
            {8'd192,8'd168,8'd1,8'd9}, {8'd192,8'd168,8'd1,8'd50}, 16'd6000, 16'd9000,
            ITCH_PAYLOAD, 4
        );
        capture(60);
        if (cap_malformed_seen) begin
            $display("FAIL [T4]: packet with IP options incorrectly flagged malformed");
            errors = errors + 1;
        end else if ((cap_len-base) != 4 || cap[base+0]!==8'h49 || cap[base+3]!==8'h48) begin
            $display("FAIL [T4]: payload wrong with IP options present, got %0d bytes", cap_len-base);
            errors = errors + 1;
        end else if (src_port !== 16'd6000 || dst_port !== 16'd9000) begin
            $display("FAIL [T4]: UDP header fields wrong with IP options present: sport=%0d dport=%0d", src_port, dst_port);
            errors = errors + 1;
        end else $display("PASS [T4]: packet with IP options (IHL=7) correctly parsed - variable IHL handling works");

        // ---- Test 5: back-to-back - a malformed packet immediately followed
        // by a valid one, confirming the parser recovers cleanly ----
        base = cap_len;
        send_udp_frame(
            48'hFF_FF_FF_FF_FF_FF, 48'hAA_BB_CC_DD_EE_FF, 0, 1, 8'h11,
            {8'd10,8'd0,8'd0,8'd5}, {8'd10,8'd0,8'd0,8'd1}, 16'd5000, 16'd1500,
            ITCH_PAYLOAD, 4
        );
        send_udp_frame(
            48'hFF_FF_FF_FF_FF_FF, 48'hAA_BB_CC_DD_EE_FF, 0, 0, 8'h11,
            {8'd10,8'd0,8'd0,8'd7}, {8'd10,8'd0,8'd0,8'd2}, 16'd5001, 16'd1501,
            ITCH_PAYLOAD, 4
        );
        capture(80);
        if ((cap_len-base) != 4 || src_ip !== {8'd10,8'd0,8'd0,8'd7}) begin
            $display("FAIL [T5]: parser did not recover cleanly after a malformed packet");
            errors = errors + 1;
        end else $display("PASS [T5]: parser recovered cleanly - malformed packet followed by a valid one both handled correctly");

        if (errors == 0) $display("\n=== ALL TESTS PASSED ===");
        else $display("\n=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end

    initial begin
        #100000;
        $display("TIMEOUT - simulation did not finish in time");
        $finish;
    end

endmodule