module top_eth_phy_bringup (
    input  clk,              // 100 MHz onboard oscillator
    output eth_ref_clk,      // drives the PHY's 25MHz reference
    output eth_rstn,         // PHY reset, active low
    output [3:0] led
);

    wire clk_25mhz;
    wire mmcm_locked;

    clk_wiz_0 clk_gen (
        .clk_in1(clk),
        .clk_out1(clk_25mhz),
        .reset(1'b0),          // MMCM's own reset input - tie low (not resetting)
        .locked(mmcm_locked)
    );

    assign eth_ref_clk = clk_25mhz;

    reg [23:0] reset_counter;
    reg phy_rst_n;

    always @(posedge clk) begin
        if (!mmcm_locked) begin
            reset_counter <= 0;
            phy_rst_n <= 0;
        end
        else if (reset_counter < 24'hFFFFFF) begin
            reset_counter <= reset_counter + 1;
            phy_rst_n <= 0;
        end
        else begin
            phy_rst_n <= 1;
        end
    end

    assign eth_rstn = phy_rst_n;
    assign led = {mmcm_locked, phy_rst_n, 2'b00};

endmodule