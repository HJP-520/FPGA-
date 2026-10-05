// =============================================================================
// tb_pwm.v —— 双路 50Hz PWM 校验（v2：连续监视器，无事件同步竞态）
// 方案：自由运转的计数器统计每周期脉宽/长度，period_tick 拍锁存结果；
//       按 tick 序号在两段窗口各校验一次（上电中位 / 新占空）。
// =============================================================================
`timescale 1ns/1ps
module tb_pwm;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;   // 50MHz

    reg         update = 0;
    reg [12:0]  dx = 13'd1500, dy = 13'd1500;
    wire        pwm_x, pwm_y, tick;

    pwm_servo dut (.I_clk(clk), .I_rst_n(rst_n), .I_update(update),
        .I_duty_x_us(dx), .I_duty_y_us(dy),
        .O_pwm_x(pwm_x), .O_pwm_y(pwm_y),
        .O_period_tick(tick), .O_duty_x_dbg(), .O_duty_y_dbg());

    // ---------------- 连续监视器 ----------------
    reg [20:0] c_x, c_y, c_len;
    reg [20:0] l_x, l_y, l_len;
    reg [15:0] tick_no;
    integer    mism = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_x <= 0; c_y <= 0; c_len <= 0;
            l_x <= 0; l_y <= 0; l_len <= 0;
            tick_no <= 0;
        end else if (tick) begin
            // 含当拍锁存：latched 窗口 = 恰好一个完整周期
            l_x <= c_x   + (pwm_x ? 21'd1 : 21'd0);
            l_y <= c_y   + (pwm_y ? 21'd1 : 21'd0);
            l_len <= c_len + 21'd1;
            c_x <= 0;   c_y <= 0;   c_len <= 0;
            tick_no <= tick_no + 16'd1;
        end else begin
            c_x   <= c_x   + (pwm_x ? 21'd1 : 21'd0);
            c_y   <= c_y   + (pwm_y ? 21'd1 : 21'd0);
            c_len <= c_len + 21'd1;
        end
    end

    // ---------------- 校验调度（按 tick 序号） ----------------
    // 期望表：tick 2 为上电中位 1500µs（75000 拍）；tick 6 为新占空
    // 1200/2000µs（60000/100000 拍）。tick 3..5 为换挡过渡（RTL 采用
    // 周期边界换装：tick3 施加请求 -> tick5 起点生效 -> tick6 窗口纯新占空）。
    task check_tick;
        input [15:0] no;
        input [20:0] exp_x;
        input [20:0] exp_y;
        begin
            if ((l_len != 21'd1000000) || (l_x != exp_x) || (l_y != exp_y)) begin
                $display("MISM tick=%0d got x=%0d y=%0d len=%0d | exp x=%0d y=%0d len=1000000",
                         no, l_x, l_y, l_len, exp_x, exp_y);
                mism = mism + 1;
            end else begin
                $display("MEAS tick=%0d OK x=%0d y=%0d len=%0d", no, l_x, l_y, l_len);
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst_n && tick) begin
            case (tick_no)
                16'd2: check_tick(16'd2, 21'd75000, 21'd75000);  // 首个完整周期（上电中位）
                16'd3: begin
                    // 换占空：延后 2 拍施加载荷（req 寄存器），
                    // 周期 5 起点边界换装，周期 5->6 成为首个纯新占空完整周期
                    dx     <= 13'd1200; dy     <= 13'd2000;
                    update <= 1'b1;
                end
                16'd4: update <= 1'b0;
                16'd6: begin
                    check_tick(16'd6, 21'd60000, 21'd100000);    // 纯新占空完整周期
                    if (mism == 0)
                        $display("TB_RESULT: PASS");
                    else
                        $display("TB_RESULT: FAIL mism=%0d", mism);
                    $finish;
                end
                default: ;
            endcase
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        rst_n <= 1;
        #150000000;   // 6 个完整周期(120ms) + 余量
        $display("TB_RESULT: FAIL timeout mism=%0d", mism);
        $finish;
    end
endmodule
