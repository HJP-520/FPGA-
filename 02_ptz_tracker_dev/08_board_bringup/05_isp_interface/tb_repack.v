`timescale 1ns/1ps
// =============================================================================
// tb_repack.v —— data_96bit_to_128bit 重构验证（第2批①，2026-10-05）
// -----------------------------------------------------------------------------
// 被测：板用副本 isp/data96_128/data96_128.v 内的 data_96bit_to_128bit
// 改动：① 气泡保相位（valid=0 不再清 S_cnt，仅帧首复位）② tlast 在 repack 内重建
//
// 判据（全部为可核验的字节级性质）：
//  P1 无气泡：输出 128b 字流 == 输入 96b 比特流按 128b 重切（byte-stream scoreboard）
//  P2 气泡在 4 个相位各注一次：输出字流与 P1 逐字一致（相位保持的直接证据）
//  P3 tlast：每行末拍的 tlast 恰好落在包含该行最后一比特的输出字序号上
//  P4 back-to-back：帧首强制相位 0，第二帧字流独立正确（无第一帧残留污染）
// =============================================================================
module tb_repack;
    reg clk = 0, rst_n = 0;
    always #7 clk = ~clk;                      // ~71.4MHz

    localparam ROW_BEATS = 8;                  // 本 TB 行 = 8 拍（4 的整数倍；720p 实为 320）
    localparam NROWS     = 4;                  // 帧 = 32 拍 = 3072 bit = 24 × 128b
    localparam NBEATS    = ROW_BEATS * NROWS;  // 32
    localparam NWORDS    = NBEATS * 3 / 4;     // 24
    localparam GAP       = 24;                 // 帧间空拍

    reg         v = 0, tuser = 0, tlast = 0;
    reg  [95:0] d = 0;

    wire         o_fs, o_tl, o_v;
    wire [127:0] o_d;

    data_96bit_to_128bit u_dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_96b_frame_start(tuser), .I_96b_valid(v),
        .I_96b_tlast(tlast), .I_96b_data(d),
        .O_128b_frame_start(o_fs), .O_128b_tlast(o_tl),
        .O_128b_valid(o_v), .O_128b_data(o_d)
    );

    integer fails = 0;

    // ---- 采集 ----
    reg [127:0] got [0:255];
    integer     got_n;
    integer     tl_idx [0:15];
    integer     tl_n;

    always @(posedge clk) begin
        if (o_v) begin
            got[got_n] <= o_d;
            if (o_tl) begin
                tl_idx[tl_n] <= got_n;
                tl_n <= tl_n + 1;
            end
            got_n <= got_n + 1;
        end
    end

    // ---- 激励 ----
    reg [95:0] exp_beats [0:255];

    task drive_frame(input [31:0] base, input integer gap_at, input integer gap_len,
                     input integer igap);
        integer k;
        begin
            @(posedge clk);
            tuser <= 1'b1; v <= 1'b1; tlast <= 1'b0;
            d     <= {32'hA0000000 + base, 32'hB0000000 + base, 32'hC0000000 + base};
            exp_beats[0] = {32'hA0000000 + base, 32'hB0000000 + base, 32'hC0000000 + base};
            @(posedge clk);
            tuser <= 1'b0;
            for (k = 1; k < NBEATS; k = k + 1) begin
                v     <= 1'b1;
                d     <= {32'hA0000000 + base + k, 32'hB0000000 + base + k, 32'hC0000000 + base + k};
                exp_beats[k] = {32'hA0000000 + base + k, 32'hB0000000 + base + k, 32'hC0000000 + base + k};
                tlast <= ((k % ROW_BEATS) == (ROW_BEATS - 1));
                @(posedge clk);
                if (gap_at > 0 && k == gap_at) begin          // 气泡：valid 拉低 gap_len 拍
                    v <= 1'b0; tlast <= 1'b0;
                    repeat (gap_len) @(posedge clk);
                end
            end
            v <= 1'b0; tlast <= 1'b0;
            repeat (igap) @(posedge clk);
        end
    endtask

    // ---- 记分板：期望字 = 输入比特流按 128b 重切 ----
    reg [3071:0] frame_bits;
    reg [127:0]  exp_word;
    task scoreboard(input [8*24:1] tag, input [31:0] base);
        integer k, j, bad_cnt;
        begin
            // 组帧比特流：beat k 占 [96k +: 96]
            for (k = 0; k < NBEATS; k = k + 1)
                frame_bits[(NBEATS-1-k)*96 +: 96] = exp_beats[k];   // beat0 在流的高位（先发送）
            bad_cnt = 0;
            if (got_n != NWORDS) begin
                $display("CHECK FAIL [%0s]: 输出字数 %0d != 期望 %0d", tag, got_n, NWORDS);
                fails = fails + 1;
            end
            for (j = 0; j < NWORDS; j = j + 1) begin
                exp_word = frame_bits[128*(NWORDS-1-j) +: 128];    // 第 j 个字 = 流的第 j 段（自高向低）
                if (got[j] !== exp_word) begin
                    if (bad_cnt < 3)
                        $display("CHECK FAIL [%0s]: word[%0d] got=%h exp=%h", tag, j, got[j], exp_word);
                    bad_cnt = bad_cnt + 1;
                end
            end
            if (bad_cnt == 0 && got_n == NWORDS)
                $display("CHECK OK   [%0s]: wordstream identical (%0d words)", tag, NWORDS);
            else if (bad_cnt > 0)
                fails = fails + 1;

            // tlast 位置：行 r 末拍 k=8r+7，末比特 96k+95 → 字序号 (96k+95)/128 = 6r+5
            if (tl_n != NROWS) begin
                $display("CHECK FAIL [%0s]: tlast 次数 %0d != %0d", tag, tl_n, NROWS);
                fails = fails + 1;
            end else begin
                bad_cnt = 0;
                for (j = 0; j < NROWS; j = j + 1)
                    if (tl_idx[j] != (3 * ROW_BEATS / 4) * j + (3 * ROW_BEATS / 4 - 1))
                        bad_cnt = bad_cnt + 1;
                if (bad_cnt == 0)
                    $display("CHECK OK   [%0s]: tlast at row-end words {5,11,17,23}", tag);
                else begin
                    $display("CHECK FAIL [%0s]: tlast idx %0d/%0d/%0d/%0d (exp 5/11/17/23)",
                             tag, tl_idx[0], tl_idx[1], tl_idx[2], tl_idx[3]);
                    fails = fails + 1;
                end
            end
        end
    endtask

    task clear_capture;
        begin
            @(negedge clk);        // 对齐负沿清点：避开 posedge 捕获 NBA 的竞争（真背靠背用例暴露）
            got_n = 0; tl_n = 0;
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        // ---- P1：无气泡 ----
        clear_capture;
        drive_frame(32'd0, 0, 0, GAP);
        scoreboard("P1 no-bubble", 32'd0);

        // ---- P2：气泡注入在 4 个相位（k mod 4 = 1/2/3/0 之后）----
        clear_capture;
        drive_frame(32'h100, 1, 3, GAP);     // 气泡出现在 beat1 之后 → 相位断点 (k mod 4)=1
        scoreboard("P2 bubble@phase1", 32'h100);

        clear_capture;
        drive_frame(32'h200, 2, 3, GAP);     // 相位断点 =2
        scoreboard("P2 bubble@phase2", 32'h200);

        clear_capture;
        drive_frame(32'h300, 3, 5, GAP);     // 相位断点 =3
        scoreboard("P2 bubble@phase3", 32'h300);

        clear_capture;
        drive_frame(32'h400, 4, 7, GAP);     // 相位断点 =0（帧首组内）
        scoreboard("P2 bubble@phase0", 32'h400);

        // ---- P4：back-to-back（第二帧紧跟第一帧，数据模式不同）----
        clear_capture;
        drive_frame(32'h500, 0, 1, 1);       // 帧1：帧间仅 1 拍空档（真背靠背；原版固定 GAP=24 是伪命题）
        clear_capture;                        // 清采集，只评帧2
        drive_frame(32'h777, 2, 2, GAP);     // 帧2 带气泡
        scoreboard("P4 back-to-back frame2", 32'h777);

        $display("============================================================");
        if (fails == 0)
            $display("TB_RESULT: PASS  (0 fail)  repack hold-phase + tlast rebuild verified");
        else
            $display("TB_RESULT: FAIL  (fails=%0d)", fails);
        $finish;
    end

    initial begin
        #50000000;   // 看门狗 50ms
        $display("TB_RESULT: FAIL (watchdog timeout)");
        $finish;
    end
endmodule
