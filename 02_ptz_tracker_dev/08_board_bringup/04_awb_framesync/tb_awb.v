`timescale 1ns/1ps
// =============================================================================
// tb_awb.v —— AWB 帧同步化行为验证（评审#1 · 第1批，2026-10-04）
// -----------------------------------------------------------------------------
// 被测：工程版 awb.v（lab_ex1 树 = 板上真值），本次改动：
//   ① 上一帧统计锁存（仅当帧 > STAT_MIN_BEATS 非白拍才采信）
//   ② 增益 = clamp(上一帧统计商, 0.5x~3.0x)，帧内恒定（不再随累加漂移）
//   ③ 帧边界按 ±0.125x/帧 步进（跨帧平滑）；不再每帧复位 1.0
//
// 激励：合成强色偏像素流，帧长 NF=24000 拍（> 20480 阈值），行 320 拍。
// 说明（期望值推导）：统计初值 +1 → 目标商偶有 1LSB 偏差（如 1.5x 实测 0x17FFF），
//   容差 TOL=0x100 覆盖；限幅测试用 3.75x 比值（若 clamp 失效会到 0x31FFF+，必判错）。
//   A 相 C1=(R100,G150,B200)：R 目标 1.5x、B 目标 0.75x — 两帧滞后后逐帧 ±0.125
//   B 相 C2=(R40, G150,B200)：R 比值 3.75x 触发**限幅** → 精确停在 3.0x(0x30000)
//   C 相 帧中突变（第 12000 拍切色）：当帧增益恒定，下一帧也不变（目标滞后）
// 判据：全部 CHECK OK → TB_RESULT: PASS
// =============================================================================
module tb_awb;
    reg clk = 0, rst_n = 0;
    always #7 clk = ~clk;                      // ~71.4MHz

    localparam NF  = 24000;                    // 拍/帧（> STAT_MIN_BEATS=20480）
    localparam LN  = 320;                      // 行内拍数（1280px / 4px）
    localparam GAP = 200;                      // 帧间空拍
    localparam [19:0] TOL = 20'h00100;         // 容差 ±1/256（吸收统计初值+1的舍入）

    reg        v = 0;
    reg [95:0] d = 0;
    reg        tuser = 0, tlast = 0;
    reg [7:0]  cr = 8'd100, cg = 8'd150, cb = 8'd200;

    wire [23:0] px = {cr, cg, cb};
    always @* d = {px, px, px, px};

    reg bad = 0;                               // 第2批：I_frame_bad 驱动（帧首呈现"上一帧坏"）

    awb #(.IMG_HEIGHT(720), .IMG_WIDTH(1280)) u_awb (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_tlast(tlast), .I_tuser(tuser), .I_tdata(d), .I_tvalid(v),
        .I_frame_bad(bad),
        .I_tready(),
        .O_tlast(), .O_tuser(), .O_tvalid(), .O_tdata(),
        .O_tready(1'b1)
    );

    integer fails = 0;
    reg [19:0] gr, gb;                         // 帧头采样
    reg [19:0] gr_end, gb_end;                 // 帧尾采样

    task frame_head(input [7:0] r, input [7:0] g, input [7:0] b);
        begin
            @(posedge clk);
            tuser <= 1'b1; v <= 1'b1; tlast <= 1'b0;
            cr <= r; cg <= g; cb <= b;
            @(posedge clk);
            tuser <= 1'b0;
            repeat (7) @(posedge clk);      // 头段共 8 拍（tuser 拍 + 7）→ 整帧拍数精确 = 调用值
            gr = u_awb.in_r_r1;
            gb = u_awb.in_b_r1;
        end
    endtask

    task frame_body(input integer sw_at,
                    input [7:0] r1, input [7:0] g1, input [7:0] b1,
                    input integer end_sample);
        integer i;
        begin
            for (i = 8; i < NF; i = i + 1) begin
                v     <= 1'b1;
                tlast <= ((i % LN) == (LN - 1));
                if (sw_at > 0 && i == sw_at) begin cr <= r1; cg <= g1; cb <= b1; end
                @(posedge clk);
            end
            if (end_sample) begin
                gr_end = u_awb.in_r_r1;
                gb_end = u_awb.in_b_r1;
            end
            v <= 1'b0; tlast <= 1'b0;
            repeat (GAP) @(posedge clk);
        end
    endtask

    task chk(input [8*40:1] tag, input [19:0] er, input [19:0] eb);
        reg [19:0] dr, db;
        begin
            dr = (gr > er) ? gr - er : er - gr;
            db = (gb > eb) ? gb - eb : eb - gb;
            if (dr > TOL || db > TOL) begin
                $display("CHECK FAIL [%0s]: gain_R=%h (exp %h)  gain_B=%h (exp %h)", tag, gr, er, gb, eb);
                fails = fails + 1;
            end else
                $display("CHECK OK   [%0s]: gain_R=%h  gain_B=%h", tag, gr, gb);
        end
    endtask

    task chk_eq(input [8*40:1] tag, input [19:0] vr, input [19:0] vb);
        begin
            if ((gr_end !== vr) || (gb_end !== vb)) begin
                $display("CHECK FAIL [%0s]: intra-frame drift R %h->%h  B %h->%h", tag, vr, gr_end, vb, gb_end);
                fails = fails + 1;
            end else
                $display("CHECK OK   [%0s]: intra-frame constant R=%h B=%h", tag, vr, vb);
        end
    endtask

    // ---- 第2批：可变帧长版本（边界相位用）----
    task bhead(input [7:0] r, input [7:0] g, input [7:0] b, input integer fb);
        begin
            @(posedge clk);
            bad   <= fb;                       // 本帧首呈现的"上一帧坏"标志
            tuser <= 1'b1; v <= 1'b1; tlast <= 1'b0;
            cr <= r; cg <= g; cb <= b;
            @(posedge clk);
            tuser <= 1'b0;
            repeat (7) @(posedge clk);      // 头段共 8 拍（tuser 拍 + 7）→ 整帧拍数精确 = 调用值
            gr = u_awb.in_r_r1;
            gb = u_awb.in_b_r1;
        end
    endtask

    task bbody(input integer n);
        integer i;
        begin
            for (i = 8; i < n; i = i + 1) begin
                v     <= 1'b1;
                tlast <= ((i % 320) == 319);
                @(posedge clk);
            end
            v <= 1'b0; tlast <= 1'b0;
            repeat (GAP) @(posedge clk);
        end
    endtask

    task breset;
        begin
            rst_n = 0; repeat (20) @(posedge clk);
            rst_n = 1; repeat (10) @(posedge clk);
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        // ============ Phase A: C1=(100,150,200) -> R target 1.5x, B target 0.75x ============
        frame_head(100,150,200); chk("F01 reset 1.0", 20'h10000, 20'h10000);          frame_body(0,0,0,0,0);
        frame_head(100,150,200); chk("F02 no-prev still 1.0", 20'h10000, 20'h10000);  frame_body(0,0,0,0,0);
        frame_head(100,150,200); chk("F03 first step +-0.125", 20'h12000, 20'h0E000); frame_body(0,0,0,0,0);
        frame_head(100,150,200); chk("F04 B hits 0.75", 20'h14000, 20'h0C000);        frame_body(0,0,0,0,0);
        frame_head(100,150,200); chk("F05", 20'h16000, 20'h0C000);                    frame_body(0,0,0,0,0);
        frame_head(100,150,200); chk("F06 R hits ~1.5", 20'h17FFF, 20'h0C000);        frame_body(0,0,0,0,1);
        chk_eq("F06 intra-frame constant", gr, gb);
        frame_head(100,150,200); chk("F07 steady", 20'h17FFF, 20'h0C000);             frame_body(0,0,0,0,0);
        frame_head(100,150,200); chk("F08 steady", 20'h17FFF, 20'h0C000);             frame_body(0,0,0,0,0);

        // ============ Phase B: C2=(40,150,200) -> ratio 3.75x, CLAMPED to 3.0x ============
        frame_head(40,150,200);  chk("F09 lag-2 frames (hold)", 20'h17FFF, 20'h0C000); frame_body(0,0,0,0,0);
        frame_head(40,150,200);  chk("F10 lag-1 frame (hold)", 20'h17FFF, 20'h0C000);  frame_body(0,0,0,0,0);
        frame_head(40,150,200);  chk("F11 climb", 20'h19FFF, 20'h0C000);               frame_body(0,0,0,0,0);
        frame_head(40,150,200);  chk("F12", 20'h1BFFF, 20'h0C000);                     frame_body(0,0,0,0,0);
        frame_head(40,150,200);  chk("F13", 20'h1DFFF, 20'h0C000);                     frame_body(0,0,0,0,0);
        frame_head(40,150,200);  chk("F14", 20'h1FFFF, 20'h0C000);                     frame_body(0,0,0,0,0);
        frame_head(40,150,200);  chk("F15", 20'h21FFF, 20'h0C000);                     frame_body(0,0,0,0,0);
        frame_head(40,150,200);  chk("F16", 20'h23FFF, 20'h0C000);                     frame_body(0,0,0,0,0);
        frame_head(40,150,200);  chk("F17", 20'h25FFF, 20'h0C000);                     frame_body(0,0,0,0,0);
        frame_head(40,150,200);  chk("F18", 20'h27FFF, 20'h0C000);                     frame_body(0,0,0,0,0);
        frame_head(40,150,200);  chk("F19", 20'h29FFF, 20'h0C000);                     frame_body(0,0,0,0,0);
        frame_head(40,150,200);  chk("F20", 20'h2BFFF, 20'h0C000);                     frame_body(0,0,0,0,0);
        frame_head(40,150,200);  chk("F21", 20'h2DFFF, 20'h0C000);                     frame_body(0,0,0,0,0);
        frame_head(40,150,200);  chk("F22", 20'h2FFFF, 20'h0C000);                     frame_body(0,0,0,0,0);
        frame_head(40,150,200);  chk("F23 CLAMP -> exactly 3.0x", 20'h30000, 20'h0C000); frame_body(0,0,0,0,0);
        frame_head(40,150,200);  chk("F24 clamp hold", 20'h30000, 20'h0C000);          frame_body(0,0,0,0,0);

        // ============ Phase C: mid-frame switch (no response in-frame / next frame) ============
        frame_head(40,150,200);  chk("F25 before switch", 20'h30000, 20'h0C000);
        frame_body(12000, 100,150,200, 1);                    // beat 12000: switch back to C1
        chk_eq("F25 intra-frame constant (switch ignored)", gr, gb);
        frame_head(100,150,200); chk("F26 lag -> hold 3.0x", 20'h30000, 20'h0C000);    frame_body(0,0,0,0,0);

        // ================= 第2批边界相位（评审批次②：窗口/暗剔除/坏帧门）=================
        // G1 下界 20480（不达标→拒；若误采信，C 帧头会显示 3.0x 方向步进 0x12000）
        breset;
        bhead(50,150,200,0); bbody(20480);
        bhead(100,150,200,0); bbody(24000);
        bhead(100,150,200,0); chk("G1 min-1 rejected", 20'h10000, 20'h10000); bbody(24000);
        bhead(100,150,200,0); chk("G1 next step ok", 20'h12000, 20'h0E000);  bbody(24000);

        // G2 下界 20481（达标→采信，体现在 C' 帧头 0x12000/0xE000）
        breset;
        bhead(50,150,200,0); bbody(20481);
        bhead(100,150,200,0); bbody(24000);
        bhead(100,150,200,0); chk("G2 min+1 committed", 20'h12000, 20'h0E000); bbody(24000);

        // H 高亮非中性（255,220,255 sum=730>720 → 剔除；若误计会向下步进）
        breset;
        bhead(255,220,255,0); bbody(24000);
        bhead(100,150,200,0); bbody(24000);
        bhead(100,150,200,0); chk("H bright excluded", 20'h10000, 20'h10000); bbody(24000);

        // H2 近黑非中性（5,15,20 sum=40<45 → 新下界剔除；若误计 R 目标=3.0 会向上步进）
        breset;
        bhead(5,15,20,0); bbody(24000);
        bhead(100,150,200,0); bbody(24000);
        bhead(100,150,200,0); chk("H2 dark excluded", 20'h10000, 20'h10000); bbody(24000);
        // H2 对照：过下界 (10,30,40) sum=80 → 采信
        breset;
        bhead(10,30,40,0); bbody(24000);
        bhead(100,150,200,0); bbody(24000);
        bhead(100,150,200,0); chk("H2 dark-control ok", 20'h12000, 20'h0E000); bbody(24000);

        // J 超长帧上界（310000>300000 → 拒；对应 720p 漏 SOF 并帧 460800 的保护）
        breset;
        bhead(50,150,200,0); bbody(310000);
        bhead(100,150,200,0); bbody(24000);
        bhead(100,150,200,0); chk("J oversize rejected", 20'h10000, 20'h10000); bbody(24000);

        // K frame_bad 门（长度合格但"上一帧坏" → 拒；下一帧恢复采信）
        breset;
        bhead(50,150,200,0); bbody(24000);                                    // K1 好统计
        bhead(100,150,200,1); bbody(24000);                                   // K2 帧首 fb=1 → 评估 K1 时拒
        bhead(100,150,200,0); chk("K bad-frame rejected", 20'h10000, 20'h10000); bbody(24000);
        bhead(100,150,200,0); chk("K gate recovers", 20'h12000, 20'h0E000);   bbody(24000);

        // L 帧中复位 → 增益回 1.0
        bhead(50,150,200,0); bbody(2000);
        rst_n = 0; repeat (5) @(posedge clk); rst_n = 1; repeat (10) @(posedge clk);
        gr = u_awb.in_r_r1;
        gb = u_awb.in_b_r1;
        chk("L reset-mid-frame", 20'h10000, 20'h10000);

        $display("============================================================");
        if (fails == 0)
            $display("TB_RESULT: PASS  (0 fail)  AWB frame-sync behavior confirmed");
        else
            $display("TB_RESULT: FAIL  (fails=%0d)", fails);
        $finish;
    end

    initial begin
        #200000000;    // watchdog: 200ms sim time (actual ~9ms)
        $display("TB_RESULT: FAIL (watchdog timeout)");
        $finish;
    end
endmodule
