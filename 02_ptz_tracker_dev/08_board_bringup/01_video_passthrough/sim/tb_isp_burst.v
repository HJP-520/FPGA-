// =============================================================================
// tb_isp_burst.v —— ISP 满速馈送下的 96bit 突发形态测量 + ser96to24 实链丢拍判定
// -----------------------------------------------------------------------------
// 背景（外部架构复审 Gate）：视觉链的 ser96to24（无反压、128 像素缓冲）此前只在
// tpg_720p 的 "1 beat/4clk" 良性节拍下仿真过；真实 ISP 的 AWB 输出在满速馈送下
// 是否行级突发、128 像素缓冲（=32 beat）是否足够，从未实测过。
//
// 结构（2026-10-03 修复后的 system_top 接法）：
//   虚拟 RAW10（满速 / 1:N 分频 / 行突发+消隐 三种模式）
//     -> isp_top
//     -> AWB 96bit 抽头（4px RGB888，tuser/tlast 均在有效拍）
//     -> ser96to24 v4（2048px 寄存器读弹性缓冲，无反压）
//   同时监测 128bit 重排路径（历史问题路径，仅供对照）。
//
// 判据（TB_RESULT）：
//   ser 输出像素 = 3*921600 且 sof=3 且 eol=3*720 且 drop=0 -> PASS
//   （v3 时代本 TB 同一激励下输出 188/2764800 像素、零 SOF——修复的验收对照）
//
// 输出（ISPBURST_REPORT）：
//   * awb 96bit / v128 valid 的最大连续长度、超 42 拍（=128 像素缓冲临界）段数
//   * ser96to24 输出像素数、SOF/EOL 计数、O_drop_cnt（饱和）
//   判定：s_pix == 3*921600 且 drop==0 → 该模式下达标；否则输出帧像素缺失。
// =============================================================================
`timescale 1ns/1ps
module tb_isp_burst;
    // FEED_DIV: 0=满速（每拍一个 beat）；N=每 N 拍一个 beat（模拟传感器平均占空）
    parameter FEED_DIV = 0;
    // FEED_MODE: 0=均匀分频；1=行突发（320 beat 连发 + 消隐空闲，模拟真实传感器行节奏）
    parameter FEED_MODE = 0;
    parameter IDLE_CYC  = 1330;    // 行突发模式：突发间消隐拍数
    reg clk = 0, rst_n = 0;
    always #7 clk = ~clk;
    initial begin rst_n = 0; #200 rst_n = 1; end

    // ---- 虚拟 RAW10 传感器（满速馈送） ----
    reg [39:0] beats [0:921599];
    reg [1:0]  metas [0:921599];
    integer    nb;
    integer    bi = 0;
    initial begin
        $readmemh("raw10_beats.hex", beats);
        $readmemh("raw10_meta.txt",  metas);
        nb = 230400 * 3;
    end

    wire        isp_up_ready;              // ISP 对上游的就绪输出（I_tready）
    reg         raw_valid = 1'b0;
    reg  [39:0] raw_data  = 40'd0;
    reg         raw_sof = 1'b0, raw_eol = 1'b0;
    integer     feed_beats = 0, stall_cyc = 0;
    integer     div_cnt = 0;
    integer     line_cnt = 0;              // 行突发模式：行内已发 beat 数
    integer     idle_cnt = 0;              // 行突发模式：消隐计时
    reg         pend = 1'b0;               // 当前 beat 已呈现、等待被消费

    // 分频/行突发馈送：每个 beat 恰好呈现一次（valid 保持到 ready），杜绝重复消费
    wire feed_slot = (FEED_MODE == 1) ? (idle_cnt == 0)
                                      : ((FEED_DIV == 0) || (div_cnt == 0));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            raw_valid <= 1'b0;
            pend      <= 1'b0;
            div_cnt   <= 0;
            line_cnt  <= 0;
            idle_cnt  <= 0;
        end else begin
            div_cnt <= (div_cnt >= FEED_DIV) ? 0 : div_cnt + 1;
            if (FEED_MODE == 1) begin
                // 行突发：先连发 320 beat，再空闲 IDLE_CYC 拍
                if (idle_cnt > 0)
                    idle_cnt <= idle_cnt - 1;
                else if (line_cnt >= 320) begin
                    line_cnt <= 0;
                    idle_cnt <= IDLE_CYC;
                end
            end
            if (pend) begin
                if (isp_up_ready) begin
                    pend      <= 1'b0;
                    raw_valid <= 1'b0;
                    feed_beats = feed_beats + 1;
                    if (FEED_MODE == 1) line_cnt = line_cnt + 1;
                end else begin
                    stall_cyc = stall_cyc + 1;
                end
            end else if ((bi < nb) && feed_slot) begin
                raw_data  <= beats[bi];
                raw_sof   <= metas[bi][1];
                raw_eol   <= metas[bi][0];
                bi = bi + 1;
                pend      <= 1'b1;
                raw_valid <= 1'b1;
            end
        end
    end

    // ---- 官方 ISP（O_tready=1：视觉分支恒不反压，最坏情况；与 system_top 语义一致） ----
    wire [127:0] isp_tdata;
    wire         isp_tvalid, isp_tuser, isp_tlast;
    wire [95:0]  tap_tdata;
    wire         tap_tvalid, tap_tuser, tap_tlast;

    isp_top u_isp (
        .axi4s_video_aclk (clk), .I_rst_n (rst_n),
        .I_tlast (raw_eol), .I_tuser (raw_sof), .I_tdata (raw_data),
        .I_tvalid (raw_valid), .I_tdest (10'd0),
        .O_tready (1'b1),
        .O_tdata (isp_tdata), .O_tlast (isp_tlast), .O_tuser (isp_tuser),
        .O_tvalid (isp_tvalid), .I_tready (isp_up_ready),
        .tap_tdata (tap_tdata), .tap_tvalid (tap_tvalid),
        .tap_tuser (tap_tuser), .tap_tlast (tap_tlast)
    );

    // ---- AWB 96bit 抽头（经 isp_top 新增端口引出，验证与 system_top 相同的端口路径） ----
    wire         a_user96, a_valid96, a_last96;
    wire [95:0]  a_data96;
    assign a_user96  = tap_tuser;
    assign a_valid96 = tap_tvalid;
    assign a_last96  = tap_tlast;
    assign a_data96  = tap_tdata;

    // ---- 128bit 重排（视觉链真实输入节奏） ----
    wire         a_user128, a_valid128;
    wire [127:0] a_data128;
    assign a_user128  = u_isp.awb_O_tuser_128;
    assign a_valid128 = u_isp.awb_O_tvalid_128;
    assign a_data128  = u_isp.awb_O_tdata_128;

    // ---- ser96to24（v4 修复后接法：直接抽 AWB 96bit 输出；无反压） ----
    // 修复依据见迭代记录 #N+6/#N+7：原 128 重排路径 tuser 结构性错位 + 3/4 占空节拍，
    // 且 v3 串化器 128px 缓冲吸不住行级突发。本实例即修复后的验收对象。
    wire        s_valid, s_sof, s_eol;
    wire [23:0] s_data;
    wire [15:0] s_drop;
    ser96to24 u_ser (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_tdata(a_data96), .I_tvalid(a_valid96), .I_tuser(a_user96),
        .I_tlast(a_last96),
        .O_tready(), .O_valid(s_valid), .O_sof(s_sof), .O_eol(s_eol),
        .O_data(s_data), .O_drop_cnt(s_drop));

    // ---- 统计 ----
    // FIFO 最大占用（复审要求的安全余量指标）：直接观测 DUT 内部缓冲计数
    integer occ_max = 0;
    always @(posedge clk)
        if (u_ser.cnt > occ_max) occ_max <= u_ser.cnt;

    integer a_run = 0, a_max = 0, a_gt42 = 0, a_beats = 0, a_frames = 0;
    integer v_run = 0, v_max = 0, v_gt42 = 0, v_beats = 0, v_frames = 0;
    integer s_pix = 0, s_sof_cnt = 0, s_eol_cnt = 0;
    integer cyc = 0, first_cyc = -1, last_cyc = -1;
    // 突发长度直方图（96bit AWB）：1-8 / 9-42 / 43-320 / 321-640 / 641-1280 / >1280
    integer h1 = 0, h2 = 0, h3 = 0, h4 = 0, h5 = 0, h6 = 0;
    // tlast 在突发中的位置（1=突发起始拍，~320=突发末拍）
    integer bpos = 0, tl_pos_min = 999999, tl_pos_max = -1, tl_cnt = 0;

    always @(posedge clk) begin
        cyc <= cyc + 1;
        // 96bit valid 连续段 + 直方图 + tlast 位置
        if (a_valid96) begin
            a_run <= a_run + 1;
            a_beats <= a_beats + 1;
            bpos  <= bpos + 1;
            if (a_run + 1 > a_max) a_max <= a_run + 1;
            if (first_cyc < 0) first_cyc <= cyc;
            last_cyc <= cyc;
            if (a_last96) begin
                tl_cnt <= tl_cnt + 1;
                if (bpos + 1 < tl_pos_min) tl_pos_min <= bpos + 1;
                if (bpos + 1 > tl_pos_max) tl_pos_max <= bpos + 1;
            end
        end else begin
            if (a_run > 42) a_gt42 <= a_gt42 + 1;
            if (a_run >= 1  && a_run <= 8)    h1 <= h1 + 1;
            if (a_run >= 9  && a_run <= 42)   h2 <= h2 + 1;
            if (a_run >= 43 && a_run <= 320)  h3 <= h3 + 1;
            if (a_run >= 321 && a_run <= 640) h4 <= h4 + 1;
            if (a_run >= 641 && a_run <= 1280)h5 <= h5 + 1;
            if (a_run > 1280)                 h6 <= h6 + 1;
            a_run <= 0;
            bpos  <= 0;
        end
        if (a_valid96 && a_user96) a_frames <= a_frames + 1;
        // 128bit valid 连续段（ser96to24 实际看到的节拍）
        if (a_valid128) begin
            v_run <= v_run + 1;
            v_beats <= v_beats + 1;
            if (v_run + 1 > v_max) v_max <= v_run + 1;
        end else begin
            if (v_run > 42) v_gt42 <= v_gt42 + 1;
            v_run <= 0;
        end
        if (a_valid128 && a_user128) v_frames <= v_frames + 1;
        // ser 输出
        if (s_valid) s_pix <= s_pix + 1;
        if (s_sof) s_sof_cnt <= s_sof_cnt + 1;
        if (s_eol) s_eol_cnt <= s_eol_cnt + 1;
    end

    // ---- 尾帧冲刷 + 报告 ----
    initial begin
        wait (bi >= nb);
        @(posedge clk);
        repeat (50000) @(posedge clk);
        $display("ISPBURST_REPORT:");
        $display("  awb96 : beats=%0d frames=%0d maxrun=%0d runs_gt42=%0d",
                 a_beats, a_frames, a_max, a_gt42);
        $display("  v128  : beats=%0d frames=%0d maxrun=%0d runs_gt42=%0d",
                 v_beats, v_frames, v_max, v_gt42);
        $display("  ser   : pixels=%0d sof=%0d eol=%0d drop=%0d (expect_pix=%0d)",
                 s_pix, s_sof_cnt, s_eol_cnt, s_drop, 921600*3);
        $display("  occ   : ser FIFO max occupancy = %0d / 2048 px (%0d%%)",
                 occ_max, (occ_max*100)/2048);
        $display("  duty  : a_beats/(last-first+1) = %0d/%0d", a_beats,
                 (last_cyc - first_cyc + 1));
        $display("  feed  : beats=%0d stall_cyc=%0d (ISP 上游反压拍数)", feed_beats, stall_cyc);
        $display("  hist  : 1-8=%0d 9-42=%0d 43-320=%0d 321-640=%0d 641-1280=%0d >1280=%0d",
                 h1, h2, h3, h4, h5, h6);
        $display("  tlast : cnt=%0d pos_in_burst: min=%0d max=%0d",
                 tl_cnt, tl_pos_min, tl_pos_max);
        if ((s_pix == 921600*3) && (s_sof_cnt == 3) && (s_eol_cnt == 720*3) && (s_drop == 0))
            $display("TB_RESULT: PASS ser pixels=%0d sof=%0d eol=%0d drop=0", s_pix, s_sof_cnt, s_eol_cnt);
        else
            $display("TB_RESULT: FAIL ser pixels=%0d (expect %0d) sof=%0d eol=%0d drop=%0d",
                     s_pix, 921600*3, s_sof_cnt, s_eol_cnt, s_drop);
        $finish;
    end

    // 看门狗
    initial begin
        #200_000_000;
        $display("ISPBURST WATCHDOG TIMEOUT bi=%0d", bi);
        $finish;
    end
endmodule
