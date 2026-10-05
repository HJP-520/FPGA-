// =============================================================================
// tb_closed_loop.v —— 闭环收敛性系统 TB（RTL 在环）
// 相机模型（TB 内行为级）：云台角度 theta 由脉宽换算（0.18°/µs），
// 带一阶速率限制（1.5°/帧）；目标世界角 40° 固定；
// 目标像素 x = 640 + (40-theta)*20（20 px/°），TPG 方块实时跟随。
// 验收：60 帧内误差进入 ±25px 死区并保持 10 帧（无振荡/发散）。
// =============================================================================
`timescale 1ns/1ps
module tb_closed_loop;
    reg pix_clk = 0, pwm_clk = 0, pix_rst = 0, pwm_rst = 0;
    always #7  pix_clk = ~pix_clk;
    always #10 pwm_clk = ~pwm_clk;

    reg  [10:0] box_x = 11'd600;
    reg  [9:0]  box_y = 10'd300;
    wire        tvalid, tuser, tlast;
    wire [95:0] tdata;

    tpg_720p #(.BOX_EN(1)) u_tpg (
        .I_clk(pix_clk), .I_rst_n(pix_rst),
        .I_box_x(box_x), .I_box_y(box_y),
        .O_tvalid(tvalid), .O_tdata(tdata), .O_tuser(tuser), .O_tlast(tlast),
        .I_tready(1'b1));

    wire [23:0] osd_data;
    wire        osd_valid, osd_sof, osd_eol;
    wire [12:0] duty_x;
    vision_top dut (
        .I_pix_clk(pix_clk), .I_pix_rst_n(pix_rst),
        .I_pwm_clk(pwm_clk), .I_pwm_rst_n(pwm_rst),
        .I_tdata(tdata), .I_tvalid(tvalid), .I_tuser(tuser), .I_tlast(tlast),
        .O_tready(), .O_tdata(), .O_tvalid(), .O_tuser(), .O_tlast(),
        .O_osd_valid(osd_valid), .O_osd_sof(osd_sof),
        .O_osd_eol(osd_eol), .O_osd_data(osd_data),
        .I_preset_idx(3'd0), .I_track_en(1'b1),
        .I_algo_edge(1'b0), .I_bright(7'd0), .I_contrast(8'd64),
        .O_pwm_x(), .O_pwm_y(),
        .O_duty_x_us(duty_x), .O_duty_y_us(),
        .O_lost_cnt(), .O_status(),
        .O_led_g(), .O_led_r(), .O_buzzer());

    // ---------------- 相机-云台行为模型 ----------------
    real theta = 30.0;          // 当前相机指向（°）
    real theta_cmd;
    real delta;
    integer frame = 0, locked_run = 0, settle_frame = -1, err_int;
    integer fd;
    initial fd = $fopen("closed_loop_trace.txt", "w");

    // 每帧末（detect 域 frame_tick）采样脉宽并推进模型
    wire frame_tick = dut.t_tick;
    always @(posedge pix_clk) begin
        if (pix_rst && frame_tick) begin
            theta_cmd = 30.0 + ($signed(duty_x) - 1500) * 0.18;  // 位置舵机：1500=保持 theta0（有符号！）
            delta = theta_cmd - theta;
            if (delta > 1.5)      delta = 1.5;
            else if (delta < -1.5) delta = -1.5;
            theta = theta + delta;
            err_int = $rtoi((40.0 - theta) * 20.0);
            $fwrite(fd, "%0d %0d %0d %f\n", frame, duty_x, err_int, theta);
            if ((err_int >= -25) && (err_int <= 25)) begin
                locked_run = locked_run + 1;
                if ((settle_frame < 0) && (locked_run >= 10)) begin
                    settle_frame = frame - 9;
                    $display("LOCKED: settle_frame=%0d", settle_frame);
                end
            end else begin
                locked_run = 0;
            end
            frame = frame + 1;
            // 更新下一帧 TPG 方块位置（相机视角）
            box_x <= 640 + err_int - 40;   // 隐式截断到 11 位（范围已保证非负）
            if (frame == 60) begin
                $fflush(fd);
                $fclose(fd);
                if (settle_frame >= 0)
                    $display("TB_RESULT: PASS settle_frame=%0d final_err=%0d",
                             settle_frame, err_int);
                else
                    $display("TB_RESULT: FAIL not locked, final_err=%0d", err_int);
                $finish;
            end
        end
    end

    initial begin
        repeat (4) @(posedge pix_clk);
        pix_rst <= 1;
        repeat (4) @(posedge pwm_clk);
        pwm_rst <= 1;
        #900000000;
        $display("TB_RESULT: FAIL timeout frame=%0d", frame);
        $finish;
    end
endmodule
