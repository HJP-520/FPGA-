// =============================================================================
// gimbal_ctrl.v —— 云台闭环控制律（死区 + 比例 + 限速 + 限幅，双轴独立）
// -----------------------------------------------------------------------------
// 每帧一次（I_frame_tick，来自检测域经 pulse_sync 跨域）：
//   err   = invert ? (center - target) : (target - center)   [像素]
//   step  = (err * KP) >>> 8                                  [µs, Q8.8]
//   |err| <= DZ 时 step=0（死区）；|step|>SLEW 时截到 ±SLEW（限速）
//   duty  = clamp(duty + step, SERVO_MIN_US, SERVO_MAX_US)     [µs]
// 丢失目标（valid=0）：保持当前脉宽，lost_cnt 累加（饱和 16bit）。
// I_track_en=0 时强制回中位（安全/演示用）。上电/复位默认中位。
// 定点算术与 golden_model.py::gimbal_ctrl_step 逐位一致。
// 时钟域：接 PWM/50MHz 域（1µs=50 拍整数）。KD 预留（默认 0=纯 P）。
// =============================================================================
module gimbal_ctrl #(
    parameter KP_X         = 20,     // Q8.8 ≈ 0.156 µs/px（回路增益 0.15，稳定域）
    parameter KP_Y         = 18,     // Q8.8 ≈ 0.137 µs/px
    parameter KD_X        = 0,      // 预留微分项（默认关）
    parameter KD_Y        = 0,
    parameter DZ_X        = 25,     // 死区（像素）
    parameter DZ_Y        = 20,
    parameter SLEW_US      = 100,    // 单帧最大脉宽增量（µs）
    parameter SERVO_MIN_US= 700,    // 软件限位（先实测机械行程再定）
    parameter SERVO_MAX_US= 2300,
    parameter SERVO_MID_US= 1500,
    parameter CENTER_X    = 640,
    parameter CENTER_Y    = 360,
    parameter INVERT_X    = 0,      // 极性（现场整定：方向反了改这里）
    parameter INVERT_Y    = 0
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_frame_tick,     // 每帧 1 拍（已跨域）
    input  wire        I_track_en,
    input  wire        I_target_valid,
    input  wire [10:0] I_cx,
    input  wire [10:0] I_cy,
    output reg  [12:0] O_duty_x_us,
    output reg  [12:0] O_duty_y_us,
    output reg  [15:0] O_lost_cnt,
    output reg  [7:0]  O_status          // [0]dz_x [1]dz_y [2]lost [3]lim_x [4]lim_y
);

    // ---------------- 误差（组合） ----------------
    wire signed [12:0] err_x_c = INVERT_X ?
        ($signed({1'b0, CENTER_X[10:0]}) - $signed({1'b0, I_cx})) :
        ($signed({1'b0, I_cx})           - $signed({1'b0, CENTER_X[10:0]}));
    wire signed [12:0] err_y_c = INVERT_Y ?
        ($signed({1'b0, CENTER_Y[10:0]}) - $signed({1'b0, I_cy})) :
        ($signed({1'b0, I_cy})           - $signed({1'b0, CENTER_Y[10:0]}));

    localparam [12:0] SLEW_P  = SLEW_US;
    localparam [12:0] SMIN_P  = SERVO_MIN_US;
    localparam [12:0] SMAX_P  = SERVO_MAX_US;
    localparam [12:0] SMID_P  = SERVO_MID_US;

    // ---------------- 单轴步进（组合，供时序块锁存） ----------------
    task calc_axis;
        input  signed [12:0] err;
        input  [15:0]        kp;
        input  signed [12:0] err_prev;
        input  [15:0]        kd;
        input  [11:0]        dz;
        input  [12:0]        duty_in;
        output [12:0]        step;
        output               dz_hit;
        output               lim_hit;
        output [12:0]        duty_out;
        reg signed [28:0]    prod;
        reg signed [28:0]    s;
        reg signed [28:0]    nx;
        begin
            prod = err * $signed({1'b0, kp});
            s    = prod >>> 8;
            if (kd != 16'd0) begin
                prod = (err - err_prev) * $signed({1'b0, kd});
                s    = s + (prod >>> 8);
            end
            dz_hit = (err >= -$signed({1'b0, dz})) && (err <= $signed({1'b0, dz}));
            if (dz_hit)
                s = 29'sd0;                              // 死区
            if (s > $signed({16'd0, SLEW_P}))       s = $signed({16'd0, SLEW_P});
            else if (s < -$signed({16'd0, SLEW_P})) s = -$signed({16'd0, SLEW_P});
            step  = s[12:0];
            nx    = $signed({1'b0, duty_in}) + s;
            lim_hit = 1'b0;
            if (nx > $signed({16'd0, SMAX_P})) begin
                duty_out = SMAX_P; lim_hit = 1'b1;
            end else if (nx < $signed({16'd0, SMIN_P})) begin
                duty_out = SMIN_P; lim_hit = 1'b1;
            end else begin
                duty_out = nx[12:0];
            end
        end
    endtask

    reg [12:0] step_x, step_y;
    reg [12:0] duty_x, duty_y;
    reg [12:0] dnx_x, dnx_y;
    reg        dzx, dzy, limx, limy;
    reg signed [12:0] err_prev_x, err_prev_y;
    reg        lost;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            duty_x <= SMID_P; duty_y <= SMID_P;
            O_duty_x_us <= SMID_P; O_duty_y_us <= SMID_P;
            err_prev_x <= 13'sd0; err_prev_y <= 13'sd0;
            O_lost_cnt <= 16'd0; O_status <= 8'h04;
            dzx <= 1'b0; dzy <= 1'b0; limx <= 1'b0; limy <= 1'b0; lost <= 1'b1;
        end else if (I_frame_tick) begin
            if (!I_track_en) begin
                duty_x <= SMID_P;
                duty_y <= SMID_P;
                lost   = 1'b1;
                dzx = 1'b0; dzy = 1'b0; limx = 1'b0; limy = 1'b0;
                O_lost_cnt <= 16'd0;
            end else if (I_target_valid) begin
                calc_axis(err_x_c, KP_X, err_prev_x, KD_X, DZ_X, duty_x,
                          step_x, dzx, limx, dnx_x);
                calc_axis(err_y_c, KP_Y, err_prev_y, KD_Y, DZ_Y, duty_y,
                          step_y, dzy, limy, dnx_y);
                duty_x <= dnx_x;
                duty_y <= dnx_y;
                err_prev_x <= err_x_c;    // 供微分项（KD=0 时不参与）
                err_prev_y <= err_y_c;
                lost  = 1'b0;
                O_lost_cnt <= 16'd0;
            end else begin
                lost = 1'b1;              // 保持脉宽，只计丢失
                dzx = 1'b0; dzy = 1'b0; limx = 1'b0; limy = 1'b0;
                if (O_lost_cnt != 16'hFFFF)
                    O_lost_cnt <= O_lost_cnt + 16'd1;
            end
            O_duty_x_us <= (I_track_en && I_target_valid) ? dnx_x : duty_x;
            O_duty_y_us <= (I_track_en && I_target_valid) ? dnx_y : duty_y;
            O_status    <= {2'b00, limy, limx, lost, dzy, dzx};
        end
    end

endmodule
