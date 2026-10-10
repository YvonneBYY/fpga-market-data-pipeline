//// IPv4 + UDP RX parser.
////
//// Sits downstream of rx_frame_cdc, alongside arp_responder (both watch the
//// same byte stream; each only acts on its own EtherType). Validates an
//// incoming Ethernet frame as IPv4 (version=4) carrying UDP (protocol=17),
//// verifies the IP header checksum, handles variable IHL (header options),
//// and streams out the UDP payload bytes as they arrive - the caller does
//// not need to buffer anything to start consuming payload data.
////
//// Deliberately does NOT filter by destination IP - real UDP market-data
//// feeds (ITCH included) are typically multicast, not addressed to one
//// unicast host, so "is this packet meant for us" is left as a decision for
//// whatever consumes this module's output (dst_ip is exposed for exactly
//// that purpose).
////
//// Byte layout assumed (offsets from the start of the frame):
////   0-5   dest MAC        12-13 EtherType (0x0800 = IPv4)
////   6-11  src MAC
////   14    IP version(4b)+IHL(4b)      15    DSCP/ECN (ignored)
////   16-17 Total Length                18-19 Identification (ignored)
////   20-21 Flags+Fragment Offset (ignored - no fragmentation support yet)
////   22    TTL (ignored)               23    Protocol (0x11 = UDP)
////   24-25 IP Header Checksum
////   26-29 Source IP                   30-33 Destination IP
////   34..  IP Options (if IHL > 5) then the UDP header:
////     +0-1 UDP Src Port  +2-3 UDP Dst Port  +4-5 UDP Length  +6-7 UDP Checksum
////   then the UDP payload.

//module ip_udp_rx_parser (
//    input  wire       clk,
//    input  wire       rst,

//    input  wire [7:0] rx_data,
//    input  wire       rx_data_valid,
//    input  wire       rx_frame_start,
//    input  wire       rx_frame_end,

//    // Parsed header fields - valid (and held) once a good packet's payload
//    // has started; consumer should latch what it needs before the next
//    // frame_start.
//    output reg  [31:0] src_ip,
//    output reg  [31:0] dst_ip,
//    output reg  [47:0] src_mac,
//    output reg  [15:0] src_port,
//    output reg  [15:0] dst_port,
//    output reg  [15:0] udp_length,   // UDP header+payload length, per the UDP header itself

//    // Live payload byte stream - only asserted for a confirmed-valid IPv4/UDP packet
//    output wire        payload_valid,
//    output wire [7:0]  payload_data,
//    output wire        payload_last,

//    // Sticky-per-packet diagnostics (cleared on the next frame_start)
//    output reg         packet_malformed,

//    // RX debug pulses for reliability characterization.
//    // These do not change parser behavior; they only expose internal
//    // parser milestones to the top-level debug counters.
//    output wire        dbg_header_ready_pulse,
//    output wire        dbg_ipv4_udp_header_pulse,
//    output wire        dbg_ip_checksum_good_pulse,
//    output wire        dbg_ip_checksum_bad_pulse,
//    output wire        dbg_udp_header_latched_pulse
//);

//    localparam OFF_ETYPE0 = 12, OFF_ETYPE1 = 13;
//    localparam OFF_SRC_MAC0 = 6, OFF_SRC_MAC5 = 11;
//    localparam OFF_VER_IHL = 14;
//    localparam OFF_TOTLEN0 = 16, OFF_TOTLEN1 = 17;
//    localparam OFF_PROTO = 23;
//    localparam OFF_IPCHK0 = 24, OFF_IPCHK1 = 25;
//    localparam OFF_SRCIP0 = 26, OFF_SRCIP3 = 29;
//    localparam OFF_DSTIP0 = 30, OFF_DSTIP3 = 33;
//    localparam IP_HDR_MIN_END = 33;   // last byte of a minimum (IHL=5) IP header

//    reg [7:0] byte_off;
//    wire [7:0] eff_byte_off = rx_frame_start ? 8'd0 : byte_off;
//    wire       gate = (parsing || rx_frame_start) && rx_data_valid;

