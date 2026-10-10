module UART_TX #(parameter CLKS_PER_BIT = 868) // 100 MHz clock / 115200 baud
    ( 
    input clk,
    input rst,
    input tx_start,
    input [7:0] tx_data,
    output tx,
    output tx_busy);
    
    localparam IDLE = 3'd0;
    localparam START = 3'd1;
    localparam DATA = 3'd2;
    localparam STOP = 3'd3;
    localparam CLEANUP = 3'd4;
    
    reg [2:0] state = IDLE;
    //baud-rate counter - it counts clock cycles to know when one bit period has elapsed
    //$clog2() - returns the ceiling of log base 2, size the counter automatically
    reg [$clog2(CLKS_PER_BIT):0] clk_cnt = 0; 
    
    //track with bit 0-7 is currently shifting out in DATA state
    reg [2:0] bit_idx = 0;
    
    //stable internal copy of an 8-bit register that holds a copy of the byte being transmitted
    reg [7:0] tx_buf = 0;
    
    reg tx_out, tx_occupied;
    
    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            tx_out <= 1'b0;
            tx_occupied <= 1'b0;
            clk_cnt     <= 0;
            bit_idx     <= 0;
        end else begin
            case(state)
                IDLE: begin
                    tx_out <= 1'b1;
                    tx_occupied <= 1'b0;
                    clk_cnt <= 0;
                    bit_idx <= 0;
                    
                    if(tx_start) begin
                        state <= START;
                        tx_buf <= tx_data;
                        tx_occupied <= 1'b1;
                    end
                end
                
                START: begin
                    tx_out<= 1'b0;
                    if (clk_cnt < CLKS_PER_BIT - 1) //make the tx high for one bit length
                        clk_cnt <= clk_cnt + 1;
                    else begin
                        clk_cnt <= 0;
                        state   <= DATA;
                    end
                end
                
                DATA: begin
                    tx_out <= tx_buf[bit_idx];
                    if (clk_cnt < CLKS_PER_BIT - 1)
                        clk_cnt <= clk_cnt + 1;
                    else begin   //shift out the 8 bits to tx one at a time, LSB first
                        clk_cnt <= 0;
                        if (bit_idx < 7)
                            bit_idx <= bit_idx + 1;
                        else begin
                            bit_idx <= 0;
                            state <= STOP;
                        end
                    end
                end
                
                STOP: begin
                    tx_out <= 1'b1;
                        if (clk_cnt < CLKS_PER_BIT - 1) //make the tx high for one bit length
                            clk_cnt <= clk_cnt + 1;
                        else begin
                            clk_cnt <= 0;
                            state <= CLEANUP;
                    end
                end
                
                CLEANUP: begin
                   tx_occupied <= 0;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
         end
    end
    
    assign tx = tx_out;
    assign tx_busy = tx_occupied;
    
    
    
endmodule