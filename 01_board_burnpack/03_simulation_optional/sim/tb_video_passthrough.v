`timescale 1ns/1ps
// =============================================================================
// tb_video_passthrough.v —— 视频传输路线整链仿真（摄像头画面到达验证）
// -----------------------------------------------------------------------------
// 链路：虚拟 RAW10 传感器(文件回放) -> isp_top(官方明码: demosaic/AWB/重排)
//       -> [饱和度增强 axis_saturation_rgb96 (SAT_EN=1 时, 本次新增)]
//       -> 96bit 抽头 -> ser96to24(1ppc) -> frame_dump24(逐帧转储)
//
// 判据与输出：
//   1. 转储 passthrough_frame_N.hex（每帧 1280x720 RGB888, 行主序）
//      —— 这就是"屏幕应该显示的画面"（仿真里的 HDMI 替身）
//   2. 几何报告：AWB 输出的 tuser/tlast 计数（诚实打印；
//      已知发现：demosaic 的 tuser 链在纯 RTL 仿真可能不激活，
//      上板若"有数据无帧同步"先查这里 —— 见使用指导 PDF）
//   3. PASS = 至少 2 帧完整转储
//   饱和度级说明：SAT_EN=1 时抽头取饱和度输出（K_Q4 见下）；
//   SAT_EN=0 可复现未加饱和度级的基线帧（与 baseline_oct03/ 对拍）。
// =============================================================================
module tb_video_passthrough;
    reg clk = 0, rst_n = 0;
    always #7 clk = ~clk;                 // ~71.4MHz（axi4s_video_aclk 仿真值）

    // ---------------- 虚拟 RAW10 传感器（文件回放） ----------------
    reg [39:0] beats [0:921599];          // 40bit = 4 像素 x RAW10
    reg [1:0]  metas [0:921599];          // bit1=sof(帧首) bit0=eol(行尾)
    integer    nb;
    integer    bi = 0;

    initial begin
        $readmemh("raw10_beats.hex", beats);
        $readmemh("raw10_meta.txt",  metas);
        nb = 230400 * 3;                  // 3 帧馈送: 前 2 帧为验收目标, 第 3 帧兼作流水冲刷
    end

    wire        isp_ready;                // isp 对上游的就绪指示
    reg         raw_valid = 1'b0;
    reg  [39:0] raw_data  = 40'd0;
    reg         raw_sof = 1'b0, raw_eol = 1'b0;

    // 馈送占空 1/8：真实 MIPI 传感器按节拍出图，且下游串化器每 4 拍才
    // 消费 1 个 beat——满速馈送会淹没 1ppc 消费端（溢出丢像素）。
    // 1/8 占空馈送 + 正确 AXI 握手（每拍恰好被消费一次）：
    // - 满 1/8：demosaic 输出 4px/拍 vs 转储侧 1px/拍存在速率差，
    //   满速会让弹性 FIFO 满而搁浅尾帧；1/8 占空留足排空余量。
    // - 历史：valid 跨拍保持会使同一 beat 被重复消费 8 次，eol/tuser
    //   计数 x8 打乱 Bayer 行相位——务必一拍一消费。
    reg [2:0] pres;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pres <= 3'd0;
        else        pres <= pres + 3'd1;
    end
    wire feed_slot = (pres == 3'd0);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            raw_valid <= 1'b0;
        end else if (raw_valid) begin
            if (isp_ready) begin
                raw_valid <= 1'b0;                 // 本拍已被消费
            end
        end else if (feed_slot && (bi < nb)) begin
            raw_data  <= beats[bi];
            raw_sof   <= metas[bi][1];
            raw_eol   <= metas[bi][0];
            raw_valid <= 1'b1;
            bi = bi + 1;
        end
    end

    // ---------------- 官方 ISP 明码链 ----------------
    wire [127:0] isp_tdata;
    wire         isp_tvalid, isp_tuser, isp_tlast;

    isp_top u_isp (
        .axi4s_video_aclk (clk),
        .I_rst_n          (rst_n),
        .I_tlast          (raw_eol),
        .I_tuser          (raw_sof),
        .I_tdata          (raw_data),
        .I_tvalid         (raw_valid),
        .I_tdest          (10'd0),
        .O_tready         (isp_ready),     // 下游就绪 -> ISP 上游流控
        .O_tdata          (isp_tdata),
        .O_tlast          (isp_tlast),
        .O_tuser          (isp_tuser),
        .O_tvalid         (isp_tvalid),
        .I_tready         ()               // 输出端口, 仿真不关心
    );

    // ---------------- 96bit 抽头（AWB 输出）-> 弹性串化 -> 逐帧转储 ----------------
    // 说明：官方链路 ISP 输出送 DDR 帧缓存（深缓冲吸收行级突发）；
    // 仿真没有 DDR，用 px_serializer_fifo（8192 beat 弹性 FIFO + 真反压）
    // 充当"浅 DDR"，保证零丢拍。ser96to24 是无反压窃流设计（13 深 FIFO），
    // 吸不住 demosaic 的行级突发，不能用在整链仿真里。
    // ---------------- 饱和度增强级（本次新增） ----------------
    // SAT_EN=1：抽头取饱和度输出；SAT_EN=0：旁路（复现基线）。
    localparam       SAT_EN   = 1'b1;
    localparam [5:0] SAT_K_Q4 = 6'd28;      // 16=1.00x, 21≈1.31x, 28≈1.75x

    wire        sat_tvalid, sat_tuser, sat_tlast;
    wire [95:0] sat_tdata;

    axis_saturation_rgb96 #(.K_Q4(SAT_K_Q4)) u_sat (
        .I_clk  (clk), .I_rst_n(rst_n),
        .I_tlast(u_isp.awb_O_tlast),  .I_tuser(u_isp.awb_O_tuser),
        .I_tdata(u_isp.awb_O_tdata),  .I_tvalid(u_isp.awb_O_tvalid),
        .O_tlast(sat_tlast), .O_tuser(sat_tuser),
        .O_tdata(sat_tdata), .O_tvalid(sat_tvalid)
    );

    wire        tap_valid = SAT_EN ? sat_tvalid : u_isp.awb_O_tvalid;
    wire        tap_sof   = SAT_EN ? sat_tuser : u_isp.awb_O_tuser;
    wire        tap_eol   = SAT_EN ? sat_tlast : u_isp.awb_O_tlast;
    wire [95:0] tap_data  = SAT_EN ? sat_tdata : u_isp.awb_O_tdata;

    wire        ser_valid, ser_sof, ser_eol;
    wire [23:0] ser_data;
    wire [15:0] ser_ovf;

    px_serializer_fifo u_ser (
        .I_clk   (clk), .I_rst_n(rst_n),
        .I_valid (tap_valid),                  // 128->96 重排（+饱和度）后的 4 像素/拍
        .I_sof   (tap_sof),
        .I_eol   (tap_eol),
        .I_data  (tap_data),
        .O_ready (isp_ready),                  // 真反压回 ISP 上游
        .O_valid (ser_valid), .O_sof(ser_sof),
        .O_eol   (ser_eol),   .O_data(ser_data),
        .O_dbg_overflows(ser_ovf)
    );

    wire dump_done;
    frame_dump24 #(
        .BASE_NAME ("passthrough_frame"),
        .MAX_FRAMES(3)
    ) u_dump (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_valid(ser_valid), .I_eol(ser_eol), .I_data(ser_data),
        .O_frame_done(dump_done)
    );

    // ---------------- 几何观察（诚实打印，不作 PASS 依据） ----------------
    integer tuser_total = 0, tlast_total = 0;
    always @(posedge clk) begin
        if (rst_n && u_isp.awb_O_tvalid) begin
            if (u_isp.awb_O_tuser) tuser_total = tuser_total + 1;
            if (u_isp.awb_O_tlast) tlast_total = tlast_total + 1;
        end
    end

    // ---------------- 终判 ----------------
    integer dumped = 0;
    always @(posedge clk) begin
        if (rst_n && dump_done) dumped = dumped + 1;
    end

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
    end

    initial begin
        #500000000;   // 看门狗：1/8 馈送约 77ms + 行窗节流, 500ms 足够 3 帧
        $display("TB_RESULT: %s frames_dumped=%0d tuser_total=%0d tlast_total=%0d ser_ovf=%0d",
                 (dumped >= 2) ? "PASS" : "FAIL", dumped, tuser_total, tlast_total, ser_ovf);
        if (tuser_total == 0)
            $display("NOTE: tuser 链在本纯 RTL 仿真环境不激活（已知发现，见使用指导 PDF 第 5 节）");
        $finish;
    end

    // 提前收工：3 帧全部转储完
    always @(posedge clk) begin
        if (rst_n && dumped >= 3) begin
            $display("TB_RESULT: PASS frames_dumped=%0d tuser_total=%0d tlast_total=%0d ser_ovf=%0d",
                     dumped, tuser_total, tlast_total, ser_ovf);
            if (tuser_total == 0)
                $display("NOTE: tuser 链在本纯 RTL 仿真环境不激活（已知发现，见使用指导 PDF 第 5 节）");
            $finish;
        end
    end

endmodule
