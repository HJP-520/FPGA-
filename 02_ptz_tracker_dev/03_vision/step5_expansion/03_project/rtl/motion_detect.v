// =============================================================================
// motion_detect.v —— 帧差运动检测（进阶④，v3 流水版 2026-10-03）
// 输入：平滑后的二值掩码流（与 centroid 同源同拍）。
// 结构：整帧 1bit 前帧缓存（W*H bit，TD 映射 ERAM），同步读一级流水：
//       第 1 拍发地址/写新值，第 2 拍取读出旧值与延迟一拍的掩码比对。
//       —— v2 用组合读 prev_mem[addr]，行为仿真可行但 TD ERAM(Block RAM)
//          不支持组合读，上板综合会失败；v3 改为同步读 + 信号对齐流水。
// 输出（语义定稿，2026-10-03 评审措辞澄清）：
//   O_mot_cnt/O_mot_bbox 每帧末锁存（含亚门限帧，cnt==0 时 bbox 全 0）；
//   O_mot_valid **本身就是阈值标志**=(cnt >= MOT_TH)：仅该帧判为运动时
//   拉高 1 拍（帧末结果与阈值判决合为一个输出，无独立逐帧选通信号）；
//   OSD 运动框以它为门控（mv），亚门限帧不画框。
//
// 版本要点：
//   v2 [1] sof 拍写地址强制 0（不再用上一帧遗留 row_base 算地址）；
//      [2] 首帧门控用 prev_ready（首帧不比对、不输出）；
//   v3 [3] 同步读流水（TD 可实现）；[4] addr 越界保护；
//   v3.1 写地址延迟一拍（与 ERAM 写模式解耦，防 WRITE_FIRST 下 diff 恒 0）；
//      [5] cnt==0 时 bbox 锁存 0（与金标准 frame_diff_motion 语义一致）。
// 已知约定：(0,0) 像素每帧只写缓存、不参与比对（sof 拍结构，1/921600）。
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

    // ---------------- 坐标计数（输入拍） ----------------
    reg [10:0] x;
    reg [9:0]  y;
    reg [20:0] row_base;
    reg        prev_ready;   // 首帧缓存填满后置位；首帧不比对、不输出

    // sof 拍像素是 (0,0)：写地址强制 0（见 v2[1]）
    wire [20:0] addr = I_sof ? 21'd0 : (row_base + {10'd0, x});
    wire [20:0] addr_safe = (addr < TOTAL) ? addr : 21'd0;   // v3[4] 越界保护

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            x <= 11'd0; y <= 10'd0; row_base <= 21'd0; prev_ready <= 1'b0;
        end else if (I_valid) begin
            if (I_sof) begin
                x <= 11'd1; y <= 10'd0; row_base <= 21'd0;
            end else if (I_eol) begin
                x <= 11'd0;
                y <= (y == IMG_HEIGHT - 1) ? 10'd0 : y + 10'd1;
                row_base <= row_base + IMG_WIDTH;
                if (y == IMG_HEIGHT - 1) prev_ready <= 1'b1;  // 首帧末行：缓存已填满
            end else begin
                x <= x + 11'd1;
            end
        end
    end

    // ---------------- 一级流水：ERAM 同步读 + 信号对齐（v3[3]） ----------------
    // v3.1 外脑评审：写地址**延迟一拍**——杜绝同拍同址读写。
    // 若 ERAM 被综合为 WRITE_FIRST 模式，同址读写会让 old_r 直接读到新掩码，
    // diff 恒 0（运动检测静默失效）；地址错开一拍后与写模式无关（结构性读旧）。
    reg        old_r;                          // 前帧掩码（同步读输出）
    reg [20:0] addr_d;                         // 写地址（延迟一拍）
    reg        mask_wr;                        // 写数据（延迟一拍）
    reg        wr_en_d;                        // 写使能（延迟一拍）
    reg        v_d, sof_d, eol_d, mask_d, ready_d;
    reg [10:0] x_d;
    reg [9:0]  y_d;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            old_r <= 1'b0;
            addr_d <= 21'd0; mask_wr <= 1'b0; wr_en_d <= 1'b0;
            v_d <= 1'b0; sof_d <= 1'b0; eol_d <= 1'b0;
            mask_d <= 1'b0; ready_d <= 1'b0;
            x_d <= 11'd0; y_d <= 10'd0;
        end else begin
            old_r <= prev_mem[addr_safe];              // 读：本拍地址（读旧）
            // 写：上一拍的地址/数据 → 与读地址恒不同址（流内地址逐一递增）
            if (wr_en_d && (addr_d < TOTAL))
                prev_mem[addr_d] <= mask_wr;
            addr_d  <= addr_safe;
            mask_wr <= I_mask;
            wr_en_d <= I_valid;
            v_d   <= I_valid; sof_d <= I_sof; eol_d <= I_eol;
            mask_d <= I_mask; ready_d <= prev_ready;
            x_d   <= x; y_d <= y;
        end
    end

    wire diff = mask_d ^ old_r;    // 与 x_d/y_d/v_d 同拍对齐

    // ---------------- 帧内累加（延迟域） ----------------
    reg [13:0] cnt;
    reg        seen;
    reg [10:0] bmin_x, bmax_x;
    reg [9:0]  bmin_y, bmax_y;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            cnt <= 14'd0; seen <= 1'b0;
            bmin_x <= 11'd0; bmax_x <= 11'd0; bmin_y <= 10'd0; bmax_y <= 10'd0;
        end else if (v_d && sof_d) begin
            cnt <= 14'd0; seen <= 1'b0;            // 帧首清零（sof 像素不比对）
        end else if (v_d && ready_d && diff) begin
            cnt <= (cnt == 14'h3FFF) ? cnt : cnt + 14'd1;   // 饱和（14bit 接口）
            if (!seen) begin
                seen   <= 1'b1;
                bmin_x <= x_d; bmax_x <= x_d; bmin_y <= y_d; bmax_y <= y_d;
            end else begin
                if (x_d < bmin_x) bmin_x <= x_d;
                if (x_d > bmax_x) bmax_x <= x_d;
                if (y_d < bmin_y) bmin_y <= y_d;
                if (y_d > bmax_y) bmax_y <= y_d;
            end
        end
    end

    // ---------------- 帧末锁存（延迟域；首帧 prev_ready=0 不输出） ----------------
    // 外脑评审修复：锁存再延迟一拍——末像素的 diff 在 last_eol_d 同拍累加，
    // 同拍锁存读到的是旧 cnt/bbox（每帧漏掉 (W-1,H-1) 一个像素的计数）。
    wire last_eol_d = v_d && eol_d && (y_d == IMG_HEIGHT - 1);
    reg  last_eol_dd;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) last_eol_dd <= 1'b0;
        else          last_eol_dd <= last_eol_d;
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_mot_valid <= 1'b0;
            O_mot_cnt <= 14'd0;
            O_mot_minx <= 11'd0; O_mot_maxx <= 11'd0;
            O_mot_miny <= 10'd0; O_mot_maxy <= 10'd0;
        end else begin
            O_mot_valid <= 1'b0;
            if (last_eol_dd && ready_d) begin
                O_mot_valid <= (cnt >= MOT_TH);
                O_mot_cnt   <= cnt;
                // v3[5] cnt==0 时 bbox 全 0（与金标准一致）
                O_mot_minx  <= (cnt == 14'd0) ? 11'd0 : bmin_x;
                O_mot_maxx  <= (cnt == 14'd0) ? 11'd0 : bmax_x;
                O_mot_miny  <= (cnt == 14'd0) ? 10'd0 : bmin_y;
                O_mot_maxy  <= (cnt == 14'd0) ? 10'd0 : bmax_y;
            end
        end
    end

endmodule
