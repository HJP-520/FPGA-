// =============================================================================
// rgb2hsv.v —— RGB888 -> HSV 色彩空间转换（2 级流水，1 像素/拍）
// -----------------------------------------------------------------------------
// 定点算术与 tools/golden_model.py::rgb_to_hsv 逐位一致（见文件头注释）：
//   V = max(R,G,B); S = max-min（未归一化饱和度代理）
//   inv[d] = floor(3840/d) 查表；h = (差值*inv)>>>6 后截断到 [0,60]
//   3 扇区优先级 R>G>B；delta==0 时 H=0。
// 已知特性：H 仅落在 {0..60, 120..180, 240..300}（详见 01_方案对比）。
// 资源：256x12 ROM + 1 个 9x13 有符号乘法（可综合到 DSP/逻辑）。
// =============================================================================
module rgb2hsv (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_valid,
    input  wire        I_sof,
    input  wire        I_eol,
    input  wire [23:0] I_data,      // {R[7:0], G[7:0], B[7:0]}
    output reg         O_valid,
    output reg         O_sof,
    output reg         O_eol,
    output reg  [8:0]  O_h,         // 0..359
    output reg  [7:0]  O_s,         // = delta
    output reg  [7:0]  O_v          // = max
);

    // ---------------- 第 0 拍：max/min/差值 ----------------
    wire [7:0] r = I_data[23:16];
    wire [7:0] g = I_data[15:8];
    wire [7:0] b = I_data[7:0];

    wire [7:0] rg_max = (r > g) ? r : g;
    wire [7:0] mx     = (rg_max > b) ? rg_max : b;
    wire [7:0] rg_min = (r < g) ? r : g;
    wire [7:0] mn     = (rg_min < b) ? rg_min : b;
    wire [7:0] d      = mx - mn;

    wire is_r = (r >= g) && (r >= b);
    wire is_g = ~is_r && (g >= r) && (g >= b);

    reg signed [8:0] diff_r;     // 扇区所需差值
    always @(*) begin
        if (is_r)      diff_r = $signed({1'b0, g}) - $signed({1'b0, b}); // G-B
        else if (is_g) diff_r = $signed({1'b0, b}) - $signed({1'b0, r}); // B-R
        else           diff_r = $signed({1'b0, r}) - $signed({1'b0, g}); // R-G
    end

    reg [7:0] d_r;
    reg       isg_r, isb_r;
    reg signed [8:0] diff_r1;
    reg [7:0] v_r, s_r;
    reg       valid_r, sof_r, eol_r;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            d_r <= 8'd0; isg_r <= 1'b0; isb_r <= 1'b0; diff_r1 <= 9'sd0;
            v_r <= 8'd0; s_r <= 8'd0;
            valid_r <= 1'b0; sof_r <= 1'b0; eol_r <= 1'b0;
        end else begin
            d_r     <= d;
            isg_r   <= is_g;
            isb_r   <= ~is_r && ~is_g;
            diff_r1 <= diff_r;
            v_r     <= mx;
            s_r     <= d;
            valid_r <= I_valid;
            sof_r   <= I_sof;
            eol_r   <= I_eol;
        end
    end

    // ---------------- 第 1 拍：倒数查表 + 乘法 + 扇区 ----------------
    wire [11:0] inv;
    hsv_inv_lut u_inv (.I_d(d_r), .O_inv(inv));

    wire signed [12:0] inv_s  = {1'b0, inv};                    // 0..3840
    wire signed [21:0] prod   = diff_r1 * inv_s;                // 有符号乘
    wire signed [21:0] h_raw  = prod >>> 6;                     // floor
    wire signed [6:0]  h_clip = (h_raw < 0)   ? 7'sd0 :
                                (h_raw > 60)  ? 7'sd60 :
                                                h_raw[6:0];
    wire [8:0] h_sec = isg_r ? (9'd120 + {2'b0, h_clip}) :
                       isb_r ? (9'd240 + {2'b0, h_clip}) :
                               ({3'b0, h_clip});
    wire [8:0] h_fin = (d_r == 8'd0) ? 9'd0 : h_sec;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_valid <= 1'b0; O_sof <= 1'b0; O_eol <= 1'b0;
            O_h <= 9'd0; O_s <= 8'd0; O_v <= 8'd0;
        end else begin
            O_valid <= valid_r;
            O_sof   <= sof_r;
            O_eol   <= eol_r;
            O_h     <= h_fin;
            O_s     <= s_r;
            O_v     <= v_r;
        end
    end

endmodule
