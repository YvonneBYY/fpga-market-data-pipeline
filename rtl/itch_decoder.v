// NASDAQ TotalView-ITCH 5.0 message decoder.
//
// Consumes a payload byte stream (the same payload_valid/payload_data/
// payload_last interface ip_udp_rx_parser exposes) containing one or more
// back-to-back ITCH messages, and decodes them.
//
// Framing: ITCH itself carries no per-message length prefix - in the real
// feed, MoldUDP64 (the wrapping session protocol) provides message
// boundaries. Rather than inventing a fake length-prefix scheme, this
// decoder does what a real ITCH parser does: every message type has a
// FIXED length, determinable purely from its own Message Type byte, so
// the length of message N tells you exactly where message N+1 starts.
// MSG_LEN below is a complete table of every message type documented in
// the NASDAQ TotalView-ITCH 5.0 spec (verified against the official PDF,
// not recalled from memory), so ANY message type can be correctly framed
// (skipped over without losing sync on the next message), even for types
// this decoder doesn't fully decode yet.
//
// Fully decoded (fields populated, msg_valid pulses): S, A, E, X, D - the
// core set needed for a working add/execute/cancel/delete order book.
// All other known types are correctly skipped (their length is known, so
// framing sync is maintained) but no fields are populated and msg_valid
// does not pulse for them - documented future scope, not a limitation of
// the framing itself.
//
// Simplifying assumption: an ITCH message is assumed not to span a UDP
// packet boundary (each payload contains a whole number of complete
// messages) - true for our own test traffic, and a very common assumption
// for a first-pass parser. payload_last forces a resync to byte_off=0
// regardless, so a violation of this assumption costs framing sync for
// the rest of that one packet, not any corruption of subsequent packets.
//
// Common header (offsets 0-10) is identical across every message type:
// Message Type(1) + Stock Locate(2) + Tracking Number(2) + Timestamp(6).

