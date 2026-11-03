// 整合适配 2026-10-17：来源 D:/舵机控制代码整合；整合实例 HOME_Y=95，首周期亦守限位。
// ============================================================
// pwm_servo.v — 双路舵机 PWM 发生器（角度输入版）
//
// 目标舵机：MG996R（180° 定位版）
//   信号规格：50Hz（20ms 周期），脉宽 0.5–2.5ms ↔ 0–180°，中位 1.5ms
// 时钟：50MHz（I_clk），1 拍 = 20ns，1μs = 50 拍，20ms = 1,000,000 拍
//
// 设计要点（为什么这么写）：
//   1) 单计数器 + 双比较器：两路看同一个计数值，上升沿天然同拍，
//      双轴云台复合运动无相位差；
//   2) duty 只在周期边界（cnt 回零前最后一拍）锁存：每个脉冲从头到尾
//      用同一个 duty，输入随时改都不会撕裂当前脉冲；
//   3) 角度→拍数：ticks = 25000 + (angle×1111)>>1 ≈ 25000 + angle×555.5
//      （理想系数 100000/180 ≈ 555.56；满量程误差 ≤10 拍 ≈ 0.036°，
//      远小于舵机机械精度 ±0.5°，不需要除法器）；
//   4) 上电/复位默认 90° 中位（安全：云台不猛甩）；
//      输入 >180 按 180 钳位（软件限位第一步）。
// ============================================================
`timescale 1ns / 1ps

module pwm_servo #(
    parameter HOME_X = 90,
    parameter HOME_Y = 90,
    parameter CNT_PERIOD = 20'd1_000_000   // 20ms @ 50MHz；换时钟只改这里
)(
    input  wire        I_clk,
    input  wire        I_rst_n,            // 低有效异步复位
    input  wire [10:0] I_angle_x,          // 水平轴角度 Q3（1/8°，0–1440 = 0–180°）
    input  wire [10:0] I_angle_y,          // 垂直轴角度 Q3（同上）
    output wire        O_pwm_x,            // 水平轴 PWM（接舵机信号线）
    output wire        O_pwm_y,            // 垂直轴 PWM
    output wire [19:0] O_dbg_ticks_x,      // 当前生效脉宽（拍），ChipWatcher/调试用
    output wire O_step_tick,             // 周期边界前 4 拍更新角度，避免迟一个周期
    output wire [19:0] O_dbg_ticks_y
);

// ---------- 常量 ----------
localparam TICK_MIN = 20'd25_000;                    // 0.5ms（0°）
localparam DUTY_MID = 20'd25_000 + ((90*1111)>>1);   // 90° 中位 = 74,995
localparam [19:0] CNT_MAX = CNT_PERIOD - 20'd1;

// ---------- 角度钳位 + 角度→脉宽换算（纯组合，2026-10-21：输入改 Q3） ----------
// Q3：1 单位 = 1/8°；ticks = 25000 + (q3*1111)>>4（= 25000 + 度*555.5）
wire [10:0]  ax    = (I_angle_x > 11'd1440) ? 11'd1440 : I_angle_x;
wire [10:0]  ay    = (I_angle_y > 11'd1440) ? 11'd1440 : I_angle_y;
wire [20:0] off_x = ax * 11'd1111;                   // ≤ 1,599,840 < 2^21
wire [20:0] off_y = ay * 11'd1111;
wire [19:0] tick_x = TICK_MIN + (off_x >> 4);        // ÷16：Q3 → ×555.5/8
wire [19:0] tick_y = TICK_MIN + (off_y >> 4);

// ---------- 20ms 自由运转计数器（时间刻度，两路共用） ----------
reg [19:0] cnt;
wire period_wrap = (cnt >= CNT_MAX);

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)         cnt <= 20'd0;
    else if (period_wrap) cnt <= 20'd0;
    else                  cnt <= cnt + 20'd1;
end

// ---------- duty 寄存器：仅周期边界锁存，防脉冲撕裂 ----------
reg [19:0] duty_x, duty_y;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)         duty_x <= 25000 + ((HOME_X*1111)>>1);   // 度→拍（与 Q3 公式等价）
    else if (period_wrap) duty_x <= tick_x;
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)         duty_y <= 25000 + ((HOME_Y*1111)>>1);
    else if (period_wrap) duty_y <= tick_y;
end

// ---------- 比较器输出（复位期间强制拉低，释放后从完整周期开始） ----------
assign O_pwm_x = I_rst_n && (cnt < duty_x);
assign O_pwm_y = I_rst_n && (cnt < duty_y);

assign O_step_tick = I_rst_n && (cnt == CNT_MAX-4);
assign O_dbg_ticks_x = duty_x;
assign O_dbg_ticks_y = duty_y;

endmodule
