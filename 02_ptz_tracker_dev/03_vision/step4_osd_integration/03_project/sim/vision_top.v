// =============================================================================
// vision_top.v —— 视觉整机顶层 v2（step5 拓展后）
// -----------------------------------------------------------------------------
// v2 新增（step5）：
//   进阶① 多算法切换：edge_detect_96 并行 + algo mux（帧边界平稳切换）
//   进阶③ 延迟可视化：fid 随目标包传递，OSD 显示 D+NN
//   进阶④ 帧差运动检测：motion_detect 分支，运动包围框 OSD 橙色叠加
//   扩展④ 亮度/对比度：video_adj（显示路径，检测分支不受影响）
//   声光反馈：led_buzzer（嵌入式方向）
// 目标包 v2 = 135bit（IF-VISION v1.1.0）
// =============================================================================
module vision_top #(
    parameter IMG_WIDTH    = 1280,
    parameter IMG_HEIGHT   = 720,
    parameter MIN_PIXELS   = 30,
    parameter KP_X         = 20,
    parameter KP_Y         = 18,
    parameter DZ_X         = 25,
    parameter DZ_Y         = 20,
    parameter SLEW_US      = 100,
    parameter SERVO_MIN_US = 700,
    parameter SERVO_MAX_US = 2300,
    parameter INVERT_X     = 0,
    parameter INVERT_Y     = 0
)(
    input  wire        I_pix_clk,
    input  wire        I_pix_rst_n,
    input  wire        I_pwm_clk,
    input  wire        I_pwm_rst_n,
    input  wire [95:0] I_tdata,
    input  wire        I_tvalid,
    input  wire        I_tuser,
    input  wire        I_tlast,
    output wire        O_tready,
    output wire [95:0] O_tdata,
    output wire        O_tvalid,
    output wire        O_tuser,
    output wire        O_tlast,
    output wire        O_osd_valid,
    output wire        O_osd_sof,
    output wire        O_osd_eol,
    output wire [23:0] O_osd_data,
    input  wire [2:0]  I_preset_idx,
    input  wire        I_track_en,
    input  wire        I_algo_edge,      // 进阶①：显示算法 0=跟踪 1=边缘
    input  wire [6:0]  I_bright,         // 扩展④ 亮度
    input  wire [7:0]  I_contrast,       // 扩展④ 对比度 Q6
    output wire        O_pwm_x,
    output wire        O_pwm_y,
    output wire [12:0] O_duty_x_us,
    output wire [12:0] O_duty_y_us,
    output wire [15:0] O_lost_cnt,
    output wire [7:0]  O_status,
    output wire        O_led_g,
    output wire        O_led_r,
    output wire        O_buzzer
);

    wire        det_s_valid, det_s_sof, det_s_eol;
    wire [23:0] det_s_data;

    // ---------------- 检测分支 ----------------
    wire         t_valid, t_upd, t_tick;
    wire [10:0]  t_cx, t_cy, t_minx, t_maxx;
    wire [9:0]   t_miny, t_maxy;
    wire [20:0]  t_cnt;
    wire [15:0]  lost_det;
    wire [7:0]   t_fid;
    wire         mo_valid;
    wire [13:0]  mo_cnt;
    wire [10:0]  mo_minx, mo_maxx;
    wire [9:0]   mo_miny, mo_maxy;

    detect_top #(
        .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT), .MIN_PIXELS(MIN_PIXELS)
    ) u_det (
        .I_clk(I_pix_clk), .I_rst_n(I_pix_rst_n),
        .I_tdata(I_tdata), .I_tvalid(I_tvalid), .I_tuser(I_tuser), .I_tlast(I_tlast),
        .O_tready(O_tready),
        .O_tdata(O_tdata), .O_tvalid(O_tvalid), .O_tuser(O_tuser), .O_tlast(O_tlast),
        .I_preset_idx(I_preset_idx),
        .O_target_valid(t_valid), .O_cx(t_cx), .O_cy(t_cy), .O_count(t_cnt),
        .O_min_x(t_minx), .O_max_x(t_maxx), .O_min_y(t_miny), .O_max_y(t_maxy),
        .O_lost_cnt(lost_det), .O_results_upd(t_upd), .O_frame_tick(t_tick),
        .O_fid(t_fid),
        .O_mot_valid(mo_valid), .O_mot_cnt(mo_cnt),
        .O_mot_minx(mo_minx), .O_mot_maxx(mo_maxx),
        .O_mot_miny(mo_miny), .O_mot_maxy(mo_maxy),
        .O_dbg_mask_valid(), .O_dbg_mask(),
        .O_s_valid(det_s_valid), .O_s_sof(det_s_sof),
        .O_s_eol(det_s_eol), .O_s_data(det_s_data)
    );

    // ---------------- 进阶①：边缘检测并行分支 ----------------
    wire        e_tlast, e_tuser, e_tvalid;
    wire [95:0] e_tdata;

    edge_detect_96 #(
        .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT), .EDGE_TH(80)
    ) u_edge (
        .I_clk(I_pix_clk), .I_rst_n(I_pix_rst_n),
        .I_tlast(I_tlast), .I_tuser(I_tuser),
        .I_tdata(I_tdata), .I_tvalid(I_tvalid), .I_tready(I_tvalid),
        .O_tlast(e_tlast), .O_tuser(e_tuser), .O_tdata(e_tdata),
        .O_tvalid(e_tvalid), .O_tready()
    );

    wire        e_s_valid, e_s_sof, e_s_eol;
    wire [23:0] e_s_data;
    ser96to24 u_ser_edge (
        .I_clk(I_pix_clk), .I_rst_n(I_pix_rst_n),
        .I_tdata(e_tdata), .I_tvalid(e_tvalid), .I_tuser(e_tuser), .I_tlast(e_tlast),
        .O_tready(),
        .O_valid(e_s_valid), .O_sof(e_s_sof), .O_eol(e_s_eol), .O_data(e_s_data)
    );

    // algo mux：帧边界平稳切换（帧首拍锁存选择）
    reg        algo_q;
    always @(posedge I_pix_clk or negedge I_pix_rst_n) begin
        if (!I_pix_rst_n)
            algo_q <= 1'b0;
        else if (I_tvalid && I_tuser)
            algo_q <= I_algo_edge;
    end

    reg        m_valid, m_sof, m_eol;
    reg [23:0] m_data;
    always @(posedge I_pix_clk or negedge I_pix_rst_n) begin
        if (!I_pix_rst_n) begin
            m_valid <= 0; m_sof <= 0; m_eol <= 0; m_data <= 0;
        end else begin
            if (!algo_q) begin
                m_valid <= det_s_valid; m_sof <= det_s_sof;
                m_eol <= det_s_eol;     m_data <= det_s_data;
            end else begin
                m_valid <= e_s_valid;   m_sof <= e_s_sof;
                m_eol <= e_s_eol;       m_data <= e_s_data;
            end
        end
    end

    // ---------------- 扩展④：亮度/对比度 ----------------
    wire        a_valid;
    wire [23:0] a_data;
    video_adj u_adj (
        .I_clk(I_pix_clk), .I_rst_n(I_pix_rst_n),
        .I_valid(m_valid), .I_data(m_data),
        .I_bright(I_bright), .I_contrast(I_contrast),
        .O_valid(a_valid), .O_data(a_data)
    );

    // ---------------- 目标包 v2（135bit） ----------------
    wire [134:0] pack_vision = {t_valid, I_algo_edge, I_preset_idx, t_cx, t_cy,
                                t_minx, t_maxx, t_miny, t_maxy, t_fid,
                                mo_valid, mo_cnt[13:0],
                                mo_minx, mo_maxx, mo_miny, mo_maxy};

    // ---------------- OSD 路径 ----------------
    osd_track #(
        .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT)
    ) u_osd (
        .I_clk(I_pix_clk), .I_rst_n(I_pix_rst_n),
        .I_valid(det_s_valid), .I_sof(det_s_sof),
        .I_eol(det_s_eol), .I_data(det_s_data),
        .I_det_clk(I_pix_clk), .I_det_rst_n(I_pix_rst_n),
        .I_det_pack(pack_vision), .I_det_load(t_upd), .O_det_busy(),
        .I_bright(I_bright), .I_contrast(I_contrast),
        .O_valid(O_osd_valid), .O_sof(O_osd_sof), .O_eol(O_osd_eol),
        .O_data(O_osd_data)
    );

    // ---------------- 声光反馈 ----------------
    led_buzzer #(.BEEP_CYCLES(100000)) u_led (
        .I_clk(I_pix_clk), .I_rst_n(I_pix_rst_n),
        .I_frame_tick(t_tick), .I_target_valid(t_valid),
        .O_led_g(O_led_g), .O_led_r(O_led_r), .O_buzzer(O_buzzer)
    );

    // ---------------- 云台控制路径 ----------------
    wire tick_pwm;
    pulse_sync u_tick_sync (
        .I_clk_src(I_pix_clk), .I_rst_src_n(I_pix_rst_n), .I_pulse_src(t_tick),
        .I_clk_dst(I_pwm_clk), .I_rst_dst_n(I_pwm_rst_n), .O_pulse_dst(tick_pwm)
    );

    wire [22:0] ctrl_pack_src = {t_valid, t_cx, t_cy};
    wire [22:0] ctrl_pack_dst;
    wire        ctrl_valid_dst;
    reg  [22:0] ctrl_hold;
    reg         ctrl_vld_hold;
    cdc_4phase #(.WIDTH(23)) u_ctrl_cdc (
        .I_clk_src(I_pix_clk), .I_rst_src_n(I_pix_rst_n),
        .I_src_data(ctrl_pack_src), .I_src_load(t_upd), .O_src_busy(),
        .I_clk_dst(I_pwm_clk), .I_rst_dst_n(I_pwm_rst_n),
        .O_dst_data(ctrl_pack_dst), .O_dst_valid(ctrl_valid_dst)
    );
    always @(posedge I_pwm_clk or negedge I_pwm_rst_n) begin
        if (!I_pwm_rst_n) begin
            ctrl_hold <= 23'd0; ctrl_vld_hold <= 1'b0;
        end else begin
            if (ctrl_valid_dst) begin
                ctrl_hold     <= ctrl_pack_dst;
                ctrl_vld_hold <= ctrl_pack_dst[22];
            end
            if (tick_pwm)
                ctrl_vld_hold <= 1'b0;
        end
    end

    wire [12:0] duty_x, duty_y;
    gimbal_ctrl #(
        .KP_X(KP_X), .KP_Y(KP_Y), .DZ_X(DZ_X), .DZ_Y(DZ_Y),
        .SLEW_US(SLEW_US), .SERVO_MIN_US(SERVO_MIN_US), .SERVO_MAX_US(SERVO_MAX_US),
        .CENTER_X(IMG_WIDTH/2), .CENTER_Y(IMG_HEIGHT/2),
        .INVERT_X(INVERT_X), .INVERT_Y(INVERT_Y)
    ) u_gimbal (
        .I_clk(I_pwm_clk), .I_rst_n(I_pwm_rst_n),
        .I_frame_tick(tick_pwm), .I_track_en(I_track_en),
        .I_target_valid(ctrl_vld_hold),
        .I_cx(ctrl_hold[21:11]), .I_cy(ctrl_hold[10:0]),
        .O_duty_x_us(duty_x), .O_duty_y_us(duty_y),
        .O_lost_cnt(O_lost_cnt), .O_status(O_status)
    );

    pwm_servo u_pwm (
        .I_clk(I_pwm_clk), .I_rst_n(I_pwm_rst_n),
        .I_update(tick_pwm),
        .I_duty_x_us(duty_x), .I_duty_y_us(duty_y),
        .O_pwm_x(O_pwm_x), .O_pwm_y(O_pwm_y),
        .O_period_tick(), .O_duty_x_dbg(O_duty_x_us), .O_duty_y_dbg(O_duty_y_us)
    );

endmodule
