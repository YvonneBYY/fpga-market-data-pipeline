// ARP responder.
//
// Watches an incoming byte stream (post-CDC, system clock domain) for
// Ethernet frames carrying an ARP request whose Target Protocol Address
// (TPA) matches OUR_IP, and produces the raw (pre-CRC, pre-preamble) bytes
// of the corresponding ARP reply frame on the tx_* interface.
//
// RX interface: expects rx_frame_start pulsed on the frame's first byte and
// rx_frame_end pulsed after the frame's last byte, alongside rx_data/
// rx_data_valid - mirrors eth_mac_rx_nibble's own signaling
// this module sits down stream of the rx_frame_cdc module.
//
// TX interface: byte + valid + last, exactly the same convention used by
// every frame-builder in this project so far - a separate wrapper attaches 
// crc32_gen and the TX driver.
//
// Ethernet + ARP byte layout assumed (offsets from the start of the frame,
// byte 0 = first byte of the destination MAC):
//   0-5   dest MAC          12-13 EtherType (0x0806 = ARP)
//   6-11  src MAC           14-15 HTYPE (0x0001)      16-17 PTYPE (0x0800)
//   18    HLEN (6)          19    PLEN (4)            20-21 OPER (1=request)
//   22-27 SHA (sender MAC)  28-31 SPA (sender IP)
//   32-37 THA (target MAC)  38-41 TPA (target IP)