//    reg parsing;
//    reg [15:0] ethertype;
//    reg [3:0]  ip_version;
//    reg [3:0]  ip_ihl;
//    reg [15:0] ip_total_len;
//    reg [7:0]  ip_protocol;
//    reg [15:0] ip_checksum_field;

//    // Dynamic (IHL-dependent) offsets - computed once IHL is known (byte 14,
//    // long before it's needed), so later comparisons are against these
//    // rather than compile-time literals.
//    wire [7:0] ip_hdr_len      = {4'b0, ip_ihl} << 2;          // IHL is in 32-bit words
//    wire [7:0] udp_hdr_start   = OFF_VER_IHL + ip_hdr_len;      // first byte of the UDP header
//    wire [7:0] udp_payload_start = udp_hdr_start + 8'd8;

//    // ---------------- Running IP header checksum (Internet checksum) ----------------
//    // Accumulate every 16-bit word of the IP header (checksum field
//    // included, per the standard algorithm) into a wide sum, then fold
//    // carries down to 16 bits once the header completes. A valid header's
//    // folded sum is exactly 16'hFFFF.
//    reg [19:0] ip_sum_acc;
//    reg        byte_pair_has_high;
//    reg [7:0]  byte_pair_high;

//    wire [19:0] fold1 = {4'b0, ip_sum_acc[15:0]} + {12'b0, ip_sum_acc[19:16]};
//    wire [19:0] fold2 = {4'b0, fold1[15:0]} + {12'b0, fold1[19:16]};
//    wire [15:0] ip_checksum_folded = fold2[15:0];
//    wire        ip_checksum_ok = (ip_checksum_folded == 16'hFFFF);

//    // ---------------- UDP header field capture ----------------
//    reg [15:0] udp_src_port_r, udp_dst_port_r, udp_length_r;

//    // ---------------- Main byte walker ----------------
//    always @(posedge clk) begin
//        if (rst) begin
//            byte_off <= 0;
//            parsing  <= 0;
//            ethertype <= 0;
//            ip_version <= 0;
//            ip_ihl <= 0;
//            ip_total_len <= 0;
//            ip_protocol <= 0;
//            ip_checksum_field <= 0;
//            src_ip <= 0;
//            src_mac <= 0;
//            dst_ip <= 0;
//            ip_sum_acc <= 0;
//            byte_pair_has_high <= 0;
//            byte_pair_high <= 0;
//            udp_src_port_r <= 0;
//            udp_dst_port_r <= 0;
//            udp_length_r <= 0;
//        end else begin
//            if (rx_frame_start) begin
//                byte_off <= 0;
//                parsing  <= 1;
//                ip_sum_acc <= 0;
//                byte_pair_has_high <= 0;
//            end

//            if (gate) begin
//                case (eff_byte_off)
//                    OFF_ETYPE0: ethertype[15:8] <= rx_data;
//                    OFF_ETYPE1: ethertype[7:0]  <= rx_data;
//                    OFF_VER_IHL: begin
//                        ip_version <= rx_data[7:4];
//                        ip_ihl     <= rx_data[3:0];
//                    end
//                    OFF_TOTLEN0: ip_total_len[15:8] <= rx_data;
//                    OFF_TOTLEN1: ip_total_len[7:0]  <= rx_data;
//                    OFF_PROTO:  ip_protocol <= rx_data;
//                    OFF_IPCHK0: ip_checksum_field[15:8] <= rx_data;
//                    OFF_IPCHK1: ip_checksum_field[7:0]  <= rx_data;
//                    default: begin
//                        if (eff_byte_off >= OFF_SRC_MAC0 && eff_byte_off <= OFF_SRC_MAC5)
//                            src_mac[(OFF_SRC_MAC5 - eff_byte_off)*8 +: 8] <= rx_data;
//                        else if (eff_byte_off >= OFF_SRCIP0 && eff_byte_off <= OFF_SRCIP3)
//                            src_ip[(OFF_SRCIP3 - eff_byte_off)*8 +: 8] <= rx_data;
//                        else if (eff_byte_off >= OFF_DSTIP0 && eff_byte_off <= OFF_DSTIP3)
//                            dst_ip[(OFF_DSTIP3 - eff_byte_off)*8 +: 8] <= rx_data;
//                    end
//                endcase

