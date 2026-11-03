`timescale 1ns/1ps
`include "production_servo_params.vh"
module tb_home110;
 reg dc=0,sc=0,rst=0,manual=0,tracking=0;reg[3:0]btn=15;reg[2:0]preset=0;
 always #4.83 dc=~dc;always #10 sc=~sc;
 wire px,py,lost;wire[10:0]qx,qy;wire[19:0]tx,ty;
 track_servo_ctrl #(.SMOOTH_EN(`PROD_SMOOTH),.HOME_X(`PROD_HOME_X),.HOME_Y(`PROD_HOME_Y),.STABILITY_EN(`PROD_PROFILE),.MAX_STEP(`PROD_MAX_STEP),.INVERT_X(1),.INVERT_Y(1))dut(
 .i_det_clk(dc),.i_clk_50m(sc),.i_arst_n(rst),.i_tracking(tracking),.i_preset(preset),.i_frame_bad(1'b0),.i_result_load(1'b0),.i_result(135'd0),
 .i_inv_x(1'b0),.i_inv_y(1'b0),.i_manual_en(manual),.i_btn(btn),.o_pwm_x(px),.o_pwm_y(py),.o_angle_q3_x(qx),.o_angle_q3_y(qy),.o_ticks_x(tx),.o_ticks_y(ty),.o_lost(lost));
 integer hx,hy,periods=0,save_y;
 task idle(input integer n);repeat(n)@(negedge sc);endtask
 task measure(input integer ex,ey);
 begin hx=0;hy=0;
  if(dut.u_pwm.cnt!=0)$fatal(1,"measurement not at first PWM count");
  for(integer k=0;k<1000000;k++)begin
   if(px)hx++;if(py)hy++;
   if(tx!=ex||ty!=ey)$fatal(1,"duty changed within period");
   if(dut.u_pwm.O_step_tick!==(k==999995))$fatal(1,"period/control timing changed");
   idle(1);
  end
  if(hx!=ex||hy!=ey||dut.u_pwm.cnt!=0)$fatal(1,"home PWM width wrong %d/%d",hx,hy);periods++;
 end endtask
 task press(input[3:0]b);btn=b;idle(40);btn=15;idle(40);endtask
 initial begin
  idle(5);if(px||py)$fatal(1,"reset PWM not gated");rst=1;wait(dut.reset_r);@(negedge sc);
  if(qx!=720||qy!=880||tx!=74995||ty!=86105)$fatal(1,"production home angle not 90/110");
  measure(74995,86105);
  manual=1;idle(30);press(4'hE);if(qy!=896)$fatal(1,"manual up2 from110 failed");
  save_y=qy;idle(100);if(qy!=save_y)$fatal(1,"manual release hold");
  while(dut.u_pwm.cnt!=0)begin if(ty!=86105)$fatal(1,"first duty torn by manual step");idle(1);end
  measure(74995,87216);
  tracking=1;manual=0;preset=2;idle(100);if(qy!=896||qx!=720)$fatal(1,"mode/colour change reset home");
  // Reset while the high part of a pulse is active: first new pulse must be110.
  rst=0;#1;if(px||py)$fatal(1,"reset pulse gate");idle(6);rst=1;wait(dut.reset_r);@(negedge sc);
  if(qx!=720||qy!=880||ty!=86105)$fatal(1,"reset after motion did not return110");measure(74995,86105);
  manual=1;tracking=0;idle(40);repeat(8)press(4'hD);if(qy!=760)$fatal(1,"Y95 limit lost");
  idle(100);if(qy!=760)$fatal(1,"limit hold");
  $display("TB_RESULT: HOME110 PASS periods=%0d actual_top_parameters/X90Y110/first_pulse86105ticks/50Hz/reset_after_motion/manual2deg/mode_hold/Y95limit",periods);$finish;
 end
 initial begin #120000000;$fatal(1,"timeout");end
endmodule
