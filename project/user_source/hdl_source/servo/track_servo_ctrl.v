// track_servo_ctrl.v -- 视觉结果到双轴舵机，2026-10-17，自研适配层。
// 相机域只发送完整帧结果，cdc_4phase 整包握手到 50MHz；不反压视频。
// 新增模块沿用 track/docs/03：独立寄存器 always、业务逻辑下沉、异步复位同步释放。
// 当前颜色预设只有 0(红)/2(蓝)，静态配置切换逐位 2FF 后清状态；
// 目标坐标/帧号始终整包 CDC，绝不逐位同步坐标。两域共用异步复位源。
module track_servo_ctrl #(
    parameter integer MAN_SMOOTH_EN = 0, // opt-in continuous fine manual motion
    parameter integer SMOOTH_EN = 0, // opt-in output shaping; legacy default unchanged
    parameter integer PWM_PERIOD = 1000000, // 50MHz/50Hz = 1,000,000
    parameter integer TIMEOUT_CYCLES = 12500000, // 50MHz*250ms
    parameter integer ACQUIRE_FRAMES = 2,
    parameter integer MAN_REPEAT_DELAY = 20000000, // 400 ms at 50 MHz
    parameter integer MAN_REPEAT_PERIOD = 6000000, // 120 ms at 50 MHz
    parameter integer INVERT_X = 0,
    parameter integer INVERT_Y = 1, // 用户确认：角度增大向上，图像 y 增大向下
    parameter integer MAX_STEP = 2,
    parameter integer STABILITY_EN = 0, // enable measured-action/observation tracking profile
    parameter integer CTL_DIV = 2,  // 2026-10-21：控制更新分频（每 CTL_DIV 个 PWM 周期更新一次；2 → 25Hz）
    parameter integer HOME_X = 90, // 上电/复位角；顶层 SERVO_HOME_X 覆盖（2026-10-15 起为 100）
    parameter integer HOME_Y = 95  // 上电/复位角；顶层 SERVO_HOME_Y 覆盖（2026-10-15 起为 100）
)(
    input wire i_det_clk, i_clk_50m, i_arst_n,
    input wire i_tracking,
    input wire [2:0] i_preset,
    input wire i_frame_bad, i_result_load,
    input wire [134:0] i_result,
    input wire i_inv_x, i_inv_y,        // 2026-10-21 运行时极性：跟踪模式 K3/K4 切换
    input wire i_manual_en,             // 2026-10-22 手动云台模式（SW1~SW4 全开）
    input wire [3:0] i_btn,             // 已去抖按键（103.5MHz 域，低有效）K1..K4
    output wire o_pwm_x, o_pwm_y,
    output wire [7:0] o_angle_x, o_angle_y,
    output wire [10:0] o_angle_q3_x, o_angle_q3_y,   // 2026-10-21：Q3（1/8°）角度，直接送 PWM
    output wire o_locked, o_lost,
    output wire [19:0] o_ticks_x, o_ticks_y
);
    (* async_reg="true" *) reg det_reset_meta_r, det_reset_r;
    (* async_reg="true" *) reg reset_meta_r, reset_r;
    always @(posedge i_det_clk or negedge i_arst_n)
        if(!i_arst_n) det_reset_meta_r<=0; else det_reset_meta_r<=1;
    always @(posedge i_det_clk or negedge i_arst_n)
        if(!i_arst_n) det_reset_r<=0; else det_reset_r<=det_reset_meta_r;
    always @(posedge i_clk_50m or negedge i_arst_n)
        if(!i_arst_n) reset_meta_r<=0; else reset_meta_r<=1;
    always @(posedge i_clk_50m or negedge i_arst_n)
        if(!i_arst_n) reset_r<=0; else reset_r<=reset_meta_r;

    // 包 bit38=跟踪使能，37:35=当前颜色，34:32=结果颜色，31=有效，
    // 30=坏帧，29:22=帧号，21:11=x，10:0=y。
    wire [4:0] config_now={i_tracking,i_preset,i_frame_bad};
    reg [4:0] config_sent_r;
    wire config_changed=(config_now!=config_sent_r);
    wire source_event=config_changed||i_result_load;
    wire source_valid=!config_changed && i_result_load && i_tracking &&
        !i_frame_bad && i_result[134] && i_result[132:130]==i_preset &&
        i_result[129:119]<1280 && i_result[118:108]<720;
    reg [38:0] mailbox_r;
    reg mailbox_pending_r;
    wire source_busy;
    wire source_send=mailbox_pending_r&&!source_busy;
    always @(posedge i_det_clk or negedge det_reset_r)
        if(!det_reset_r) config_sent_r<=0; else config_sent_r<=config_now;
    // 握手忙时保留最新整包；配置改变优先发送无效包，取消旧颜色。
    always @(posedge i_det_clk or negedge det_reset_r)
        if(!det_reset_r) mailbox_r<=0;
        else if(source_event) mailbox_r<={i_tracking,i_preset,i_result[132:130],
            source_valid,i_frame_bad,i_result[65:58],i_result[129:119],i_result[118:108]};
    always @(posedge i_det_clk or negedge det_reset_r)
        if(!det_reset_r) mailbox_pending_r<=0;
        else if(source_event) mailbox_pending_r<=1;
        else if(source_send) mailbox_pending_r<=0;

    wire [38:0] packet;
    wire packet_load;
    cdc_4phase #(.WIDTH(39)) u_result_cdc(
        .I_clk_src(i_det_clk),.I_rst_src_n(det_reset_r),
        .I_src_data(mailbox_r),.I_src_load(source_send),.O_src_busy(source_busy),
        .I_clk_dst(i_clk_50m),.I_rst_dst_n(reset_r),
        .O_dst_data(packet),.O_dst_valid(packet_load));

    // 配置仅用于快速禁止运动，不代替整包传输。红/蓝切换只改变一位。
    (* async_reg="true" *) reg [4:0] config_meta_r,config_sync_r;
    reg [4:0] config_seen_r;
    always @(posedge i_clk_50m or negedge reset_r)
        if(!reset_r) config_meta_r<=0; else config_meta_r<=config_now;
    always @(posedge i_clk_50m or negedge reset_r)
        if(!reset_r) config_sync_r<=0; else config_sync_r<=config_meta_r;
    always @(posedge i_clk_50m or negedge reset_r)
        if(!reset_r) config_seen_r<=0; else config_seen_r<=config_sync_r;
    wire destination_change=config_seen_r!=config_sync_r;
    (* async_reg="true" *) reg man_en_meta_r,man_en_sync_r;
    wire mode_ok=config_sync_r[4]&&!config_sync_r[0]&&!man_en_sync_r;
    wire matching_packet=packet[38] && packet[37:35]==config_sync_r[3:1] &&
        packet[34:32]==config_sync_r[3:1] && !packet[30];
    reg [7:0] last_frame_r;
    reg have_frame_r;
    wire new_result=packet_load && matching_packet &&
        (!have_frame_r||packet[29:22]!=last_frame_r);
    wire good_result=new_result && packet[31] && packet[21:11]<1280 && packet[10:0]<720;
    wire cancel_packet=packet_load && (!matching_packet||!packet[31]);
    reg [23:0] age_r; // 12,500,000 < 2^24
    wire expired=age_r>=TIMEOUT_CYCLES;
    wire about_to_expire=age_r>=TIMEOUT_CYCLES-1;
    reg [7:0] acquire_r;
    reg [10:0] x_r,y_r;
    reg result_pending_r;
    wire eligible=mode_ok&&!destination_change&&!expired&&acquire_r>=ACQUIRE_FRAMES;
    always @(posedge i_clk_50m or negedge reset_r)
        if(!reset_r) have_frame_r<=0;
        else if(destination_change||!mode_ok) have_frame_r<=0;
        else if(new_result) have_frame_r<=1;
    always @(posedge i_clk_50m or negedge reset_r)
        if(!reset_r) last_frame_r<=0; else if(new_result) last_frame_r<=packet[29:22];
    always @(posedge i_clk_50m or negedge reset_r)
        if(!reset_r) age_r<=TIMEOUT_CYCLES;
        else if(destination_change||!mode_ok) age_r<=TIMEOUT_CYCLES;
        else if(new_result) age_r<=0;
        else if(!expired) age_r<=age_r+1'b1;
    always @(posedge i_clk_50m or negedge reset_r)
        if(!reset_r) acquire_r<=0;
        else if(destination_change||!mode_ok||cancel_packet) acquire_r<=0;
        else if(good_result) begin if(acquire_r<ACQUIRE_FRAMES) acquire_r<=acquire_r+1'b1; end
        else if(about_to_expire) acquire_r<=0;
    always @(posedge i_clk_50m or negedge reset_r)
        if(!reset_r) x_r<=640; else if(good_result) x_r<=packet[21:11];
    always @(posedge i_clk_50m or negedge reset_r)
        if(!reset_r) y_r<=360; else if(good_result) y_r<=packet[10:0];
    wire step_tick;
    // 2026-10-21：控制更新降频（50Hz → 50/CTL_DIV），给舵机与检测留出响应时间，抑制极限环
    reg [1:0] ctl_div_r;
    always @(posedge i_clk_50m or negedge reset_r)
        if(!reset_r) ctl_div_r<=2'd0;
        else if(step_tick) ctl_div_r<=(ctl_div_r==CTL_DIV-1)?2'd0:ctl_div_r+2'd1;
    wire ctl_slot = step_tick && (ctl_div_r==CTL_DIV-1);
    wire control_tick=ctl_slot && !packet_load && !destination_change &&
        (result_pending_r||!eligible);
    always @(posedge i_clk_50m or negedge reset_r)
        if(!reset_r) result_pending_r<=0;
        else if(destination_change||!mode_ok||cancel_packet) result_pending_r<=0;
        else if(good_result) result_pending_r<=1;
        else if(control_tick||expired) result_pending_r<=0;

    wire controller_locked,controller_lost;
    // 2026-10-21：极性位来自 103.5MHz 按键域，进 50MHz 前做 2FF（慢变配置，仅防亚稳态）
    (* async_reg="true" *) reg invx_meta_r, invy_meta_r;
    (* async_reg="true" *) reg invx_sync_r, invy_sync_r;
    always @(posedge i_clk_50m or negedge reset_r)
        if(!reset_r) begin invx_meta_r<=1'b0; invy_meta_r<=1'b0; end
        else         begin invx_meta_r<=i_inv_x; invy_meta_r<=i_inv_y; end
    always @(posedge i_clk_50m or negedge reset_r)
        if(!reset_r) begin invx_sync_r<=1'b0; invy_sync_r<=1'b0; end
        else         begin invx_sync_r<=invx_meta_r; invy_sync_r<=invy_meta_r; end

    // Manual mode and already-debounced buttons cross together into 50 MHz.
    // A new press steps immediately. First repeat is at 400 ms, then 120 ms.
    // Leaving manual mode/releasing/changing keys cancels old repeat timing.
    (* async_reg="true" *) reg [3:0] man_meta_r,man_sync_r;
    reg [3:0] man_prev_r;wire [3:0] man_step_r;
    reg [24:0] man_count_r;
    reg man_repeating_r;
    wire [3:0] man_press=man_prev_r & ~man_sync_r;
    wire man_keys_changed=man_prev_r!=man_sync_r;
    wire [24:0] repeat_limit=man_repeating_r ? MAN_REPEAT_PERIOD : MAN_REPEAT_DELAY;
    always @(posedge i_clk_50m or negedge reset_r) begin
        if(!reset_r) begin
            man_en_meta_r<=0;man_en_sync_r<=0;
            man_meta_r<=4'hF;man_sync_r<=4'hF;
        end else begin
            man_en_meta_r<=i_manual_en;man_en_sync_r<=man_en_meta_r;
            man_meta_r<=i_btn;man_sync_r<=man_meta_r;
        end
    end
    generate if(!MAN_SMOOTH_EN)begin:legacy_manual_repeat
    reg[3:0]pulse_r;assign man_step_r=pulse_r;
    always @(posedge i_clk_50m or negedge reset_r) begin
        if(!reset_r) begin
            man_prev_r<=4'hF;pulse_r<=0;man_count_r<=0;man_repeating_r<=0;
        end else begin
            man_prev_r<=man_sync_r;pulse_r<=0;
            if(!man_en_sync_r || man_sync_r==4'hF) begin
                man_count_r<=0;man_repeating_r<=0;
            end else if(man_keys_changed) begin
                pulse_r<=man_press;
                man_count_r<=0;man_repeating_r<=0;
            end else if(man_count_r>=repeat_limit-1) begin
                pulse_r<=~man_sync_r;
                man_count_r<=0;man_repeating_r<=1;
            end else man_count_r<=man_count_r+1'b1;
        end
    end
    end else begin:fine_manual_repeat
        assign man_step_r=0;
    end endgenerate
    // o_angle_q3_* remains the controller target for compatibility. Actual
    // emitted pulse pose is separate; cancellation/manual entry rebases target
    // to it before accepting a new manual press. No mechanical encoder assumed.
    wire [10:0] pwm_angle_x,pwm_angle_y,emitted_x,emitted_y;
    wire [10:0] manual_x,manual_y;
    wire [3:0] manual_steps=MAN_SMOOTH_EN?4'd0:man_step_r;
    generate if(MAN_SMOOTH_EN)begin:fine_manual
        servo_manual_axis #(.HOME(HOME_X),.MIN_Q3(0),.MAX_Q3(1440)) mx(
            i_clk_50m,reset_r,man_en_sync_r,step_tick,!man_sync_r[3],!man_sync_r[2],emitted_x,manual_x);
        servo_manual_axis #(.HOME(HOME_Y),.MIN_Q3(760),.MAX_Q3(1440)) my(
            i_clk_50m,reset_r,man_en_sync_r,step_tick,!man_sync_r[0],!man_sync_r[1],emitted_y,manual_y);
    end else begin:no_fine_manual
        assign manual_x=emitted_x;assign manual_y=emitted_y;
    end endgenerate
    wire fine_manual_active=MAN_SMOOTH_EN&&man_en_sync_r;
    wire [10:0] slew_target_x=fine_manual_active?manual_x:o_angle_q3_x;
    wire [10:0] slew_target_y=fine_manual_active?manual_y:o_angle_q3_y;
    wire [10:0] sync_pose_x=fine_manual_active?manual_x:emitted_x;
    wire [10:0] sync_pose_y=fine_manual_active?manual_y:emitted_y;
    reg [3:0] wrap_delay;
    reg previous_manual;
    always @(posedge i_clk_50m or negedge reset_r)
        if(!reset_r)begin wrap_delay<=0;previous_manual<=0;end
        else begin wrap_delay<={wrap_delay[2:0],step_tick};previous_manual<=man_en_sync_r;end
    wire manual_entry=man_en_sync_r&&!previous_manual;
    wire cancel_slew=manual_entry||(!man_en_sync_r&&(!eligible||destination_change||cancel_packet));
    wire pose_sync=(SMOOTH_EN && (manual_entry||(!man_en_sync_r&&cancel_slew)))||fine_manual_active;
    servo_command_slew #(.ADAPTIVE(1),.ENABLED(SMOOTH_EN),.HOME_X(HOME_X),.HOME_Y(HOME_Y)) u_slew(
        .clk(i_clk_50m),.rst_n(reset_r),.step_tick(step_tick),.commit(wrap_delay[3]),
        .manual(man_en_sync_r),.cancel(cancel_slew),
        .target_x(slew_target_x),.target_y(slew_target_y),
        .pwm_x(pwm_angle_x),.pwm_y(pwm_angle_y),.emitted_x(emitted_x),.emitted_y(emitted_y),
        .urgent_x(x_r<160||x_r>1120),.urgent_y(y_r<72||y_r>648));
    gimbal_center #(.POSE_SYNC_EN(SMOOTH_EN||MAN_SMOOTH_EN),.STABILITY_EN(STABILITY_EN),.INVERT_X(INVERT_X),.INVERT_Y(INVERT_Y),.MAX_STEP(MAX_STEP),
        .ANGLE_MIN_X(0),.ANGLE_MAX_X(180),.ANGLE_MIN_Y(95),.ANGLE_MAX_Y(180),
        .HOME_X(HOME_X),.HOME_Y(HOME_Y)) u_gimbal(
        .I_pose_sync(pose_sync),.I_pose_x(sync_pose_x),.I_pose_y(sync_pose_y),
        .I_clk(i_clk_50m),.I_rst_n(reset_r),.I_frame_tick(control_tick),
        .I_target_valid(eligible&&result_pending_r),.I_target_x(x_r),.I_target_y(y_r),
        .I_inv_x(invx_sync_r),.I_inv_y(invy_sync_r),
        .I_manual_en(man_en_sync_r),
        .I_step_xp(manual_steps[3]),.I_step_xn(manual_steps[2]),   // K4 右 / K3 左
        .I_step_yp(manual_steps[0]),.I_step_yn(manual_steps[1]),   // K1 上 / K2 下
        .O_angle_x(o_angle_x),.O_angle_y(o_angle_y),
        .O_angle_q3_x(o_angle_q3_x),.O_angle_q3_y(o_angle_q3_y),.O_locked(controller_locked),
        .O_lost(controller_lost),.O_dbg_err_x(),.O_dbg_err_y());
    pwm_servo #(.CNT_PERIOD(PWM_PERIOD),.HOME_X(HOME_X),.HOME_Y(HOME_Y)) u_pwm(
        .I_clk(i_clk_50m),.I_rst_n(reset_r),.I_angle_x(pwm_angle_x),.I_angle_y(pwm_angle_y),
        .O_pwm_x(o_pwm_x),.O_pwm_y(o_pwm_y),.O_dbg_ticks_x(o_ticks_x),
        .O_dbg_ticks_y(o_ticks_y),.O_step_tick(step_tick));
    assign o_locked=eligible&&controller_locked;
    assign o_lost=!eligible;
