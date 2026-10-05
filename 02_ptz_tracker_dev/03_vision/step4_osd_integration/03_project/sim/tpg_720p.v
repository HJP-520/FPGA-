// =============================================================================
// tpg_720p.v —— 720p 测试图案发生器（96bit 4像素/拍 AXI-S 视频源）
// -----------------------------------------------------------------------------
// 作用一：无摄像头阶段替代 SC500CS，验证显示/检测全链路；
// 作用二：闭环仿真中由 TB 实时改变 I_box_x/I_box_y 模拟云台转动；
// 作用三：最终板载演示的"无相机演示源"（赛道允许时）。
// 图案：8 竖条（灰阶×4 + 蓝 + 绿 + 深绿 + 深蓝，全部避开红色阈值窗）
//       + 参数化红色方块（默认关闭时颜色无害）。
// 方块坐标为"左上角"输入，TB/上位机按云台模型换算后驱动。
// =============================================================================
module tpg_720p #(
    parameter IMG_WIDTH   = 1280,
    parameter IMG_HEIGHT  = 720,
    parameter BOX_EN      = 1,      // 红色方块使能
    parameter BOX_W       = 80,
    parameter BOX_H       = 80,
    parameter GAP_EN      = 0       // 1: 插入随机空闲拍，锻炼握手鲁棒性
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire [10:0] I_box_x,     // 方块左上角 x（0..W-BOX_W）
    input  wire [9:0]  I_box_y,
    output reg         O_tvalid,
    output reg  [95:0] O_tdata,
    output reg         O_tuser,
    output reg         O_tlast,
    input  wire        I_tready     // 未用（本模块恒发），保留端口对称
);

    localparam BEATS_PER_LINE = IMG_WIDTH / 4;      // 320
    localparam CW = 11;                              // x 位宽

    reg [CW-1:0] beat_x;
    reg [9:0]    y;
    reg [15:0]   lfsr;
    reg [1:0]    pres;    // beat 节拍 4 分频：beat 率 = 像素率/4（真实总线占空）

    wire do_send = (pres == 2'd0) &&
                   (~GAP_EN | (lfsr[0] | (lfsr[7:0] == 8'h00)));

    // 单像素颜色生成：8 竖条 + 红方块
    function [23:0] px_color;
        input [CW+1:0] px;    // 像素列号
        input [9:0]    py;
        begin
            if (BOX_EN && (px >= {1'b0, I_box_x}) && (px < {1'b0, I_box_x} + BOX_W) &&
                (py >= I_box_y) && (py < I_box_y + BOX_H))
                px_color = 24'hE0_20_20;                       // 目标红
            else if (px < 13'd160)
                px_color = 24'h40_40_40;
            else if (px < 13'd320)
                px_color = 24'h80_80_80;
            else if (px < 13'd480)
                px_color = 24'hC0_C0_C0;
            else if (px < 13'd640)
                px_color = 24'hE0_E0_E0;
            else if (px < 13'd800)
                px_color = 24'h20_20_E0;                       // 蓝
            else if (px < 13'd960)
                px_color = 24'h20_E0_20;                       // 绿
            else if (px < 13'd1120)
                px_color = 24'h10_60_10;                       // 深绿
            else
                px_color = 24'h10_10_60;                       // 深蓝
        end
    endfunction

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            beat_x <= 0;
            y      <= 0;
            pres   <= 2'd0;
            lfsr   <= 16'hACE1;
            O_tvalid <= 1'b0;
            O_tdata  <= 96'd0;
            O_tuser  <= 1'b0;
            O_tlast  <= 1'b0;
        end else begin
            O_tvalid <= do_send;
            pres <= pres + 2'd1;
            if (do_send) begin
                O_tdata <= {px_color({beat_x, 2'b00}, y),
                            px_color({beat_x, 2'b01}, y),
                            px_color({beat_x, 2'b10}, y),
                            px_color({beat_x, 2'b11}, y)};
                O_tuser <= (beat_x == 0) && (y == 0);
                O_tlast <= (beat_x == BEATS_PER_LINE - 1);
                if (beat_x == BEATS_PER_LINE - 1) begin
                    beat_x <= 0;
                    if (y == IMG_HEIGHT - 1)
                        y <= 0;
                    else
                        y <= y + 10'd1;
                end else begin
                    beat_x <= beat_x + 1'b1;
                end
            end
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        end
    end

endmodule
