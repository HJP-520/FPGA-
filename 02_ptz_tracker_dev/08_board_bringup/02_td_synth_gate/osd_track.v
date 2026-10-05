// =============================================================================
// osd_track.v —— 跟踪信息 OSD 叠加层 v3（三行文本 + 跑马灯 + 双框 + 坐标双缓冲）
// -----------------------------------------------------------------------------
// v3 变更（2026-09-20，消撕裂）：
//   CDC 送来的目标包（pack_valid）可能落在一帧中间。v2 及之前直接更新绘制
//   寄存器，导致同帧上半部分用旧坐标、下半部分用新坐标（可见的框撕裂）。
//   v3 引入影子寄存器组：pack_valid 只写影子；绘制寄存器仅在 I_sof 拍从
//   影子整组换装（vsync 语义），整帧恒用同一快照。
//   注：sof 拍本身（像素 (0,0)）仍用旧值绘制一拍，OSD 起始在 x=16，无视觉影响。
// v2 变更（配合 step5 拓展）：
//   目标包 68bit -> 135bit（IF-VISION v1.1.0）：
//     {valid, algo, preset[2:0], cx[10:0], cy[10:0], minx[10:0], maxx[10:0],
//      miny[9:0], maxy[9:0], fid[7:0], mot_valid, mot_cnt[13:0],
//      mot_minx[10:0], mot_maxx[10:0], mot_miny[9:0], mot_maxy[9:0]}
//   三行文本：
//     L1 y=16:  "<TRK|EDG><n> <LOCK|LOST> X####Y####"
//     L2 y=40:  "D%02d B%+03d C%03d M%04d"
//     L3 y=64:  跑马灯（64 字符消息逐像素滚动，2px/帧）
//   双框：绿色准星 + 红色目标框；运动有效时叠加橙色运动包围框
// 绘制优先级：文字 > 准星 > 目标框 > 运动框 > 底图
// =============================================================================
module osd_track #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720,
    parameter TXT_X0     = 16,
    parameter TXT_Y0     = 16,
    parameter TXT2_Y0    = 40,
    parameter TXT3_Y0    = 64
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_valid,
    input  wire        I_sof,
    input  wire        I_eol,
    input  wire [23:0] I_data,
    input  wire        I_det_clk,
    input  wire        I_det_rst_n,
    input  wire [134:0] I_det_pack,
    input  wire        I_det_load,
    output wire        O_det_busy,
    input  wire [6:0]  I_bright,       // -64..+63
    input  wire [7:0]  I_contrast,     // Q6, 64=1.0
    output reg         O_valid,
    output reg         O_sof,
    output reg         O_eol,
    output reg  [23:0] O_data
);

    wire [134:0] pack_dst;
    wire         pack_valid;
    cdc_4phase #(.WIDTH(135)) u_cdc (
        .I_clk_src(I_det_clk), .I_rst_src_n(I_det_rst_n),
        .I_src_data(I_det_pack), .I_src_load(I_det_load), .O_src_busy(O_det_busy),
        .I_clk_dst(I_clk), .I_rst_dst_n(I_rst_n),
        .O_dst_data(pack_dst), .O_dst_valid(pack_valid)
    );

    reg [7:0] disp_cnt;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) disp_cnt <= 8'd0;
        else if (I_valid && I_sof) disp_cnt <= disp_cnt + 8'd1;
    end

    // ---------------- 影子寄存器组（CDC 域写入，sof 换装） ----------------
    reg        s_tv, s_algo_edg;
    reg [2:0]  s_preset;
    reg [10:0] s_cx, s_cy, s_bminx, s_bmaxx;
    reg [9:0]  s_bminy, s_bmaxy;
    reg [7:0]  s_lat;
    reg        s_mv;
    reg [13:0] s_mcnt;
    reg [10:0] s_mminx, s_mmaxx;
    reg [9:0]  s_mminy, s_mmaxy;
    reg [7:0]  txt1_s [0:19];
    reg [7:0]  txt2_s [0:19];

    // ---------------- 绘制寄存器组（sof 拍整组换装，帧内恒定） ----------------
    reg        tv, algo_edg;
    reg [2:0]  preset_q;
    reg [10:0] cx, cy, bminx, bmaxx;
    reg [9:0]  bminy, bmaxy;
    reg [7:0]  lat_q;
    reg        mv;
    reg [13:0] mcnt;
    reg [10:0] mminx, mmaxx;
    reg [9:0]  mminy, mmaxy;
    reg [7:0]  txt1 [0:19];
    reg [7:0]  txt2 [0:19];
    integer    k;

    function [31:0] to_digits4;
        input [13:0] val;
        reg [13:0] r;
        begin
            to_digits4[31:24] = 8'd48 + val / 14'd1000;
            r = val % 14'd1000;
            to_digits4[23:16] = 8'd48 + r / 14'd100;
            r = r % 14'd100;
            to_digits4[15:8]  = 8'd48 + r / 14'd10;
            to_digits4[7:0]   = 8'd48 + r % 14'd10;
        end
    endfunction
    function [15:0] to_digits2;
        input [7:0] val;
        begin
            to_digits2[15:8] = 8'd48 + val / 8'd10;
            to_digits2[7:0]   = 8'd48 + val % 8'd10;
        end
    endfunction

    reg [31:0] d_x, d_y, d_mot;
    reg [15:0] d_lat;
    reg [7:0]  b_abs;
    // 外脑评审修复：D 字段应使用本包延迟（原读旧 s_lat，文本滞后一包）
    wire [7:0] lat_new = disp_cnt - pack_dst[65:58];

    // 影子写入：CDC 包到达时（可能在帧中间）
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            s_tv <= 0; s_algo_edg <= 0; s_preset <= 0;
            s_cx <= 0; s_cy <= 0;
            s_bminx <= 0; s_bmaxx <= 0; s_bminy <= 0; s_bmaxy <= 0;
            s_lat <= 0; s_mv <= 0; s_mcnt <= 0;
            s_mminx <= 0; s_mmaxx <= 0; s_mminy <= 0; s_mmaxy <= 0;
            for (k = 0; k < 20; k = k + 1) begin
                txt1_s[k] <= 8'd32; txt2_s[k] <= 8'd32;
            end
        end else if (pack_valid) begin
            s_tv       <= pack_dst[134];
            s_algo_edg <= pack_dst[133];
            s_preset   <= pack_dst[132:130];
            s_cx       <= pack_dst[129:119];
            s_cy       <= pack_dst[118:108];
            s_bminx    <= pack_dst[107:97];
            s_bmaxx    <= pack_dst[96:86];
            s_bminy    <= pack_dst[85:76];
            s_bmaxy    <= pack_dst[75:66];
            s_lat      <= lat_new;
            s_mv       <= pack_dst[57];
            s_mcnt     <= pack_dst[56:43];
            s_mminx    <= pack_dst[42:32];
            s_mmaxx    <= pack_dst[31:21];
            s_mminy    <= pack_dst[20:11];
            s_mmaxy    <= pack_dst[10:1];

            txt1_s[0] <= pack_dst[133] ? "E" : "T";
            txt1_s[1] <= pack_dst[133] ? "D" : "R";
            txt1_s[2] <= pack_dst[133] ? "G" : "K";
            txt1_s[3] <= 8'd48 + {5'd0, pack_dst[132:130]};
            txt1_s[4] <= " ";
            txt1_s[5] <= "L"; txt1_s[6] <= "O";
            if (pack_dst[134]) begin
                txt1_s[7] <= "C"; txt1_s[8] <= "K";
            end else begin
                txt1_s[7] <= "S"; txt1_s[8] <= "T";
            end
            txt1_s[9] <= " "; txt1_s[10] <= "X";
            d_x = to_digits4(pack_dst[134] ? pack_dst[129:119] : 11'd0);
            d_y = to_digits4(pack_dst[134] ? pack_dst[118:108] : 11'd0);
            if (!pack_dst[134]) begin
                d_x = 32'h2D2D2D2D; d_y = 32'h2D2D2D2D;
            end
            txt1_s[11] <= d_x[31:24]; txt1_s[12] <= d_x[23:16];
            txt1_s[13] <= d_x[15:8];  txt1_s[14] <= d_x[7:0];
            txt1_s[15] <= "Y";
            txt1_s[16] <= d_y[31:24]; txt1_s[17] <= d_y[23:16];
            txt1_s[18] <= d_y[15:8];  txt1_s[19] <= d_y[7:0];

            d_lat = to_digits2((lat_new > 8'd99) ? 8'd99 : lat_new);
            txt2_s[0] <= "D";
            txt2_s[1] <= d_lat[15:8]; txt2_s[2] <= d_lat[7:0];
            txt2_s[3] <= " ";
            txt2_s[4] <= "B";
            txt2_s[5] <= I_bright[6] ? "-" : "+";
            b_abs = I_bright[6] ? (~I_bright + 1'b1) : I_bright;
            d_lat = to_digits2(b_abs);
            txt2_s[6] <= d_lat[15:8]; txt2_s[7] <= d_lat[7:0];
            txt2_s[8] <= " ";
            txt2_s[9] <= "C";
            d_lat = to_digits2(I_contrast[7:3]);
            txt2_s[10] <= d_lat[15:8]; txt2_s[11] <= d_lat[7:0];
            txt2_s[12] <= " ";
            txt2_s[13] <= "M";
            // 外脑评审覆盖测试抓出的真 bug：原读 s_mcnt（同块 NBA 旧值）,
            // M 字段永远滞后一包（与 D 字段同类的"读旧值"错误）。
            // 改用本包 live 值。
            d_mot = to_digits4((pack_dst[56:43] > 14'd9999) ? 14'd9999 : pack_dst[56:43]);
            txt2_s[14] <= d_mot[31:24]; txt2_s[15] <= d_mot[23:16];
            txt2_s[16] <= d_mot[15:8];  txt2_s[17] <= d_mot[7:0];
            txt2_s[18] <= " "; txt2_s[19] <= " ";
        end
    end

    // vsync 换装：sof 拍整组影子 -> 绘制（帧内恒定，消撕裂）
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            tv <= 0; algo_edg <= 0; preset_q <= 0;
            cx <= 0; cy <= 0;
            bminx <= 0; bmaxx <= 0; bminy <= 0; bmaxy <= 0;
            lat_q <= 0; mv <= 0; mcnt <= 0;
            mminx <= 0; mmaxx <= 0; mminy <= 0; mmaxy <= 0;
            for (k = 0; k < 20; k = k + 1) begin
                txt1[k] <= 8'd32; txt2[k] <= 8'd32;
            end
        end else if (I_valid && I_sof) begin
            tv       <= s_tv;
            algo_edg <= s_algo_edg;
            preset_q <= s_preset;
            cx       <= s_cx;
            cy       <= s_cy;
            bminx    <= s_bminx;
            bmaxx    <= s_bmaxx;
            bminy    <= s_bminy;
            bmaxy    <= s_bmaxy;
            lat_q    <= s_lat;
            mv       <= s_mv;
            mcnt     <= s_mcnt;
            mminx    <= s_mminx;
            mmaxx    <= s_mmaxx;
            mminy    <= s_mminy;
            mmaxy    <= s_mmaxy;
            for (k = 0; k < 20; k = k + 1) begin
                txt1[k] <= txt1_s[k];
                txt2[k] <= txt2_s[k];
            end
        end
    end

    reg [10:0] px;
    reg [9:0]  py;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            px <= 0; py <= 0;
        end else if (I_valid) begin
            if (I_sof) begin
                px <= 11'd1; py <= 10'd0;
            end else if (I_eol) begin
                px <= 11'd0; py <= py + 10'd1;
            end else begin
                px <= px + 11'd1;
            end
        end
    end

    // 跑马灯：消息 "2026 FPGA CONTEST - ANLOGIC PH1P35 VISION TRACKER - " 共 63 字符
    // 偏移 = disp_cnt × 2 px/帧，取模 504（63×8），字符索引 = (px-TXT_X0+off)>>3
    wire [9:0]  mar_off  = {disp_cnt[7:0], 1'b0};               // 0..510
    // 外脑评审: 原 mar_pos[8:3] 截断高位——mar_pos>=512 后字符索引错位。
    // 正确 (mar_pos>>3) mod 63: 63*3=189, 连减三次(索引最大 221)
    wire [11:0] mar_pos  = (px >= TXT_X0) ? (px - TXT_X0 + {2'b00, mar_off}) : 12'd0;
    wire [2:0]  mar_bit  = 3'd7 - mar_pos[2:0];
    wire [3:0]  mar_row  = py - TXT3_Y0;
    wire        in_mar   = (py >= TXT3_Y0) && (py < TXT3_Y0 + 16) &&
                           (px >= TXT_X0) && (px < TXT_X0 + 1280);

    // ---- 跑马灯流水（2026-10-03：TD 将 1024x8 ROM 映射为 ~10 级 LUT3 mux 链，
    //      是 74.25MHz 域的唯一关键路径。此处把"地址计算 + ROM 读"整体提前 4 像素，
    //      ROM 输出经 4 级移位与当前像素对齐——ROM 获得整拍预算，混合级仅剩
    //      位选 + 区域门控 3~4 级逻辑。功能位精确等价（tb_osd_track 逐像素复验）。----
    // 前瞻位姿 (px+4) 需处理行尾跨越：越过 1279 -> 下一行的 px/py。
    // 语义核对：n = px - TXT_X0 + mar_off（虚拟文本坐标，TXT_X0 为 8 的倍数）；
    //           字符 = (n>>3) mod 63；位选 = 7 - (n&7)。
    wire [11:0] px_4  = px + 12'd4;
    wire        xw    = (px_4 > 12'd1279) && (py < 10'd719);   // 行内跨越才换行
    wire [11:0] px_c  = xw ? (px_4 - 12'd1280) : px_4;
    wire [9:0]  py_c  = xw ? (py + 10'd1) : py;

    wire [11:0] mar_pos_c = (px_c >= TXT_X0) ? (px_c - TXT_X0 + {2'b00, mar_off}) : 12'd0;
    wire [7:0]  ci_full_c = {1'b0, mar_pos_c[10:3]};
    wire [7:0]  ci_r1_c   = (ci_full_c >= 8'd252) ? ci_full_c - 8'd252 :
                            (ci_full_c >= 8'd189) ? ci_full_c - 8'd189 :
                            (ci_full_c >= 8'd126) ? ci_full_c - 8'd126 :
                            (ci_full_c >= 8'd63)  ? ci_full_c - 8'd63  : ci_full_c;
    wire [5:0]  mar_ci_c  = ci_r1_c[5:0];
    wire [3:0]  mar_row_c = py_c - TXT3_Y0;
    wire [7:0]  mar_glyph_c;
    marquee_rom_64 u_marq (.I_addr({mar_ci_c, mar_row_c}), .O_bits(mar_glyph_c));

    // 4 级移位对齐：g3 在当拍恰为"本像素"的 ROM 输出（仅在有效像素拍推进）
    reg [7:0] mg0, mg1, mg2, mg3;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            mg0 <= 8'd0; mg1 <= 8'd0; mg2 <= 8'd0; mg3 <= 8'd0;
        end else if (I_valid) begin
            mg0 <= mar_glyph_c;
            mg1 <= mg0;
            mg2 <= mg1;
            mg3 <= mg2;
        end
    end
    wire on_mar = in_mar && mg3[mar_bit];

    // L1 状态行
    wire in_txt1 = (py >= TXT_Y0) && (py < TXT_Y0 + 16) &&
                   (px >= TXT_X0) && (px < TXT_X0 + 160);
    wire [4:0]  ch1_idx = (px - TXT_X0) >> 3;
    wire [3:0]  ch1_row = py - TXT_Y0;
    wire [10:0] dxp     = px - TXT_X0;
    wire [2:0]  bit_sel = 3'd7 - dxp[2:0];
    wire [7:0]  g1;
    font_rom_8x16 u_f1 (.I_addr({txt1[ch1_idx], ch1_row}), .O_bits(g1));
    wire on_txt1 = in_txt1 && g1[bit_sel];

    // L2 遥测行
    wire in_txt2 = (py >= TXT2_Y0) && (py < TXT2_Y0 + 16) &&
                   (px >= TXT_X0) && (px < TXT_X0 + 160);
    wire [4:0]  ch2_idx = (px - TXT_X0) >> 3;
    wire [3:0]  ch2_row = py - TXT2_Y0;
    wire [7:0]  g2;
    font_rom_8x16 u_f2 (.I_addr({txt2[ch2_idx], ch2_row}), .O_bits(g2));
    wire on_txt2 = in_txt2 && g2[bit_sel];

    // 准星/框
    wire signed [12:0] dx_c = $signed({1'b0, px}) - $signed({1'b0, cx});
    wire signed [12:0] dy_c = $signed({1'b0, py}) - $signed({1'b0, cy});
    wire ax = (dx_c >= -13'sd12) && (dx_c <= 13'sd12) &&
              ((dx_c <= -13'sd3) || (dx_c >= 13'sd3));
    wire ay = (dy_c >= -13'sd12) && (dy_c <= 13'sd12) &&
              ((dy_c <= -13'sd3) || (dy_c >= 13'sd3));
    wire on_cross = tv && ((ay && (dx_c == 13'sd0)) || (ax && (dy_c == 13'sd0)));

    wire x_edge = (px == bminx) || (px == bminx + 11'd1) ||
                  (px == bmaxx - 11'd1) || (px == bmaxx);
    wire y_edge = (py == bminy) || (py == bminy + 10'd1) ||
                  (py == bmaxy - 10'd1) || (py == bmaxy);
    wire in_bx = (px >= bminx) && (px <= bmaxx);
    wire in_by = (py >= bminy) && (py <= bmaxy);
    wire on_box = tv && ((x_edge && in_by) || (y_edge && in_bx));

    wire mx_e = (px == mminx) || (px == mminx + 11'd1) ||
                (px == mmaxx - 11'd1) || (px == mmaxx);
    wire my_e = (py == mminy) || (py == mminy + 10'd1) ||
                (py == mmaxy - 10'd1) || (py == mmaxy);
    wire in_mx = (px >= mminx) && (px <= mmaxx);
    wire in_my = (py >= mminy) && (py <= mmaxy);
    wire on_mbox = mv && ((mx_e && in_my) || (my_e && in_mx));

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_valid <= 0; O_sof <= 0; O_eol <= 0; O_data <= 0;
        end else begin
            O_valid <= I_valid;
            O_sof   <= I_sof;
            O_eol   <= I_eol;
            O_data  <= on_txt1 ? 24'hFF_FF_FF :
                       on_txt2 ? 24'hFF_FF_FF :
                       on_mar  ? 24'h00_FF_FF :
                       on_cross ? 24'h00_FF_00 :
                       on_box  ? 24'hFF_00_00 :
                       on_mbox ? 24'hFF_80_00 : I_data;
        end
    end

endmodule
