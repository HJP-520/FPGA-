`timescale 1ns/1ps
module tb_manual_fast;
 reg dc=0,sc=0,rst=0,man=0;reg[3:0]btn=15;
 always #4.83 dc=~dc;always #10 sc=~sc;
 wire[10:0]qx,qy;
 track_servo_ctrl #(.STABILITY_EN(2),.PWM_PERIOD(512),.TIMEOUT_CYCLES(4096),
 .MAN_REPEAT_DELAY(64),.MAN_REPEAT_PERIOD(24)) dut(
 .i_det_clk(dc),.i_clk_50m(sc),.i_arst_n(rst),.i_tracking(1'b0),.i_preset(3'd0),
 .i_frame_bad(1'b0),.i_result_load(1'b0),.i_result(135'd0),.i_inv_x(1'b0),.i_inv_y(1'b0),
 .i_manual_en(man),.i_btn(btn),.o_angle_q3_x(qx),.o_angle_q3_y(qy));
 integer cycle=0,pulses=0,t0=-1,t1=-1,t2=-1;
 always @(posedge sc)begin
  #1;cycle++;
  if(rst&&dut.man_step_r!=0)begin
   if(pulses==0)t0=cycle;if(pulses==1)t1=cycle;if(pulses==2)t2=cycle;
   pulses++;
  end
  if(rst&&dut.reset_r&&(qx>1440||qy<760||qy>1440))$fatal(1,"mechanical limit");
 end
 task waitsc(input integer n);repeat(n)@(negedge sc);endtask
 task tap(input[3:0]b);begin btn=b;waitsc(8);btn=15;waitsc(8);end endtask
 reg[10:0]sx,sy;integer saved;
 initial begin
  waitsc(8);rst=1;waitsc(30);
  btn=14;waitsc(200);btn=15;waitsc(8);
  if(qx!=720||qy!=760||pulses!=0)$fatal(1,"buttons active outside manual mode");
  man=1;waitsc(10);btn=14;waitsc(8);
  if(qy!=776||pulses!=1)$fatal(1,"first press not immediate");
  waitsc(50);if(pulses!=1)$fatal(1,"repeat too early");
  waitsc(14);if(pulses!=2||qy!=792)$fatal(1,"first repeat absent");
  waitsc(24);if(pulses!=3||qy!=808)$fatal(1,"periodic repeat absent");
  if(t1-t0!=64||t2-t1!=24)$fatal(1,"repeat timing %d/%d",t1-t0,t2-t1);
  btn=15;waitsc(100);if(pulses!=3)$fatal(1,"release did not stop repeat");
  sy=qy;tap(13);if(qy!=sy-16)$fatal(1,"K2 Y-");
  tap(11);if(qx!=704)$fatal(1,"K3 X-");tap(7);if(qx!=720)$fatal(1,"K4 X+");
  sx=qx;sy=qy;tap(0);if(qx!=sx||qy!=sy)$fatal(1,"opposing keys did not cancel");
  repeat(100)tap(7);if(qx!=1440)$fatal(1,"X max clamp");
  repeat(100)tap(11);if(qx!=0)$fatal(1,"X min clamp");
  repeat(100)tap(14);if(qy!=1440)$fatal(1,"Y max clamp");
  repeat(100)tap(13);if(qy!=760)$fatal(1,"Y min clamp");
  btn=14;waitsc(90);man=0;waitsc(10);sx=qx;sy=qy;saved=pulses;
  waitsc(200);if(qx!=sx||qy!=sy||pulses!=saved)$fatal(1,"exit did not stop manual");
  man=1;waitsc(20);if(qx!=sx||qy!=sy)$fatal(1,"stale repeat leaked across mode entry");
  btn=15;waitsc(8);tap(14);if(qy!=sy+16)$fatal(1,"fresh key after reentry");
  $display("TB_RESULT: MANUAL_FAST PASS mapping/first/repeat/release/opposed/limits/mode_reentry pulses=%0d",pulses);$finish;
 end
endmodule
