// =============================================================================
// tb_detect_chain.v —— 检测链整链 TB（真实场景 3 帧，全尺寸 1280x720）
// 场景：红块+噪声 / 红块+品红干扰物 / 小目标。
// 验收：1) 每帧 results_upd 与 golden（chain_exp.txt）一致；
//       2) 窃流直通输出与输入逐拍一致（不干扰主线）。
// =============================================================================
`timescale 1ns/1ps
module tb_detect_chain;
    reg clk = 0, rst_n = 0;
    always #7 clk = ~clk;

    wire       src_valid, src_user, src_last;
    wire [95:0] src_data;

    sim_video_src #(
        .BEAT_FILE("chain_beats.hex"), .FLAG_FILE("chain_flags.hex"),
        .BEATS_TOTAL(3*720*320), .FRAMES(3)
    ) u_src (
        .I_clk(clk), .I_rst_n(rst_n),
        .O_tvalid(src_valid), .O_tdata(src_data),
        .O_tuser(src_user), .O_tlast(src_last), .I_tready(1'b1));

    wire       pt_valid, pt_user, pt_last;
    wire [95:0] pt_data;
    wire       t_valid, r_upd;
    wire [10:0] cx, cy, minx, maxx;
    wire [9:0]  miny, maxy;
    wire [20:0] cnt;
    wire [15:0] lost;

    detect_top dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_tdata(src_data), .I_tvalid(src_valid), .I_tuser(src_user), .I_tlast(src_last),
        .O_tready(), .O_tdata(pt_data), .O_tvalid(pt_valid),
        .O_tuser(pt_user), .O_tlast(pt_last),
        .I_preset_idx(3'd0),
        .O_target_valid(t_valid), .O_cx(cx), .O_cy(cy), .O_count(cnt),
        .O_min_x(minx), .O_max_x(maxx), .O_min_y(miny), .O_max_y(maxy),
        .O_lost_cnt(lost), .O_results_upd(r_upd), .O_frame_tick(),
        .O_dbg_mask_valid(), .O_dbg_mask(), .O_s_valid(), .O_s_sof(),
        .O_s_eol(), .O_s_data());

    // 直通一致性
    integer pass_mism = 0, frames = 0, mism = 0;
    always @(posedge clk) begin
        if (rst_n && src_valid) begin
            if ((pt_data !== src_data) || (pt_valid !== 1'b1) ||
                (pt_user !== src_user) || (pt_last !== src_last)) begin
                if (pass_mism < 5)
                    $display("PASSTHRU_MISM t=%0t", $time);
                pass_mism = pass_mism + 1;
            end
        end
    end

    // 每帧结果比对
    integer fd, scanned;
    reg exp_v; integer exp_cnt, exp_cx, exp_cy, exp_x0, exp_x1, exp_y0, exp_y1;
    task check_line;
        begin
            scanned = $fscanf(fd, "%1x%5x%3x%3x%3x%3x%3x%3x",
                              exp_v, exp_cnt, exp_cx, exp_cy,
                              exp_x0, exp_x1, exp_y0, exp_y1);
            if ((t_valid !== (exp_v == 1)) ||
                (exp_v == 1 && ((cnt !== exp_cnt[20:0]) || (cx !== exp_cx[10:0]) || (cy !== exp_cy[10:0]) ||
                 (minx !== exp_x0[10:0]) || (maxx !== exp_x1[10:0]) ||
                 (miny !== exp_y0[9:0]) || (maxy !== exp_y1[9:0])))) begin
                $display("MISM frame=%0d got v=%b cnt=%0d cx=%0d cy=%0d x[%0d..%0d] y[%0d..%0d] | exp v=%0d cnt=%0d cx=%0d cy=%0d x[%0d..%0d] y[%0d..%0d]",
                         frames, t_valid, cnt, cx, cy, minx, maxx, miny, maxy,
                         exp_v, exp_cnt, exp_cx, exp_cy, exp_x0, exp_x1, exp_y0, exp_y1);
                mism = mism + 1;
            end else begin
                $display("FRAME%0d OK v=%0d cnt=%0d cx=%0d cy=%0d",
                         frames, t_valid, cnt, cx, cy);
            end
            frames = frames + 1;
        end
    endtask

    always @(posedge clk) begin
        if (rst_n && r_upd && frames < 3)
            check_line;
    end

    initial begin
        fd = $fopen("chain_exp.txt", "r");
        repeat (3) @(posedge clk);
        rst_n <= 1;
        #80000000;
        if ((mism == 0) && (pass_mism == 0) && (frames == 3))
            $display("TB_RESULT: PASS (frames=%0d passthru_ok)", frames);
        else
            $display("TB_RESULT: FAIL frames=%0d mism=%0d passthru_mism=%0d",
                     frames, mism, pass_mism);
        $finish;
    end
endmodule
