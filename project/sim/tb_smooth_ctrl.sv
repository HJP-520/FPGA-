`timescale 1ns/1ps
`include "production_servo_params.vh"
module tb_smooth_ctrl;
 reg dc=0,sc=0,rst=0,tracking=1,manual=0,bad=0,load=0;
 reg[2:0]preset=0;reg[134:0]pack=0;reg[3:0]btn=15;
 always #4.83 dc=~dc;always #10 sc=~sc;
 wire[10:0]qx,qy;wire lost;wire[19:0]tx,ty;
 track_servo_ctrl #(.PWM_PERIOD(512),.TIMEOUT_CYCLES(100000),.CTL_DIV(2),.SMOOTH_EN(`PROD_SMOOTH),
 .HOME_X(`PROD_HOME_X),.HOME_Y(`PROD_HOME_Y),.STABILITY_EN(`PROD_PROFILE),.MAX_STEP(`PROD_MAX_STEP),.INVERT_X(1),.INVERT_Y(1),.MAN_REPEAT_DELAY(20000),.MAN_REPEAT_PERIOD(6000))dut(
 .i_det_clk(dc),.i_clk_50m(sc),.i_arst_n(rst),.i_tracking(tracking),.i_preset(preset),.i_frame_bad(bad),.i_result_load(load),.i_result(pack),
 .i_inv_x(1'b0),.i_inv_y(1'b0),.i_manual_en(manual),.i_btn(btn),.o_angle_q3_x(qx),.o_angle_q3_y(qy),.o_lost(lost),.o_ticks_x(tx),.o_ticks_y(ty));
 integer fid=0,saved,savedy,oldex=720,oldey=880,oldtx=74995,oldty=86105;
 integer commands=0,emissions=0,mid_ramp=0,peak=0,delta,guard;
 always @(posedge sc)begin #1;
  if(!dut.reset_r)begin oldex=720;oldey=880;oldtx=74995;oldty=86105;end
  else begin
   if(tx!=25000+((dut.emitted_x*1111)>>4)||ty!=25000+((dut.emitted_y*1111)>>4))$fatal(1,"emitted pose not same actual PWM duty");
   if((tx!=oldtx||ty!=oldty)&&dut.u_pwm.cnt!=0)$fatal(1,"PWM torn inside pulse");
   delta=dut.emitted_x>oldex?dut.emitted_x-oldex:oldex-dut.emitted_x;
   if(delta>16)$fatal(1,"actual pulse command jump above2deg");
   if(delta>peak)peak=delta;
   if(delta)emissions++;
   if(dut.u_slew.left_x!=0&&dut.emitted_x!=qx)mid_ramp++;
   if(dut.emitted_x>1440||dut.emitted_y<760||dut.emitted_y>1440)$fatal(1,"PWM pose out of limits");
   oldex=dut.emitted_x;oldey=dut.emitted_y;oldtx=tx;oldty=ty;
  end
 end
 task idle(input integer n);repeat(n)@(negedge sc);endtask
 task packet(input integer x,input bit good,advance,input integer waitn);
 begin
  @(negedge dc);pack=0;pack[134]=good;pack[132:130]=preset;pack[129:119]=x;pack[118:108]=360;
  if(advance)fid=(fid+1)%256;pack[65:58]=fid;
  load=1;@(negedge dc);load=0;idle(waitn);
 end endtask
 initial begin
  if(`PROD_PROFILE!=5||`PROD_SMOOTH!=1||`PROD_MAX_STEP!=4)$fatal(1,"not actual production smooth profile");
  idle(8);rst=1;idle(80);repeat(4)packet(640,1,1,1100);
  packet(900,1,1,1100);packet(940,1,1,1100);packet(990,1,1,1100);
  for(integer k=0;k<20;k++)packet(1000+k*8,1,1,1100);
  idle(4000);
  if(emissions<20||peak!=16||mid_ramp<10)$fatal(1,"ramp/urgent endpoint coverage missing e=%0d peak=%0d",emissions,peak);
  saved=dut.emitted_x;
  repeat(8)packet(1200,1,0,1100);
  if(qx!=saved||dut.emitted_x!=saved)$fatal(1,"duplicate frame creates a new trajectory");
  // Cancel a partially emitted automatic movement: actual PWM freezes, logical
  // integrator rebases to that emitted pose; the unissued remainder is dropped.
  guard=0;
  while(dut.u_slew.left_x==0&&guard<20)begin packet(1190,1,1,100);guard++;end
  if(dut.u_slew.left_x==0)$fatal(1,"no in-flight ramp for invalid test");
  packet(1190,0,1,150);saved=dut.emitted_x;idle(4000);
  if(!lost||qx!=saved||dut.emitted_x!=saved||dut.u_slew.left_x!=0)$fatal(1,"invalid cancellation/rebase/hold");
  // Restart, then enter manual while a new ramp is pending.
  repeat(4)packet(1000,1,1,1100);guard=0;
  while(dut.u_slew.left_x==0&&guard<20)begin packet(1040+guard*5,1,1,100);guard++;end
  manual=1;tracking=0;idle(1200);saved=dut.emitted_x;savedy=dut.emitted_y;
  if(qx!=saved||qy!=savedy)$fatal(1,"manual entry jumps to unissued auto goal");
  btn=7;idle(24);btn=15;idle(24);
  if(qx!=saved+16)$fatal(1,"first manual press not exactly2deg from emitted pose");
  idle(1200);if(dut.emitted_x!=saved+16||dut.emitted_y!=savedy)$fatal(1,"manual command was filtered");
  saved=dut.emitted_x;idle(3000);if(dut.emitted_x!=saved||qx!=saved)$fatal(1,"manual release resumes old auto trajectory");
  manual=0;tracking=1;preset=2;idle(2000);repeat(4)packet(640,1,1,1100);
  if(lost||dut.u_gimbal.motion_qual_x||qx!=saved||dut.emitted_x!=saved)$fatal(1,"mode/color reacquisition reused auto trajectory");
  $display("TB_RESULT: SMOOTH_CTRL PASS emitted_changes=%0d peak_q3=%0d pending_samples=%0d actual_top_profile5/smooth_enabled/asyncCDC/20ms_commit/wholepulse/shadow/urgent2deg/duplicate/invalid_rebase/manual2deg/release/color",emissions,peak,mid_ramp);$finish;
 end
 initial begin #20000000;$fatal(1,"smooth ctrl timeout");end
endmodule