endmodule

// Command shaper at the existing50Hz PWM rate, not a faster PWM carrier.
// Large automatic commands use4 PWM frames; near a viewport edge use2
// frames to preserve catch-up response. Small corrections
// <=1deg and all manual commands retain the original immediate target path.
// emitted_* is the last whole PWM pulse command, NOT mechanical encoder data.
module servo_command_slew #(
 parameter ENABLED=0,HOME_X=90,HOME_Y=110,PARTS=4,ADAPTIVE=0
)(input wire clk,rst_n,step_tick,commit,manual,cancel,
 input wire[10:0] target_x,target_y,
 output wire[10:0] pwm_x,pwm_y,
 output reg[10:0] emitted_x,emitted_y,input wire urgent_x,urgent_y);
 reg[10:0] position_x,position_y,goal_x,goal_y,base_x,base_y;
 reg[1:0] left_x,left_y,extra_x,extra_y;
 reg negative_x,negative_y,first_commit_x,first_commit_y;
 wire[10:0] dist_x=target_x>=emitted_x?target_x-emitted_x:emitted_x-target_x;
 wire[10:0] dist_y=target_y>=emitted_y?target_y-emitted_y:emitted_y-target_y;
 wire two_x=PARTS==2||(ADAPTIVE&&urgent_x);
 wire two_y=PARTS==2||(ADAPTIVE&&urgent_y);
 wire[10:0] base_new_x=two_x?dist_x>>1:dist_x>>2;
 wire[10:0] base_new_y=two_y?dist_y>>1:dist_y>>2;
 wire[1:0] extra_new_x=two_x?{1'b0,dist_x[0]}:dist_x[1:0];
 wire[1:0] extra_new_y=two_y?{1'b0,dist_y[0]}:dist_y[1:0];
 wire[10:0] first_x=base_new_x+(extra_new_x!=0);
 wire[10:0] first_y=base_new_y+(extra_new_y!=0);
 wire[10:0] next_x=base_x+(extra_x!=0);
 wire[10:0] next_y=base_y+(extra_y!=0);
 assign pwm_x=!ENABLED?target_x:cancel?emitted_x:manual?target_x:position_x;
 assign pwm_y=!ENABLED?target_y:cancel?emitted_y:manual?target_y:position_y;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   emitted_x<=HOME_X*8;emitted_y<=HOME_Y*8;
   position_x<=HOME_X*8;position_y<=HOME_Y*8;goal_x<=HOME_X*8;goal_y<=HOME_Y*8;
   base_x<=0;base_y<=0;left_x<=0;left_y<=0;extra_x<=0;extra_y<=0;negative_x<=0;negative_y<=0;first_commit_x<=0;first_commit_y<=0;
  end else begin
   if(commit)begin emitted_x<=pwm_x;emitted_y<=pwm_y;first_commit_x<=0;first_commit_y<=0;end
   if(cancel)begin
    position_x<=emitted_x;position_y<=emitted_y;goal_x<=target_x;goal_y<=target_y;
    left_x<=0;left_y<=0;extra_x<=0;extra_y<=0;first_commit_x<=0;first_commit_y<=0;
   end else if(manual||!ENABLED)begin
    position_x<=target_x;position_y<=target_y;goal_x<=target_x;goal_y<=target_y;
    left_x<=0;left_y<=0;extra_x<=0;extra_y<=0;first_commit_x<=0;first_commit_y<=0;
   end else begin
    if(target_x!=goal_x)begin
     goal_x<=target_x;first_commit_x<=1;base_x<=base_new_x;negative_x<=target_x<emitted_x;
     extra_x<=extra_new_x==0?0:extra_new_x-1'b1;
     if(dist_x<=8)begin position_x<=target_x;left_x<=0;end
     else begin position_x<=target_x<emitted_x?emitted_x-first_x:emitted_x+first_x;left_x<=two_x?1:3;end
    end else if(step_tick&&!first_commit_x&&left_x!=0)begin
     position_x<=left_x==1?goal_x:negative_x?position_x-next_x:position_x+next_x;
     left_x<=left_x-1'b1;if(extra_x!=0)extra_x<=extra_x-1'b1;
    end
    if(target_y!=goal_y)begin
     goal_y<=target_y;first_commit_y<=1;base_y<=base_new_y;negative_y<=target_y<emitted_y;
     extra_y<=extra_new_y==0?0:extra_new_y-1'b1;
     if(dist_y<=8)begin position_y<=target_y;left_y<=0;end
     else begin position_y<=target_y<emitted_y?emitted_y-first_y:emitted_y+first_y;left_y<=two_y?1:3;end
    end else if(step_tick&&!first_commit_y&&left_y!=0)begin
     position_y<=left_y==1?goal_y:negative_y?position_y-next_y:position_y+next_y;
     left_y<=left_y-1'b1;if(extra_y!=0)extra_y<=extra_y-1'b1;
    end
   end
  end
 end
endmodule

// Manual velocity at the unchanged50Hz carrier. Q3 units are1/8 degree.
// First four held PWM frames use2Q3 (0.25deg); subsequent frames use3Q3
// (0.375deg,18.75deg/s). No400ms repeat gap and no queued target steps.
// Neutral/conflicting keys stop integration. Direct reversal inserts one
// stationary PWM frame and restarts at the lower speed. Axes are independent.
module servo_manual_axis #(parameter HOME=90,MIN_Q3=0,MAX_Q3=1440)(
 input wire clk,rst_n,enabled,tick,positive,negative,input wire[10:0]seed,
 output reg[10:0]position);
 wire[1:0]request_dir=positive==negative?2'd0:positive?2'd1:2'd2;
 reg[1:0]direction;reg[2:0]held_frames;reg reverse_pause;
 wire[1:0]increment=held_frames>=4?2'd3:2'd2;
 wire[11:0]up={1'b0,position}+increment;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin position<=HOME*8;direction<=0;held_frames<=0;reverse_pause<=0;end
  else if(!enabled)begin
   position<=seed<MIN_Q3?MIN_Q3:seed>MAX_Q3?MAX_Q3:seed;
   direction<=0;held_frames<=0;reverse_pause<=0;
  end else if(request_dir==0)begin direction<=0;held_frames<=0;reverse_pause<=0;end
  else if(request_dir!=direction)begin
   direction<=request_dir;held_frames<=0;reverse_pause<=direction!=0;
  end else if(tick)begin
   if(reverse_pause)begin reverse_pause<=0;held_frames<=0;end
   else begin
    if(direction==1)position<=up>MAX_Q3?MAX_Q3:up[10:0];
    else position<=position<MIN_Q3+increment?MIN_Q3:position-increment;
    if(held_frames<4)held_frames<=held_frames+1'b1;
   end
  end
 end
endmodule
