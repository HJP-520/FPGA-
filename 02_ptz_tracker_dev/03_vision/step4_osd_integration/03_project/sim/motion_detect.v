// =============================================================================
// motion_detect.v —— 帧差运动检测（进阶④）
// 输入：平滑后的二值掩码流（与 centroid 同源同拍）。
// 结构：整帧 1bit 前帧缓存（W*H bit，TD 映射 ERAM；仿真为寄存器阵列），
//       同地址读旧写新，diff = cur ^ prev。
// 输出：每帧锁存 运动像素计数 + 运动包围框（cnt ≥ MOT_TH 才有效）。
// 首帧 prev 未填充：started 门控，首帧不计（仿真 X 与综合 0 行为一致性强制）。
// =============================================================================
module motion_detect #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720,
    parameter MOT_TH     = 64
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_valid,
    input  wire        I_sof,
    input  wire        I_eol,
    input  wire        I_mask,
    output reg         O_mot_valid,
    output reg  [13:0] O_mot_cnt,
    output reg  [10:0] O_mot_minx,
    output reg  [10:0] O_mot_maxx,
    output reg  [9:0]  O_mot_miny,
    output reg  [9:0]  O_mot_maxy
);
    localparam TOTAL = IMG_WIDTH * IMG_HEIGHT;

    (* ram_style = "block" *) reg prev_mem [0:TOTAL-1];

    reg [10:0] x;
    reg [9:0]  y;
    reg [20:0] row_base;
    reg        started;

    wire [20:0] addr = row_base + {10'd0, x};
    wire        old  = prev_mem[addr];
    wire        diff = I_mask ^ old;

    // 帧内累加
    reg [13:0] cnt;
    reg        seen;
    reg [10:0] bmin_x, bmax_x;
    reg [9:0]  bmin_y, bmax_y;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            x <= 0; y <= 0; row_base <= 0; started <= 0;
        end else if (I_valid) begin
            if (I_sof) begin
                x <= 11'd1; y <= 10'd0; row_base <= 21'd0;
            end else if (I_eol) begin
                x <= 11'd0;
                y <= (y == IMG_HEIGHT - 1) ? 10'd0 : y + 10'd1;
            end else begin
                x <= x + 11'd1;
            end
            // 行基址随行推进（避免乘法）
            if (I_eol)
                row_base <= row_base + IMG_WIDTH;
            // 前帧缓存滚动（读旧写新）
            prev_mem[addr] <= I_mask;
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            cnt <= 0; seen <= 0;
            bmin_x <= 0; bmax_x <= 0; bmin_y <= 0; bmax_y <= 0;
        end else if (I_valid && I_sof) begin
            cnt <= 0; seen <= 0;
        end else if (I_valid && started && diff) begin
            cnt <= (cnt == 14'h3FFF) ? cnt : cnt + 14'd1;
            if (!seen) begin
                seen <= 1'b1;
                bmin_x <= x; bmax_x <= x; bmin_y <= y; bmax_y <= y;
            end else begin
                if (x < bmin_x) bmin_x <= x;
                if (x > bmax_x) bmax_x <= x;
                if (y < bmin_y) bmin_y <= y;
                if (y > bmax_y) bmax_y <= y;
            end
        end
    end

    // 末行 eol 后锁存
    wire last_eol = I_valid && I_eol && (y == IMG_HEIGHT - 1);
    reg started_d;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            started_d <= 1'b0;
        end else begin
            started_d <= started;
            if (I_valid && I_sof) started <= 1'b1;
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_mot_valid <= 1'b0;
            O_mot_cnt <= 0; O_mot_minx <= 0; O_mot_maxx <= 0;
            O_mot_miny <= 0; O_mot_maxy <= 0;
        end else begin
            O_mot_valid <= 1'b0;
            if (last_eol && started_d) begin
                O_mot_valid <= (cnt >= MOT_TH);
                O_mot_cnt   <= cnt;
                O_mot_minx  <= bmin_x; O_mot_maxx <= bmax_x;
                O_mot_miny  <= bmin_y; O_mot_maxy <= bmax_y;
            end
        end
    end

endmodule
