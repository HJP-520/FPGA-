// =============================================================================
// system_top.v —— 嵌入式方向系统集成顶层（仿真/TD 双用）
// -----------------------------------------------------------------------------
// 挂载关系（对应 06_interfaces/current 三份接口文档）：
//   虚拟/真实 RAW10 流 ─> isp_top（官方，CSI 解包在 PHY 侧已完成，此处从
//                          raw10_unpacket 输出界接入）─> 128bit DDR 写流
//   128bit ─data128_96(官方重排)─> 96bit ─> vision_top（视觉目标包/OSD/云台）
//   按键消抖 ─> 阈值组切换；UART 遥测输出目标状态
// 与官方例程的差异（全部为"增加"，无官方文件改动）：
//   1. 不含 DDR2/MIPI-PHY/HDMI 加密核（仿真以帧转储替代 HDMI；DDR 写流空置）
//   2. 新增 uart_telemetry 遥测
// 时钟：单域 axi4s_video_aclk（74.25M 级）；pwm_clk 50M 由引脚给入
// =============================================================================
module system_top #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720,
    parameter CLK_DIV_UART = 646          // 74.25MHz/115200 ≈ 645
)(
    input  wire        I_clk,             // axi4s_video_aclk
    input  wire        I_rst_n,
    input  wire        I_pwm_clk,         // 50MHz
    input  wire        I_pwm_rst_n,
    // 虚拟/真实 RAW10 传感器流（真实板 = raw10_unpacket_2lane 输出）
    input  wire [39:0] I_raw10_data,
    input  wire        I_raw10_valid,
    input  wire        I_raw10_sof,
    input  wire        I_raw10_eol,
    // 按键（低有效，经消抖）
    input  wire [1:0]  I_btn_n,
    input  wire        I_algo_edge,
    input  wire [6:0]  I_bright,
    input  wire [7:0]  I_contrast,
    output wire        O_led_g,
    output wire        O_led_r,
    output wire        O_buzzer,
    // 云台 PWM
    output wire        O_pwm_x,
    output wire        O_pwm_y,
    output wire [12:0] O_duty_x_us,
    output wire [12:0] O_duty_y_us,
    output wire [15:0] O_lost_cnt,
    // UART 遥测
    output wire        O_uart_txd,
    // 调试观察口（外脑评审：OSD 流接口补全 sof/eol，供显示侧正式消费）
    output wire [23:0] O_osd_data,
    output wire        O_osd_valid,
    output wire        O_osd_sof,
    output wire        O_osd_eol
);

    // ---------------- 官方 ISP（RAW10 -> RGB） ----------------
    // 2026-10-03 修复（迭代记录 #N+6）：
    //  (1) 握手：isp_top.O_tready 是"下游就绪输入"（官方 wrapper 也悬空该网，
    //      有效行为=无背压）。原代码把该浮动网串进 I_tvalid —— 仿真为 Z、综合后
    //      会毁掉输入使能。本整合顶层无显示主路，显式恒 1（与有效行为一致）；
    //      I_tvalid 直接用 RAW 有效（与官方 design_top_wrapper 同款接法）。
    //  (2) 视觉抽头改 AWB 96bit（tap_*，4px RGB888，tuser/tlast 实测正确）；
    //      弃用 128bit 重排路径——其 tuser 与 valid 结构性错位（frame_start 直通
    //      延迟 1 拍 vs valid 受 4:3 门控，实测 tuser∧valid 恒为 0）。
    wire [127:0] isp_tdata;
    wire         isp_tvalid, isp_tuser, isp_tlast;
    wire         isp_up_tready;
    wire [95:0]  tap_tdata;
    wire         tap_tvalid, tap_tuser, tap_tlast;

    isp_top u_isp (
        .axi4s_video_aclk (I_clk),
        .I_rst_n          (I_rst_n),
        .I_tlast          (I_raw10_eol),
        .I_tuser          (I_raw10_sof),
        .I_tdata          (I_raw10_data),
        .I_tvalid         (I_raw10_valid),
        .I_tdest          (10'd0),
        .O_tready         (1'b1),            // 无显示主路，恒就绪（原悬空网已修）
        .O_tdata          (isp_tdata),
        .O_tlast          (isp_tlast),
        .O_tuser          (isp_tuser),
        .O_tvalid         (isp_tvalid),
        .I_tready         (isp_up_tready),   // 对上游就绪指示（输出）
        .tap_tdata        (tap_tdata),
        .tap_tvalid       (tap_tvalid),
        .tap_tuser        (tap_tuser),
        .tap_tlast        (tap_tlast)
    );

    // ---------------- 按键消抖（官方模块）-> 阈值组/跟踪使能 ----------------
    wire key0_trig, key1_trig;
    key_remove_shakes u_key0 (.I_clk(I_clk), .I_rst_n(I_rst_n),
        .I_key_in(~I_btn_n[0]), .O_key_trig_out(key0_trig));
    key_remove_shakes u_key1 (.I_clk(I_clk), .I_rst_n(I_rst_n),
        .I_key_in(~I_btn_n[1]), .O_key_trig_out(key1_trig));

    reg [2:0]  preset_idx  = 3'd0;
    reg        track_en    = 1'b1;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            preset_idx <= 3'd0;
            track_en   <= 1'b1;
        end else begin
            if (key0_trig) preset_idx <= preset_idx + 3'd1;   // KEY0: 切阈值组
            if (key1_trig) track_en   <= ~track_en;           // KEY1: 跟踪使能
        end
    end

    // ---------------- 外部输入 2FF 同步 ----------------
    // 外脑评审：按键/拨码为异步引脚输入，直接使用存在亚稳风险
    // （尤其 I_algo_edge 在帧首采样）。每输入两组触发器同步。
    reg [1:0] syn_algo, syn_bright0, syn_bright1, syn_ctr0, syn_ctr1;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            syn_algo <= 2'b00; syn_bright0 <= 7'd0; syn_bright1 <= 7'd0;
            syn_ctr0 <= 8'd64; syn_ctr1 <= 8'd64;
        end else begin
            syn_algo    <= {syn_algo[0], I_algo_edge};
            syn_bright0 <= I_bright;      syn_bright1 <= syn_bright0;
            syn_ctr0    <= I_contrast;    syn_ctr1    <= syn_ctr0;
        end
    end
    wire        algo_s     = syn_algo[1];
    wire [6:0]  bright_s   = syn_bright1;
    wire [7:0]  contrast_s = syn_ctr1;

    // ---------------- 视觉方向 vision_top（检测/OSD/云台） ----------------
    wire [95:0]  vis_pt_data;   // 视觉直通（本顶层不使用）
    wire         vis_pt_valid, vis_pt_user, vis_pt_last, vis_tready;
    wire         osd_valid, osd_sof, osd_eol;
    wire [23:0]  osd_data;
    wire [12:0]  duty_x, duty_y;
    wire [15:0]  lost_cnt;
    wire [7:0]   status;
    // 遥测用目标状态（外脑评审: 端口化替代层次化引用, 可综合可约束）
    wire         frame_tick, target_valid;
    wire [10:0]  tgt_cx, tgt_cy;

    vision_top #(
        .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT)
    ) u_vision (
        .I_pix_clk    (I_clk),
        .I_pix_rst_n  (I_rst_n),
        .I_pwm_clk    (I_pwm_clk),
        .I_pwm_rst_n  (I_pwm_rst_n),
        .I_tdata      (tap_tdata),
        .I_tvalid     (tap_tvalid),
        .I_tuser      (tap_tuser),
        .I_tlast      (tap_tlast),
        .O_tready     (vis_tready),
        .O_tdata      (vis_pt_data),
        .O_tvalid     (vis_pt_valid),
        .O_tuser      (vis_pt_user),
        .O_tlast      (vis_pt_last),
        .O_osd_valid  (osd_valid),
        .O_osd_sof    (osd_sof),
        .O_osd_eol    (osd_eol),
        .O_osd_data   (osd_data),
        .I_preset_idx (preset_idx),
        .I_track_en   (track_en),
        .I_algo_edge  (algo_s),
        .I_bright     (bright_s),
        .I_contrast   (contrast_s),
        .O_pwm_x      (O_pwm_x),
        .O_pwm_y      (O_pwm_y),
        .O_duty_x_us  (O_duty_x_us),
        .O_duty_y_us  (O_duty_y_us),
        .O_lost_cnt   (O_lost_cnt),
        .O_status     (status),
        .O_led_g      (O_led_g),
        .O_led_r      (O_led_r),
        .O_buzzer     (O_buzzer),
        .O_frame_tick (frame_tick),
        .O_target_valid (target_valid),
        .O_tgt_cx     (tgt_cx),
        .O_tgt_cy     (tgt_cy)
    );
    assign O_osd_valid = osd_valid;
    assign O_osd_data  = osd_data;
    assign O_osd_sof   = osd_sof;
    assign O_osd_eol   = osd_eol;
    // vis_tready 由 vision_top 内部恒 1 驱动（窃流不反压），
    // 顶层不得再 assign 同一网络（外脑评审: 多驱动会在 TD 综合报错）。

    // ---------------- UART 遥测（新增 RTL；信号经 vision_top 端口引出） ----------------
    // 外脑评审修复：原用层次化引用 u_vision.t_* 取跨域信号——TD 综合下
    // 层次引用不可靠且无法施加 CDC 约束，现改走 vision_top 显式端口。
    uart_telemetry #(.CLK_DIV(CLK_DIV_UART)) u_uart (
        .I_clk          (I_clk),
        .I_rst_n        (I_rst_n),
        .I_frame_tick   (frame_tick),
        .I_target_valid (target_valid),
        .I_cx           (tgt_cx),
        .I_cy           (tgt_cy),
        .I_preset       (preset_idx),
        .O_txd          (O_uart_txd)
    );

    // 视觉内部信号已端口化（见 vision_top O_frame_tick/O_target_valid/O_tgt_cx/cy）
endmodule
