module UART_RX #(parameter CLKS_PER_BIT = 868) // 100 MHz clock / 115200 baud
    ( 
    input clk,
    input rst,
    input rx,
    output reg [7:0] rx_data,
    output reg rx_valid,
    output reg rx_error);
    
    localparam IDLE = 3'd0;
    localparam START = 3'd1;
    localparam DATA = 3'd2;
    localparam STOP = 3'd3;
    
    reg [2:0] state = IDLE;
    reg [$clog2(CLKS_PER_BIT):0] clk_cnt = 0;
    reg [2:0] bit_idx = 0;
    reg [7:0] rx_buf = 0;
        
    always @(posedge clk) begin
       if (rst) begin
            state    <= IDLE;
            clk_cnt  <= 0;
            bit_idx  <= 0;
            rx_valid <= 1'b0;
            rx_error <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    rx_valid <= 1'b0;   // clear the one-cycle pulse from any previous byte
                    clk_cnt  <= 0;
                    bit_idx  <= 0;

                    if (rx == 1'b0) begin   // falling edge detected - start bit beginning
                        state <= START;
                    end
                end
                
                START: begin
                    if (clk_cnt < CLKS_PER_BIT/2 - 1)
                        clk_cnt <= clk_cnt + 1;
                    else begin
                        clk_cnt <= 0;
                        if (rx == 1'b0)
                            state <= DATA;
                        else
                            state <= IDLE;   // was a glitch, not a real start bit - bail out
                    end
                end
                
                DATA: begin
                    if (clk_cnt < CLKS_PER_BIT - 1) // count out one full bit period to reach the next bit's middle
                        clk_cnt <= clk_cnt + 1;
                    else begin
                        clk_cnt <= 0;
                        rx_buf[bit_idx] <= rx;
                        if (bit_idx < 7) 
                            bit_idx <= bit_idx + 1;
                        else begin
                            bit_idx <= 0;
                            state <= STOP;
                        end
                    end
                end
                
                STOP: begin
                    if (clk_cnt < CLKS_PER_BIT - 1) // count out the stop-bit period, then check it's high
                            clk_cnt <= clk_cnt + 1;
                        else begin
                            clk_cnt <= 0;
                            state <= IDLE;
                            if (rx==1'b1) begin
                                rx_valid <= 1'b1;
                                rx_data  <= rx_buf;
                                rx_error <= 1'b0;
                            end
                            else 
                                rx_error <= 1'b1;
                        end
                    end
                default: state <= IDLE;
            endcase
        end
    
    end
    
    
endmodule