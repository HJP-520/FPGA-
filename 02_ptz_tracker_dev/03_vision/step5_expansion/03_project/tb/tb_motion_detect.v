// =============================================================================
// tb_motion_detect.v —— 帧差运动检测位精确校验（64x48 x 5 帧）
// 场景：f0 静止背景(填缓存) → f1 出现8x8块 → f2 移动 → f3 消失 → f4 5px亚门限
//       → f5 仅末像素 (63,47) 差分（帧末锁存边界）
// 期望：golden_model.frame_diff_motion 位精确生成（motion_exp.txt，
//       每行 15 位 hex = {cnt[13:0], valid, minx[10:0], maxx[10:0], miny[9:0], maxy[9:0]}）
// 全部 5 帧各有一条期望（f0 = 全 0：prev_ready 未置位，输出保持复位值）。
// 采样方法：O_mot_valid 仅 1 拍，直接抓会竞态。驱动器在每个帧末拍置 frame_end，
//       监视器经 frame_end_d 同步后延时读取输出总线快照（snap 每拍 NBA 采样）。
//       注：motion_detect v3（ERAM 同步读流水）输出脉冲比 v2 后移 1 拍，
//       采样窗口相应 +1 拍。
// =============================================================================
`timescale 1ns/1ps
module tb_motion_detect;
    localparam W = 64, H = 48, TH = 12, FRAMES = 6, TOTAL = W*H*FRAMES;
    reg clk = 0, rst_n = 0;
    always #7 clk = ~clk;

    reg        in_valid, in_sof, in_eol, in_mask;
    wire       o_v;
    wire [13:0] o_cnt;
    wire [10:0] o_mnx, o_mxx;
    wire [9:0]  o_mny, o_mxy;

    motion_detect #(.IMG_WIDTH(W), .IMG_HEIGHT(H), .MOT_TH(TH)) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_valid(in_valid), .I_sof(in_sof), .I_eol(in_eol), .I_mask(in_mask),
        .O_mot_valid(o_v), .O_mot_cnt(o_cnt),
        .O_mot_minx(o_mnx), .O_mot_maxx(o_mxx),
        .O_mot_miny(o_mny), .O_mot_maxy(o_mxy));

    reg        vin  [0:TOTAL-1];
    reg [56:0] vexp [0:FRAMES-1];
    reg [56:0] snap;
    integer    i = 0, x = 0, y = 0, mism = 0, f = 0;
    integer    pending = -1, pend_r = -1, cmp_cnt = 0;
    reg        frame_end;
    reg        x_sof, x_eol;

    // 输出总线每拍快照（NBA）
    always @(posedge clk) snap <= {o_cnt, o_v, o_mnx, o_mxx, o_mny, o_mxy};

    // 单帧比对任务
    // snap 位段：cnt=[56:43] valid=[42] minx=[41:31] maxx=[30:20] miny=[19:10] maxy=[9:0]
    task check_frame;
        input integer idx;
        begin
            if (snap !== vexp[idx]) begin
                if (mism < 8)
                    $display("MISM frame=%0d got=%h exp=%h", idx, snap, vexp[idx]);
                mism = mism + 1;
            end else begin
                $display("MEAS f%0d: cnt=%0d valid=%b bbox=(%0d,%0d)-(%0d,%0d)",
                         idx, snap[56:43], snap[42], snap[41:31], snap[19:10],
                         snap[30:20], snap[9:0]);
            end
        end
    endtask

    initial begin
        $readmemh("motion_in.hex", vin);
        $readmemh("motion_exp.txt", vexp);
    end

    // 驱动：1 像素/拍，sof/eol 按几何；帧末拍置 frame_end/pending
    always @(posedge clk) begin
        if (rst_n && (i < TOTAL+1)) begin           // 多喂 1 个冲刷令牌
            in_valid <= 1'b1;
            in_mask  <= (i == TOTAL) ? 1'b0 : vin[i];
            x_sof    = (i % (W*H) == 0);
            x_eol    = (x == W-1);
            in_sof   <= x_sof;
            in_eol   <= x_eol;
            if (x == W-1) begin
                x <= 0;
                y <= y + 1;
            end else begin
                x <= x + 1;
            end
            i = i + 1;
            frame_end <= (i % (W*H) == 0) && (i <= TOTAL);
            if (i % (W*H) == 0)
                pending = i/(W*H) - 1;
        end else begin
            in_valid <= 1'b0; in_sof <= 1'b0; in_eol <= 1'b0;
            frame_end <= 1'b0;
        end
    end

    // 监视器：frame_end_d 同步 → 延时 2 拍 → 读快照比对
    reg frame_end_d = 1'b0;
    always @(posedge clk) begin
        frame_end_d <= frame_end;
        if (frame_end_d) begin
            pend_r  <= pending;
            cmp_cnt <= 3;   // v3.1 帧末锁存再延一拍：脉冲在 frame_end_d 后第 3 拍
        end else if (cmp_cnt != 0) begin
            cmp_cnt <= cmp_cnt - 1;
            if (cmp_cnt == 1) begin
                check_frame(pend_r);
                f = f + 1;
                if (f == FRAMES) begin
                    if (mism == 0)
                        $display("TB_RESULT: PASS (frames=%0d)", FRAMES);
                    else
                        $display("TB_RESULT: FAIL mism=%0d/%0d", mism, FRAMES);
                    $finish;
                end
            end
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        rst_n <= 1;
        #20000000;
        $display("TB_RESULT: FAIL timeout f=%0d/%0d", f, FRAMES);
        $finish;
    end
endmodule