module arp_responder #(
    parameter [31:0] OUR_IP  = {8'd192, 8'd168, 8'd1, 8'd50},
    parameter [47:0] OUR_MAC = 48'h02_00_00_00_00_01
) (
    input  wire       clk,
    input  wire       rst,

    // RX stream (system clock domain, post-CDC)
    input  wire [7:0] rx_data,
    input  wire       rx_data_valid,
    input  wire       rx_frame_start,
    input  wire       rx_frame_end,

    // TX stream: raw Ethernet+ARP reply bytes, no CRC/preamble
    output wire        tx_valid,
    output wire [7:0]  tx_byte,
    output wire        tx_last,
    output wire        tx_req      // pulses once when a reply is ready to send
);

    // ---------------- RX parse ----------------
    localparam OFF_SRC_MAC0  = 6,  OFF_SRC_MAC5  = 11;
    localparam OFF_ETYPE0    = 12, OFF_ETYPE1    = 13;
    localparam OFF_OPER0     = 20, OFF_OPER1     = 21;
    localparam OFF_SHA0      = 22, OFF_SHA5      = 27;
    localparam OFF_SPA0      = 28, OFF_SPA3      = 31;
    localparam OFF_TPA0      = 38, OFF_TPA3      = 41;
    localparam FRAME_MAX_OFF = 41;

    reg [5:0]  byte_off;            // 0..63 is plenty for what we index
    
    // byte_off's own reset to 0 (in the frame_start branch below) is a
    // non-blocking assignment, not visible until next cycle
    // Use combinational override to avoide race condition with rx_frame_start
    // and determine what byte 0 actually gets indexed by.
    wire [5:0] eff_byte_off = rx_frame_start ? 6'd0 : byte_off;
    reg [15:0] ethertype;
    reg [15:0] arp_oper;
    reg [47:0] sender_mac;          // SHA - becomes reply's dest MAC / THA
    reg [31:0] sender_ip;           // SPA - becomes reply's dest IP / TPA
    reg        parsing;             // true from frame_start to frame_end

    always @(posedge clk) begin
        if (rst) begin
            byte_off  <= 0;
            ethertype <= 0;
            arp_oper  <= 0;
            sender_mac <= 0;
            sender_ip  <= 0;
            parsing    <= 0;
        end else begin
            if (rx_frame_start) begin
                byte_off <= 0;
                parsing  <= 1;
            end

            // Use (parsing || rx_frame_start) rather than parsing alone:
            // parsing's own non-blocking update from the frame_start branch
            // above hasn't landed yet on this same cycle, so byte 0 (which
            // co-occurs with frame_start) would otherwise be skipped,
            // silently shifting every later byte's offset by one.
            if ((parsing || rx_frame_start) && rx_data_valid) begin
                case (eff_byte_off)
                    OFF_ETYPE0: ethertype[15:8] <= rx_data;
                    OFF_ETYPE1: ethertype[7:0]  <= rx_data;
                    OFF_OPER0:  arp_oper[15:8]  <= rx_data;
                    OFF_OPER1:  arp_oper[7:0]   <= rx_data;
                    default: begin
                        if (eff_byte_off >= OFF_SHA0 && eff_byte_off <= OFF_SHA5)
                            sender_mac[(OFF_SHA5 - eff_byte_off)*8 +: 8] <= rx_data;
                        else if (eff_byte_off >= OFF_SPA0 && eff_byte_off <= OFF_SPA3)
                            sender_ip[(OFF_SPA3 - eff_byte_off)*8 +: 8] <= rx_data;
                        // OFF_TPA handled below (needs same-cycle compare on
                        // the LAST TPA byte, so it is captured into a
                        // separate combinational check rather than a
                        // register we'd only be able to read next cycle)
                    end
                endcase
                if (eff_byte_off < 63) byte_off <= eff_byte_off + 1;
                else byte_off <= 63;
            end

            if (rx_frame_end) parsing <= 0;
        end
    end

    // TPA (target IP) is checked live as its 4 bytes stream in, rather than
    // registered and compared later, so the "is this frame the one we
    // should reply to" decision is ready the instant frame_end arrives.
    reg [31:0] target_ip_partial;
    always @(posedge clk) begin
        if (rst) begin
            target_ip_partial <= 0;
        end else if ((parsing || rx_frame_start) && rx_data_valid &&
                     eff_byte_off >= OFF_TPA0 && eff_byte_off <= OFF_TPA3) begin
            target_ip_partial[(OFF_TPA3 - eff_byte_off)*8 +: 8] <= rx_data;
        end
    end

    wire is_arp_request = (ethertype == 16'h0806) && (arp_oper == 16'h0001) &&
                           (target_ip_partial == OUR_IP);

    // frame_end and target_ip_partial's own last-byte update (TPA[3], byte
    // 41 - the frame's very last byte) both land via non-blocking assignment
    // on the SAME clock edge, so target_ip_partial is not yet visible to a
    // check made on that same edge 
    
    // thus, delay the frame_end check by one cycle so target_ip_partial has settled first.
    reg frame_end_d;
    always @(posedge clk) begin
        if (rst) frame_end_d <= 0;
        else     frame_end_d <= rx_frame_end;
    end

    // Latch the decision + sender fields one cycle after frame_end, since
    // sender_mac/sender_ip/target_ip_partial are still mid-frame-tail values
    // on the frame_end cycle itself.
    reg        reply_pending;
    reg [47:0] reply_dest_mac;
    reg [31:0] reply_dest_ip;

    always @(posedge clk) begin
        if (rst) begin
            reply_pending  <= 0;
            reply_dest_mac <= 0;
            reply_dest_ip  <= 0;
        end else begin
            reply_pending <= 0;  // one-cycle pulse
            if (frame_end_d && is_arp_request) begin
                reply_pending  <= 1;
                reply_dest_mac <= sender_mac;
                reply_dest_ip  <= sender_ip;
            end
        end
    end

    // ---------------- TX build ----------------
    // Total reply length before CRC: 14 (Ethernet header) + 28 (ARP payload)
    // + 18 (zero padding to the 60-byte minimum) = 60 bytes.
    localparam REPLY_LEN = 7'd60;

    localparam TB_IDLE = 0, TB_SEND = 1;
    reg       tb_state;
    reg [6:0] tx_idx;
    reg [47:0] latched_dest_mac;
    reg [31:0] latched_dest_ip;

    always @(posedge clk) begin
        if (rst) begin
            tb_state <= TB_IDLE;
            tx_idx   <= 0;
        end else begin
            case (tb_state)
                TB_IDLE: begin
                    tx_idx <= 0;
                    if (reply_pending) begin
                        latched_dest_mac <= reply_dest_mac;
                        latched_dest_ip  <= reply_dest_ip;
                        tb_state <= TB_SEND;
                    end
                end
                TB_SEND: begin
                    if (tx_idx == REPLY_LEN - 1) tb_state <= TB_IDLE;
                    else tx_idx <= tx_idx + 1;
                end
                default: tb_state <= TB_IDLE;
            endcase
        end
    end

    assign tx_req = reply_pending;

    // Combinational byte generator for the reply frame, indexed by tx_idx.
    // Dest MAC = the requester's MAC; src MAC = OUR_MAC; EtherType = ARP;
    // ARP payload = a standard reply (OPER=2) addressed back to the requester.
    // (An explicit always @(*) block, rather than a function called from a
    // continuous assign, to avoid a same-edge re-evaluation case)
    reg [7:0] reply_byte_r;
    always @(*) begin
            case (tx_idx)
                // Ethernet header: dest MAC (requester's MAC)
                0: reply_byte_r = latched_dest_mac[47:40];
                1: reply_byte_r = latched_dest_mac[39:32];
                2: reply_byte_r = latched_dest_mac[31:24];
                3: reply_byte_r = latched_dest_mac[23:16];
                4: reply_byte_r = latched_dest_mac[15:8];
                5: reply_byte_r = latched_dest_mac[7:0];
                // src MAC = OUR_MAC
                6:  reply_byte_r = OUR_MAC[47:40];
                7:  reply_byte_r = OUR_MAC[39:32];
                8:  reply_byte_r = OUR_MAC[31:24];
                9:  reply_byte_r = OUR_MAC[23:16];
                10: reply_byte_r = OUR_MAC[15:8];
                11: reply_byte_r = OUR_MAC[7:0];
                // EtherType = 0x0806 (ARP)
                12: reply_byte_r = 8'h08;
                13: reply_byte_r = 8'h06;
                // ARP payload
                14: reply_byte_r = 8'h00; // HTYPE
                15: reply_byte_r = 8'h01;
                16: reply_byte_r = 8'h08; // PTYPE
                17: reply_byte_r = 8'h00;
                18: reply_byte_r = 8'h06; // HLEN
                19: reply_byte_r = 8'h04; // PLEN
                20: reply_byte_r = 8'h00; // OPER = 2 (reply)
                21: reply_byte_r = 8'h02;
                // SHA = OUR_MAC
                22: reply_byte_r = OUR_MAC[47:40];
                23: reply_byte_r = OUR_MAC[39:32];
                24: reply_byte_r = OUR_MAC[31:24];
                25: reply_byte_r = OUR_MAC[23:16];
                26: reply_byte_r = OUR_MAC[15:8];
                27: reply_byte_r = OUR_MAC[7:0];
                // SPA = OUR_IP
                28: reply_byte_r = OUR_IP[31:24];
                29: reply_byte_r = OUR_IP[23:16];
                30: reply_byte_r = OUR_IP[15:8];
                31: reply_byte_r = OUR_IP[7:0];
                // THA = requester's MAC (what they asked us to fill in)
                32: reply_byte_r = latched_dest_mac[47:40];
                33: reply_byte_r = latched_dest_mac[39:32];
                34: reply_byte_r = latched_dest_mac[31:24];
                35: reply_byte_r = latched_dest_mac[23:16];
                36: reply_byte_r = latched_dest_mac[15:8];
                37: reply_byte_r = latched_dest_mac[7:0];
                // TPA = requester's IP
                38: reply_byte_r = latched_dest_ip[31:24];
                39: reply_byte_r = latched_dest_ip[23:16];
                40: reply_byte_r = latched_dest_ip[15:8];
                41: reply_byte_r = latched_dest_ip[7:0];
                default: reply_byte_r = 8'h00; // zero-pad to 60 bytes
            endcase
    end

    assign tx_valid = (tb_state == TB_SEND);
    assign tx_byte   = reply_byte_r;
    assign tx_last   = (tb_state == TB_SEND) && (tx_idx == REPLY_LEN - 1);

endmodule