//                // IP header checksum: pair up bytes 14..(udp_hdr_start-1)
//                // into 16-bit words and accumulate. Uses eff_byte_off's
//                // parity relative to the header start (byte 14 is even
//                // offset -> high byte of its pair).
//                if (eff_byte_off >= OFF_VER_IHL &&
//                    (eff_byte_off == OFF_VER_IHL || eff_byte_off < udp_hdr_start)) begin
//                    if (!byte_pair_has_high) begin
//                        byte_pair_high     <= rx_data;
//                        byte_pair_has_high <= 1;
//                    end else begin
//                        ip_sum_acc <= ip_sum_acc + {4'b0, byte_pair_high, rx_data};
//                        byte_pair_has_high <= 0;
//                    end
//                end

//                // UDP header fields (dynamic offsets)
//                if (eff_byte_off == udp_hdr_start + 8'd0) udp_src_port_r[15:8] <= rx_data;
//                if (eff_byte_off == udp_hdr_start + 8'd1) udp_src_port_r[7:0]  <= rx_data;
//                if (eff_byte_off == udp_hdr_start + 8'd2) udp_dst_port_r[15:8] <= rx_data;
//                if (eff_byte_off == udp_hdr_start + 8'd3) udp_dst_port_r[7:0]  <= rx_data;
//                if (eff_byte_off == udp_hdr_start + 8'd4) udp_length_r[15:8]   <= rx_data;
//                if (eff_byte_off == udp_hdr_start + 8'd5) udp_length_r[7:0]    <= rx_data;

//                byte_off <= eff_byte_off + 1;
//            end

//            if (rx_frame_end) parsing <= 0;
//        end
//    end

//    // Is this frame IPv4/UDP at all, and does it look well-formed enough to
//    // trust? Available combinationally once protocol (byte 23) has arrived,
//    // well before the checksum (byte 24-25) or the UDP header complete.
//    wire is_ipv4_udp = (ethertype == 16'h0800) && (ip_version == 4'd4) &&
//                        (ip_ihl >= 4'd5) && (ip_protocol == 8'h11);

//    // Latch header fields + malformed status once the checksum is known to
//    // be settled (one cycle after byte 25, mirroring arp_responder's
//    // same-edge-race fix from Phase 3 - the checksum's own accumulation
//    // finishes on the same edge the last header byte arrives, so any check
//    // reading it must be delayed by one cycle).
//    reg header_ready_d;
//    always @(posedge clk) begin
//        if (rst) header_ready_d <= 0;
//        else     header_ready_d <= gate && (eff_byte_off == udp_hdr_start - 1);
//    end

//    reg good_packet;   // latched: this frame is a validated IPv4/UDP packet
//    always @(posedge clk) begin
//        if (rst) begin
//            good_packet <= 0;
//            packet_malformed <= 0;
//        end else begin
//            if (rx_frame_start) begin
//                good_packet <= 0;
//                packet_malformed <= 0;
//            end
//            if (header_ready_d) begin
//                if (is_ipv4_udp && ip_checksum_ok) begin
//                    good_packet <= 1;
//                    // (src_port/dst_port/udp_length are NOT reset here - they're
//                    // driven exclusively by the udp_hdr_latched block below.
//                    // Two always blocks writing the same reg is a real
//                    // multiple-drivers conflict at synthesis, even though
//                    // simulators tolerate it with last-write-wins semantics.)
//                end else if (is_ipv4_udp && !ip_checksum_ok) begin
//                    packet_malformed <= 1;  // was IPv4/UDP, but the header itself is corrupt
//                end
//                // if !is_ipv4_udp: silently not-for-us, same as arp_responder ignoring non-ARP
//            end
//        end
//    end

