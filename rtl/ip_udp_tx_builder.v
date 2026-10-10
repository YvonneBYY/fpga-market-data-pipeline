// IPv4 + UDP TX packet builder.
//
// Given a payload stream (byte+valid+last, presented once and consumed as
// it's provided) plus destination/source MAC, IP, and port, constructs the
// complete raw Ethernet+IPv4+UDP frame bytes (pre-CRC, pre-preamble) on the
// same byte+valid+last TX convention every frame builder in this project
// uses - a separate wrapper (mirroring arp_reply_framer) attaches CRC32 and
// the TX driver during hardware integration.
//
// Fixed IHL=5 (no IP options) for generated packets - standard, and what
// real UDP senders (Scapy included) produce by default. UDP checksum is
// left as 0x0000, which is valid/optional over IPv4 per RFC 768 - computing
// it would require summing the payload too, for a field real receivers are
// required to accept as absent.
//
// Usage: assert in_start with in_dest_mac/in_dest_ip/in_src_ip/in_src_port/
// in_dst_port held stable, then stream the payload on in_data/in_data_valid/
// in_last (payload_len is derived automatically from counting bytes until
// in_last). The module buffers the whole payload locally (needed since the
// UDP/IP length fields must be written before the payload streams out) then
// emits the complete frame on tx_valid/tx_byte/tx_last.

