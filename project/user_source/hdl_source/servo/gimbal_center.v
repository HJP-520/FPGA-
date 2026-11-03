// 整合适配 2026-10-17：来源 D:/舵机控制代码整合；保留移植命名/寄存器分组例外。
// 修正分轴死区及正负比例舍入不对称；限位仍为 X[0,180]、Y[95,180]。
// ============================================================
// gimbal_center.v -- 云台对中控制律（坐标 -> 角度增量闭环）
//
// 链路位置：视觉目标坐标 -> 本模块 -> pwm_servo(角度版) -> MG996R
//   输入是视觉方向给的目标像素坐标 (I_target_x/y + valid)，
//   输出是双轴角度 (O_angle_x/y)，直接接 pwm_servo 的 I_angle_x/y。
//
// 控制思想（一帧走一步）：
//   err = 目标坐标 - 画面中心。err 为正说明物体偏右/偏下，
//   云台就朝该方向转一点；err 落进死区就认为已对中，不再动。
//   每帧只动一点点（限速），多帧收敛，不会一拍甩过头。
//
// 一帧内五步（和报告里控制模块小节一一对应）：
//   1) 求偏差 err；2) 死区判定；3) 比例换算 delta；
//   4) 限速钳住；5) 角度累加后限幅。
// 时钟：与 pwm_servo 同一个 I_clk（50MHz），I_frame_tick 每帧来一拍。
// ============================================================
`timescale 1ns / 1ps

module gimbal_center #(
    parameter POSE_SYNC_EN = 0,
    parameter STABILITY_EN = 0, // 0 preserves fix4 control for regression
    parameter CENTER_X   = 640,    // 画面中心 X = IMG_W/2（1280x720）
    parameter CENTER_Y   = 360,    // 画面中心 Y = IMG_H/2
    parameter DEADZONE   = 25,     // 死区 ±25px（quiet 版基线；2026-10-24 按用户要求回到 25）
    parameter HYST       = 10,     // 死区迟滞（停止 ≤D、再启动 >D+HYST=35），防边界来回抖
    parameter KP_X       = 3,      // X 比例系数（2026-10-21：由 20 降到 3，实测原值导致极限环）
    parameter KP_Y       = 3,      // Y 比例系数（同上；原 18 → 3）
    parameter KP_SHIFT   = 8,      // 定点小数位：delta = err*KP/256（Q8.8 思想）
    parameter MAX_STEP   = 5,      // 限速：每帧最多转 5 度
    parameter MAN_STEP   = 2,      // 2026-10-22：手动模式每次按键步进 2°
    parameter ANGLE_MIN_X = 0,     // X 轴软件限位下限（2026-10-16 实测：全范围无干涉）
    parameter ANGLE_MAX_X = 180,   // X 轴软件限位上限（同上）
    parameter ANGLE_MIN_Y = 95,    // Y 轴软件限位下限（2026-10-16 实测：低于 95 度撞机构）
    parameter ANGLE_MAX_Y = 180,   // Y 轴软件限位上限（2026-10-16 实测：满程已目检确认）
    parameter HOME_X      = 90,    // 整合补充：水平上电角
    parameter HOME_Y      = 95,    // 上电/复位回中角（必须落在 [ANGLE_MIN_Y, ANGLE_MAX_Y] 内）
    parameter INVERT_X   = 0,      // 极性：装机后若方向反了，改 1，不改代码
    parameter FAST_ENTER_X=320, FAST_EXIT_X=256, FAST_OUTER_X=480,
    parameter FAST_ENTER_Y=192, FAST_EXIT_Y=144, FAST_OUTER_Y=288,
    parameter INVERT_Y   = 0
)(
    input  wire        I_clk,
    input  wire        I_rst_n,          // 低有效异步复位
    input  wire        I_frame_tick,     // 帧拍：每帧一拍，控制节拍
    input  wire        I_target_valid,   // 视觉目标有效（0=丢目标）
    input  wire [10:0] I_target_x,       // 目标 X（像素）
    input  wire [10:0] I_target_y,       // 目标 Y（像素）
    input  wire        I_inv_x,          // 运行时极性（异或到 INVERT_X；跟踪模式 K3 切换）
    input  wire        I_inv_y,          // 运行时极性（异或到 INVERT_Y；跟踪模式 K4 切换）
    // 2026-10-22：手动云台模式（SW1~SW4 全开）：按键步进，与跟踪积分互斥
    input  wire        I_manual_en,
    input  wire        I_step_xp,        // X 向右（角度增大）
    input  wire        I_step_xn,        // X 向左
    input  wire        I_step_yp,        // Y 向上（角度增大）
    input  wire        I_step_yn,        // Y 向下
    output reg  [7:0]  O_angle_x,        // 水平轴角度 0-180（度，调试观测用）
    output reg  [7:0]  O_angle_y,        // 垂直轴角度
    output wire [10:0] O_angle_q3_x,     // 2026-10-21：Q3 角度（1/8°），直接送 pwm_servo
    output wire [10:0] O_angle_q3_y,
    output reg         O_locked,         // 1=已对中（偏差在死区内）
    output reg         O_lost,           // 1=丢目标（valid=0，保持不动）
    output reg  signed [11:0] O_dbg_err_x, // 当前偏差（ChipWatcher 观测用）
    output reg  signed [11:0] O_dbg_err_y,
    input wire I_pose_sync,
    input wire [10:0] I_pose_x,I_pose_y // last PWM-commanded pose; not mechanical feedback
);

    // ---------- 帧拍边沿检测：跨域拉宽也只触发一次 ----------
    reg tick_d;
    wire tick_pulse = I_frame_tick & ~tick_d;

    // ---------- 有符号偏差（组合先算，时序里锁存） ----------
    // 11bit 无符号坐标 0-2047，减中心后范围约 -640~+1407，用 12bit 有符号装下
    wire signed [11:0] err_x_w = $signed({1'b0, I_target_x}) - $signed(CENTER_X[11:0]);
    wire signed [11:0] err_y_w = $signed({1'b0, I_target_y}) - $signed(CENTER_Y[11:0]);

    // 绝对值（死区判定用）
    wire [11:0] abs_x = err_x_w[11] ? (~err_x_w + 12'd1) : err_x_w;
    wire [11:0] abs_y = err_y_w[11] ? (~err_y_w + 12'd1) : err_y_w;

    // 2026-10-21：死区迟滞状态（1=已到位，只有超出 D+HYST 才重新启动），抑制静止时的小幅抖动
    reg hys_x, hys_y;
    always @(posedge I_clk or negedge I_rst_n)
        if (!I_rst_n) begin hys_x <= 1'b0; hys_y <= 1'b0; end
        else begin
            if (abs_x <= DEADZONE)            hys_x <= 1'b1;
            else if (abs_x > DEADZONE + HYST) hys_x <= 1'b0;
            if (abs_y <= DEADZONE)            hys_y <= 1'b1;
            else if (abs_y > DEADZONE + HYST) hys_y <= 1'b0;
        end

    // ---------- 比例换算（2026-10-21 调参）----------
    // 角度改为 Q3（1/8°）内部累加：低增益时步长可小于 1°，避免"1° 量化 + 高增益"的来回摆动；
    // KP 由 20/18 降到 3/3（原值：Kp×像素/度×延迟 已 >1，实测出现极限环）。
    reg [10:0] angle_q3_x, angle_q3_y;                 // Q3 角度累加器（0..1440 = 0..180°）
    wire [31:0] magq3_x = (abs_x * KP_X) >> (KP_SHIFT - 3);   // Q3 步长
    wire [31:0] magq3_y = (abs_y * KP_Y) >> (KP_SHIFT - 3);
    wire signed [31:0] signedq3_x = err_x_w[11] ? -magq3_x : magq3_x;
    wire signed [31:0] signedq3_y = err_y_w[11] ? -magq3_y : magq3_y;
    // 2026-10-21：有效极性 = 参数 XOR 运行时输入（跟踪模式 K3/K4 现场翻转，不必重建）
    wire invx = INVERT_X ^ I_inv_x;
    wire invy = INVERT_Y ^ I_inv_y;
    // Profile4 accelerates escaping targets outside per-axis hysteretic bands.
    // Two successive outward displacements (>2px each) qualify a fast action.
    // Mid/outer caps3/4deg, minimum80ms; near/static retain profile3. A previous
    // fast action brakes for120ms before entering the slow zone or reversing.
    // Profile 3 preserves profile-2 cadence and near/far behavior; only the
    // >400px: 2.5deg; 321..400px: 2.25deg; <=320px is unchanged.
    // Profile 2: 32/96/240 px bands use 1/6/8 Q3 caps and 80/120/80 ms intervals.
    // Profile 1: observe 200 ms after a near correction, 80 ms after a far
    // correction. The next command therefore arrives no sooner than 240/120 ms.
    // Delay counts advance only on fresh valid control observations.
    reg [2:0] wait_x,wait_y;
    reg dir_x,dir_y,have_dir_x,have_dir_y;
    reg [1:0] reverse_x,reverse_y;
    wire opposite_x=have_dir_x && (err_x_w[11]!=dir_x);
    wire opposite_y=have_dir_y && (err_y_w[11]!=dir_y);
    wire [11:0] residual_x=abs_x>DEADZONE?abs_x-DEADZONE:0;
    wire [11:0] residual_y=abs_y>DEADZONE?abs_y-DEADZONE:0;
    wire [31:0] quiet_mag_x=(residual_x*KP_X)>>(KP_SHIFT-3);
    wire [31:0] quiet_mag_y=(residual_y*KP_Y)>>(KP_SHIFT-3);
    // Profile5 pairs profile4 with the50Hz command shaper. Retain initially
    // qualified pursuit through flat/slowly closing error (<=8px/observation),
    // and clear on fast closing, braking, inner zone, reversal or cancellation.
    // Profile4: qualify outward motion before boosting. A distant stationary
    // object therefore retains profile3, including its delayed-plant behavior.
    reg [11:0] prev_abs_x,prev_abs_y;
    reg prev_sign_x,prev_sign_y,have_observation;
    reg [1:0] grow_x,grow_y;
    reg motion_qual_x,motion_qual_y;
    reg far_x,far_y,last_boost_x,last_boost_y;
    wire same_sign_x=have_observation&&(prev_sign_x==err_x_w[11]);
    wire same_sign_y=have_observation&&(prev_sign_y==err_y_w[11]);
    wire outward_x=same_sign_x&&(abs_x>prev_abs_x+12'd2);
    wire outward_y=same_sign_y&&(abs_y>prev_abs_y+12'd2);
    wire [11:0] closing_x=same_sign_x&&prev_abs_x>abs_x?prev_abs_x-abs_x:12'd0;
    wire [11:0] closing_y=same_sign_y&&prev_abs_y>abs_y?prev_abs_y-abs_y:12'd0;
    // Brake before three recent observation-displacements would enter slow zone.
    wire [13:0] approach_x={2'b0,closing_x}+{1'b0,closing_x,1'b0};
    wire [13:0] approach_y={2'b0,closing_y}+{1'b0,closing_y,1'b0};
    wire boost_x=(STABILITY_EN==4 || STABILITY_EN==5) && same_sign_x && !opposite_x &&
        (far_x||abs_x>FAST_ENTER_X) && abs_x>FAST_EXIT_X &&
        ((outward_x&&grow_x>=1)||(STABILITY_EN==5&&motion_qual_x&&closing_x<=8)) &&
        ({2'b0,abs_x}>FAST_EXIT_X+approach_x);
    wire boost_y=(STABILITY_EN==4 || STABILITY_EN==5) && same_sign_y && !opposite_y &&
        (far_y||abs_y>FAST_ENTER_Y) && abs_y>FAST_EXIT_Y &&
        ((outward_y&&grow_y>=1)||(STABILITY_EN==5&&motion_qual_y&&closing_y<=8)) &&
        ({2'b0,abs_y}>FAST_EXIT_Y+approach_y);
    wire brake_x=(STABILITY_EN==4 || STABILITY_EN==5) && last_boost_x && (!same_sign_x || abs_x<=FAST_EXIT_X || (closing_x!=0 && {2'b0,abs_x}<=FAST_EXIT_X+approach_x));
    wire brake_y=(STABILITY_EN==4 || STABILITY_EN==5) && last_boost_y && (!same_sign_y || abs_y<=FAST_EXIT_Y || (closing_y!=0 && {2'b0,abs_y}<=FAST_EXIT_Y+approach_y));
    always @(posedge I_clk or negedge I_rst_n)begin
        if(!I_rst_n)begin
            prev_abs_x<=0;prev_abs_y<=0;prev_sign_x<=0;prev_sign_y<=0;have_observation<=0;
            grow_x<=0;grow_y<=0;motion_qual_x<=0;motion_qual_y<=0;far_x<=0;far_y<=0;last_boost_x<=0;last_boost_y<=0;
        end else if((POSE_SYNC_EN && I_pose_sync)||I_manual_en||(tick_pulse&&!I_target_valid))begin
            prev_abs_x<=0;prev_abs_y<=0;prev_sign_x<=0;prev_sign_y<=0;have_observation<=0;
            grow_x<=0;grow_y<=0;motion_qual_x<=0;motion_qual_y<=0;far_x<=0;far_y<=0;last_boost_x<=0;last_boost_y<=0;
        end else if(tick_pulse&&I_target_valid)begin
            prev_abs_x<=abs_x;prev_abs_y<=abs_y;prev_sign_x<=err_x_w[11];prev_sign_y<=err_y_w[11];have_observation<=1;
            if(boost_x&&clmp_x_w!=angle_q3_x)last_boost_x<=1;else if(brake_x)last_boost_x<=0;
            if(boost_y&&clmp_y_w!=angle_q3_y)last_boost_y<=1;else if(brake_y)last_boost_y<=0;
            if(abs_x>FAST_ENTER_X)far_x<=1;else if(abs_x<=FAST_EXIT_X)far_x<=0;
            if(abs_y>FAST_ENTER_Y)far_y<=1;else if(abs_y<=FAST_EXIT_Y)far_y<=0;
            if(!same_sign_x||abs_x<=FAST_EXIT_X||brake_x||closing_x>8)motion_qual_x<=0;
            else if(outward_x&&grow_x>=1)motion_qual_x<=1;
            if(!same_sign_y||abs_y<=FAST_EXIT_Y||brake_y||closing_y>8)motion_qual_y<=0;
            else if(outward_y&&grow_y>=1)motion_qual_y<=1;
            if(outward_x)begin if(grow_x<2)grow_x<=grow_x+1'b1;end else grow_x<=0;
            if(outward_y)begin if(grow_y<2)grow_y<=grow_y+1'b1;end else grow_y<=0;
        end
    end
    wire near_x=abs_x<=160,near_y=abs_y<=160;
    wire [31:0] base_cap_x=(STABILITY_EN==2 || STABILITY_EN==3 || STABILITY_EN==4 || STABILITY_EN==5) ? (abs_x<=32?32'd1:abs_x<=96?32'd6:abs_x<=240?32'd8:(STABILITY_EN>=3?(abs_x>400?32'd20:abs_x>320?32'd18:32'd16):MAX_STEP*8)) : (near_x?32'd4:MAX_STEP*8);
    wire [31:0] base_cap_y=(STABILITY_EN==2 || STABILITY_EN==3 || STABILITY_EN==4 || STABILITY_EN==5) ? (abs_y<=32?32'd1:abs_y<=96?32'd6:abs_y<=240?32'd8:(STABILITY_EN>=3?(abs_y>400?32'd20:abs_y>320?32'd18:32'd16):MAX_STEP*8)) : (near_y?32'd4:MAX_STEP*8);
    wire [31:0] quiet_cap_x=boost_x?(abs_x>FAST_OUTER_X?32'd32:32'd24):base_cap_x;
    wire [31:0] quiet_cap_y=boost_y?(abs_y>FAST_OUTER_Y?32'd32:32'd24):base_cap_y;
    wire [31:0] quiet_size_x=quiet_mag_x>quiet_cap_x?quiet_cap_x:(quiet_mag_x==0 && residual_x!=0?32'd1:quiet_mag_x);
    wire [31:0] quiet_size_y=quiet_mag_y>quiet_cap_y?quiet_cap_y:(quiet_mag_y==0 && residual_y!=0?32'd1:quiet_mag_y);
    wire blocked_x=brake_x || wait_x!=0 || (opposite_x && reverse_x<2);
    wire blocked_y=brake_y || wait_y!=0 || (opposite_y && reverse_y<2);
    wire signed [31:0] desired_x=(err_x_w[11]^invx)?-$signed(quiet_size_x):$signed(quiet_size_x);
    wire signed [31:0] desired_y=(err_y_w[11]^invy)?-$signed(quiet_size_y):$signed(quiet_size_y);
    wire signed [31:0] step_x_w = hys_x ? 0 : STABILITY_EN ? (blocked_x?32'sd0:desired_x) : (invx ? -signedq3_x : signedq3_x);
    wire signed [31:0] step_y_w = hys_y ? 0 : STABILITY_EN ? (blocked_y?32'sd0:desired_y) : (invy ? -signedq3_y : signedq3_y);

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n)begin
            wait_x<=0;wait_y<=0;dir_x<=0;dir_y<=0;
            have_dir_x<=0;have_dir_y<=0;reverse_x<=0;reverse_y<=0;
        end else if((POSE_SYNC_EN && I_pose_sync)||I_manual_en || (tick_pulse && !I_target_valid))begin
            wait_x<=0;wait_y<=0;have_dir_x<=0;have_dir_y<=0;reverse_x<=0;reverse_y<=0;
        end else if(tick_pulse && I_target_valid && STABILITY_EN)begin
            if(wait_x!=0)wait_x<=wait_x-1'b1;
            if(wait_y!=0)wait_y<=wait_y-1'b1;
            if(brake_x)wait_x<=3'd2;
            if(brake_y)wait_y<=3'd2;
            if(!opposite_x || hys_x)reverse_x<=0;
            else if(reverse_x<2)reverse_x<=reverse_x+1'b1;
            if(!opposite_y || hys_y)reverse_y<=0;
            else if(reverse_y<2)reverse_y<=reverse_y+1'b1;
            if(clmp_x_w!=angle_q3_x)begin
                wait_x<=boost_x?3'd1:(STABILITY_EN==2 || STABILITY_EN==3 || STABILITY_EN==4 || STABILITY_EN==5)?(abs_x<=32?3'd1:abs_x<=96?3'd2:abs_x<=240?3'd1:3'd2):(near_x?3'd5:3'd2);dir_x<=err_x_w[11];have_dir_x<=1;reverse_x<=0;
            end
            if(clmp_y_w!=angle_q3_y)begin
                wait_y<=boost_y?3'd1:(STABILITY_EN==2 || STABILITY_EN==3 || STABILITY_EN==4 || STABILITY_EN==5)?(abs_y<=32?3'd1:abs_y<=96?3'd2:abs_y<=240?3'd1:3'd2):(near_y?3'd5:3'd2);dir_y<=err_y_w[11];have_dir_y<=1;reverse_y<=0;
            end
        end
    end

    // 限速到 ±MAX_STEP 度（换算成 Q3 单位）
    wire signed [31:0] lim_x_w =
        (step_x_w >  MAX_STEP*8) ?  MAX_STEP*8 :
        (step_x_w < -MAX_STEP*8) ? -MAX_STEP*8 : step_x_w;
    wire signed [31:0] lim_y_w =
        (step_y_w >  MAX_STEP*8) ?  MAX_STEP*8 :
        (step_y_w < -MAX_STEP*8) ? -MAX_STEP*8 : step_y_w;

    // 新角度 = 当前累加值 + 限速步长，再做软件限位（Q3）
    wire signed [31:0] nxt_x_w = $signed({1'b0, angle_q3_x}) + lim_x_w;
    wire signed [31:0] nxt_y_w = $signed({1'b0, angle_q3_y}) + lim_y_w;
    wire [10:0] clmp_x_w =
        (nxt_x_w > ANGLE_MAX_X*8) ? ANGLE_MAX_X*8 :
        (nxt_x_w < ANGLE_MIN_X*8) ? ANGLE_MIN_X*8 : nxt_x_w[10:0];
    wire [10:0] clmp_y_w =
        (nxt_y_w > ANGLE_MAX_Y*8) ? ANGLE_MAX_Y*8 :
        (nxt_y_w < ANGLE_MIN_Y*8) ? ANGLE_MIN_Y*8 : nxt_y_w[10:0];

    assign O_angle_q3_x = angle_q3_x;
    assign O_angle_q3_y = angle_q3_y;

    // 2026-10-22：手动步进（MAN_STEP 度/脉冲，Q3 单位）——与跟踪共用同一累加器和限位
    wire signed [31:0] man_x_w = $signed({1'b0, angle_q3_x})
        + (I_step_xp ? MAN_STEP*8 : 0) - (I_step_xn ? MAN_STEP*8 : 0);
    wire signed [31:0] man_y_w = $signed({1'b0, angle_q3_y})
        + (I_step_yp ? MAN_STEP*8 : 0) - (I_step_yn ? MAN_STEP*8 : 0);
    wire [10:0] manclm_x_w = (man_x_w > ANGLE_MAX_X*8) ? ANGLE_MAX_X*8 :
                             (man_x_w < ANGLE_MIN_X*8) ? ANGLE_MIN_X*8 : man_x_w[10:0];
    wire [10:0] manclm_y_w = (man_y_w > ANGLE_MAX_Y*8) ? ANGLE_MAX_Y*8 :
                             (man_y_w < ANGLE_MIN_Y*8) ? ANGLE_MIN_Y*8 : man_y_w[10:0];

    // ---------- 时序：只在帧拍那一拍更新 ----------
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            tick_d      <= 1'b0;
            angle_q3_x  <= HOME_X*8;   // Q3 累加器回到上电角
            angle_q3_y  <= HOME_Y*8;
            O_angle_x   <= HOME_X;     // 上电回中，安全
            O_angle_y   <= HOME_Y;
            O_locked    <= 1'b0;
            O_lost      <= 1'b1;
            O_dbg_err_x <= 12'd0;
            O_dbg_err_y <= 12'd0;
        end else begin
            tick_d <= I_frame_tick;
            if (POSE_SYNC_EN && I_pose_sync) begin
                angle_q3_x<=I_pose_x;angle_q3_y<=I_pose_y;
                O_angle_x<=I_pose_x[10:3];O_angle_y<=I_pose_y[10:3];O_locked<=0;O_lost<=1;
            end else if (I_manual_en) begin
                // 手动云台：按键步进；跟踪积分冻结（从当前位置起步，不跳变）
                angle_q3_x <= manclm_x_w;
                angle_q3_y <= manclm_y_w;
                O_angle_x  <= manclm_x_w[10:3];
                O_angle_y  <= manclm_y_w[10:3];
                O_lost     <= 1'b1;
                O_locked   <= 1'b0;
            end else if (tick_pulse) begin
                O_dbg_err_x <= err_x_w;
                O_dbg_err_y <= err_y_w;
                if (!I_target_valid) begin
                    O_lost   <= 1'b1;  // 丢目标：角度冻结，保持最后位置
                    O_locked <= 1'b0;
                end else if ((abs_x <= DEADZONE[11:0]) && (abs_y <= DEADZONE[11:0])) begin
                    O_lost   <= 1'b0;
                    O_locked <= 1'b1;  // 已对中：不动
                end else begin
                    O_lost   <= 1'b0;
                    O_locked <= 1'b0;
                    angle_q3_x <= clmp_x_w;          // Q3 累加（1/8° 分辨率）
                    angle_q3_y <= clmp_y_w;
                    O_angle_x  <= clmp_x_w[10:3];    // 输出整数度给 PWM
                    O_angle_y  <= clmp_y_w[10:3];
                end
            end
        end
    end

endmodule