//    // Latch UDP header fields for the consumer once they've arrived
//    reg udp_hdr_latched;
//    always @(posedge clk) begin
//        if (rst) begin
//            udp_hdr_latched <= 0;
//        end else begin
//            if (rx_frame_start) udp_hdr_latched <= 0;
//            if (gate && eff_byte_off == udp_hdr_start + 8'd5 && good_packet) begin
//                src_port   <= udp_src_port_r;
//                dst_port   <= udp_dst_port_r;
//                udp_length <= udp_length_r;
//                udp_hdr_latched <= 1;
//            end
//        end
//    end

//    // Payload boundary: udp_length includes the 8-byte UDP header itself,
//    // so the payload runs udp_length-8 bytes starting at udp_payload_start.
//    wire [15:0] payload_len = (udp_length_r >= 16'd8) ? (udp_length_r - 16'd8) : 16'd0;
//    wire [15:0] payload_end_off = {8'b0, udp_payload_start} + payload_len - 16'd1;

////    assign payload_valid = gate && good_packet && udp_hdr_latched &&
////                            ({8'b0, eff_byte_off} >= {8'b0, udp_payload_start});
//    assign payload_valid = gate && good_packet && udp_hdr_latched &&
//                       ({8'b0, eff_byte_off} >= {8'b0, udp_payload_start}) &&
//                       ({8'b0, eff_byte_off} <= payload_end_off);
//    assign payload_data  = rx_data;
//    // "last" fires at the expected end per the length field, OR at the
//    // real frame_end if that comes first - never trust the length field
//    // alone to avoid ever running past the actual frame.
//    assign payload_last  = payload_valid &&
//                            (({8'b0, eff_byte_off} >= payload_end_off) || rx_frame_end);

//    // -------------------------------------------------------------------------
//    // Debug-only milestone pulses
//    // -------------------------------------------------------------------------
//    // header_ready_d is asserted one cycle after the final IPv4 header byte
//    // has been accumulated, so the checksum result and dst_ip are settled.
//    assign dbg_header_ready_pulse =
//        header_ready_d;

//    assign dbg_ipv4_udp_header_pulse =
//        header_ready_d && is_ipv4_udp;

//    assign dbg_ip_checksum_good_pulse =
//        header_ready_d && is_ipv4_udp && ip_checksum_ok;

//    assign dbg_ip_checksum_bad_pulse =
//        header_ready_d && is_ipv4_udp && !ip_checksum_ok;

//    // Same condition that causes the UDP header fields to be committed.
//    assign dbg_udp_header_latched_pulse =
//        gate &&
//        (eff_byte_off == udp_hdr_start + 8'd5) &&
//        good_packet;


//endmodule


// IPv4 + UDP RX parser.
//
// Sits downstream of rx_frame_cdc, alongside arp_responder (both watch the
// same byte stream; each only acts on its own EtherType). Validates an
// incoming Ethernet frame as IPv4 (version=4) carrying UDP (protocol=17),
// verifies the IP header checksum, handles variable IHL (header options),
// and streams out the UDP payload bytes as they arrive - the caller does
// not need to buffer anything to start consuming payload data.
//
// Deliberately does NOT filter by destination IP - real UDP market-data
// feeds (ITCH included) are typically multicast, not addressed to one
// unicast host, so "is this packet meant for us" is left as a decision for
// whatever consumes this module's output (dst_ip is exposed for exactly
// that purpose).
//
// Byte layout assumed (offsets from the start of the frame):
//   0-5   dest MAC        12-13 EtherType (0x0800 = IPv4)
//   6-11  src MAC
//   14    IP version(4b)+IHL(4b)      15    DSCP/ECN (ignored)
//   16-17 Total Length                18-19 Identification (ignored)
//   20-21 Flags+Fragment Offset (ignored - no fragmentation support yet)
//   22    TTL (ignored)               23    Protocol (0x11 = UDP)
//   24-25 IP Header Checksum
//   26-29 Source IP                   30-33 Destination IP
//   34..  IP Options (if IHL > 5) then the UDP header:
//     +0-1 UDP Src Port  +2-3 UDP Dst Port  +4-5 UDP Length  +6-7 UDP Checksum
//   then the UDP payload.

