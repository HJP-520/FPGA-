// =============================================================================
// led_buzzer.v —— 目标状态声光反馈（扩展"外部控制"演示）
// 锁定：绿灯亮；丢失：红灯亮（1Hz 闪烁提示）；锁定沿：蜂鸣器短鸣 200ms。
// 板载双色 LED / 蜂鸣器为 GPIO 直驱（若为有源蜂鸣器低有效，接 BEEP_N 低有效参数）。
// =============================================================================
module led_buzzer #(
    parameter integer BEEP_CYCLES = 20000000   // 200ms @100MHz，参数化
)(
    input  wire I_clk,
    input  wire I_rst_n,
    input  wire I_frame_tick,       // 每帧一拍
    input  wire I_target_valid,     // 本帧检测有效
    output reg  O_led_g,            // 锁定绿灯
    output reg  O_led_r,            // 丢失红灯
    output reg  O_buzzer            // 蜂鸣器（高有效脉冲）
);
    reg [25:0] beep_cnt;
    reg        valid_d;
    reg [25:0] blink_cnt;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_led_g <= 1'b0; O_led_r <= 1'b0; O_buzzer <= 1'b0;
            valid_d <= 1'b0; beep_cnt <= 0; blink_cnt <= 0;
        end else begin
            valid_d <= I_target_valid;

            // 锁定沿：蜂鸣 200ms
            if (I_frame_tick && I_target_valid && !valid_d)
                beep_cnt <= BEEP_CYCLES[25:0];
            if (beep_cnt != 0) begin
                O_buzzer <= 1'b1;
                beep_cnt <= beep_cnt - 26'd1;
            end else begin
                O_buzzer <= 1'b0;
            end

            // LED：锁定常亮绿；丢失红灯 1Hz 闪烁（远看醒目）
            blink_cnt <= blink_cnt + 26'd1;
            O_led_g <= I_target_valid;
            if (I_target_valid)
                O_led_r <= 1'b0;
            else
                O_led_r <= blink_cnt[24];   // ~0.67s 半周期 @100MHz
        end
    end
endmodule
