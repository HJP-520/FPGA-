// =============================================================================
// uart_rx_mon.v —— UART 接收监视器（仅供仿真）：8N1，2 分辨率过采样
// =============================================================================
`timescale 1ns/1ps
module uart_rx_mon #(
    parameter integer CLK_DIV = 646
)(
    input  wire       I_clk,
    input  wire       I_rst_n,
    input  wire       I_rxd,
    output reg  [7:0] O_byte,
    output reg        O_valid
);
    reg [1:0] sync;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) sync <= 2'b11;
        else          sync <= {sync[0], I_rxd};
    end
    wire rxd = sync[1];

    reg [3:0] bit_cnt;
    reg [7:0] shifter;
    reg [9:0] div;
    reg       busy;
    reg       done_d;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            busy <= 0; bit_cnt <= 0; div <= 0; shifter <= 0;
            O_byte <= 0; O_valid <= 0; done_d <= 0;
        end else begin
            O_valid <= 0;
            done_d  <= O_valid;
            if (!busy) begin
                if (!rxd) begin            // 起始位
                    busy <= 1;
                    div  <= CLK_DIV/2;     // 半拍后采样对齐位中心
                    bit_cnt <= 0;
                end
            end else begin
                div <= div + 1;
                if (div == CLK_DIV - 1) begin
                    div <= 0;
                    if (bit_cnt == 0) begin
                        if (rxd) begin      // 假起始
                            busy <= 0;
                        end else begin
                            bit_cnt <= 1;
                        end
                    end else if (bit_cnt <= 8) begin
                        shifter <= {rxd, shifter[7:1]};
                        bit_cnt <= bit_cnt + 1;
                    end else begin
                        busy <= 0;
                        if (rxd) begin      // 停止位正确
                            O_byte  <= shifter;
                            O_valid <= 1;
                        end
                    end
                end
            end
        end
    end
endmodule
