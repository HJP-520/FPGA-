// =============================================================================
// tb_osd_track.v —— OSD 叠加层帧级校验 v2（双缓冲消撕裂验证）
// 时序：帧 0 中段（y=360）注入目标包 → CDC 落入影子寄存器（帧 0 画面不受影响），
//       帧 1 sof 换装 → 帧 1/帧 2 整帧使用新状态。
// 比对：dump osd_act_f0/f1/f2.hex 与 Python 金标准 osd_exp_f0/f1/f2.hex 逐位比对
//       （由 run_all 的 frame check 完成）。
//       f0 = 空状态（无文本无框，跑马灯滚动）；f1/f2 = 完整 OSD（跑马灯偏移递增）。
//       若双缓冲失效（包到达即生效），f0 将被撕裂，不可能匹配金标准。
// =============================================================================
`timescale 1ns/1ps
module tb_osd_track;
    localparam FLEN = 1280*720, FRAMES = 3;
    reg clk = 0, rst_n = 0;
    always #7 clk = ~clk;

    reg        in_valid, in_sof, in_eol;
    reg [23:0] in_data;
    wire       o_valid, o_sof, o_eol;
    wire [23:0] o_data;

    reg  [134:0] pack;
    reg         pack_load = 0;
    wire        pack_busy;

    osd_track dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_valid(in_valid), .I_sof(in_sof), .I_eol(in_eol), .I_data(in_data),
        .I_det_clk(clk), .I_det_rst_n(rst_n),
        .I_det_pack(pack), .I_det_load(pack_load), .O_det_busy(pack_busy),
        .I_bright(7'd0), .I_contrast(8'd64),
        .O_valid(o_valid), .O_sof(o_sof), .O_eol(o_eol), .O_data(o_data));

    reg [23:0] base [0:FLEN-1];
    integer f0, f1, f2, i = 0, x = 0, y = 0;
    integer fdc, scanned;
    integer got = 0;
    integer w0 = 0, w1 = 0, w2 = 0;
    reg v_in; integer c_cx, c_cy, c_x0, c_x1, c_y0, c_y1;

    initial begin
        // 句柄必须先于首像素打开：若在首个 o_valid 边沿 fopen，与 $fwrite 同拍
        // 竞态，像素 0 会写进 fd0（stdout）且整个文件前移一格（实测教训）
        f0 = $fopen("osd_act_f0.hex", "w");
        f1 = $fopen("osd_act_f1.hex", "w");
        f2 = $fopen("osd_act_f2.hex", "w");
        $readmemh("osd_base.hex", base);
        fdc = $fopen("osd_coord.txt", "r");
        scanned = $fscanf(fdc, "%1x%3x%3x%3x%3x%3x%3x",
                          v_in, c_cx, c_cy, c_x0, c_x1, c_y0, c_y1);
        // 运动框字段填入与金标准一致的值（外脑评审补覆盖）：
        // mot_valid=1, mot_cnt=64, bbox=(200,200)-(260,240)
        pack = {v_in, 1'b0, 3'd0, c_cx[10:0], c_cy[10:0], c_x0[10:0], c_x1[10:0],
                c_y0[9:0], c_y1[9:0], 8'd0, 1'b1, 14'd64,
                11'd200, 11'd260, 10'd200, 10'd240, 1'b0};   // 135bit：bit0 保留位必须补齐
        $display("SCAN scanned=%0d v_in=%b cx=%0d cy=%0d x0=%0d x1=%0d y0=%0d y1=%0d",
                 scanned, v_in, c_cx, c_cy, c_x0, c_x1, c_y0, c_y1);
    end

    // 帧 0 中段（y=360 的行中点）注入目标包：影子寄存器当帧更新，画面不变
    always @(posedge clk) begin
        if (rst_n && (y == 360) && (x == 640))
            pack_load <= 1'b1;
        else if (pack_load)
            pack_load <= 1'b0;
    end

    // 驱动底图
    always @(posedge clk) begin
        if (rst_n && (i < FLEN*FRAMES)) begin
            in_valid <= 1'b1;
            in_data  <= base[i % FLEN];
            in_sof   <= (i % FLEN == 0);
            in_eol   <= (x == 1280-1);
            if (x == 1280-1) begin
                x <= 0; y <= y + 1;
            end else begin
                x <= x + 1;
            end
            i = i + 1;
        end else begin
            in_valid <= 1'b0; in_sof <= 1'b0; in_eol <= 1'b0;
        end
    end

    // 采集输出（按帧分文件）。快照+延迟一拍写入，避免与 NBA 同沿读写的耦合。
    reg [23:0] od_d;
    reg        ov_d;
    always @(posedge clk) begin
        od_d <= o_data;
        ov_d <= o_valid;
    end

    always @(posedge clk) begin
        if (rst_n && ov_d) begin
            case (got / FLEN)
                0: begin
                    $fwrite(f0, "%02X%02X%02X\n", od_d[23:16], od_d[15:8], od_d[7:0]);
                    w0 = w0 + 1;
                end
                1: begin
                    $fwrite(f1, "%02X%02X%02X\n", od_d[23:16], od_d[15:8], od_d[7:0]);
                    w1 = w1 + 1;
                end
                default: begin
                    $fwrite(f2, "%02X%02X%02X\n", od_d[23:16], od_d[15:8], od_d[7:0]);
                    w2 = w2 + 1;
                end
            endcase
            got = got + 1;
            if (got == FLEN*FRAMES) begin
                $fflush(f0); $fclose(f0);
                $fflush(f1); $fclose(f1);
                $fflush(f2); $fclose(f2);
                $display("TB_RESULT: PASS (dumped=%0d w0=%0d w1=%0d w2=%0d)",
                         got, w0, w1, w2);
                $finish;
            end
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        rst_n <= 1;
        #130000000;
        $display("TB_RESULT: FAIL timeout got=%0d", got);
        $finish;
    end
endmodule
