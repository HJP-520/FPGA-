// =============================================================================
// axis_saturation_rgb96.v —— RGB 饱和度增强级（4 像素/拍，96-bit 流）
// -----------------------------------------------------------------------------
// 背景：板上画面"发灰、饱和度低"的根因是 ISP 链路只有 demosaic + AWB，
//       没有色彩校正（CCM）也没有饱和度处理；本模块补一个最小可用的饱和度级。
//
// 公式（全整数，与 tools/sat_tool.py 严格一致，可位精确对拍）：
//     Y   = (77*R + 150*G + 29*B) >> 8      // BT.601 亮度近似，8bit
//     d   = ch - Y                          // 有符号
//     out = clamp(Y + ((K_Q4 * d + 8) >> 4))// Q4.4 增益, 16=1.00x, 28≈1.75x, 32=2.00x
//
// 接口风格与 isp_top 内 axis_gamma_rgb96 一致：单时钟、无背压、2 拍流水；
// tvalid/tlast/tuser 同步延迟 2 拍，与数据严格对齐（帧边界不受影响）。
//
// 字节序约定：与 AWB 输出一致 —— 每 24bit 一个像素 {R[23:16], G[15:8], B[7:0]}，
//             [23:0]=第 0 像素 … [95:72]=第 3 像素；模块逐通道原位变换，不改布局。
// =============================================================================
module axis_saturation_rgb96 #(
    parameter [5:0] K_Q4 = 6'd21          // Q4.4 增益: 16=1.00x(恒等), 21≈1.31x, 28≈1.75x, 32=2.00x, 上限 63≈3.94x
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tlast,
    input  wire        I_tuser,
    input  wire [95:0] I_tdata,
    input  wire        I_tvalid,
    output reg         O_tlast,
    output reg         O_tuser,
    output reg  [95:0] O_tdata,
    output reg         O_tvalid
);

    // ---------------- 第一级：每像素亮度 Y + 原色寄存 ----------------
    reg [7:0] s1_c [0:11];                // 4 像素 x {R,G,B}：3*i+0=R, +1=G, +2=B
    reg [7:0] s1_y [0:3];
    reg       s1_valid, s1_last, s1_user;
    integer   i;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            s1_valid <= 1'b0;
            s1_last  <= 1'b0;
            s1_user  <= 1'b0;
        end else begin
            s1_valid <= I_tvalid;
            s1_last  <= I_tlast;
            s1_user  <= I_tuser;
            for (i = 0; i < 4; i = i + 1) begin
                s1_c[3*i+0] <= I_tdata[24*i + 23 -: 8];   // R
                s1_c[3*i+1] <= I_tdata[24*i + 15 -: 8];   // G
                s1_c[3*i+2] <= I_tdata[24*i +  7 -: 8];   // B
                s1_y[i]     <= (77  * I_tdata[24*i + 23 -: 8]
                              + 150 * I_tdata[24*i + 15 -: 8]
                              + 29  * I_tdata[24*i +  7 -: 8]) >> 8;
            end
        end
    end

    // ---------------- 第二级：饱和增益 + 限幅 ----------------
    function [7:0] sat_ch;
        input [7:0] c;
        input [7:0] y;
        reg signed [8:0]  d;
        reg signed [15:0] t;
        reg signed [11:0] v;                   // 12bit：K≤63 满量程（评审#7：原10bit 在 K≥33 时先于限幅溢出）
        begin
            d = $signed({1'b0, c}) - $signed({1'b0, y});
            t = d * $signed({1'b0, K_Q4});        // 9bit x 7bit -> 16bit(signed)，|d|·K≤255×63=16065
            t = t + 16'sd8;                        // 四舍五入(+0.5)
            v = $signed({1'b0, y}) + (t >>> 4);    // 算术右移 = floor，与 Python >> 一致
            if (v < 0)          sat_ch = 8'd0;
            else if (v > 16'sd255) sat_ch = 8'd255;
            else                sat_ch = v[7:0];
        end
    endfunction

    reg [7:0] s2_o [0:11];
    reg       s2_valid, s2_last, s2_user;
    integer   j;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            s2_valid <= 1'b0;
            s2_last  <= 1'b0;
            s2_user  <= 1'b0;
        end else begin
            s2_valid <= s1_valid;
            s2_last  <= s1_last;
            s2_user  <= s1_user;
            for (j = 0; j < 4; j = j + 1) begin
                s2_o[3*j+0] <= sat_ch(s1_c[3*j+0], s1_y[j]);
                s2_o[3*j+1] <= sat_ch(s1_c[3*j+1], s1_y[j]);
                s2_o[3*j+2] <= sat_ch(s1_c[3*j+2], s1_y[j]);
            end
        end
    end

    // ---------------- 输出寄存（总延迟 2 拍） ----------------
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_tvalid <= 1'b0;
            O_tlast  <= 1'b0;
            O_tuser  <= 1'b0;
            O_tdata  <= 96'd0;
        end else begin
            O_tvalid <= s2_valid;
            O_tlast  <= s2_last;
            O_tuser  <= s2_user;
            O_tdata  <= { s2_o[ 9], s2_o[10], s2_o[11],   // 像素3 (95:72)
                          s2_o[ 6], s2_o[ 7], s2_o[ 8],   // 像素2 (71:48)
                          s2_o[ 3], s2_o[ 4], s2_o[ 5],   // 像素1 (47:24)
                          s2_o[ 0], s2_o[ 1], s2_o[ 2] }; // 像素0 (23:0)
        end
    end

endmodule
