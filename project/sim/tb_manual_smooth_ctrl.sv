`timescale 1ns/1ps
module tb_manual_smooth_ctrl;
 reg dc=0,sc=0,rst=0,tracking=0,manual=1,bad=0,load=0;
 reg[2:0]preset=0;reg[134:0]pack=0;reg[3:0]btn=15;
 always #4.83 dc=~dc;always #10 sc=~sc;
 wire[10:0]qx,qy;wire[19:0]tx,ty;
 track_servo_ctrl #(.MAN_SMOOTH_EN(1),.SMOOTH_EN(1),.PWM_PERIOD(512),.TIMEOUT_CYCLES(100000),
 .CTL_DIV(2),.HOME_X(90),.HOME_Y(110),.STABILITY_EN(5),.MAX_STEP(4),.INVERT_X(1),.INVERT_Y(1))dut(
 .i_det_clk(dc),.i_clk_50m(sc),.i_arst_n(rst),.i_tracking(tracking),.i_preset(preset),.i_frame_bad(bad),.i_result_load(load),.i_result(pack),
 .i_inv_x(1'b0),.i_inv_y(1'b0),.i_manual_en(manual),.i_btn(btn),.o_angle_q3_x(qx),.o_angle_q3_y(qy),.o_ticks_x(tx),.o_ticks_y(ty));
 integer savedx,savedy,oldex=720,oldey=880,oldtx=74995,oldty=86105,guard=0,fid=0;
 integer changes=0,delta,peak=0;reg watch_manual=0;
 always @(posedge sc)begin #1;
  if(dut.reset_r)begin
   if((tx!=oldtx||ty!=oldty)&&dut.u_pwm.cnt!=0)$fatal(1,"PWM duty changed inside period");
   if(tx!=25000+((dut.emitted_x*1111)>>4)||ty!=25000+((dut.emitted_y*1111)>>4))$fatal(1,"PWM emitted shadow mismatch");
   if(watch_manual)begin
    delta=dut.emitted_x>oldex?dut.emitted_x-oldex:oldex-dut.emitted_x;
    if(delta>3)$fatal(1,"manual pulse x jump %0d",delta);if(delta>peak)peak=delta;
    if(delta)changes++;
    delta=dut.emitted_y>oldey?dut.emitted_y-oldey:oldey-dut.emitted_y;
    if(delta>3)$fatal(1,"manual pulse y jump %0d",delta);
   end
   if(dut.emitted_x>1440||dut.emitted_y<760||dut.emitted_y>1440)$fatal(1,"limits");
  end
  oldex=dut.emitted_x;oldey=dut.emitted_y;oldtx=tx;oldty=ty;
 end
 task idle(input integer n);repeat(n)@(negedge sc);endtask
 task frames(input integer n);repeat(n)begin @(negedge dut.step_tick);idle(8);end endtask
 task packet(input integer x,input bit good,input integer waitn);begin
  @(negedge dc);pack=0;pack[134]=good;pack[132:130]=preset;pack[129:119]=x;pack[118:108]=360;
  fid=(fid+1)%256;pack[65:58]=fid;load=1;@(negedge dc);load=0;idle(waitn);
 end endtask
 initial begin
  idle(8);rst=1;frames(2);watch_manual=1;
  if(qx!=720||qy!=880)$fatal(1,"home");
  // One complete frame press is one fine0.25deg command; holding reaches3Q3.
  @(negedge dut.step_tick);idle(12);btn=7;frames(1);btn=15;idle(12);frames(2);
  if(dut.emitted_x!=722)$fatal(1,"short tap expected0.25deg got%0d",dut.emitted_x);
  savedx=dut.emitted_x;savedy=dut.emitted_y;btn=6;frames(12);btn=15;idle(12);frames(2);
  if(dut.emitted_x<=savedx+20||dut.emitted_y<=savedy+20||peak!=3)$fatal(1,"continuous diagonal/ramp");
  savedx=dut.emitted_x;savedy=dut.emitted_y;frames(8);
  if(dut.emitted_x!=savedx||dut.emitted_y!=savedy)$fatal(1,"release drift");
  btn=3;frames(5);btn=15;idle(12);frames(2);
  if(dut.emitted_x!=savedx)$fatal(1,"opposing x keys should cancel");
  // Reversing direct must not move in the previous direction or jump.
  btn=7;frames(8);savedx=dut.emitted_x;btn=11;idle(12);frames(1);
  if(dut.emitted_x!=savedx)$fatal(1,"direct reversal missing stationary frame");
  frames(1);if(dut.emitted_x!=savedx-2)$fatal(1,"reverse start not fine");btn=15;idle(12);frames(2);
  // Another axis's key must not reset an already-held axis ramp.
  btn=7;frames(7);savedx=dut.emitted_x;btn=6;frames(2);
  if(dut.emitted_x!=savedx+6)$fatal(1,"new Y press interrupted X");btn=15;idle(12);frames(2);
  // Automatic mode then enter manual while an automatic substep is pending.
  watch_manual=0;manual=0;tracking=1;idle(1500);repeat(4)packet(640,1,1100);
  guard=0;while(dut.u_slew.left_x==0&&guard<20)begin packet(1000+guard*4,1,100);guard++;end
  if(dut.u_slew.left_x==0)$fatal(1,"auto handoff coverage missing");
  manual=1;tracking=0;frames(2);savedx=dut.emitted_x;savedy=dut.emitted_y;watch_manual=1;
  if(qx!=savedx||qy!=savedy||dut.u_slew.left_x!=0)$fatal(1,"handoff retained unissued auto target");
  frames(4);if(dut.emitted_x!=savedx)$fatal(1,"manual idle resumed auto trajectory");
  btn=11;frames(2);btn=15;idle(12);frames(2);savedx=dut.emitted_x;
  if(qx!=savedx)$fatal(1,"manual HUD target out of sync");
  watch_manual=0;manual=0;tracking=1;preset=2;idle(2000);repeat(4)packet(640,1,1100);
  if(qx!=savedx||dut.emitted_x!=savedx)$fatal(1,"manual exit jump");
  // Both sides of step_tick and PWM wrap, including held-key exit.
  for(integer phase=0;phase<16;phase++)begin
   guard=phase<8?phase:phase+496;
   while(dut.u_pwm.cnt!=guard)idle(1);
   watch_manual=1;manual=1;tracking=0;btn=7;idle(12);frames(3);
   while(dut.u_pwm.cnt!=guard)idle(1);
   manual=0;tracking=1;btn=15;idle(12);
   savedx=dut.emitted_x;savedy=dut.emitted_y;frames(3);
   if(dut.emitted_x!=savedx||dut.emitted_y!=savedy||qx!=savedx||qy!=savedy)$fatal(1,"PWM phase handoff drift phase=%0d",guard);
  end
  $display("TB_RESULT: MANUAL_SMOOTH_CTRL PASS changes=%0d peak_q3=%0d tap/hold/diagonal/independent_axes/conflict/reversal/stop/CDC/whole_pulse/auto_handoff/16_PWM_boundary_phases",changes,peak);$finish;
 end
 initial begin #20000000;$fatal(1,"ctrl timeout");end
endmodule
