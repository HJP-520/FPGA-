// =============================================================================
// tb_ser96to24.v —— 96->24 串化器 TB：随机空拍 + 帧边界标志 + 队列自检
// 验收：输入侧 4 像素/拍全展开，sof/eol 标志逐像素正确，无丢失/乱序。
// 阶段 2（v4.1 加固验证，2026-10-03 第 7 轮复审）：
//   故障注入——连续 back-to-back 入队制造溢出 + 全程 tuser 缺失（帧同步契约破坏），
//   验证：看门狗置 O_sync_err；tlast 门控的合成帧首恢复入队（恰 1 个 sof）；
//   恢复后普通 beat 持续可写（drop 停止增长）。SYNC_TIMEOUT 缩短为 2000 便于仿真。
// =============================================================================
`timescale 1ns/1ps
module tb_ser96to24;
    localparam W = 64, H = 8, BEATS = W/4, FRAME_BEATS = BEATS*H, FRAMES = 3;

    reg clk = 0, rst_n = 0;
    always #7 clk = ~clk;

    reg [95:0] tdata;
    reg        tvalid, tuser, tlast;
    wire       tready;
    wire       o_valid, o_sof, o_eol;
    wire [23:0] o_data;
    wire       o_sync_err;

    ser96to24 #(.SYNC_TIMEOUT(24'd2000)) dut (.I_clk(clk), .I_rst_n(rst_n),
        .I_tdata(tdata), .I_tvalid(tvalid), .I_tuser(tuser), .I_tlast(tlast),
        .O_tready(tready),
        .O_valid(o_valid), .O_sof(o_sof), .O_eol(o_eol), .O_data(o_data),
        .O_sync_err(o_sync_err));

    // 期望队列
    reg [23:0] exp_d [0:FRAMES*W*H-1];
    reg        exp_s [0:FRAMES*W*H-1];
    reg        exp_e [0:FRAMES*W*H-1];
    integer    push_n = 0, pop_n = 0, mism = 0;
    integer    f, b, k, i;
    reg [15:0] lfsr = 16'hBEEF;
    reg        drv_valid;

    // 阶段 2（故障注入）观测
    reg        phase2 = 0;
    integer    p2_pop = 0, p2_sof = 0, p2_mism = 0, p2_after_sof = 0;
    reg        p2_empty_seen = 0;
    reg        p2_busy_after = 0;

    // 输入驱动
    initial begin
        tdata = 0; tvalid = 0; tuser = 0; tlast = 0;
        repeat (4) @(posedge clk);
        rst_n <= 1;
        for (f = 0; f < FRAMES; f = f + 1) begin
            for (b = 0; b < FRAME_BEATS; b = b + 1) begin
                // 总线契约：beat 率 = 像素率/4（4 拍 1 beat），另有少量随机额外空闲
                repeat (3) begin
                    @(posedge clk);
                    tvalid <= 1'b0;
                end
                lfsr = {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
                drv_valid = (lfsr[2:0] != 3'b000);
                while (!drv_valid) begin
                    @(posedge clk);
                    tvalid <= 1'b0;
                    lfsr = {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
                    drv_valid = (lfsr[2:0] != 3'b000);
                end
                @(posedge clk);
                tvalid <= 1'b1;
                for (k = 0; k < 4; k = k + 1) begin
                    tdata[95-24*k -: 24] <= 24'h100000 * f + b * 4 + k;
                    exp_d[push_n + k] = 24'h100000 * f + b * 4 + k;
                    exp_s[push_n + k] = (b == 0) && (k == 0);
                    exp_e[push_n + k] = (k == 3) && ((b % BEATS) == BEATS-1);
                end
                tuser <= (b == 0);
                tlast <= ((b % BEATS) == BEATS-1);
                push_n = push_n + 4;
            end
        end
        @(posedge clk);
        tvalid <= 1'b0; tuser <= 1'b0; tlast <= 1'b0;
        repeat (64) @(posedge clk);

        // ---------------- 阶段 2：故障注入（溢出 + tuser 缺失 + 看门狗恢复） ----------------
        phase2 = 1;
        // 2a: 连续 back-to-back 入队至溢出（960 beat @1/clk → 净积压 2880 > 2048），
        //     全程 tuser=0（帧同步契约破坏）；tlast 保留行边界
        for (i = 0; i < 960; i = i + 1) begin
            @(posedge clk);
            tdata  <= 96'h0;
            tvalid <= 1'b1; tuser <= 1'b0; tlast <= ((i % 320) == 319);
        end
        // 2b: 无 tuser 继续喂 > SYNC_TIMEOUT(2000) beat —— 看门狗应触发
        for (i = 0; i < 2600; i = i + 1) begin
            @(posedge clk);
            tvalid <= 1'b1; tuser <= 1'b0; tlast <= 1'b0;
        end
        @(posedge clk);
        if (!o_sync_err) begin p2_mism = p2_mism + 1; $display("MISM P2: sync_err 未置位"); end
        else $display("P2: 看门狗触发 sync_err=1；缓冲已排空 o_valid=%b", o_valid);
        if (o_valid) p2_busy_after = 1;     // 此刻缓冲应已排空（o_valid 应为 0）
        // 2c: 给一个 tlast 拍 -> 合成帧首恢复（仍无 tuser）
        @(posedge clk);
        tdata  <= {24'hB00001, 24'hB00002, 24'hB00003, 24'hB00004};
        tvalid <= 1'b1; tuser <= 1'b0; tlast <= 1'b1;
        // 2d: 恢复后继续喂普通 beat（仍无 tuser），验证持续可写
        for (i = 0; i < 16; i = i + 1) begin
            @(posedge clk);
            tdata  <= {24'hB00005, 24'hB00006, 24'hB00007, 24'hB00008};
            tvalid <= 1'b1; tuser <= 1'b0; tlast <= 1'b0;
        end
        @(posedge clk);
        tvalid <= 1'b0;
        repeat (64) @(posedge clk);
        if ((mism == 0) && (p2_mism == 0) && (pop_n == push_n) &&
            (p2_sof == 1) && (p2_after_sof == 3) && (p2_pop >= 12) &&
            (p2_empty_seen) && !p2_busy_after)
            $display("TB_RESULT: PASS (p1 pixels=%0d, p2 recovered sof=%0d pop=%0d)",
                     pop_n, p2_sof, p2_pop);
        else
            $display("TB_RESULT: FAIL p1 mism=%0d pop=%0d/%0d | p2 mism=%0d sof=%0d after_sof=%0d pop=%0d empty_seen=%b",
                     mism, pop_n, push_n, p2_mism, p2_sof, p2_after_sof, p2_pop, p2_empty_seen);
        $finish;
    end

    // 输出比对（阶段 1：逐像素期望；阶段 2：恢复段语义检查）
    always @(posedge clk) begin
        if (rst_n && o_valid) begin
            if (!phase2) begin
                if ((o_data !== exp_d[pop_n]) || (o_sof !== exp_s[pop_n]) ||
                    (o_eol !== exp_e[pop_n])) begin
                    if (mism < 8)
                        $display("MISM idx=%0d got d=%h s=%b e=%b exp d=%h s=%b e=%b",
                                 pop_n, o_data, o_sof, o_eol,
                                 exp_d[pop_n], exp_s[pop_n], exp_e[pop_n]);
                    mism = mism + 1;
                end
                pop_n = pop_n + 1;
            end else begin
                p2_pop = p2_pop + 1;
                if (o_sof) begin
                    p2_sof = p2_sof + 1;
                    if (o_data !== 24'hB00001) begin
                        p2_mism = p2_mism + 1;
                        $display("MISM P2: sof 像素数据=%h（应 B00001）", o_data);
                    end
                end else if (p2_sof > 0 && p2_after_sof < 3) begin
                    // 合成帧首之后的 3 个像素必须为 B00002..B00004
                    if (o_data !== (24'hB00002 + p2_after_sof)) begin
                        p2_mism = p2_mism + 1;
                        $display("MISM P2: 恢复段数据=%h（应 %h）",
                                 o_data, 24'hB00002 + p2_after_sof);
                    end
                    p2_after_sof = p2_after_sof + 1;
                end
            end
        end
        if (phase2 && o_sync_err && !o_valid) p2_empty_seen = 1;   // 看门狗后的排空态
    end

    initial begin
        #20000000;
        $display("TB_RESULT: FAIL timeout");
        $finish;
    end
endmodule
