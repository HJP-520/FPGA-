`timescale 1ns/1ps
module tb_manual_smooth_pwm;
 reg dc=0,sc=0,rst=0;reg[3:0]btn=15;
 always #4.83 dc=~dc;always #10 sc=~sc;
 wire px,py;wire[19:0]tx,ty;wire[10:0]qx,qy;
 track_servo_ctrl #(.MAN_SMOOTH_EN(1),.SMOOTH_EN(1),.HOME_X(90),.HOME_Y(110),.STABILITY_EN(5),.MAX_STEP(4))dut(
 .i_det_clk(dc),.i_clk_50m(sc),.i_arst_n(rst),.i_tracking(1'b0),.i_preset(3'd0),.i_frame_bad(1'b0),.i_result_load(1'b0),.i_result(135'd0),
 .i_inv_x(1'b0),.i_inv_y(1'b0),.i_manual_en(1'b1),.i_btn(btn),.o_pwm_x(px),.o_pwm_y(py),.o_ticks_x(tx),.o_ticks_y(ty),.o_angle_q3_x(qx),.o_angle_q3_y(qy));
 integer frames=0,hx=0,hy=0,savedx=720,savedy=880,delta,peak=0,cycles=0;
 reg[19:0]dutyx=74995,dutyy=86105;
 always @(negedge sc)if(dut.reset_r)begin
  if(px)hx++;if(py)hy++;cycles++;
  if(dut.u_pwm.cnt==999999)begin
   if(cycles!=1000000&&frames>0)$fatal(1,"50Hz period changed %0d",cycles);
   if(frames>0&&(hx!=dutyx||hy!=dutyy))$fatal(1,"pulse widths mismatch f=%0d x=%0d/%0d y=%0d/%0d",frames,hx,dutyx,hy,dutyy);
   hx=0;hy=0;cycles=0;frames++;
  end
  if(dut.u_pwm.cnt==1)begin
   dutyx=tx;dutyy=ty;
   delta=dut.emitted_x>savedx?dut.emitted_x-savedx:savedx-dut.emitted_x;
   if(delta>3)$fatal(1,"manual emitted step too large");if(delta>peak)peak=delta;
   savedx=dut.emitted_x;savedy=dut.emitted_y;
  end
 end
 task idle(input integer n);repeat(n)@(negedge sc);endtask
 task frame;@(negedge dut.step_tick);idle(12);endtask
 integer heldx,heldy;
 initial begin
  idle(8);rst=1;frame;btn=6;repeat(9)frame;btn=15;idle(20);repeat(2)frame;
  heldx=qx;heldy=qy;repeat(3)frame;
  if(qx!=heldx||qy!=heldy||peak!=3||frames<14)$fatal(1,"stop/ramp/real PWM coverage");
  $display("TB_RESULT: MANUAL_SMOOTH_PWM PASS frames=%0d peak_q3=%0d actual_1000000_clocks/20ms/whole_pulses/diagonal/release_hold",frames,peak);$finish;
 end
 initial begin #400000000;$fatal(1,"PWM timeout");end
endmodule