module ip_udp_tx_builder #(
    parameter [47:0] OUR_MAC = 48'h02_00_00_00_00_01,
    parameter [31:0] OUR_IP  = {8'd169, 8'd254, 8'd89, 8'd52}
) (
    input  wire        clk,
    input  wire        rst,

    // Trigger + destination parameters (sampled when in_start pulses)
    input  wire        in_start,
    input  wire [47:0] in_dest_mac,
    input  wire [31:0] in_dest_ip,
    input  wire [15:0] in_src_port,
    input  wire [15:0] in_dst_port,

    // Payload stream (presented starting the same or a later cycle than in_start)
    input  wire [7:0]  in_data,
    input  wire        in_data_valid,
    input  wire        in_last,

    // Raw frame output (pre-CRC, pre-preamble)
    output wire        tx_req,      // pulses once, one cycle before tx_valid first goes high
    output wire        tx_valid,
    output wire [7:0]  tx_byte,
    output wire        tx_last
);

    localparam MAX_PAYLOAD = 200;   // generous; ITCH messages are small

    reg [7:0] payload_buf [0:MAX_PAYLOAD-1];
    reg [8:0] payload_len;          // bytes actually loaded
    reg [8:0] load_idx;

    reg [47:0] dest_mac_r;
    reg [31:0] dest_ip_r;
    reg [15:0] src_port_r, dst_port_r;

    localparam LD_IDLE = 0, LD_COLLECT = 1;
    reg ld_state;
    
    localparam MIN_ETH_FRAME_LEN = 9'd60;

    always @(posedge clk) begin
        if (rst) begin
            ld_state <= LD_IDLE;
            load_idx <= 0;
            payload_len <= 0;
        end else begin
            case (ld_state)
                LD_IDLE: if (in_start) begin
                    dest_mac_r <= in_dest_mac;
                    dest_ip_r  <= in_dest_ip;
                    src_port_r <= in_src_port;
                    dst_port_r <= in_dst_port;
                    load_idx   <= 0;
                    ld_state   <= LD_COLLECT;
                end
                LD_COLLECT: if (in_data_valid) begin
                    if (load_idx < MAX_PAYLOAD) payload_buf[load_idx] <= in_data;
                    load_idx <= load_idx + 1'b1;
                    if (in_last) begin
                        payload_len <= load_idx + 1'b1;
                        ld_state <= LD_IDLE;
                    end
                end
                default: ld_state <= LD_IDLE;
            endcase
        end
    end

    // A frame is ready to send one cycle after ld_state returns to LD_IDLE
    // having just collected a payload (edge-detected via ld_state itself).
    reg ld_state_prev;
    always @(posedge clk) begin
        if (rst) ld_state_prev <= LD_IDLE;
        else     ld_state_prev <= ld_state;
    end
    wire frame_ready = (ld_state == LD_IDLE) && (ld_state_prev == LD_COLLECT);

    // ---------------- Frame construction ----------------
    localparam HEADER_LEN = 9'd14 + 9'd20 + 9'd8;  // Eth + IP(IHL=5) + UDP = 42

    reg        building;
    reg [8:0]  out_idx;
    reg [8:0]  total_len;      // full frame length (header + payload)
    reg [15:0] ip_total_len_r;
    reg [15:0] udp_len_r;

    // Internet checksum over the IP header, computed once payload_len (and
    // therefore ip_total_len) is known, using the same incremental-sum +
    // fold technique as ip_udp_rx_parser.
    reg [19:0] chk_sum;
    reg [15:0] ip_checksum_r;

    localparam CK_IDLE = 0, CK_SUM = 1, CK_DONE = 2;
    reg [1:0] ck_state;
    reg [3:0] ck_word_idx;   // 0..9, the 10 16-bit words of a 20-byte header

    // The 10 header words in order, with the checksum field (word 5) as 0
    // during the sum - built combinationally from the known header content.
    function [15:0] hdr_word(input [3:0] idx);
        begin
            case (idx)
                0: hdr_word = {4'h4, 4'h5, 8'h00};              // ver/ihl, DSCP
                1: hdr_word = ip_total_len_r;
                2: hdr_word = 16'h0000;                          // ID
                3: hdr_word = 16'h0000;                          // flags/frag
                4: hdr_word = {8'd64, 8'h11};                    // TTL, protocol=UDP
                5: hdr_word = 16'h0000;                          // checksum field (0 during sum)
                6: hdr_word = OUR_IP[31:16];
                7: hdr_word = OUR_IP[15:0];
                8: hdr_word = dest_ip_r[31:16];
                9: hdr_word = dest_ip_r[15:0];
                default: hdr_word = 16'h0000;
            endcase
        end
    endfunction

    wire [19:0] fold1 = {4'b0, chk_sum[15:0]} + {12'b0, chk_sum[19:16]};
    wire [19:0] fold2 = {4'b0, fold1[15:0]} + {12'b0, fold1[19:16]};

    always @(posedge clk) begin
        if (rst) begin
            building <= 0;
            ck_state <= CK_IDLE;
        end else begin
            if (frame_ready && !building) begin
//                total_len <= HEADER_LEN + payload_len;
                if ((HEADER_LEN + payload_len) < MIN_ETH_FRAME_LEN)
                    total_len <= MIN_ETH_FRAME_LEN;
                else
                    total_len <= HEADER_LEN + payload_len;
                ip_total_len_r <= 20 + 8 + payload_len;
                udp_len_r <= 8 + payload_len;
                ck_state <= CK_SUM;
                ck_word_idx <= 0;
                chk_sum <= 0;
            end

            case (ck_state)
                CK_SUM: begin
                    chk_sum <= chk_sum + {4'b0, hdr_word(ck_word_idx)};
                    if (ck_word_idx == 4'd9) ck_state <= CK_DONE;
                    else ck_word_idx <= ck_word_idx + 1'b1;
                end
                CK_DONE: begin
                    ip_checksum_r <= ~fold2[15:0];
                    building <= 1;
                    out_idx <= 0;
                    ck_state <= CK_IDLE;
                end
                default: ;
            endcase

            if (building && out_idx == total_len - 1) begin
                building <= 0;
            end else if (building) begin
                out_idx <= out_idx + 1'b1;
            end
        end
    end

    // Combinational byte generator, indexed by out_idx over the full frame.
    reg [7:0] out_byte_r;
    always @(*) begin
        if (out_idx < 6) begin
            case (out_idx[2:0])
                0: out_byte_r = dest_mac_r[47:40];
                1: out_byte_r = dest_mac_r[39:32];
                2: out_byte_r = dest_mac_r[31:24];
                3: out_byte_r = dest_mac_r[23:16];
                4: out_byte_r = dest_mac_r[15:8];
                default: out_byte_r = dest_mac_r[7:0];
            endcase
        end else if (out_idx < 12) begin
            case (out_idx - 6)
                0: out_byte_r = OUR_MAC[47:40];
                1: out_byte_r = OUR_MAC[39:32];
                2: out_byte_r = OUR_MAC[31:24];
                3: out_byte_r = OUR_MAC[23:16];
                4: out_byte_r = OUR_MAC[15:8];
                default: out_byte_r = OUR_MAC[7:0];
            endcase
        end else if (out_idx == 12) out_byte_r = 8'h08;   // EtherType hi (IPv4)
        else if (out_idx == 13) out_byte_r = 8'h00;        // EtherType lo
        else if (out_idx == 14) out_byte_r = 8'h45;        // ver=4, IHL=5
        else if (out_idx == 15) out_byte_r = 8'h00;        // DSCP/ECN
        else if (out_idx == 16) out_byte_r = ip_total_len_r[15:8];
        else if (out_idx == 17) out_byte_r = ip_total_len_r[7:0];
        else if (out_idx == 18) out_byte_r = 8'h00;        // ID
        else if (out_idx == 19) out_byte_r = 8'h00;
        else if (out_idx == 20) out_byte_r = 8'h00;        // flags/frag
        else if (out_idx == 21) out_byte_r = 8'h00;
        else if (out_idx == 22) out_byte_r = 8'd64;        // TTL
        else if (out_idx == 23) out_byte_r = 8'h11;        // protocol=UDP
        else if (out_idx == 24) out_byte_r = ip_checksum_r[15:8];
        else if (out_idx == 25) out_byte_r = ip_checksum_r[7:0];
        else if (out_idx == 26) out_byte_r = OUR_IP[31:24];
        else if (out_idx == 27) out_byte_r = OUR_IP[23:16];
        else if (out_idx == 28) out_byte_r = OUR_IP[15:8];
        else if (out_idx == 29) out_byte_r = OUR_IP[7:0];
        else if (out_idx == 30) out_byte_r = dest_ip_r[31:24];
        else if (out_idx == 31) out_byte_r = dest_ip_r[23:16];
        else if (out_idx == 32) out_byte_r = dest_ip_r[15:8];
        else if (out_idx == 33) out_byte_r = dest_ip_r[7:0];
        else if (out_idx == 34) out_byte_r = src_port_r[15:8];
        else if (out_idx == 35) out_byte_r = src_port_r[7:0];
        else if (out_idx == 36) out_byte_r = dst_port_r[15:8];
        else if (out_idx == 37) out_byte_r = dst_port_r[7:0];
        else if (out_idx == 38) out_byte_r = udp_len_r[15:8];
        else if (out_idx == 39) out_byte_r = udp_len_r[7:0];
        else if (out_idx == 40) out_byte_r = 8'h00;        // UDP checksum (unused, optional)
        else if (out_idx == 41) out_byte_r = 8'h00;
//        else out_byte_r = (out_idx - HEADER_LEN < payload_len) ?
//                   payload_buf[out_idx - HEADER_LEN] : 8'h00;
        
        // UDP payload
        else if (out_idx < HEADER_LEN + payload_len)
            out_byte_r = payload_buf[out_idx - HEADER_LEN];
        
        // Ethernet zero-padding up to minimum frame size
        else
            out_byte_r = 8'h00;
    end

    assign tx_req   = (ck_state == CK_DONE);
    assign tx_valid = building;
    assign tx_byte  = out_byte_r;
    assign tx_last  = building && (out_idx == total_len - 1);

endmodule