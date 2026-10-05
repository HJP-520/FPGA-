// =============================================================================
// detect_top.v —— 目标检测分支顶层（96bit 窃流 -> 1ppc 检测链 -> 坐标输出）
// -----------------------------------------------------------------------------
// 挂载点：官方链路 isp_top 输出（AWB 之后、data128_96 之前）的 96bit
// AXI4-Stream。本模块为纯旁路：O_* 直通输入（时序零改动），检测链
// ser96to24 -> rgb2hsv -> hsv_threshold -> bin_smooth3x3 -> centroid_accum
// 并行工作，不反压、不修改视频流（OSD 在显示侧叠加）。
// 输出：每帧目标坐标/包围框/计数 + 帧脉冲（供云台控制与 OSD 用）。
// =============================================================================
module detect_top #(
    parameter IMG_WIDTH   = 1280,
    parameter IMG_HEIGHT  = 720,
    parameter MIN_PIXELS  = 30
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    // 96bit AXI4-Stream 视频输入（窃流，不影响主线）
    input  wire [95:0] I_tdata,
    input  wire        I_tvalid,
    input  wire        I_tuser,
    input  wire        I_tlast,
    output wire        O_tready,
    // 直通输出（与输入逐拍一致，供继续传输/比对）
    output wire [95:0] O_tdata,
    output wire        O_tvalid,
    output wire        O_tuser,
    output wire        O_tlast,
    // 阈值组选择（接按键/拨码）
    input  wire [2:0]  I_preset_idx,
    // 检测结果（帧率更新，帧末锁存）
    output wire         O_target_valid,
    output wire [10:0]  O_cx,
    output wire [10:0]  O_cy,
    output wire [20:0]  O_count,
    output wire [10:0]  O_min_x,
    output wire [10:0]  O_max_x,
    output wire [9:0]   O_min_y,
    output wire [9:0]   O_max_y,
    output wire [15:0]  O_lost_cnt,
    output wire         O_results_upd,
    output wire         O_frame_tick,
    // 调试：1ppc 掩码流（可选观察）
    output wire         O_dbg_mask_valid,
    output wire         O_dbg_mask,
    // 进阶④：运动检测输出（帧级锁存）
    output wire         O_mot_valid,
    output wire [13:0]  O_mot_cnt,
    output wire [10:0]  O_mot_minx,
    output wire [10:0]  O_mot_maxx,
    output wire [9:0]   O_mot_miny,
    output wire [9:0]   O_mot_maxy,
    // 串化后 1ppc 原始流（供 OSD 叠加层取底图）
    output wire         O_s_valid,
    output wire         O_s_sof,
    output wire         O_s_eol,
    output wire [23:0]  O_s_data,
    // 进阶③：采集帧号（每输入帧 sof 自增，随目标包携带用于延迟测量）
    output wire [7:0]   O_fid
);

    assign O_tready = 1'b1;
    assign O_tdata  = I_tdata;
    assign O_tvalid = I_tvalid;
    assign O_tuser  = I_tuser;
    assign O_tlast  = I_tlast;

    // 96 -> 1 像素/拍
    wire        s_valid, s_sof, s_eol;
    wire [23:0] s_data;
    ser96to24 u_ser (
        .I_clk(I_clk), .I_rst_n(I_rst_n),
        .I_tdata(I_tdata), .I_tvalid(I_tvalid),
        .I_tuser(I_tuser), .I_tlast(I_tlast),
        .O_tready(),
        .O_valid(s_valid), .O_sof(s_sof), .O_eol(s_eol), .O_data(s_data)
    );

    assign O_s_valid = s_valid;
    assign O_s_sof   = s_sof;
    assign O_s_eol   = s_eol;
    assign O_s_data  = s_data;

    // 进阶③：采集帧号计数器
    reg [7:0] fid;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)
            fid <= 8'd0;
        else if (I_tvalid && I_tuser)
            fid <= fid + 8'd1;
    end
    assign O_fid = fid;

    // RGB -> HSV（2 拍延迟）
    wire        h_valid, h_sof, h_eol;
    wire [8:0]  h_h;
    wire [7:0]  h_s, h_v;
    rgb2hsv u_hsv (
        .I_clk(I_clk), .I_rst_n(I_rst_n),
        .I_valid(s_valid), .I_sof(s_sof), .I_eol(s_eol), .I_data(s_data),
        .O_valid(h_valid), .O_sof(h_sof), .O_eol(h_eol),
        .O_h(h_h), .O_s(h_s), .O_v(h_v)
    );

    // 阈值分割（1 拍延迟）
    wire        t_valid, t_sof, t_eol, t_mask;
    hsv_threshold u_thr (
        .I_clk(I_clk), .I_rst_n(I_rst_n),
        .I_valid(h_valid), .I_sof(h_sof), .I_eol(h_eol),
        .I_h(h_h), .I_s(h_s), .I_v(h_v),
        .I_preset_idx(I_preset_idx),
        .O_valid(t_valid), .O_sof(t_sof), .O_eol(t_eol), .O_mask(t_mask)
    );

    // 3x3 多数表决平滑
    wire        m_valid, m_sof, m_eol, m_mask;
    bin_smooth3x3 #(
        .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT)
    ) u_smooth (
        .I_clk(I_clk), .I_rst_n(I_rst_n),
        .I_valid(t_valid), .I_sof(t_sof), .I_eol(t_eol), .I_mask(t_mask),
        .O_valid(m_valid), .O_sof(m_sof), .O_eol(m_eol), .O_mask(m_mask)
    );

    // 质心/包围框累加
    centroid_accum #(
        .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT),
        .MIN_PIXELS(MIN_PIXELS)
    ) u_cent (
        .I_clk(I_clk), .I_rst_n(I_rst_n),
        .I_valid(m_valid), .I_sof(m_sof), .I_eol(m_eol), .I_mask(m_mask),
        .O_target_valid(O_target_valid), .O_cx(O_cx), .O_cy(O_cy),
        .O_count(O_count),
        .O_min_x(O_min_x), .O_max_x(O_max_x),
        .O_min_y(O_min_y), .O_max_y(O_max_y),
        .O_lost_cnt(O_lost_cnt),
        .O_results_upd(O_results_upd),
        .O_frame_tick(O_frame_tick)
    );

    assign O_dbg_mask_valid = m_valid;
    assign O_dbg_mask       = m_mask;

    // 进阶④：帧差运动检测分支（与 centroid 共享平滑掩码流）
    wire         md_hit;
    wire [13:0]  md_cnt;
    wire [10:0]  md_minx, md_maxx;
    wire [9:0]   md_miny, md_maxy;
    motion_detect #(
        .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT), .MOT_TH(64)
    ) u_motion (
        .I_clk(I_clk), .I_rst_n(I_rst_n),
        .I_valid(m_valid), .I_sof(m_sof), .I_eol(m_eol), .I_mask(m_mask),
        .O_mot_valid(md_hit), .O_mot_cnt(md_cnt),
        .O_mot_minx(md_minx), .O_mot_maxx(md_maxx),
        .O_mot_miny(md_miny), .O_mot_maxy(md_maxy)
    );
    assign O_mot_valid = md_hit;
    assign O_mot_cnt   = md_cnt;
    assign O_mot_minx  = md_minx; assign O_mot_maxx = md_maxx;
    assign O_mot_miny  = md_miny; assign O_mot_maxy = md_maxy;


endmodule
