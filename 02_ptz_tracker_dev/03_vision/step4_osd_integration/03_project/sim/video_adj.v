// =============================================================================
// video_adj.v —— 显示参数调节（扩展④）：亮度/对比度
// out = clamp( ((c - 128) * C >> 6) + 128 + B )
//   C: 对比度 64..192（64 = 1.0 倍，Q6 定点）；B: 亮度 -64..+64
// 应用点：显示路径（OSD 之前），检测分支不受影响（扩展④"调节显示参数"）。
// 1 拍流水；参数同域直连（vision_top 内 pix 域）。
// =============================================================================
module video_adj (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_valid,
    input  wire [23:0] I_data,        // {R,G,B}
    input  wire [6:0]  I_bright,      // 有符号：-64..+63（二补码）
    input  wire [7:0]  I_contrast,    // 无符号：64..192（Q6）
    output reg         O_valid,
    output reg  [23:0] O_data
);
    // 单通道处理函数
    function [7:0] adj_ch;
        input [7:0] c;
        input [6:0] bright;
        input [7:0] contrast;
        reg signed [16:0] v;
        begin
            v = $signed({1'b0, c}) - 17'sd128;       // 居中
            v = (v * $signed({1'b0, contrast})) >>> 6;
            v = v + 17'sd128 + $signed({1'b0, bright});
            if (v < 0)        adj_ch = 8'd0;
            else if (v > 255) adj_ch = 8'd255;
            else              adj_ch = v[7:0];
        end
    endfunction

    wire [7:0] r_adj = adj_ch(I_data[23:16], I_bright, I_contrast);
    wire [7:0] g_adj = adj_ch(I_data[15:8],  I_bright, I_contrast);
    wire [7:0] b_adj = adj_ch(I_data[7:0],   I_bright, I_contrast);

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_valid <= 1'b0;
            O_data  <= 24'd0;
        end else begin
            O_valid <= I_valid;
            O_data  <= {r_adj, g_adj, b_adj};
        end
    end
endmodule
