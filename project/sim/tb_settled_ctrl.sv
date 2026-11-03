`timescale 1ns/1ps
module tb_settled_ctrl;
 reg dc=0,sc=0,rst=0,tracking=1,manual=0,load=0,bad=0;reg[2:0]preset=0;reg[3:0]btn=15;reg[134:0]pack=0;
 always #4.83 dc=~dc;always #10 sc=~sc;
 wire[10:0]qx,qy;wire[7:0]ax,ay;wire lost;wire[19:0]tx,ty;
 track_servo_ctrl #(.STABILITY_EN(1),.INVERT_X(1),.INVERT_Y(1),.PWM_PERIOD(512),.TIMEOUT_CYCLES(8192),.MAN_REPEAT_DELAY(20000),.MAN_REPEAT_PERIOD(6000)) dut(
 .i_det_clk(dc),.i_clk_50m(sc),.i_arst_n(rst),.i_tracking(tracking),.i_preset(preset),.i_frame_bad(bad),.i_result_load(load),.i_result(pack),
 .i_inv_x(1'b0),.i_inv_y(1'b0),.i_manual_en(manual),.i_btn(btn),.o_angle_q3_x(qx),.o_angle_q3_y(qy),.o_angle_x(ax),.o_angle_y(ay),.o_lost(lost),.o_ticks_x(tx),.o_ticks_y(ty));
 integer cycles=0,oldqx=720,oldqy=760,last_change=-99999,changes=0,fid=0,save_x,save_y,dx;reg checking=0;
 always @(posedge sc)begin
  #1;cycles++;
  if(rst && checking && qx!=oldqx)begin
   dx=$signed({1'b0,qx})-oldqx;
   if(dx>4||dx< -4)$fatal(1,"near CDC step");
   if(cycles-last_change<6144)$fatal(1,"fresh frames bypassed settle wait");
   last_change=cycles;changes++;
  end
  if(rst&&(qx>1440||qy<760||qy>1440))$fatal(1,"axis limits");
  oldqx=qx;oldqy=qy;
 end
 task idle(input integer n);repeat(n)@(negedge sc);endtask
 task frame(input integer x,y,v,tag);
 begin
  @(negedge dc);pack=0;pack[134]=v;pack[132:130]=tag;pack[129:119]=x;pack[118:108]=y;pack[65:58]=fid;fid=(fid+1)%256;load=1;
  @(negedge dc);load=0;idle(96);
 end endtask
 task press(input[3:0]b);btn=b;idle(20);btn=15;idle(20);endtask
 initial begin
  idle(8);rst=1;idle(100);checking=1;
  repeat(250)frame(540,360,1,0);
  if(changes<3||qx<=720||qy!=760||lost)$fatal(1,"new controller no tracking");
  checking=0;save_x=qx;save_y=qy;
  frame(540,360,0,0);idle(2000);if(qx!=save_x||qy!=save_y||!lost)$fatal(1,"invalid freeze");
  manual=1;tracking=0;idle(100);
  press(4'hE);if(qy!=save_y+16)$fatal(1,"manual up");
  press(4'hD);if(qy!=save_y)$fatal(1,"manual down");
  press(4'hB);if(qx!=save_x-16)$fatal(1,"manual left");
  press(4'h7);if(qx!=save_x)$fatal(1,"manual right");
  idle(2000);if(qx!=save_x||qy!=save_y)$fatal(1,"manual release hold");
  manual=0;tracking=1;idle(100);preset=2;idle(100);
  repeat(20)frame(280,100,1,0);if(qx!=save_x||qy!=save_y)$fatal(1,"old colour moved new mode");
  repeat(20)frame(280,100,1,2);if(qx<=save_x||qy<=save_y)$fatal(1,"blue tracking unavailable");
  save_x=qx;save_y=qy;bad=1;idle(1500);if(qx!=save_x||qy!=save_y)$fatal(1,"bad frame hold");
  $display("TB_RESULT: SETTLED_CTRL PASS production_directions/CDC/fresh_frames/near_rate/invalid/manual4/release/colour/bad/limits");$finish;
 end
 initial begin #10000000;$fatal(1,"timeout");end
endmodule
