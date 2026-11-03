`timescale 1ns/1ps
module tb_track_servo;
 reg dc=0,sc=0,rst=0,mode=0,bad=0,load=0,ivx=0,ivy=0,man=0;reg[2:0]preset=0;reg[134:0]pack=0;reg[3:0]btn=4'hF;
 always #4.83 dc=~dc;always #10 sc=~sc;
 wire px,py,locked,lost;wire[7:0]ax,ay;wire[19:0]tx,ty;wire[10:0]qx,qy;
 track_servo_ctrl #(.PWM_PERIOD(512),.TIMEOUT_CYCLES(4096),.HOME_X(90),.HOME_Y(95),.CTL_DIV(1)) dut(
   .i_det_clk(dc),.i_clk_50m(sc),.i_arst_n(rst),.i_tracking(mode),.i_preset(preset),
   .i_frame_bad(bad),.i_result_load(load),.i_result(pack),.i_inv_x(ivx),.i_inv_y(ivy),
   .i_manual_en(man),.i_btn(btn),
   .o_pwm_x(px),.o_pwm_y(py),.o_angle_x(ax),.o_angle_y(ay),.o_locked(locked),.o_lost(lost),
   .o_ticks_x(tx),.o_ticks_y(ty),.o_angle_q3_x(qx),.o_angle_q3_y(qy));
 // 此 TB 缩短控制计数以覆盖异常控制；实际 20ms/脉宽另由 tb_pwm 检查。
 integer fid=0,checks=0,cycles=0,previous_change=-1000;reg[7:0]oldx=90,oldy=95;
 integer dx,dy;
 always @(posedge sc)begin
  #1;cycles++;
  if(rst&&dut.reset_r)begin
   if(ax>180||ay<95||ay>180)$fatal(1,"mechanical limit ax=%d ay=%d",ax,ay);
   dx=$signed({1'b0,ax})-$signed({1'b0,oldx});dy=$signed({1'b0,ay})-$signed({1'b0,oldy});
   if(dx!=0||dy!=0)begin
    if(dx>2||dx< -2||dy>2||dy< -2)$fatal(1,"step limit");
    if(cycles-previous_change<512)$fatal(1,"rate limit");
    previous_change=cycles;
   end
  end else previous_change=-1000;
  oldx=ax;oldy=ay;
 end
 task settle(input integer n);repeat(n)@(negedge sc);endtask
 task emit(input integer x,y,valid,tag,id);
  begin @(negedge dc);pack=0;pack[134]=valid;pack[132:130]=tag;
   pack[129:119]=x;pack[118:108]=y;pack[65:58]=id;load=1;
   @(negedge dc);load=0;
  end
 endtask
 task frame(input integer x,y,valid);
  begin fid=(fid+1)%256;emit(x,y,valid,preset,fid);settle(600);checks++;end
 endtask
 task still(input integer n);
  reg[7:0]sx,sy;begin sx=ax;sy=ay;settle(n);if(ax!=sx||ay!=sy)$fatal(1,"unexpected movement");checks++;end
 endtask
 reg[7:0]sx,sy;integer x,y,da,db;
 initial begin
  settle(8);rst=1;settle(50);
  if(ax!=90||ay!=95||tx!=74995||ty!=77772)$fatal(1,"startup X/Y must be 90/95 including first PWM period");
  emit(1000,100,1,0,1);still(700); // 非跟踪模式不动
  mode=1;settle(80);fid=1;
  frame(1000,100,1);if(ax!=90||ay!=95||!lost)$fatal(1,"single-frame acquisition moved");
  frame(1000,100,1);if(ax!=92||ay!=97||lost)$fatal(1,"confirmed target direction ax=%d ay=%d",ax,ay);
  // 2026-10-21：运行时极性翻转必须立刻改变方向（K3/K4 现场定方向用）
  ivx=1;frame(1000,100,1);if(ax!=90)$fatal(1,"runtime X invert did not reverse (ax=%d)",ax);
  ivx=0;frame(1000,100,1);if(ax!=92)$fatal(1,"X invert restore failed (ax=%d)",ax);
  // 2026-10-22：手动云台（SW1/2/3 关 + SW4 开）——K1/K2 控 Y 上/下，K3/K4 控 X 左/右
  mode=0;man=1;settle(600);sx=ax;sy=ay;
  btn=4'hE;settle(600);btn=4'hF;settle(600);          // K1 -> Y 向上 +2
  if(ax!=sx||ay!=sy+2)$fatal(1,"manual K1(Y+) ax=%d ay=%d",ax,ay);
  btn=4'hD;settle(600);btn=4'hF;settle(600);          // K2 -> Y 向下 -2
  if(ax!=sx||ay!=sy)$fatal(1,"manual K2(Y-) ax=%d ay=%d",ax,ay);
  btn=4'hB;settle(600);btn=4'hF;settle(600);          // K3 -> X 向左 -2
  if(ax!=sx-2||ay!=sy)$fatal(1,"manual K3(X-) ax=%d ay=%d",ax,ay);
  btn=4'h7;settle(600);btn=4'hF;settle(600);          // K4 -> X 向右 +2
  if(ax!=sx||ay!=sy)$fatal(1,"manual K4(X+) ax=%d ay=%d",ax,ay);
  man=0;mode=1;settle(600);
  sx=ax;sy=ay;frame(1000,100,0);if(ax!=sx||ay!=sy||!lost)$fatal(1,"lost hold");
  frame(640,100,1);sx=ax;sy=ay;frame(640,100,1);
  if(ax!=sx||ay<=sy)$fatal(1,"independent X deadzone");
  sx=ax;sy=ay;frame(1000,360,1);if(ax<=sx||ay!=sy)$fatal(1,"independent Y deadzone");
  sx=ax;sy=ay;emit(1000,360,1,preset,fid);still(700); // 同帧重复不得再走一步
  still(4200);if(!lost)$fatal(1,"watchdog did not expire");
  frame(1000,360,1);if(ax!=sx||ay!=sy)$fatal(1,"timeout must reacquire");
  frame(1000,360,1);if(ax<=sx)$fatal(1,"reacquire failed");
  bad=1;settle(100);still(700);if(!lost)$fatal(1,"bad frame gate");
  bad=0;settle(100);frame(1000,100,1);frame(1000,100,1);
  mode=0;settle(100);still(700);if(!lost)$fatal(1,"mode exit gate");
  mode=1;settle(100);sx=ax;sy=ay;
  emit(1000,100,1,0,fid);settle(100); // 重入后旧包不满足两帧确认
  preset=2;settle(100);
  emit(1000,100,1,0,fid+1);still(700);if(!lost)$fatal(1,"old colour accepted");
  frame(1000,100,1);if(ax!=sx||ay!=sy)$fatal(1,"colour requires acquisition");
  frame(1000,100,1);
  // 坐标越界、标签不匹配、无效帧均取消待执行命令。
  sx=ax;sy=ay;frame(2047,100,1);if(ax!=sx||ay!=sy||!lost)$fatal(1,"invalid coordinate");
  // 持续极端目标覆盖两个机械边界。
  for(integer k=0;k<100;k++)frame(1279,0,1);
  if(ax!=180||ay!=180)$fatal(1,"positive saturation %d/%d",ax,ay);
  for(integer k=0;k<100;k++)frame(0,719,1);
  if(ax!=0||ay!=95)$fatal(1,"negative saturation %d/%d",ax,ay);
  // 重新复位后数学相机模型：X角增大 -> 目标x减小，Y角增大 -> 目标y增大。
  rst=0;settle(8);rst=1;mode=1;preset=0;bad=0;settle(100);
  x=1000;y=100;
  for(integer k=0;k<80;k++)begin
   sx=ax;sy=ay;frame(x,y,1);
   da=$signed({1'b0,ax})-$signed({1'b0,sx});db=$signed({1'b0,ay})-$signed({1'b0,sy});
   x=x-da*8;y=y+db*8;
  end
  if(!locked||x<615||x>665||y<335||y>385)$fatal(1,"closed loop did not converge %d/%d",x,y);
  frame(640,360,1);still(700);
  // 忙时快速产生多个完整包：只允许最新完整坐标，不能混成 x/y。
  for(integer k=0;k<12;k++)begin fid=(fid+1)%256;emit(700+k,400+k,1,preset,fid);end
  settle(150);
  if(dut.x_r!=711||dut.y_r!=411)$fatal(1,"latest mailbox / atomic CDC %d/%d",dut.x_r,dut.y_r);
  // 外部复位半帧触发，PWM 立即低且角度回到有效 HOME。
  rst=0;#1;if(px||py)$fatal(1,"reset output gate");settle(8);rst=1;settle(100);
  if(ax!=90||ay!=95||!lost)$fatal(1,"midstream reset");
  $display("TB_RESULT: TRACK_SERVO PASS checks=%0d asyncCDC/direction/acquire/deadzone/limits/timeout/mode/colour/duplicate/converge/reset",checks);$finish;
 end
 initial begin #100000000;$fatal(1,"timeout");end
endmodule
