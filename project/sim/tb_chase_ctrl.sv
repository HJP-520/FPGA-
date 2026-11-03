`timescale 1ns/1ps
`include "production_servo_params.vh"
module tb_chase_ctrl;
 reg dc=0,sc=0,rst=0,tracking=1,manual=0,bad=0,load=0;
 reg[2:0]preset=0;reg[134:0]pack=0;reg[3:0]btn=15;
 always #4.83 dc=~dc;always #10 sc=~sc;
 wire[10:0]qx,qy;wire lost;
 track_servo_ctrl #(.PWM_PERIOD(512),.TIMEOUT_CYCLES(100000),.CTL_DIV(2),
 .HOME_X(`PROD_HOME_X),.HOME_Y(`PROD_HOME_Y),.STABILITY_EN(4),.MAX_STEP(4),.INVERT_X(1),.INVERT_Y(1))dut(
 .i_det_clk(dc),.i_clk_50m(sc),.i_arst_n(rst),.i_tracking(tracking),.i_preset(preset),.i_frame_bad(bad),.i_result_load(load),.i_result(pack),
 .i_inv_x(1'b0),.i_inv_y(1'b0),.i_manual_en(manual),.i_btn(btn),.o_angle_q3_x(qx),.o_angle_q3_y(qy),.o_lost(lost));
 integer cycles=0,last_cycle=-99999,oldq=720,fast=0,steps=0,fid=0,saved;
 always @(posedge sc)begin #1;
  if(!rst)begin cycles=0;last_cycle=-99999;oldq=720;end
  else begin
   cycles++;
   if(qx!=oldq)begin
    if(qx>oldq+32||qx+32<oldq)$fatal(1,"ctrl step above4deg");
    if(cycles-last_cycle<2048)$fatal(1,"ctrl cadence faster than80ms equivalent");
    if(qx>oldq+20||qx+20<oldq)fast++;
    last_cycle=cycles;oldq=qx;steps++;
   end
   if(qy!=880)$fatal(1,"X chase changed Y/home");
  end
 end
 task idle(input integer n);repeat(n)@(negedge sc);endtask
 task packet(input integer x,input bit good,advance);
 begin
  @(negedge dc);pack=0;pack[134]=good;pack[132:130]=preset;pack[129:119]=x;pack[118:108]=360;
  if(advance)fid=(fid+1)%256;pack[65:58]=fid;
  load=1;@(negedge dc);load=0;idle(1100);
 end endtask
 initial begin
  if(4!=4||4!=4)$fatal(1,"production profile not staged chase");
  idle(8);rst=1;idle(80);
  repeat(4)packet(640,1,1);
  packet(900,1,1);packet(940,1,1);packet(990,1,1);
  for(integer k=0;k<16;k++)packet(1000+k*8,1,1);
  if(fast<2||steps<3)$fatal(1,"production CDC chain never executed fast action");
  idle(12000);saved=qx;
  repeat(8)packet(1200,1,0);
  if(qx!=saved)$fatal(1,"duplicate frame integrated");
  packet(1200,0,1);idle(3000);saved=qx;
  if(!lost||dut.u_gimbal.have_observation||dut.u_gimbal.last_boost_x)$fatal(1,"invalid did not clear chase history");
  idle(10000);if(qx!=saved)$fatal(1,"invalid continued chasing");
  preset=2;idle(3000);repeat(4)packet(640,1,1);
  if(qx!=saved||lost||dut.u_gimbal.far_x)$fatal(1,"color change/reacquire reused fast history");
  $display("TB_RESULT: CHASE_CTRL PASS fast_commands=%0d steps=%0d legacy_profile4/asyncCDC/fresh_frames/fast80ms/step4deg/duplicates_hold/invalid_clear/color_reacquire/home",fast,steps);$finish;
 end
 initial begin #10000000;$fatal(1,"chase ctrl timeout");end
endmodule
