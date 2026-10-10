`timescale 1ns/1ps

module arp_responder_tb;

    reg clk = 0;
    always #5 clk = ~clk;  // 100MHz

    reg        rst = 1;
    reg  [7:0] rx_data = 0;
    reg        rx_data_valid = 0;
    reg        rx_frame_start = 0;
    reg        rx_frame_end   = 0;

    wire       tx_valid, tx_last, tx_req;
    wire [7:0] tx_byte;

    // Same defaults the DUT itself uses, so the testbench's own "our IP/MAC"
    // expectations line up automatically if those parameters ever change.
    localparam [31:0] OUR_IP  = {8'd192, 8'd168, 8'd1, 8'd50};
    localparam [47:0] OUR_MAC = 48'h02_00_00_00_00_01;

    arp_responder #(.OUR_IP(OUR_IP), .OUR_MAC(OUR_MAC)) dut (
        .clk(clk), .rst(rst),
        .rx_data(rx_data), .rx_data_valid(rx_data_valid),
        .rx_frame_start(rx_frame_start), .rx_frame_end(rx_frame_end),
        .tx_valid(tx_valid), .tx_byte(tx_byte), .tx_last(tx_last), .tx_req(tx_req)
    );

    // ---------------- drive one byte ----------------
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

    // ---------------- drive a full 42-byte Ethernet+ARP frame ----------------
    task send_arp_frame(
        input [47:0] dest_mac, input [47:0] src_mac, input [15:0] ethertype,
        input [15:0] oper, input [47:0] sha, input [31:0] spa,
        input [47:0] tha, input [31:0] tpa
    );
        integer i;
        reg [7:0] frame [0:41];
        begin
            {frame[0], frame[1], frame[2], frame[3], frame[4], frame[5]} = dest_mac;
            {frame[6], frame[7], frame[8], frame[9], frame[10], frame[11]} = src_mac;
            {frame[12], frame[13]} = ethertype;
            frame[14] = 8'h00; frame[15] = 8'h01;   // HTYPE
            frame[16] = 8'h08; frame[17] = 8'h00;   // PTYPE
            frame[18] = 8'h06;                       // HLEN
            frame[19] = 8'h04;                       // PLEN
            {frame[20], frame[21]} = oper;
            {frame[22], frame[23], frame[24], frame[25], frame[26], frame[27]} = sha;
            {frame[28], frame[29], frame[30], frame[31]} = spa;
            {frame[32], frame[33], frame[34], frame[35], frame[36], frame[37]} = tha;
            {frame[38], frame[39], frame[40], frame[41]} = tpa;

            for (i = 0; i < 42; i = i + 1)
                drive_byte(frame[i], (i == 0), (i == 41));
        end
    endtask

    // ---------------- drive an arbitrary short non-ARP frame ----------------
    task send_non_arp_frame(input [47:0] dest_mac, input [47:0] src_mac);
        integer i;
        reg [7:0] frame [0:19];
        begin
            {frame[0], frame[1], frame[2], frame[3], frame[4], frame[5]} = dest_mac;
            {frame[6], frame[7], frame[8], frame[9], frame[10], frame[11]} = src_mac;
            frame[12] = 8'h08; frame[13] = 8'h00;  // EtherType = IPv4, not ARP
            for (i = 14; i < 20; i = i + 1) frame[i] = 8'hCC;  // arbitrary payload
            for (i = 0; i < 20; i = i + 1)
                drive_byte(frame[i], (i == 0), (i == 19));
        end
    endtask

    // ---------------- capture the reply on the TX side ----------------
    reg [7:0] cap [0:127];
    integer   cap_len;
    integer   reply_seen;

    task capture_reply(input integer wait_cycles);
        integer i;
        begin
            cap_len = 0;
            reply_seen = 0;
            for (i = 0; i < wait_cycles; i = i + 1) begin
                @(negedge clk);
                if (tx_req) reply_seen = 1;
                if (tx_valid) begin
                    cap[cap_len] = tx_byte;
                    cap_len = cap_len + 1;
                end
            end
        end
    endtask

    integer errors = 0;

    task check_byte(input integer idx, input [7:0] exp, input [255:0] label);
        begin
            if (cap[idx] !== exp) begin
                $display("FAIL [%s] byte %0d: got %02x expected %02x", label, idx, cap[idx], exp);
                errors = errors + 1;
            end
        end
    endtask

    reg [47:0] requester_mac;
    reg [31:0] requester_ip;

    initial begin
        rst = 1;
        repeat (5) @(negedge clk);
        rst = 0;
        repeat (5) @(negedge clk);

        // ---- Test 1: valid ARP request for OUR_IP ----
        requester_mac = 48'hAA_BB_CC_DD_EE_FF;
        requester_ip  = {8'd192, 8'd168, 8'd1, 8'd77};
        send_arp_frame(
            48'hFF_FF_FF_FF_FF_FF,   // dest MAC (broadcast, as a real ARP request would be)
            requester_mac,           // src MAC
            16'h0806,                // EtherType = ARP
            16'h0001,                // OPER = request
            requester_mac,           // SHA
            requester_ip,             // SPA
            48'h00_00_00_00_00_00,   // THA (unknown, as in a real request)
            OUR_IP                    // TPA = us
        );
        capture_reply(100);

        if (!reply_seen) begin
            $display("FAIL [T1]: tx_req never pulsed for a valid ARP request");
            errors = errors + 1;
        end else if (cap_len != 60) begin
            $display("FAIL [T1]: reply length was %0d, expected 60", cap_len);
            errors = errors + 1;
        end else begin
            $display("PASS [T1]: reply pulsed, length 60");
            check_byte(0,  requester_mac[47:40], "T1 dest_mac[0]");
            check_byte(5,  requester_mac[7:0],   "T1 dest_mac[5]");
            check_byte(6,  OUR_MAC[47:40],        "T1 src_mac[0]");
            check_byte(11, OUR_MAC[7:0],          "T1 src_mac[5]");
            check_byte(12, 8'h08, "T1 ethertype hi");
            check_byte(13, 8'h06, "T1 ethertype lo");
            check_byte(20, 8'h00, "T1 oper hi");
            check_byte(21, 8'h02, "T1 oper lo (reply)");
            check_byte(22, OUR_MAC[47:40], "T1 SHA[0]");
            check_byte(27, OUR_MAC[7:0],   "T1 SHA[5]");
            check_byte(28, OUR_IP[31:24],  "T1 SPA[0]");
            check_byte(31, OUR_IP[7:0],    "T1 SPA[3]");
            check_byte(32, requester_mac[47:40], "T1 THA[0]");
            check_byte(37, requester_mac[7:0],   "T1 THA[5]");
            check_byte(38, requester_ip[31:24],  "T1 TPA[0]");
            check_byte(41, requester_ip[7:0],    "T1 TPA[3]");
            check_byte(59, 8'h00, "T1 zero-pad last byte");
            if (errors == 0) $display("PASS [T1]: all reply fields correct");
        end

        // ---- Test 2: ARP request for a DIFFERENT target IP - no reply ----
        send_arp_frame(
            48'hFF_FF_FF_FF_FF_FF, requester_mac, 16'h0806, 16'h0001,
            requester_mac, requester_ip, 48'h0, {8'd10, 8'd0, 8'd0, 8'd1}  // not OUR_IP
        );
        capture_reply(100);
        if (reply_seen) begin
            $display("FAIL [T2]: replied to an ARP request for a different IP");
            errors = errors + 1;
        end else $display("PASS [T2]: correctly ignored ARP request for a different IP");

        // ---- Test 3: non-ARP frame (EtherType 0x0800) - no reply ----
        send_non_arp_frame(48'hFF_FF_FF_FF_FF_FF, requester_mac);
        capture_reply(100);
        if (reply_seen) begin
            $display("FAIL [T3]: replied to a non-ARP frame");
            errors = errors + 1;
        end else $display("PASS [T3]: correctly ignored a non-ARP frame");

        // ---- Test 4: ARP REPLY (not request) targeting our IP - no reply ----
        send_arp_frame(
            48'h11_22_33_44_55_66, requester_mac, 16'h0806, 16'h0002,  // OPER=2 (reply)
            requester_mac, requester_ip, OUR_MAC, OUR_IP
        );
        capture_reply(100);
        if (reply_seen) begin
            $display("FAIL [T4]: replied to an ARP REPLY packet (should only answer requests)");
            errors = errors + 1;
        end else $display("PASS [T4]: correctly ignored an ARP reply (non-request) packet");

        // ---- Test 5: a non-matching frame immediately followed by a valid
        // request, back-to-back - confirms the parser resets cleanly and
        // doesn't get stuck from the previous frame ----
        send_non_arp_frame(48'hFF_FF_FF_FF_FF_FF, requester_mac);
        send_arp_frame(
            48'hFF_FF_FF_FF_FF_FF, requester_mac, 16'h0806, 16'h0001,
            requester_mac, requester_ip, 48'h0, OUR_IP
        );
        capture_reply(100);
        if (!reply_seen || cap_len != 60) begin
            $display("FAIL [T5]: back-to-back frames - parser did not correctly recover for the second (valid) frame");
            errors = errors + 1;
        end else begin
            check_byte(41, requester_ip[7:0], "T5 TPA[3] after back-to-back frames");
            $display("PASS [T5]: parser correctly handled a non-matching frame immediately followed by a valid request");
        end

        if (errors == 0) $display("\n=== ALL TESTS PASSED ===");
        else $display("\n=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end

    initial begin
        #50000;
        $display("TIMEOUT - simulation did not finish in time");
        $finish;
    end

endmodule