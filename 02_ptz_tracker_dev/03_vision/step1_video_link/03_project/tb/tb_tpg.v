// =============================================================================
// tb_tpg.v —— 测试图案发生器 TB：几何计数自检 + 帧转储交 Python 比对
// 验收：每帧 sof 恰 1 次、eol 恰 720 次、像素数恰 921600；frame_0 交给
// Python 与 gen_vectors 生成的 tpg_exp.hex 逐像素比对（run_all.py）。
// =============================================================================
`timescale 1ns/1ps
module tb_tpg;
    reg clk = 0, rst_n = 0;
    always #7 clk = ~clk;

    reg  [10:0] box_x = 11'd500;
    reg  [9:0]  box_y = 10'd300;
    wire        tvalid, tuser, tlast;
    wire [95:0] tdata;

    tpg_720p #(.BOX_EN(1)) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_box_x(box_x), .I_box_y(box_y),
        .O_tvalid(tvalid), .O_tdata(tdata), .O_tuser(tuser), .O_tlast(tlast),
        .I_tready(1'b1));

    wire        s_valid, s_sof, s_eol;
    wire [23:0] s_data;
    ser96to24 u_ser (.I_clk(clk), .I_rst_n(rst_n),
        .I_tdata(tdata), .I_tvalid(tvalid), .I_tuser(tuser), .I_tlast(tlast),
        .O_tready(), .O_valid(s_valid), .O_sof(s_sof), .O_eol(s_eol), .O_data(s_data));

    frame_dump24 #(.BASE_NAME("tpg_act"), .MAX_FRAMES(1)) u_dump (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_valid(s_valid), .I_eol(s_eol), .I_data(s_data), .O_frame_done());

    integer sof_cnt = 0, eol_cnt = 0, px_cnt = 0, err_cnt = 0;
    integer frames = 0;

    always @(posedge clk) begin
        if (rst_n && s_valid) begin
            px_cnt = px_cnt + 1;
            if (s_sof) begin
                sof_cnt = sof_cnt + 1;
                if (px_cnt != 1) err_cnt = err_cnt + 1;  // sof 必须是帧首像素
            end
            if (s_eol) eol_cnt = eol_cnt + 1;
            if (px_cnt == 1280*720) begin
                if ((sof_cnt != 1) || (eol_cnt != 720)) begin
                    $display("FRAME_GEO_ERR frame=%0d sof=%0d eol=%0d",
                             frames, sof_cnt, eol_cnt);
                    err_cnt = err_cnt + 1;
                end
                frames = frames + 1;
                sof_cnt = 0; eol_cnt = 0; px_cnt = 0;
                if (frames == 2) begin
                    if (err_cnt == 0)
                        $display("TB_RESULT: PASS (geometry 2 frames)");
                    else
                        $display("TB_RESULT: FAIL err_cnt=%0d", err_cnt);
                    $finish;
                end
            end
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        rst_n <= 1;
        #30000000;
        $display("TB_RESULT: FAIL timeout frames=%0d", frames);
        $finish;
    end
endmodule
