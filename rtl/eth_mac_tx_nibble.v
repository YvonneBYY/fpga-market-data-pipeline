//module eth_mac_tx_nibble (
//    input phy_tx_clk,
//    input rst,
//    input tx_start,
//    input  [7:0] tx_data,
//    input tx_data_valid,
//    input tx_last,

//    output [3:0] phy_txd,
//    output phy_tx_en,
//    output reg tx_ready,
//    output reg tx_busy   // high from tx_start through the end of IFG - caller must wait for this to drop before
//                       // asserting tx_start again
//);
//    localparam IDLE = 2'd0;
//    localparam PREAMBLE = 2'd1;
//    localparam DATA = 2'd2;
//    localparam IFG = 2'd3; 

//    localparam PREAMBLE_LEN = 7;
//    localparam IFG_CYCLES = 24; 

//    reg [1:0] state;
//    reg [3:0] preamble_count;
//    reg [7:0] byte_to_send;
//    reg       byte_to_send_valid;

//    wire splitter_busy;
//    wire splitter_sending_high;
//    wire nibble_valid;

//    reg splitter_was_busy;
//    reg sfd_sent;

//    // Last-byte tracking
//    reg queued_last;
//    reg active_last;
    
//    //count to 24 for ifg
//    reg [4:0] ifg_count; 


//    byte_to_nibble nibble_splitter (
//        .clk(phy_tx_clk),
//        .rst(rst),
//        .byte_in(byte_to_send),
//        .byte_valid(byte_to_send_valid),
//        .nibble(phy_txd),
//        .nibble_valid(nibble_valid),
//        .busy(splitter_busy),
//        .sending_high(splitter_sending_high)
//    );
//    assign phy_tx_en = nibble_valid;

//    always @(posedge phy_tx_clk) begin
//        if (rst) begin
//            state <= IDLE;
//            tx_ready <= 0;
//            preamble_count <= 0;
//            byte_to_send_valid <= 0;
//            splitter_was_busy <= 0;
//            sfd_sent <= 0;
//            queued_last <= 0;
//            active_last <= 0;
//            tx_busy <= 0;
//            ifg_count <= 0;
//        end
        
//        else begin
//            // Previous-cycle busy value
//            splitter_was_busy <= splitter_busy;

//            // byte_valid is normally a one-cycle pulse
//            byte_to_send_valid <= 0;

//            case (state)
//                IDLE: begin
//                    tx_ready  <= 0;
//                    tx_busy   <= 0;
                
//                    preamble_count <= 0;
//                    ifg_count       <= 0;
                
//                    if (tx_start) begin
//                        state <= PREAMBLE;
                
//                        sfd_sent    <= 0;
//                        queued_last <= 0;
//                        active_last <= 0;
//                        tx_busy     <= 1;
                
//                        preamble_count <= 1;
                
//                        byte_to_send       <= 8'h55;
//                        byte_to_send_valid <= 1;
//                    end
//                end

//                PREAMBLE: begin                        
//                   // While the splitter is producing the high nibble,
//                    // queue the next byte so transmission remains
//                    // continuous.
//                   if (splitter_busy && splitter_sending_high) begin

//                        // Aready sent preamble byte #1 in IDLE.
//                        // Send bytes #2 through #7
//                        if (preamble_count < PREAMBLE_LEN) begin
//                            preamble_count <= preamble_count + 1;
//                            byte_to_send <= 8'h55;
//                            byte_to_send_valid <= 1;
//                        end

//                        // After the seven 55 bytes, queue D5.
//                        else if (!sfd_sent) begin
//                            sfd_sent <= 1;
//                            byte_to_send       <= 8'hD5;
//                            byte_to_send_valid <= 1;
//                        end
//                    end

//                    // The queued D5 is now being accepted by the
//                    // splitter. It will output:
//                    //
//                    // current cycle: 5
//                    // next cycle:    D
//                    //
//                    // Enter DATA now so the first data byte can be
//                    // queued while the D nibble is going out.
//                    if (sfd_sent && byte_to_send_valid && !splitter_busy) begin
//                        state <= DATA;
//                        tx_ready <= 1;
//                    end
//                end

//                DATA: begin
//                    // Accept a byte from upstream
//                    if (tx_data_valid && tx_ready) begin
//                        byte_to_send <= tx_data;
//                        byte_to_send_valid <= 1;

//                        // This describes the byte waiting to enter
//                        // byte_to_nibble.
//                        queued_last <= tx_last;

//                        // Queue is now occupied.
//                        tx_ready <= 0;
//                    end

//                    // Queued byte enters byte_to_nibble
//                    if (byte_to_send_valid && !splitter_busy) begin

//                        // It is no longer merely queued; it is now
//                        // the byte actively being transmitted.
//                        active_last <= queued_last;
                        
//                        // During a non-final byte, allow upstream
//                        // to give us the next byte.
//                        if (!queued_last)
//                            tx_ready <= 1;
//                        else
//                            tx_ready <= 0;
//                    end


//                    // Active final byte has completely finished
//                    if (splitter_was_busy && !splitter_busy && active_last) begin
//                        state <= IFG;
//                        tx_ready  <= 0;
//                        queued_last <= 0;
//                        active_last <= 0;
//                        ifg_count <= 0;
//                    end
//                end
                
//                IFG: begin
//                    tx_ready  <= 0;
//                    tx_busy   <= 1;
                
//                    if (ifg_count < IFG_CYCLES - 1)
//                        ifg_count <= ifg_count + 1;
//                    else begin
//                        state   <= IDLE;
//                        tx_busy <= 0;
//                    end
//                end

