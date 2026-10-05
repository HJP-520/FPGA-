// =============================================================================
// pwm_servo.v —— 双路 50Hz 舵机 PWM（共周期，上电中位，输入限幅）
// -----------------------------------------------------------------------------
// 规格（与《环境配置与文件清单》5.2 节钉死）：
//   周期 20ms（50Hz），脉宽 0.5~2.5ms 对应 0~180°；
//   时钟 50MHz：周期 = 1,000,000 拍，1µs = 50 拍，分辨率 0.02µs(20ns)；
//   两路共用同一周期计数器（严格共周期，避免 X/Y 互相拉扯）；
//   输入 duty(µs) 在 I_update（帧拍）时锁存，内部再 clamp 到 500~2500µs
//   （第二道保险，第一道在 gimbal_ctrl 的 700~2300 软限位）；
//   复位后输出中位 1500µs 脉冲，上电即安全中位。
// 极性：高电平有效脉冲。时钟域：50MHz（I_clk）。
// =============================================================================
module pwm_servo #(
    parameter CLK_HZ        = 50_000_000,
    parameter SERVO_FREQ_HZ = 50,           // 50Hz => 周期 20ms
    parameter TICKS_PER_US  = 50            // CLK_HZ/1e6
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_update,          // 帧拍：锁存新占空
    input  wire [12:0] I_duty_x_us,
    input  wire [12:0] I_duty_y_us,
    output wire        O_pwm_x,           // 高电平有效
    output wire        O_pwm_y,
    output wire        O_period_tick,     // 周期起点脉冲（测量用）
    output reg  [12:0] O_duty_x_dbg,
    output reg  [12:0] O_duty_y_dbg
);

    localparam PERIOD_TICKS = CLK_HZ / SERVO_FREQ_HZ;   // 1,000,000
    localparam PW_CNT_W = 20;

    // 输入限幅（第二道保险）
    wire [12:0] dx = (I_duty_x_us > 13'd2500) ? 13'd2500 :
                     (I_duty_x_us < 13'd500)  ? 13'd500  : I_duty_x_us;
    wire [12:0] dy = (I_duty_y_us > 13'd2500) ? 13'd2500 :
                     (I_duty_y_us < 13'd500)  ? 13'd500  : I_duty_y_us;

    // 共周期计数器
    reg [PW_CNT_W-1:0] period_cnt;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)
            period_cnt <= {PW_CNT_W{1'b0}};
        else if (period_cnt >= PERIOD_TICKS - 1)
            period_cnt <= {PW_CNT_W{1'b0}};
        else
            period_cnt <= period_cnt + 20'd1;
    end

    reg [12:0] duty_x, duty_y;
    reg [12:0] req_x, req_y;    // 请求值（帧拍写入）
    reg        update_d;        // 外脑评审：gimbal 的 O_duty 与 update 同沿更新，
    always @(posedge I_clk or negedge I_rst_n) begin   // 同沿采样会拿到上一帧值
        if (!I_rst_n) begin
            req_x <= 13'd1500;   req_y <= 13'd1500;
            update_d <= 1'b0;
        end else begin
            update_d <= I_update;
            if (update_d) begin
                req_x <= dx;     req_y <= dy;   // 延后一拍采到刚更新的占空
            end
        end
    end

    // 占空在周期起点换装（外脑评审: 防止帧拍落在周期中途,
    // 本周期脉宽被截断产生毛刺；变化延迟 ≤1 个 20ms 周期，舵机无感）
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            duty_x <= 13'd1500;  duty_y <= 13'd1500;
            O_duty_x_dbg <= 13'd1500; O_duty_y_dbg <= 13'd1500;
        end else if (period_cnt == {PW_CNT_W{1'b0}}) begin
            duty_x <= req_x;     duty_y <= req_y;
            O_duty_x_dbg <= req_x; O_duty_y_dbg <= req_y;
        end
    end

    // 脉宽换算：µs -> 拍（*50 = *32 + *16 + *2）
    wire [PW_CNT_W-1:0] pulse_x = duty_x * TICKS_PER_US;
    wire [PW_CNT_W-1:0] pulse_y = duty_y * TICKS_PER_US;

    assign O_period_tick = (period_cnt == {PW_CNT_W{1'b0}});
    assign O_pwm_x = (period_cnt < pulse_x);
    assign O_pwm_y = (period_cnt < pulse_y);

endmodule
