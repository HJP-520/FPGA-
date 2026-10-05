// =============================================================================
// osd_track.v —— 跟踪信息 OSD 叠加层 v2（三行文本 + 跑马灯 + 双框）
// -----------------------------------------------------------------------------
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
            to_digits2[7:0]  = 8'd48 + val % 8'd10;
        end
    endfunction

    reg [31:0] d_x, d_y, d_mot;
    reg [15:0] d_lat;
    reg [7:0]  b_abs;

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
        end else if (pack_valid) begin
            tv       <= pack_dst[134];
            algo_edg <= pack_dst[133];
            preset_q <= pack_dst[132:130];
            cx       <= pack_dst[129:119];
            cy       <= pack_dst[118:108];
            bminx    <= pack_dst[107:97];
            bmaxx    <= pack_dst[96:86];
            bminy    <= pack_dst[85:76];
            bmaxy    <= pack_dst[75:66];
            lat_q    <= disp_cnt - pack_dst[65:58];
            mv       <= pack_dst[57];
            mcnt     <= pack_dst[56:43];
            mminx    <= pack_dst[42:32];
            mmaxx    <= pack_dst[31:21];
            mminy    <= pack_dst[20:11];
            mmaxy    <= pack_dst[10:1];

            txt1[0] <= pack_dst[133] ? "E" : "T";
            txt1[1] <= pack_dst[133] ? "D" : "R";
            txt1[2] <= pack_dst[133] ? "G" : "K";
            txt1[3] <= 8'd48 + {5'd0, pack_dst[132:130]};
            txt1[4] <= " ";
            txt1[5] <= "L"; txt1[6] <= "O";
            if (pack_dst[134]) begin
                txt1[7] <= "C"; txt1[8] <= "K";
            end else begin
                txt1[7] <= "S"; txt1[8] <= "T";
            end
            txt1[9] <= " "; txt1[10] <= "X";
            d_x = to_digits4(pack_dst[134] ? pack_dst[129:119] : 11'd0);
            d_y = to_digits4(pack_dst[134] ? pack_dst[118:108] : 11'd0);
            if (!pack_dst[134]) begin
                d_x = 32'h2D2D2D2D; d_y = 32'h2D2D2D2D;
            end
            txt1[11] <= d_x[31:24]; txt1[12] <= d_x[23:16];
            txt1[13] <= d_x[15:8];  txt1[14] <= d_x[7:0];
            txt1[15] <= "Y";
            txt1[16] <= d_y[31:24]; txt1[17] <= d_y[23:16];
            txt1[18] <= d_y[15:8];  txt1[19] <= d_y[7:0];

            d_lat = to_digits2((lat_q > 8'd99) ? 8'd99 : lat_q);
            txt2[0] <= "D";
            txt2[1] <= d_lat[15:8]; txt2[2] <= d_lat[7:0];
            txt2[3] <= " ";
            txt2[4] <= "B";
            txt2[5] <= I_bright[6] ? "-" : "+";
            b_abs = I_bright[6] ? (~I_bright + 1'b1) : I_bright;
            d_lat = to_digits2(b_abs);
            txt2[6] <= d_lat[15:8]; txt2[7] <= d_lat[7:0];
            txt2[8] <= " ";
            txt2[9] <= "C";
            d_lat = to_digits2(I_contrast[7:3]);
            txt2[10] <= d_lat[15:8]; txt2[11] <= d_lat[7:0];
            txt2[12] <= " ";
            txt2[13] <= "M";
            d_mot = to_digits4((mcnt > 14'd9999) ? 14'd9999 : mcnt);
            txt2[14] <= d_mot[31:24]; txt2[15] <= d_mot[23:16];
            txt2[16] <= d_mot[15:8];  txt2[17] <= d_mot[7:0];
            txt2[18] <= " "; txt2[19] <= " ";
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
    wire [11:0] mar_pos  = (px >= TXT_X0) ? (px - TXT_X0 + {2'b00, mar_off}) : 12'd0;
    wire [5:0]  mar_ci   = mar_pos[8:3] % 6'd63;                 // mod 63（消息长度）
    wire [3:0]  mar_row  = py - TXT3_Y0;
    wire        in_mar   = (py >= TXT3_Y0) && (py < TXT3_Y0 + 16) &&
                           (px >= TXT_X0) && (px < TXT_X0 + 1280);
    wire [7:0]  mar_glyph;
    marquee_rom_64 u_marq (.I_addr({mar_ci, mar_row}), .O_bits(mar_glyph));
    wire on_mar = in_mar && mar_glyph[7 - mar_pos[2:0]];

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
