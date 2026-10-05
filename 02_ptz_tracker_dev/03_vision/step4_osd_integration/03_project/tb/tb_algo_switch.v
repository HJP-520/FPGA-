`timescale 1ns/1ps
// =============================================================================
// tb_algo_switch.v —— 算法切换帧对齐专项 TB（三版外部评审要求，2026-10-03）
// -----------------------------------------------------------------------------
// 场景：TPG(灰阶柱 + 彩色柱 + 静态红块) -> vision_top。
//   I_algo_edge 在输入帧 3 / 5 期间切换（0->1->0），请求在下一输入帧首被锁存、
//   由输出侧 SOF 提交逻辑换装。
// 判据（两层）：
//  【窗判据】对 O_osd_* 输出流按 921600 像素划分"输出帧窗"，跳过前 2 个启动窗：
//   1) 任何窗 sof >= 1（**关键**：绝不允许丢帧首——修复前切换窗 sof=0 即此弊）；
//   2) sof <= 2（切换跨越窗允许 2 次：旧帧截尾 + 新帧帧首，且此类窗 <= 2 个）；
//   3) eol ∈ [719,720]（跨切换窗 719，稳态 720）；
//   4) valid 像素恰好 921600（含跨切换窗——输出流连续无洞）；
//   5) 分支内容真实生效：≥2 窗采样点全灰（edge 输出）且 ≥2 窗采样点含彩色
//      （det 输出）——采样点取彩色柱区且避开 OSD 叠加/目标框。
//  【严格帧 scoreboard】（2026-10-03 复审要求，SOF -> 下一 SOF）：
//   SB1 每条 EOL 结束的行必须恰好 1280 valid 像素；SB2 非切换帧必须 720 行/921600 像素；
//   SB3 切换帧允许 719 行 + 1 条残行（或恰在行边界按完整帧）；SB4 残行事件 <= 命令切换数（2）。
// 语义备注：切换发生在目标分支输出 SOF 当拍（组合选择），旧分支帧被截短、
//   新分支从自身 SOF/首像素开始——下游各模块由每次 SOF 复位内部计数。
// =============================================================================
module tb_algo_switch;
    reg pix_clk = 0, pwm_clk = 0, pix_rst = 0, pwm_rst = 0;
    always #7  pix_clk = ~pix_clk;   // ~71.4MHz
    always #10 pwm_clk = ~pwm_clk;   // 50MHz

    reg [10:0] box_x = 11'd600;
    reg [9:0]  box_y = 10'd300;
    wire        tvalid, tuser, tlast;
    wire [95:0] tdata;

    tpg_720p #(.BOX_EN(1)) u_tpg (
        .I_clk(pix_clk), .I_rst_n(pix_rst),
        .I_box_x(box_x), .I_box_y(box_y),
        .O_tvalid(tvalid), .O_tdata(tdata), .O_tuser(tuser), .O_tlast(tlast),
        .I_tready(1'b1));

    reg         algo_edge = 1'b0;
    wire [23:0] osd_data;
    wire        osd_valid, osd_sof, osd_eol;

    vision_top dut (
        .I_pix_clk(pix_clk), .I_pix_rst_n(pix_rst),
        .I_pwm_clk(pwm_clk), .I_pwm_rst_n(pwm_rst),
        .I_tdata(tdata), .I_tvalid(tvalid), .I_tuser(tuser), .I_tlast(tlast),
        .O_tready(), .O_tdata(), .O_tvalid(), .O_tuser(), .O_tlast(),
        .O_osd_valid(osd_valid), .O_osd_sof(osd_sof),
        .O_osd_eol(osd_eol), .O_osd_data(osd_data),
        .I_preset_idx(3'd0), .I_track_en(1'b1),
        .I_algo_edge(algo_edge), .I_bright(7'd0), .I_contrast(8'd64),
        .O_pwm_x(), .O_pwm_y(),
        .O_duty_x_us(), .O_duty_y_us(),
        .O_lost_cnt(), .O_status(),
        .O_led_g(), .O_led_r(), .O_buzzer(),
        .O_frame_tick(), .O_target_valid(), .O_tgt_cx(), .O_tgt_cy());

    // ---------------- 切换调度（按输入帧号） ----------------
    integer in_frame = 0;
    always @(posedge pix_clk) begin
        if (pix_rst && tvalid && tuser) in_frame = in_frame + 1;
        if (in_frame == 3) algo_edge <= 1'b1;   // 帧 4 首被锁存 -> 请求切边缘
        if (in_frame == 5) algo_edge <= 1'b0;   // 帧 6 首被锁存 -> 请求切回
    end

    // ---------------- 输出流分窗监视 ----------------
    localparam FRAME_PX = 1280 * 720;
    integer x = 0, y = 0;
    integer px_cnt = 0, sof_cnt = 0, eol_cnt = 0, col_smpl = 0;
    integer win = 0, mism = 0, gray_wins = 0, color_wins = 0, switch_wins = 0;
    integer eval_wins = 0;

    // ---------------- 严格帧 scoreboard（2026-10-03 复审要求：SOF -> 下一 SOF） ----------------
    // 判据（比 921600 像素分窗严格；"切换跨度"= 结束 SOF 落在行中，即旧帧被提交瞬时截断）：
    //   SB1 每一条以 EOL 结束的行必须恰好 1280 个 valid 像素（禁止 1279）；
    //   SB2 非切换跨度（结束 SOF 紧接行尾）：必须恰好 720 行、921600 像素；
    //   SB3 切换跨度：允许 ≤719 行 + 1 条残行（残行像素 1..1279，切点任意——
    //       实测两次切换分别为 0 行+1px 与 719 行+1279px，源于两分支流水延迟差）；
    //   SB4 切换跨度总数 <= 本 TB 命令的切换次数（2）——多余即未命令的截断，FAIL。
    integer sb_active = 0, sb_lines = 0, sb_px_line = 0, sb_px_total = 0;
    integer sb_frames = 0, sb_fail = 0, sb_partial = 0, sb_partial_px = 0;
    localparam SWITCH_CMD = 2;   // 本 TB 命令的切换次数（帧 3、帧 5）

    // 采样点：彩色柱区（x=700 蓝、x=880 绿），y=600/650 避开 OSD/目标框
    task sample_px;
        input integer sx, sy;
        begin
            if ((x == sx) && (y == sy)) begin
                if (!(osd_data[23:16] == osd_data[15:8] &&
                      osd_data[15:8]  == osd_data[7:0]))
                    col_smpl = col_smpl + 1;
            end
        end
    endtask

    always @(posedge pix_clk) begin
        if (pix_rst && osd_valid) begin
            if (osd_sof) sof_cnt = sof_cnt + 1;
            if (osd_eol) begin
                x = 0; y = y + 1;
            end else begin
                x = x + 1;
            end
            sample_px(700, 600);
            sample_px(880, 650);
            px_cnt = px_cnt + 1;
            if (osd_eol) eol_cnt = eol_cnt + 1;

            // ---- 严格帧 scoreboard（按"本跨度如何结束"判定） ----
            if (osd_sof) begin
                if (sb_active) begin
                    sb_frames = sb_frames + 1;
                    if (sb_px_line == 0) begin                 // SB2 非切换跨度：必须完整
                        if ((sb_lines != 720) || (sb_px_total != FRAME_PX)) begin
                            sb_fail = sb_fail + 1;
                            $display("SB_MISM frame=%0d lines=%0d px=%0d（非切换跨度不完整）",
                                     sb_frames, sb_lines, sb_px_total);
                        end
                    end else begin                              // SB3 切换跨度：旧帧截断
                        sb_partial = sb_partial + 1;
                        sb_partial_px = sb_px_line;
                        if (sb_lines > 719) begin
                            sb_fail = sb_fail + 1;
                            $display("SB_MISM frame=%0d lines=%0d（切换跨度行数非法）",
                                     sb_frames, sb_lines);
                        end
                        if ((sb_px_total != sb_lines*1280 + sb_px_line)) begin
                            sb_fail = sb_fail + 1;              // 恒真性自检（防计数错）
                            $display("SB_MISM frame=%0d px=%0d != lines*1280+partial",
                                     sb_frames, sb_px_total);
                        end
                    end
                end
                sb_active = 1;
                sb_lines = 0; sb_px_line = 0; sb_px_total = 0;
            end
            sb_px_line  = sb_px_line + 1;
            sb_px_total = sb_px_total + 1;
            if (osd_eol) begin
                if (sb_active && (sb_px_line != 1280)) begin          // SB1 行宽严格
                    sb_fail = sb_fail + 1;
                    $display("SB_MISM line_len=%0d（frame=%0d line=%0d）",
                             sb_px_line, sb_frames+1, sb_lines);
                end
                sb_lines = sb_lines + 1;
                sb_px_line = 0;
            end

            if (px_cnt == FRAME_PX) begin    // 一个输出帧窗闭合
                win = win + 1;
                if (win > 2) begin           // 跳过启动窗
                    eval_wins = eval_wins + 1;
                    if (sof_cnt == 0) begin                          // 关键判据
                        $display("MISM win=%0d sof=0（帧首丢失！）", win);
                        mism = mism + 1;
                    end
                    if (sof_cnt > 2) begin
                        $display("MISM win=%0d sof=%0d（>2）", win, sof_cnt);
                        mism = mism + 1;
                    end
                    if (sof_cnt == 2) switch_wins = switch_wins + 1;
                    if (eol_cnt < 719) begin
                        $display("MISM win=%0d eol=%0d（<719）", win, eol_cnt);
                        mism = mism + 1;
                    end
                    if (col_smpl == 0) gray_wins = gray_wins + 1;
                    else               color_wins = color_wins + 1;
                    $display("WIN %0d: sof=%0d eol=%0d 彩色采样=%0d", win, sof_cnt, eol_cnt, col_smpl);
                end
                px_cnt = 0; sof_cnt = 0; eol_cnt = 0; col_smpl = 0;
                y = 0;
            end
        end
    end

    // ---------------- 终判 ----------------
    integer guard;
    initial begin
        repeat (5) @(posedge pix_clk);
        pix_rst = 1;
        repeat (4) @(posedge pwm_clk);
        pwm_rst = 1;
        guard = 1;
    end

    always @(posedge pix_clk) begin
        if (pix_rst && guard && (in_frame >= 11) && (win >= 8)) begin
            if (mism == 0 && sb_fail == 0 && (sb_partial <= SWITCH_CMD) &&
                (sb_frames >= 6) && gray_wins >= 2 && color_wins >= 2 && switch_wins >= 1)
                $display("TB_RESULT: PASS windows=%0d gray=%0d color=%0d switch=%0d | SB frames=%0d partial=%0d(px=%0d) sb_fail=0",
                         eval_wins, gray_wins, color_wins, switch_wins,
                         sb_frames, sb_partial, sb_partial_px);
            else
                $display("TB_RESULT: FAIL mism=%0d gray=%0d color=%0d switch=%0d | SB frames=%0d partial=%0d sb_fail=%0d",
                         mism, gray_wins, color_wins, switch_wins,
                         sb_frames, sb_partial, sb_fail);
            $finish;
        end
    end

    initial begin
        #300000000;
        $display("TB_RESULT: FAIL timeout in_frame=%0d win=%0d mism=%0d",
                 in_frame, win, mism);
        $finish;
    end
endmodule
