// =============================================================================
// tb_centroid.v —— 质心/包围框/除零保护校验（128x72 迷你几何，3 帧）
// 帧0 实心块 / 帧1 噪声+块 / 帧2 微块(<MIN_PIXELS -> 无效+lost_cnt)
// =============================================================================
`timescale 1ns/1ps
module tb_centroid;
    localparam W = 128, H = 72, FRAMES = 3, TOTAL = W*H*FRAMES;
    reg clk = 0, rst_n = 0;
    always #7 clk = ~clk;

    reg        in_valid, in_sof, in_eol, in_mask;
    wire       t_valid, r_upd;
    wire [10:0] cx, cy, minx, maxx;
    wire [9:0]  miny, maxy;
    wire [20:0] cnt;
    wire [15:0] lost;

    centroid_accum #(.IMG_WIDTH(W), .IMG_HEIGHT(H), .MIN_PIXELS(30)) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_valid(in_valid), .I_sof(in_sof), .I_eol(in_eol), .I_mask(in_mask),
        .O_target_valid(t_valid), .O_cx(cx), .O_cy(cy), .O_count(cnt),
        .O_min_x(minx), .O_max_x(maxx), .O_min_y(miny), .O_max_y(maxy),
        .O_lost_cnt(lost), .O_results_upd(r_upd), .O_frame_tick());

    reg vin [0:TOTAL-1];
    integer fd, i = 0, x = 0, y = 0, frame = 0, mism = 0, scanned;
    reg exp_v; integer exp_cnt, exp_cx, exp_cy, exp_x0, exp_x1, exp_y0, exp_y1;

    initial begin
        $readmemh("centroid_in.hex", vin);
        fd = $fopen("centroid_exp.txt", "r");
    end

    // 驱动
    always @(posedge clk) begin
        if (rst_n && (i < TOTAL)) begin
            in_valid <= 1'b1;
            in_mask  <= vin[i];
            in_sof   <= (i % (W*H) == 0);
            in_eol   <= (x == W-1);
            if (x == W-1) begin
                x <= 0; y <= y + 1;
            end else begin
                x <= x + 1;
            end
            i = i + 1;
        end else begin
            in_valid <= 1'b0; in_sof <= 1'b0; in_eol <= 1'b0;
        end
    end

    // 结果比对（每帧 results_upd 时读一行期望）
    task check_line;
        begin
            scanned = $fscanf(fd, "%1x%5x%3x%3x%3x%3x%3x%3x",
                              exp_v, exp_cnt, exp_cx, exp_cy,
                              exp_x0, exp_x1, exp_y0, exp_y1);
            if (scanned != 8) begin
                $display("TB_RESULT: FAIL exp-file-short");
                $finish;
            end
            if ((t_valid !== (exp_v == 1)) ||
                (exp_v == 1 && ((cnt !== exp_cnt[20:0]) || (cx !== exp_cx[10:0]) ||
                 (cy !== exp_cy[10:0]) || (minx !== exp_x0[10:0]) ||
                 (maxx !== exp_x1[10:0]) || (miny !== exp_y0[9:0]) ||
                 (maxy !== exp_y1[9:0])))) begin
                $display("MISM frame=%0d got v=%b cnt=%0d cx=%0d cy=%0d x[%0d..%0d] y[%0d..%0d] | exp v=%0d cnt=%0d cx=%0d cy=%0d x[%0d..%0d] y[%0d..%0d]",
                         frame, t_valid, cnt, cx, cy, minx, maxx, miny, maxy,
                         exp_v, exp_cnt, exp_cx, exp_cy, exp_x0, exp_x1, exp_y0, exp_y1);
                $display("                 exp v=%0d cnt=%0d cx=%0d cy=%0d x[%0d..%0d] y[%0d..%0d]",
                         exp_v, exp_cnt, exp_cx, exp_cy, exp_x0, exp_x1, exp_y0, exp_y1);
                mism = mism + 1;
            end else begin
                $display("FRAME%0d OK v=%0d cnt=%0d cx=%0d cy=%0d lost=%0d",
                         frame, t_valid, cnt, cx, cy, lost);
            end
            frame = frame + 1;
            if (frame == FRAMES) begin
                if (mism == 0)
                    $display("TB_RESULT: PASS (frames=%0d)", FRAMES);
                else
                    $display("TB_RESULT: FAIL mism=%0d", mism);
                $finish;
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst_n && r_upd)
            check_line;
    end

    initial begin
        repeat (3) @(posedge clk);
        rst_n <= 1;
        #30000000;
        $display("TB_RESULT: FAIL timeout frame=%0d", frame);
        $finish;
    end
endmodule
