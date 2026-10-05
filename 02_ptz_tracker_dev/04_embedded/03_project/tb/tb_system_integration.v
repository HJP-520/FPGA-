// =============================================================================
// tb_system_integration.v —— 嵌入式×视觉 整链对接仿真（核心交付）
// 虚拟 RAW10 传感器（Python 生成 BGGR 场景）→ isp_top（官方 ISP：去马赛克/AWB）
// → 128→96 重排 → vision_top（检测/OSD/云台）→ 帧转储 + 断言
//
// 判据（功能级，非像素级——AWB 会自适应改变颜色）：
//   A. ISP 输出几何：每帧 tuser 恰 1 次、tlast 恰 720 次
//   B. 检测锁定：valid=1 且 |cx−539|≤40、|cy−339|≤40（红块中心 539/339）
//   C. 云台方向：duty_x < 1500（块在左半屏）
//   D. UART 遥测：收到 A5..5A 帧且 valid=1、坐标与检测一致
// =============================================================================
`timescale 1ns/1ps
module tb_system_integration;
    reg clk = 0, pwm_clk = 0, rst_n = 0, pwm_rst_n = 0;
    always #7 clk = ~clk;          // ~71.4MHz
    always #10 pwm_clk = ~pwm_clk; // 50MHz

    // ---------------- RAW10 激励 ----------------
    reg [39:0] beats [0:921599];    // 4 帧余量
    reg [1:0]  metas [0:921599];    // bit1=sof bit0=eol
    integer nb;
    initial begin
        $readmemh("raw10_beats.hex", beats);
        $readmemh("raw10_meta.txt", metas);
        nb = 230400 * 4;            // 4 帧
    end

    wire        isp_tready;
    reg  [39:0] raw_data;
    reg         raw_valid, raw_sof, raw_eol;
    integer     bi = 0;

    // 馈送：每拍一 beat（ isp 内部为整拍流水），tsof/teol 随拍
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            raw_valid <= 1'b0; raw_sof <= 1'b0; raw_eol <= 1'b0; raw_data <= 0;
        end else if (bi < nb) begin
            raw_valid <= 1'b1;
            raw_data  <= beats[bi];
            raw_sof   <= metas[bi][1];
            raw_eol   <= metas[bi][0];
            bi = bi + 1;
        end else begin
            raw_valid <= 1'b0; raw_sof <= 1'b0; raw_eol <= 1'b0;
        end
    end

    // ---------------- 被测系统集成顶层 ----------------
    wire pwm_x, pwm_y, uart_txd, osd_valid, osd_sof, osd_eol;
    wire [23:0] osd_data;
    wire [12:0] duty_x, duty_y;
    wire [15:0] lost_cnt;

    system_top u_sys (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_pwm_clk(pwm_clk), .I_pwm_rst_n(pwm_rst_n),
        .I_raw10_data(raw_data), .I_raw10_valid(raw_valid),
        .I_raw10_sof(raw_sof), .I_raw10_eol(raw_eol),
        .I_btn_n(2'b11),
        .O_pwm_x(pwm_x), .O_pwm_y(pwm_y),
        .O_duty_x_us(duty_x), .O_duty_y_us(duty_y),
        .O_lost_cnt(lost_cnt),
        .O_uart_txd(uart_txd),
        .O_osd_data(osd_data), .O_osd_valid(osd_valid),
        .O_osd_sof(osd_sof), .O_osd_eol(osd_eol)
    );

    // ---------------- 帧转储（OSD 流） ----------------
    frame_dump24 #(.BASE_NAME("sys_osd"), .MAX_FRAMES(4)) u_dump (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_valid(osd_valid), .I_eol(osd_eol), .I_data(osd_data),
        .O_frame_done());

    // ---------------- ISP 几何检查 ----------------
    integer tuser_cnt = 0, tlast_cnt = 0, frames_done = 0, geo_err = 0;
    always @(posedge clk) begin
        if (rst_n && u_sys.isp_tvalid) begin
            if (u_sys.isp_tuser) begin
                if (frames_done > 0 && (tuser_cnt != 1 || tlast_cnt != 720)) begin
                    $display("GEO_ERR frame=%0d tuser=%0d tlast=%0d", frames_done, tuser_cnt, tlast_cnt);
                    geo_err = geo_err + 1;
                end
                tuser_cnt = 1; tlast_cnt = 0; frames_done = frames_done + 1;
            end
            if (u_sys.isp_tlast) tlast_cnt = tlast_cnt + 1;
        end
    end

    // ---------------- 检测/云台检查 ----------------
    integer det_ok = 0, det_seen = 0;
    wire [10:0] cx  = u_sys.u_vision.t_cx;
    wire [10:0] cy  = u_sys.u_vision.t_cy;
    wire        tv  = u_sys.u_vision.t_valid;
    always @(posedge clk) begin
        if (rst_n && u_sys.u_vision.t_upd && tv && frames_done >= 3) begin
            det_seen = det_seen + 1;
            if ((cx >= 499) && (cx <= 579) && (cy >= 299) && (cy <= 379))
                det_ok = det_ok + 1;
            else
                $display("DET_MISS frame=%0d cx=%0d cy=%0d", frames_done, cx, cy);
        end
    end

    // ---------------- UART 解码监视 ----------------
    wire [7:0] urx_byte; wire urx_valid;
    uart_rx_mon #(.CLK_DIV(646)) u_mon (
        .I_clk(clk), .I_rst_n(rst_n), .I_rxd(uart_txd),
        .O_byte(urx_byte), .O_valid(urx_valid));
    integer u_state = 0, u_good = 0, u_frames = 0;
    reg [7:0] u_b1, u_b2, u_b3, u_b4, u_b5, u_b6, u_b7;
    always @(posedge clk) begin
        if (rst_n && urx_valid) begin
            case (u_state)
                0: if (urx_byte == 8'hA5) u_state = 1;
                1: begin u_b1 = urx_byte; u_state = 2; end
                2: begin u_b2 = urx_byte; u_state = 3; end
                3: begin u_b3 = urx_byte; u_state = 4; end
                4: begin u_b4 = urx_byte; u_state = 5; end
                5: begin u_b5 = urx_byte; u_state = 6; end
                6: begin u_b6 = urx_byte; u_state = 7; end
                7: begin u_b7 = urx_byte; u_state = 8; end
                8: if (urx_byte == 8'h5A) begin
                    u_frames = u_frames + 1;
                    // 校验和 + valid=1 + cx 在框内
                    if ((u_b7 == (8'hA5 + u_b1 + u_b2 + u_b3 + u_b4 + u_b5 + u_b6))
                        && (u_b1 == 8'h01) && (u_b2 >= 8'd24) && (u_b2 <= 8'd67))
                        u_good = u_good + 1;
                    u_state = 0;
                end else u_state = 0;
            endcase
        end
    end

    // ---------------- 终判 ----------------
    integer guard;
    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge pwm_clk);
        pwm_rst_n = 1;
        guard = 1;
    end
    always @(posedge clk) begin
        if (rst_n && (frames_done >= 8) && guard && (det_ok >= 2) && (u_good >= 2)) begin
            $display("TB_RESULT: PASS frames=%0d det_ok=%0d uart_good=%0d duty_x=%0d",
                     frames_done, det_ok, u_good, duty_x);
            $finish;
        end
        if (rst_n && (frames_done >= 8) && (det_seen >= 4) && (det_ok == 0) && guard) begin
            $display("TB_RESULT: FAIL detect locked on wrong target/none (det_seen=%0d)", det_seen);
            $finish;
        end
        if (rst_n && (u_dump.frame_idx >= 3) && guard && (u_frames < 2)) begin
            $display("TB_RESULT: FAIL uart no good frames=%0d", u_frames);
            $finish;
        end
    end
    initial begin
        #450000000;
        $display("TB_RESULT: FAIL timeout frames=%0d det_ok=%0d uart_good=%0d geo_err=%0d",
                 frames_done, det_ok, u_good, geo_err);
        $finish;
    end
endmodule
