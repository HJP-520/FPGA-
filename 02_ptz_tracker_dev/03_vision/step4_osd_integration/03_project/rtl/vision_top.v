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
    output wire        O_buzzer,
    // 目标状态直出（外脑评审: 供顶层 UART 遥测等使用, 替代层次化引用）
    output wire        O_frame_tick,
    output wire        O_target_valid,
    output wire [10:0] O_tgt_cx,
    output wire [10:0] O_tgt_cy
);

    // ---------------- 复位同步释放（异步置位 / 各域同步释放） ----------------
    // 外脑评审（两版一致）：直接透传引脚复位在释放沿存在 recovery/removal 风险
    // 与域间释放偏斜；此处每域两拍同步释放，全部分子模块统一使用。
    reg [1:0] pix_rst_sync, pwm_rst_sync;
    always @(posedge I_pix_clk or negedge I_pix_rst_n)
        if (!I_pix_rst_n) pix_rst_sync <= 2'b00;
        else              pix_rst_sync <= {pix_rst_sync[0], 1'b1};
    always @(posedge I_pwm_clk or negedge I_pwm_rst_n)
        if (!I_pwm_rst_n) pwm_rst_sync <= 2'b00;
        else              pwm_rst_sync <= {pwm_rst_sync[0], 1'b1};
    wire pix_rst_n_s = pix_rst_sync[1];
    wire pwm_rst_n_s = pwm_rst_sync[1];

    wire        det_s_valid, det_s_sof, det_s_eol;
    wire [23:0] det_s_data;
    wire        det_sync_err;      // v4.1 串化器帧同步错误（检测支路）

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
        .I_clk(I_pix_clk), .I_rst_n(pix_rst_n_s),
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
        .O_s_eol(det_s_eol), .O_s_data(det_s_data),
        .O_sync_err(det_sync_err)
    );

    // ---------------- 进阶①：边缘检测并行分支 ----------------
    wire        e_tlast, e_tuser, e_tvalid;
    wire [95:0] e_tdata;
    wire [7:0]  gimbal_status;     // gimbal 原始状态字节（[6] 由顶层并入同步错误）

    edge_detect_96 #(
        .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT), .EDGE_TH(80)
    ) u_edge (
        .I_clk(I_pix_clk), .I_rst_n(pix_rst_n_s),
        .I_tlast(I_tlast), .I_tuser(I_tuser),
        .I_tdata(I_tdata), .I_tvalid(I_tvalid), .I_tready(I_tvalid),
        .O_tlast(e_tlast), .O_tuser(e_tuser), .O_tdata(e_tdata),
        .O_tvalid(e_tvalid), .O_tready()
    );

    wire        e_s_valid, e_s_sof, e_s_eol, e_sync_err;
    wire [23:0] e_s_data;
    ser96to24 u_ser_edge (
        .I_clk(I_pix_clk), .I_rst_n(pix_rst_n_s),
        .I_tdata(e_tdata), .I_tvalid(e_tvalid), .I_tuser(e_tuser), .I_tlast(e_tlast),
        .O_tready(),
        .O_valid(e_s_valid), .O_sof(e_s_sof), .O_eol(e_s_eol), .O_data(e_s_data),
        .O_sync_err(e_sync_err)
    );

    // algo mux：输出侧帧边界提交（三版外部评审共识修复）
    // 原实现按"输入 SOF"切换：mux 立即换选择，而被选分支仍在输出其上一帧
    // 尾部，造成切换帧内新旧算法内容拼接。现改为：输入 SOF 处请求，
    // 等**目标分支自己的输出 SOF** 到达时才换装——每个输出帧严格单算法，
    // 旧算法帧尾被截短（下游由新帧 SOF 复位，无污染）。
    reg        algo_q;       // 当前生效算法
    reg        algo_req;     // 有未决切换
    reg        algo_pend;    // 目标算法
    reg        algo_req_d;   // 请求延迟一拍（超时判定用）
    // 提交/超时条件与选择信号（外脑评审 GPT-3 实锤修复）：
    // 原实现里 mux 由独立 always 在"提交沿之后"才看到新 algo_q，
    // 而目标分支的 SOF 仅 1 拍脉冲 → 新帧 SOF 被吃掉（切换窗 sof=0，
    // tb_algo_switch 已在修复前复现）。现在让提交沿**当拍**直接控制选择。
    wire algo_commit = algo_req && (algo_pend ? e_s_sof  : det_s_sof);
    wire algo_force  = algo_req && algo_req_d && I_tvalid && I_tuser;
    wire algo_sel    = (algo_commit || algo_force) ? algo_pend : algo_q;

    always @(posedge I_pix_clk or negedge pix_rst_n_s) begin
        if (!pix_rst_n_s) begin
            algo_q <= 1'b0; algo_req <= 1'b0; algo_pend <= 1'b0; algo_req_d <= 1'b0;
        end else begin
            algo_req_d <= algo_req;
            if (I_tvalid && I_tuser && (I_algo_edge != algo_q) && !algo_req) begin
                algo_req  <= 1'b1;
                algo_pend <= I_algo_edge;
            end else if (algo_commit || algo_force) begin
                // 正常：目标分支输出 SOF 当拍提交；
                // 超时：请求挂满一帧仍未提交（目标分支异常）→ 输入帧首强制提交，
                // 退化为输入侧切换语义（仅损失该帧的无拼接保证，绝不卡死）。
                algo_q   <= algo_pend;
                algo_req <= 1'b0;
            end
        end
    end

    reg        m_valid, m_sof, m_eol;
    reg [23:0] m_data;
    always @(posedge I_pix_clk or negedge pix_rst_n_s) begin
        if (!pix_rst_n_s) begin
            m_valid <= 0; m_sof <= 0; m_eol <= 0; m_data <= 0;
        end else begin
            // 注意：这里用组合的 algo_sel（含提交沿当拍）而非 algo_q，
            // 保证提交拍就选出新分支的 SOF/首像素（见上方修复注释）。
            if (!algo_sel) begin
                m_valid <= det_s_valid; m_sof <= det_s_sof;
                m_eol <= det_s_eol;     m_data <= det_s_data;
            end else begin
                m_valid <= e_s_valid;   m_sof <= e_s_sof;
                m_eol <= e_s_eol;       m_data <= e_s_data;
            end
        end
    end

    // ---------------- 扩展④：亮度/对比度（显示路径） ----------------
    // 外脑评审修复（显示链断接）：原实现 OSD 底图接 det_s_*，导致
    // 算法切换（edge）与亮度/对比度只进 video_adj 后再无下游（死分支）、
    // 画面上永远只有跟踪视频。现改为 mux -> video_adj -> OSD 完整串联；
    // sof/eol 与 video_adj 同拍延迟对齐。
    wire        a_valid;
    wire [23:0] a_data;
    reg         a_sof, a_eol;
    video_adj u_adj (
        .I_clk(I_pix_clk), .I_rst_n(pix_rst_n_s),
        .I_valid(m_valid), .I_data(m_data),
        .I_bright(I_bright), .I_contrast(I_contrast),
        .O_valid(a_valid), .O_data(a_data)
    );
    always @(posedge I_pix_clk or negedge pix_rst_n_s) begin
        if (!pix_rst_n_s) begin a_sof <= 1'b0; a_eol <= 1'b0; end
        else begin        a_sof <= m_sof;      a_eol <= m_eol; end
    end

    // ---------------- 目标包 v2（135bit，bit0 保留位，发送端必须补齐。
    // 缺位时整包上移一位，OSD 解析 valid 恒 0（"永远 LOST"事故根因，2026-09-20 修） ----
    // 外脑评审: algo 位用帧首锁存的 algo_q（与该帧实际使用的算法一致）
    wire [134:0] pack_vision = {t_valid, algo_q, I_preset_idx, t_cx, t_cy,
                                t_minx, t_maxx, t_miny, t_maxy, t_fid,
                                mo_valid, mo_cnt[13:0],
                                mo_minx, mo_maxx, mo_miny, mo_maxy, 1'b0};

    // ---------------- OSD 路径 ----------------
    osd_track #(
        .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT)
    ) u_osd (
        .I_clk(I_pix_clk), .I_rst_n(pix_rst_n_s),
        .I_valid(a_valid), .I_sof(a_sof),
        .I_eol(a_eol), .I_data(a_data),
        .I_det_clk(I_pix_clk), .I_det_rst_n(pix_rst_n_s),
        .I_det_pack(pack_vision), .I_det_load(t_upd), .O_det_busy(),
        .I_bright(I_bright), .I_contrast(I_contrast),
        .O_valid(O_osd_valid), .O_sof(O_osd_sof), .O_eol(O_osd_eol),
        .O_data(O_osd_data)
    );

    // ---------------- 声光反馈 ----------------
    // 200ms @74.25MHz = 14,850,000（原 100000 仅 1.35ms，与文档"200ms"不符）
    led_buzzer #(.BEEP_CYCLES(14850000)) u_led (
        .I_clk(I_pix_clk), .I_rst_n(pix_rst_n_s),
        .I_frame_tick(t_tick), .I_target_valid(t_valid),
        .O_led_g(O_led_g), .O_led_r(O_led_r), .O_buzzer(O_buzzer)
    );

    // ---------------- 云台控制路径 ----------------
    // 外脑评审 D1 实锤：原 tick=pulse_sync(t_tick) 比 cdc 数据早到约 0.9µs，
    // 云台在 tick 拍拿到的是上一帧甚至更旧的包（实际 2 帧滞后）。
    // 现改为"新包到达的下一拍"做节拍——tick 与数据同源，滞后=1 帧。
    wire [22:0] ctrl_pack_src = {t_valid, t_cx, t_cy};
    wire [22:0] ctrl_pack_dst;
    wire        ctrl_valid_dst;
    reg  [22:0] ctrl_hold;
    reg         ctrl_vld_hold;
    cdc_4phase #(.WIDTH(23)) u_ctrl_cdc (
        .I_clk_src(I_pix_clk), .I_rst_src_n(pix_rst_n_s),
        .I_src_data(ctrl_pack_src), .I_src_load(t_upd), .O_src_busy(),
        .I_clk_dst(I_pwm_clk), .I_rst_dst_n(pwm_rst_n_s),
        .O_dst_data(ctrl_pack_dst), .O_dst_valid(ctrl_valid_dst)
    );
    // 控制节拍 = ctrl_valid_dst 打一拍（保证本拍消费的就是刚换装的包）
    reg tick_pwm_r;
    always @(posedge I_pwm_clk or negedge pwm_rst_n_s) begin
        if (!pwm_rst_n_s) tick_pwm_r <= 1'b0;
        else              tick_pwm_r <= ctrl_valid_dst;
    end
    wire tick_pwm = tick_pwm_r;

    always @(posedge I_pwm_clk or negedge pwm_rst_n_s) begin
        if (!pwm_rst_n_s) begin
            ctrl_hold <= 23'd0; ctrl_vld_hold <= 1'b0;
        end else begin
            // 外脑评审: 新包与 tick 同拍时新包优先（原写法后清零覆盖新包,
            // 云台会丢一帧目标）
            if (ctrl_valid_dst) begin
                ctrl_hold     <= ctrl_pack_dst;
                ctrl_vld_hold <= ctrl_pack_dst[22];
            end else if (tick_pwm) begin
                ctrl_vld_hold <= 1'b0;
            end
        end
    end

    wire [12:0] duty_x, duty_y;
    gimbal_ctrl #(
        .KP_X(KP_X), .KP_Y(KP_Y), .DZ_X(DZ_X), .DZ_Y(DZ_Y),
        .SLEW_US(SLEW_US), .SERVO_MIN_US(SERVO_MIN_US), .SERVO_MAX_US(SERVO_MAX_US),
        .CENTER_X(IMG_WIDTH/2), .CENTER_Y(IMG_HEIGHT/2),
        .INVERT_X(INVERT_X), .INVERT_Y(INVERT_Y)
    ) u_gimbal (
        .I_clk(I_pwm_clk), .I_rst_n(pwm_rst_n_s),
        .I_frame_tick(tick_pwm), .I_track_en(I_track_en),
        .I_target_valid(ctrl_vld_hold),
        .I_cx(ctrl_hold[21:11]), .I_cy(ctrl_hold[10:0]),
        .O_duty_x_us(duty_x), .O_duty_y_us(duty_y),
        .O_lost_cnt(O_lost_cnt), .O_status(gimbal_status)
    );

    // O_status 位定义：gimbal [5:0]（dz/lim/lost）+ [6] 串化器帧同步错误（v4.1 新）
    //                    + [7] 保留（0）。位 6 为"帧同步契约破坏"粘滞指示。
    assign O_status = {1'b0, (det_sync_err | e_sync_err), gimbal_status[5:0]};

    pwm_servo u_pwm (
        .I_clk(I_pwm_clk), .I_rst_n(pwm_rst_n_s),
        .I_update(tick_pwm),
        .I_duty_x_us(duty_x), .I_duty_y_us(duty_y),
        .O_pwm_x(O_pwm_x), .O_pwm_y(O_pwm_y),
        .O_period_tick(), .O_duty_x_dbg(O_duty_x_us), .O_duty_y_dbg(O_duty_y_us)
    );

    // ---------------- 目标状态直出 ----------------
    assign O_frame_tick   = t_tick;
    assign O_target_valid = t_valid;
    assign O_tgt_cx       = t_cx;
    assign O_tgt_cy       = t_cy;

endmodule
