`timescale 1ns/1ps
module tb_smooth_unit;
 reg clk=0,rst=0,step=0,commit=0,manual=0,cancel=0;
 reg[10:0]x=720,y=880;always #5 clk=~clk;
 wire[10:0]px,py,ex,ey,bx,by;
 servo_command_slew #(.ENABLED(1)) dut(clk,rst,step,commit,manual,cancel,x,y,px,py,ex,ey,1'b0,1'b0);
 servo_command_slew #(.ENABLED(0)) bypass(.clk(clk),.rst_n(rst),.step_tick(step),.commit(commit),.manual(manual),.cancel(cancel),.target_x(x),.target_y(y),.pwm_x(bx),.pwm_y(by));
 integer checks=0,oldx,oldy,peak=0,wantx,wanty,savedx,savedy;
 task idle(input integer n);repeat(n)@(negedge clk);endtask
 task pulse;
 begin
  oldx=ex;oldy=ey;step=1;idle(1);step=0;idle(3);commit=1;idle(1);commit=0;idle(3);
  if(ex>1440||ey<760||ey>1440)$fatal(1,"slew bounds");
  if(ex>oldx+8||ex+8<oldx||ey>oldy+8||ey+8<oldy)$fatal(1,"large automatic pulse jump");
  if(bx!==x||by!==y)$fatal(1,"legacy bypass changed");checks++;
 end endtask
 initial begin
  idle(4);rst=1;idle(3);
  for(integer sign=0;sign<2;sign++)for(integer delta=1;delta<=32;delta++)begin
   rst=0;cancel=0;x=720;y=880;idle(3);rst=1;idle(3);oldx=ex;oldy=ey;
   wantx=sign?oldx-delta:oldx+delta;wanty=sign?oldy+delta:oldy-delta;
   x=wantx;y=wanty;idle(2);
   // No first substep can be skipped even when a target arrives before step.
   repeat(4)pulse();
   if(ex!=wantx||ey!=wanty)$fatal(1,"exact endpoint/rounding delta=%0d",delta);
   savedx=ex;savedy=ey;repeat(3)pulse();if(ex!=savedx||ey!=savedy)$fatal(1,"same target queued again");
  end
  // Mid-trajectory target replacement begins from emitted pose, not old goal.
  x=ex+32;y=ey+32;idle(2);pulse();savedx=ex;savedy=ey;
  x=ex-24;y=ey-24;idle(2);repeat(4)pulse();
  if(ex!=savedx-24||ey!=savedy-24)$fatal(1,"mid-ramp reversal endpoint");
  x=ex+32;y=ey+32;idle(2);pulse();savedx=ex;savedy=ey;cancel=1;idle(2);
  repeat(8)pulse();if(ex!=savedx||ey!=savedy)$fatal(1,"cancel moved/finished old goal");
  x=ex;y=ey;idle(3);cancel=0;repeat(4)pulse();if(ex!=savedx||ey!=savedy)$fatal(1,"cancel history resumed");
  manual=1;x=ex+16;y=ey+16;idle(2);step=1;idle(1);step=0;idle(3);commit=1;idle(1);commit=0;idle(2);
  if(ex!=savedx+16||ey!=savedy+16)$fatal(1,"manual2deg was filtered");
  $display("TB_RESULT: SMOOTH_UNIT PASS checks=%0d Q3_steps1_to32/both_signs/exact_four_part_endpoints/no_skipped_first/cancel/reversal/manual_direct/legacy_bypass",checks);$finish;
 end
endmodule

module tb_smooth_pwm;
 reg clk=0,rst=0,manual=0,cancel=0;reg[10:0]x=720,y=880;always #10 clk=~clk;
 wire[10:0]px,py,ex,ey;wire pwmx,pwmy,step;wire[19:0]tx,ty;
 reg[3:0]pipe=0;always @(posedge clk or negedge rst)if(!rst)pipe<=0;else pipe<={pipe[2:0],step};
 servo_command_slew #(.ENABLED(1)) shape(clk,rst,step,pipe[3],manual,cancel,x,y,px,py,ex,ey,1'b0,1'b0);
 pwm_servo #(.HOME_X(90),.HOME_Y(110)) pwm(clk,rst,px,py,pwmx,pwmy,tx,step,ty);
 integer periods=0,hx,hy,expectx,expecty;
 task idle(input integer n);repeat(n)@(negedge clk);endtask
 task measure(input integer qx,qy);
 begin
  hx=0;hy=0;expectx=25000+((qx*1111)>>4);expecty=25000+((qy*1111)>>4);
  if(pwm.cnt!=0)$fatal(1,"PWM measurement phase");
  for(integer k=0;k<1000000;k++)begin
   if(pwmx)hx++;if(pwmy)hy++;
   if(tx!=expectx||ty!=expecty||ex!=qx||ey!=qy)$fatal(1,"PWM commit/whole-pulse/shadow mismatch k=%0d q=%0d/%0d emitted=%0d/%0d",k,qx,qy,ex,ey);
   // Mimic production: new control result1clock after step, target visible
   // to shaper at step+2, safely before PWM period boundary at step+4.
   if(periods==0&&k==999997)begin x=752;y=912;end
   idle(1);
  end
  if(hx!=expectx||hy!=expecty||pwm.cnt!=0)$fatal(1,"50Hz pulse width");periods++;
 end endtask
 initial begin
  idle(5);if(pwmx||pwmy)$fatal(1,"reset output gate");rst=1;#1;
  measure(720,880);measure(728,888);measure(736,896);measure(744,904);measure(752,912);
  rst=0;#1;if(pwmx||pwmy)$fatal(1,"mid pulse reset");idle(5);rst=1;#1;
  x=720;y=880;measure(720,880);
  $display("TB_RESULT: SMOOTH_PWM PASS periods=%0d actual50Hz/20ms/step_plus4_commit/whole_pulses/4deg_to_four1deg/shadow_matches_ticks/first_X90Y110/reset",periods);$finish;
 end
endmodule