module itch_decoder (
    input  wire       clk,
    input  wire       rst,

    input  wire       payload_valid,
    input  wire [7:0] payload_data,
    input  wire       payload_last,

    output reg        msg_valid,        // one-cycle pulse: a SUPPORTED message finished decoding
    output reg  [7:0] msg_type,
    output reg        unknown_type,     // one-cycle pulse: message type not in MSG_LEN table at all - framing lost until next payload_last

    // Common header (valid for every decoded message, supported or not)
    output reg [15:0] stock_locate,
    output reg [15:0] tracking_number,
    output reg [47:0] timestamp,

    // Type-specific fields. Validity is determined by msg_type at the
    // msg_valid pulse - fields irrelevant to the current type hold stale
    // values from a previous message and must not be read.
    output reg [63:0] order_ref_number,   // A, E, X, D
    output reg        buy_sell_indicator, // A only: 1 = Buy, 0 = Sell
    output reg [31:0] shares,             // A (total), E (executed), X (canceled) - reused per type
    output reg [63:0] stock,              // A only, 8 ASCII bytes
    output reg [31:0] price,              // A only, Price(4): 4 implied decimal places
    output reg  [7:0] event_code,         // S only
    output reg [63:0] match_number        // E only
);

    reg [5:0] byte_off;
    reg [7:0] msg_type_latched;
    reg [5:0] msg_len;

    wire is_supported_type =
        (msg_type_latched == "S") || (msg_type_latched == "A") ||
        (msg_type_latched == "E") || (msg_type_latched == "X") ||
        (msg_type_latched == "D");

    // Complete length table, every offset verified against the official
    // NASDAQ TotalView-ITCH 5.0 spec (03/06/2015).
    function [5:0] msg_length_for_type(input [7:0] t);
        case (t)
            "S": msg_length_for_type = 6'd12;  // System Event
            "R": msg_length_for_type = 6'd39;  // Stock Directory
            "H": msg_length_for_type = 6'd25;  // Stock Trading Action
            "Y": msg_length_for_type = 6'd20;  // Reg SHO
            "L": msg_length_for_type = 6'd26;  // Market Participant Position
            "V": msg_length_for_type = 6'd35;  // MWCB Decline Level
            "W": msg_length_for_type = 6'd12;  // MWCB Status
            "K": msg_length_for_type = 6'd28;  // IPO Quoting Period Update
            "A": msg_length_for_type = 6'd36;  // Add Order - No MPID
            "F": msg_length_for_type = 6'd40;  // Add Order - MPID Attribution
            "E": msg_length_for_type = 6'd31;  // Order Executed
            "C": msg_length_for_type = 6'd36;  // Order Executed With Price
            "X": msg_length_for_type = 6'd23;  // Order Cancel
            "D": msg_length_for_type = 6'd19;  // Order Delete
            "U": msg_length_for_type = 6'd35;  // Order Replace
            "P": msg_length_for_type = 6'd44;  // Trade (Non-Cross)
            "Q": msg_length_for_type = 6'd40;  // Cross Trade
            "B": msg_length_for_type = 6'd19;  // Broken Trade
            "I": msg_length_for_type = 6'd50;  // NOII
            "N": msg_length_for_type = 6'd20;  // Retail Interest
            default: msg_length_for_type = 6'd0; // unknown type
        endcase
    endfunction

    always @(posedge clk) begin
        msg_valid    <= 1'b0;
        unknown_type <= 1'b0;

        if (rst) begin
            byte_off <= 0;
        end else if (payload_valid) begin

            if (byte_off == 0) begin
                msg_type_latched <= payload_data;
                msg_len          <= msg_length_for_type(payload_data);
                if (msg_length_for_type(payload_data) == 0)
                    unknown_type <= 1'b1;
            end

            // Common header - identical layout for every message type.
            if (byte_off >= 1 && byte_off <= 2)
                stock_locate[(2 - byte_off)*8 +: 8] <= payload_data;
            if (byte_off >= 3 && byte_off <= 4)
                tracking_number[(4 - byte_off)*8 +: 8] <= payload_data;
            if (byte_off >= 5 && byte_off <= 10)
                timestamp[(10 - byte_off)*8 +: 8] <= payload_data;

            // Type-specific fields.
            case (msg_type_latched)
                "S": begin
                    if (byte_off == 11) event_code <= payload_data;
                end
                "A": begin
                    if (byte_off >= 11 && byte_off <= 18)
                        order_ref_number[(18 - byte_off)*8 +: 8] <= payload_data;
                    if (byte_off == 19)
                        buy_sell_indicator <= (payload_data == "B");
                    if (byte_off >= 20 && byte_off <= 23)
                        shares[(23 - byte_off)*8 +: 8] <= payload_data;
                    if (byte_off >= 24 && byte_off <= 31)
                        stock[(31 - byte_off)*8 +: 8] <= payload_data;
                    if (byte_off >= 32 && byte_off <= 35)
                        price[(35 - byte_off)*8 +: 8] <= payload_data;
                end
                "E": begin
                    if (byte_off >= 11 && byte_off <= 18)
                        order_ref_number[(18 - byte_off)*8 +: 8] <= payload_data;
                    if (byte_off >= 19 && byte_off <= 22)
                        shares[(22 - byte_off)*8 +: 8] <= payload_data;
                    if (byte_off >= 23 && byte_off <= 30)
                        match_number[(30 - byte_off)*8 +: 8] <= payload_data;
                end
                "X": begin
                    if (byte_off >= 11 && byte_off <= 18)
                        order_ref_number[(18 - byte_off)*8 +: 8] <= payload_data;
                    if (byte_off >= 19 && byte_off <= 22)
                        shares[(22 - byte_off)*8 +: 8] <= payload_data;
                end
                "D": begin
                    if (byte_off >= 11 && byte_off <= 18)
                        order_ref_number[(18 - byte_off)*8 +: 8] <= payload_data;
                end
                default: ; // known-but-unsupported, or unknown: header only, no field decode
            endcase

            // End of message? (msg_len was latched on byte_off==0's cycle,
            // many cycles before it's ever checked here, so it's always
            // settled by the time this comparison runs - no same-cycle
            // race, unlike some earlier timing bugs in this project.)
            if (byte_off == msg_len - 1) begin
                msg_valid <= is_supported_type;
                msg_type  <= msg_type_latched;
                byte_off  <= 0;   // ready immediately for the next back-to-back message
            end else begin
                byte_off <= byte_off + 1'b1;
            end

            // Resync at the packet boundary regardless (the "no spanning"
            // assumption means this should coincide with a message end in
            // well-formed traffic).
            if (payload_last) byte_off <= 0;
        end
    end

endmodule