// =============================================================================
// tb_vision_top.v —— 整机联调 TB：tpg(红块@500,300) -> vision_top
// 采集：第 2 帧 OSD 叠加图（frame_1）+ 云台脉宽方向。
// Python 侧：帧像素比对 + 质心/方向校验（run_all.py）。
// =============================================================================
`timescale 1ns/1ps
module tb_vision_top;
    reg pix_clk = 0, pwm_clk = 0, pix_rst = 0, pwm_rst = 0;
    always #7  pix_clk = ~pix_clk;
    always #10 pwm_clk = ~pwm_clk;

    reg  [10:0] box_x = 11'd500;
    reg  [9:0]  box_y = 10'd300;
    wire        tvalid, tuser, tlast;
    wire [95:0] tdata;

    tpg_720p #(.BOX_EN(1)) u_tpg (
        .I_clk(pix_clk), .I_rst_n(pix_rst),
        .I_box_x(box_x), .I_box_y(box_y),
        .O_tvalid(tvalid), .O_tdata(tdata), .O_tuser(tuser), .O_tlast(tlast),
        .I_tready(1'b1));

    wire        osd_valid, osd_sof, osd_eol;
    wire [23:0] osd_data;
    wire [95:0] pt_data;
    wire        pt_valid, pt_user, pt_last, tready;
    wire        pwm_x, pwm_y;
    wire [12:0] duty_x, duty_y;
    wire [15:0] lost;
    wire [7:0]  status;

    vision_top dut (
        .I_pix_clk(pix_clk), .I_pix_rst_n(pix_rst),
        .I_pwm_clk(pwm_clk), .I_pwm_rst_n(pwm_rst),
        .I_tdata(tdata), .I_tvalid(tvalid), .I_tuser(tuser), .I_tlast(tlast),
        .O_tready(tready),
        .O_tdata(pt_data), .O_tvalid(pt_valid), .O_tuser(pt_user), .O_tlast(pt_last),
        .O_osd_valid(osd_valid), .O_osd_sof(osd_sof),
        .O_osd_eol(osd_eol), .O_osd_data(osd_data),
        .I_preset_idx(3'd0), .I_track_en(1'b1),
        .I_algo_edge(1'b0), .I_bright(7'd0), .I_contrast(8'd64),
        .O_pwm_x(pwm_x), .O_pwm_y(pwm_y),
        .O_duty_x_us(duty_x), .O_duty_y_us(duty_y),
        .O_lost_cnt(lost), .O_status(status),
        .O_led_g(), .O_led_r(), .O_buzzer());

    frame_dump24 #(.BASE_NAME("vision_frame"), .MAX_FRAMES(5)) u_dump (
        .I_clk(pix_clk), .I_rst_n(pix_rst),
        .I_valid(osd_valid), .I_eol(osd_eol), .I_data(osd_data),
        .O_frame_done());

    integer done_frames = 0;
    integer fd;
    initial fd = $fopen("vision_duty.txt", "w");

    // 直通一致性
    integer pm = 0;
    always @(posedge pix_clk) begin
        if (pix_rst && tvalid && ((pt_data !== tdata) || (pt_valid !== 1'b1)))
            pm = pm + 1;
    end

    always @(posedge pix_clk) begin
        if (pix_rst && osd_valid && osd_eol && (done_frames == 1)) begin
            // 第 2 帧末（dump 帧序号 1 完成）
        end
    end

    always @(posedge pwm_clk) begin
        if (pwm_rst && dut.u_gimbal.O_lost_cnt === 16'd0) begin
        end
    end

    // 帧计数（用 dump 模块内部 frame_idx 层次引用）
    always @(posedge pix_clk) begin
        if (pix_rst && (u_dump.frame_idx == 5)) begin   // 第5帧末：frame_4.hex 已写完
            $fwrite(fd, "%0d %0d %0d %0d\n", duty_x, duty_y, lost, status);
            $fflush(fd);
            $fclose(fd);
            $display("DUTY_REPORT: x=%0d y=%0d lost=%0d status=%b passthru_mism=%0d",
                     duty_x, duty_y, lost, status, pm);
            if (pm == 0)
                $display("TB_RESULT: PASS (duty_x=%0d, expect python frame compare)", duty_x);
            else
                $display("TB_RESULT: FAIL passthru_mism=%0d", pm);
            $finish;
        end
    end

    initial begin
        repeat (4) @(posedge pix_clk);
        pix_rst <= 1;
        repeat (4) @(posedge pwm_clk);
        pwm_rst <= 1;
        #170000000;
        $display("TB_RESULT: FAIL timeout frames=%0d", u_dump.frame_idx);
        $finish;
    end
endmodule