//                default: begin
//                    state    <= IDLE;
//                    tx_ready <= 0;
//                    tx_busy  <= 0;
//                end
//            endcase
//        end
//    end
//endmodule

module eth_mac_tx_nibble (
    input phy_tx_clk,
    input rst,
    input tx_start,
    input  [7:0] tx_data,
    input tx_data_valid,
    input tx_last,

    output [3:0] phy_txd,
    output phy_tx_en,
    output reg tx_ready,
    output reg tx_busy,      // high from tx_start through the end of IFG
    output reg frame_done    // 1-cycle pulse immediately after final frame nibble completes
);
    localparam IDLE = 2'd0;
    localparam PREAMBLE = 2'd1;
    localparam DATA = 2'd2;
    localparam IFG = 2'd3; 

    localparam PREAMBLE_LEN = 7;
    localparam IFG_CYCLES = 24; 

    reg [1:0] state;
    reg [3:0] preamble_count;
    reg [7:0] byte_to_send;
    reg       byte_to_send_valid;

    wire splitter_busy;
    wire splitter_sending_high;
    wire nibble_valid;

    reg splitter_was_busy;
    reg sfd_sent;

    // Last-byte tracking
    reg queued_last;
    reg active_last;
    
    //count to 24 for ifg
    reg [4:0] ifg_count; 


    byte_to_nibble nibble_splitter (
        .clk(phy_tx_clk),
        .rst(rst),
        .byte_in(byte_to_send),
        .byte_valid(byte_to_send_valid),
        .nibble(phy_txd),
        .nibble_valid(nibble_valid),
        .busy(splitter_busy),
        .sending_high(splitter_sending_high)
    );
    assign phy_tx_en = nibble_valid;

    always @(posedge phy_tx_clk) begin
        if (rst) begin
            state <= IDLE;
            tx_ready <= 0;
            preamble_count <= 0;
            byte_to_send_valid <= 0;
            splitter_was_busy <= 0;
            sfd_sent <= 0;
            queued_last <= 0;
            active_last <= 0;
            tx_busy <= 0;
            frame_done <= 0;
            ifg_count <= 0;
        end
        
        else begin
            // frame_done is a one-cycle pulse.
            frame_done <= 0;

            // Previous-cycle busy value
            splitter_was_busy <= splitter_busy;

            // byte_valid is normally a one-cycle pulse
            byte_to_send_valid <= 0;

            case (state)
                IDLE: begin
                    tx_ready  <= 0;
                    tx_busy   <= 0;
                
                    preamble_count <= 0;
                    ifg_count       <= 0;
                
                    if (tx_start) begin
                        state <= PREAMBLE;
                
                        sfd_sent    <= 0;
                        queued_last <= 0;
                        active_last <= 0;
                        tx_busy     <= 1;
                
                        preamble_count <= 1;
                
                        byte_to_send       <= 8'h55;
                        byte_to_send_valid <= 1;
                    end
                end

                PREAMBLE: begin                        
                   // While the splitter is producing the high nibble,
                    // queue the next byte so transmission remains
                    // continuous.
                   if (splitter_busy && splitter_sending_high) begin

                        // Aready sent preamble byte #1 in IDLE.
                        // Send bytes #2 through #7
                        if (preamble_count < PREAMBLE_LEN) begin
                            preamble_count <= preamble_count + 1;
                            byte_to_send <= 8'h55;
                            byte_to_send_valid <= 1;
                        end

                        // After the seven 55 bytes, queue D5.
                        else if (!sfd_sent) begin
                            sfd_sent <= 1;
                            byte_to_send       <= 8'hD5;
                            byte_to_send_valid <= 1;
                        end
                    end

                    // The queued D5 is now being accepted by the
                    // splitter. It will output:
                    //
                    // current cycle: 5
                    // next cycle:    D
                    //
                    // Enter DATA now so the first data byte can be
                    // queued while the D nibble is going out.
                    if (sfd_sent && byte_to_send_valid && !splitter_busy) begin
                        state <= DATA;
                        tx_ready <= 1;
                    end
                end

                DATA: begin
                    // Accept a byte from upstream
                    if (tx_data_valid && tx_ready) begin
                        byte_to_send <= tx_data;
                        byte_to_send_valid <= 1;

                        // This describes the byte waiting to enter
                        // byte_to_nibble.
                        queued_last <= tx_last;

                        // Queue is now occupied.
                        tx_ready <= 0;
                    end

                    // Queued byte enters byte_to_nibble
                    if (byte_to_send_valid && !splitter_busy) begin

                        // It is no longer merely queued; it is now
                        // the byte actively being transmitted.
                        active_last <= queued_last;
                        
                        // During a non-final byte, allow upstream
                        // to give us the next byte.
                        if (!queued_last)
                            tx_ready <= 1;
                        else
                            tx_ready <= 0;
                    end


                    // Active final byte has completely finished.
                    // The final high nibble was driven during the preceding
                    // MII clock. Pulse frame_done now, before IFG timing.
                    if (splitter_was_busy && !splitter_busy && active_last) begin
                        frame_done <= 1'b1;
                        state <= IFG;
                        tx_ready  <= 0;
                        queued_last <= 0;
                        active_last <= 0;
                        ifg_count <= 0;
                    end
                end
                
                IFG: begin
                    tx_ready  <= 0;
                    tx_busy   <= 1;
                
                    if (ifg_count < IFG_CYCLES - 1)
                        ifg_count <= ifg_count + 1;
                    else begin
                        state   <= IDLE;
                        tx_busy <= 0;
                    end
                end

                default: begin
                    state    <= IDLE;
                    tx_ready <= 0;
                    tx_busy  <= 0;
                end
            endcase
        end
    end
endmodule