module ip_udp_rx_parser (
    input  wire       clk,
    input  wire       rst,

    input  wire [7:0] rx_data,
    input  wire       rx_data_valid,
    input  wire       rx_frame_start,
    input  wire       rx_frame_end,

    // Parsed header fields - valid (and held) once a good packet's payload
    // has started; consumer should latch what it needs before the next
    // frame_start.
    output reg  [31:0] src_ip,
    output reg  [31:0] dst_ip,
    output reg  [47:0] src_mac,
    output reg  [15:0] src_port,
    output reg  [15:0] dst_port,
    output reg  [15:0] udp_length,   // UDP header+payload length, per the UDP header itself

    // Live payload byte stream - only asserted for a confirmed-valid IPv4/UDP packet
    output wire        payload_valid,
    output wire [7:0]  payload_data,
    output wire        payload_last,

    // Sticky-per-packet diagnostics (cleared on the next frame_start)
    output reg         packet_malformed,

    // RX debug pulses for reliability characterization.
    // These do not change parser behavior; they only expose internal
    // parser milestones to the top-level debug counters.
    output wire        dbg_header_ready_pulse,
    output wire        dbg_ipv4_udp_header_pulse,
    output wire        dbg_ip_checksum_good_pulse,
    output wire        dbg_ip_checksum_bad_pulse,
    output wire        dbg_udp_header_latched_pulse
);

    localparam OFF_ETYPE0 = 12, OFF_ETYPE1 = 13;
    localparam OFF_SRC_MAC0 = 6, OFF_SRC_MAC5 = 11;
    localparam OFF_VER_IHL = 14;
    localparam OFF_TOTLEN0 = 16, OFF_TOTLEN1 = 17;
    localparam OFF_PROTO = 23;
    localparam OFF_IPCHK0 = 24, OFF_IPCHK1 = 25;
    localparam OFF_SRCIP0 = 26, OFF_SRCIP3 = 29;
    localparam OFF_DSTIP0 = 30, OFF_DSTIP3 = 33;
    localparam IP_HDR_MIN_END = 33;   // last byte of a minimum (IHL=5) IP header

    reg [7:0] byte_off;
    wire [7:0] eff_byte_off = rx_frame_start ? 8'd0 : byte_off;
    wire       gate = (parsing || rx_frame_start) && rx_data_valid;

    reg parsing;
    reg [15:0] ethertype;
    reg [3:0]  ip_version;
    reg [3:0]  ip_ihl;
    reg [15:0] ip_total_len;
    reg [7:0]  ip_protocol;
    reg [15:0] ip_checksum_field;

    // Dynamic (IHL-dependent) offsets - computed once IHL is known (byte 14,
    // long before it's needed), so later comparisons are against these
    // rather than compile-time literals.
    wire [7:0] ip_hdr_len      = {4'b0, ip_ihl} << 2;          // IHL is in 32-bit words
    wire [7:0] udp_hdr_start   = OFF_VER_IHL + ip_hdr_len;      // first byte of the UDP header
    wire [7:0] udp_payload_start = udp_hdr_start + 8'd8;

    // ---------------- Running IP header checksum (Internet checksum) ----------------
    // Accumulate every 16-bit word of the IP header (checksum field
    // included, per the standard algorithm) into a wide sum, then fold
    // carries down to 16 bits once the header completes. A valid header's
    // folded sum is exactly 16'hFFFF.
    reg [19:0] ip_sum_acc;
    reg        byte_pair_has_high;
    reg [7:0]  byte_pair_high;

    wire [19:0] fold1 = {4'b0, ip_sum_acc[15:0]} + {12'b0, ip_sum_acc[19:16]};
    wire [19:0] fold2 = {4'b0, fold1[15:0]} + {12'b0, fold1[19:16]};
    wire [15:0] ip_checksum_folded = fold2[15:0];
    wire        ip_checksum_ok = (ip_checksum_folded == 16'hFFFF);

    // ---------------- UDP header field capture ----------------
    reg [15:0] udp_src_port_r, udp_dst_port_r, udp_length_r;

    // ---------------- Main byte walker ----------------
    always @(posedge clk) begin
        if (rst) begin
            byte_off <= 0;
            parsing  <= 0;
            ethertype <= 0;
            ip_version <= 0;
            ip_ihl <= 0;
            ip_total_len <= 0;
            ip_protocol <= 0;
            ip_checksum_field <= 0;
            src_ip <= 0;
            src_mac <= 0;
            dst_ip <= 0;
            ip_sum_acc <= 0;
            byte_pair_has_high <= 0;
            byte_pair_high <= 0;
            udp_src_port_r <= 0;
            udp_dst_port_r <= 0;
            udp_length_r <= 0;
        end else begin
            if (rx_frame_start) begin
                byte_off <= 0;
                parsing  <= 1;
                ip_sum_acc <= 0;
                byte_pair_has_high <= 0;
            end

            if (gate) begin
                case (eff_byte_off)
                    OFF_ETYPE0: ethertype[15:8] <= rx_data;
                    OFF_ETYPE1: ethertype[7:0]  <= rx_data;
                    OFF_VER_IHL: begin
                        ip_version <= rx_data[7:4];
                        ip_ihl     <= rx_data[3:0];
                    end
                    OFF_TOTLEN0: ip_total_len[15:8] <= rx_data;
                    OFF_TOTLEN1: ip_total_len[7:0]  <= rx_data;
                    OFF_PROTO:  ip_protocol <= rx_data;
                    OFF_IPCHK0: ip_checksum_field[15:8] <= rx_data;
                    OFF_IPCHK1: ip_checksum_field[7:0]  <= rx_data;
                    default: begin
                        if (eff_byte_off >= OFF_SRC_MAC0 && eff_byte_off <= OFF_SRC_MAC5)
                            src_mac[(OFF_SRC_MAC5 - eff_byte_off)*8 +: 8] <= rx_data;
                        else if (eff_byte_off >= OFF_SRCIP0 && eff_byte_off <= OFF_SRCIP3)
                            src_ip[(OFF_SRCIP3 - eff_byte_off)*8 +: 8] <= rx_data;
                        else if (eff_byte_off >= OFF_DSTIP0 && eff_byte_off <= OFF_DSTIP3)
                            dst_ip[(OFF_DSTIP3 - eff_byte_off)*8 +: 8] <= rx_data;
                    end
                endcase

                // IP header checksum: pair up bytes 14..(udp_hdr_start-1)
                // into 16-bit words and accumulate. Uses eff_byte_off's
                // parity relative to the header start (byte 14 is even
                // offset -> high byte of its pair).
                if (eff_byte_off >= OFF_VER_IHL &&
                    (eff_byte_off == OFF_VER_IHL || eff_byte_off < udp_hdr_start)) begin
                    if (!byte_pair_has_high) begin
                        byte_pair_high     <= rx_data;
                        byte_pair_has_high <= 1;
                    end else begin
                        ip_sum_acc <= ip_sum_acc + {4'b0, byte_pair_high, rx_data};
                        byte_pair_has_high <= 0;
                    end
                end

                // UDP header fields (dynamic offsets)
                if (eff_byte_off == udp_hdr_start + 8'd0) udp_src_port_r[15:8] <= rx_data;
                if (eff_byte_off == udp_hdr_start + 8'd1) udp_src_port_r[7:0]  <= rx_data;
                if (eff_byte_off == udp_hdr_start + 8'd2) udp_dst_port_r[15:8] <= rx_data;
                if (eff_byte_off == udp_hdr_start + 8'd3) udp_dst_port_r[7:0]  <= rx_data;
                if (eff_byte_off == udp_hdr_start + 8'd4) udp_length_r[15:8]   <= rx_data;
                if (eff_byte_off == udp_hdr_start + 8'd5) udp_length_r[7:0]    <= rx_data;

                byte_off <= eff_byte_off + 1;
            end

            if (rx_frame_end) parsing <= 0;
        end
    end

    // Is this frame IPv4/UDP at all, and does it look well-formed enough to
    // trust? Available combinationally once protocol (byte 23) has arrived,
    // well before the checksum (byte 24-25) or the UDP header complete.
    wire is_ipv4_udp = (ethertype == 16'h0800) && (ip_version == 4'd4) &&
                        (ip_ihl >= 4'd5) && (ip_protocol == 8'h11);

    // Latch header fields + malformed status once the checksum is known to
    // be settled (one cycle after byte 25, mirroring arp_responder's
    // same-edge-race fix from Phase 3 - the checksum's own accumulation
    // finishes on the same edge the last header byte arrives, so any check
    // reading it must be delayed by one cycle).
    reg header_ready_d;
    always @(posedge clk) begin
        if (rst) header_ready_d <= 0;
        else     header_ready_d <= gate && (eff_byte_off == udp_hdr_start - 1);
    end

    reg good_packet;   // latched: this frame is a validated IPv4/UDP packet
    always @(posedge clk) begin
        if (rst) begin
            good_packet <= 0;
            packet_malformed <= 0;
        end else begin
            if (rx_frame_start) begin
                good_packet <= 0;
                packet_malformed <= 0;
            end
            if (header_ready_d) begin
                if (is_ipv4_udp && ip_checksum_ok) begin
                    good_packet <= 1;
                    // (src_port/dst_port/udp_length are NOT reset here - they're
                    // driven exclusively by the udp_hdr_latched block below.
                    // Two always blocks writing the same reg is a real
                    // multiple-drivers conflict at synthesis, even though
                    // simulators tolerate it with last-write-wins semantics.)
                end else if (is_ipv4_udp && !ip_checksum_ok) begin
                    packet_malformed <= 1;  // was IPv4/UDP, but the header itself is corrupt
                end
                // if !is_ipv4_udp: silently not-for-us, same as arp_responder ignoring non-ARP
            end
        end
    end

    // Latch UDP header fields for the consumer once they've arrived
    reg udp_hdr_latched;
    always @(posedge clk) begin
        if (rst) begin
            udp_hdr_latched <= 0;
        end else begin
            if (rx_frame_start) udp_hdr_latched <= 0;
            if (gate && eff_byte_off == udp_hdr_start + 8'd5 && good_packet) begin
                src_port   <= udp_src_port_r;
                dst_port   <= udp_dst_port_r;
                udp_length <= udp_length_r;
                udp_hdr_latched <= 1;
            end
        end
    end

    // Payload boundary: udp_length includes the 8-byte UDP header itself,
    // so the payload runs udp_length-8 bytes starting at udp_payload_start.
    wire [15:0] payload_len = (udp_length_r >= 16'd8) ? (udp_length_r - 16'd8) : 16'd0;
    wire [15:0] payload_end_off = {8'b0, udp_payload_start} + payload_len - 16'd1;

//    assign payload_valid = gate && good_packet && udp_hdr_latched &&
//                            ({8'b0, eff_byte_off} >= {8'b0, udp_payload_start});
    assign payload_valid = gate && good_packet && udp_hdr_latched &&
                       ({8'b0, eff_byte_off} >= {8'b0, udp_payload_start}) &&
                       ({8'b0, eff_byte_off} <= payload_end_off);
    assign payload_data  = rx_data;
    // "last" fires at the expected end per the length field, OR at the
    // real frame_end if that comes first - never trust the length field
    // alone to avoid ever running past the actual frame.
    assign payload_last  = payload_valid &&
                            (({8'b0, eff_byte_off} >= payload_end_off) || rx_frame_end);

    // -------------------------------------------------------------------------
    // Debug-only milestone pulses
    // -------------------------------------------------------------------------
    // header_ready_d is asserted one cycle after the final IPv4 header byte
    // has been accumulated, so the checksum result and dst_ip are settled.
    assign dbg_header_ready_pulse =
        header_ready_d;

    assign dbg_ipv4_udp_header_pulse =
        header_ready_d && is_ipv4_udp;

    assign dbg_ip_checksum_good_pulse =
        header_ready_d && is_ipv4_udp && ip_checksum_ok;

    assign dbg_ip_checksum_bad_pulse =
        header_ready_d && is_ipv4_udp && !ip_checksum_ok;

    // Same condition that causes the UDP header fields to be committed.
    assign dbg_udp_header_latched_pulse =
        gate &&
        (eff_byte_off == udp_hdr_start + 8'd5) &&
        good_packet;


endmodule