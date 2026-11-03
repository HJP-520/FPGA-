`timescale 1ns/1ps
module tb_pwm;
 reg clk=0,rst=0;always #10 clk=~clk;
 reg[10:0]ax=720,ay=760;wire px,py,step;wire[19:0]tx,ty;   // Q3：90°=720、95°=760
 pwm_servo #(.HOME_X(90),.HOME_Y(95)) dut(clk,rst,ax,ay,px,py,tx,step,ty);
 integer checks=0,hx,hy,expectedx,expectedy;
 task measure(input integer ex,ey);
  begin
   // 从 cnt=0 开始完整量测一个 1,000,000 拍周期。
   hx=0;hy=0;
   for(integer k=0;k<1000000;k++)begin
    if(px)hx++;if(py)hy++;
    if(tx!=ex||ty!=ey)$fatal(1,"duty changed inside period");
    if(step!=(k==999995))$fatal(1,"control slot");
    @(negedge clk);
   end
   if(hx!=ex||hy!=ey)$fatal(1,"pulse width got %d/%d exp %d/%d",hx,hy,ex,ey);
   if(dut.cnt!=0)$fatal(1,"20ms period");checks++;
  end
 endtask
 initial begin
  repeat(5)@(negedge clk);if(px||py)$fatal(1,"reset gate");rst=1;#1;
  measure(74995,77772); // 2026-10-21：Q3 输入，X90/Y95 首周期（720/760 → 74995/77772）。
  for(integer n=0;n<6;n++)begin
   ax=(n==0)?0:(n==1)?360:(n==2)?720:(n==3)?1080:(n==4)?1440:2040;   // 0/45/90/135/180/255°
   ay=(n==0)?1440:(n==1)?1080:(n==2)?760:(n==3)?720:(n==4)?360:0;     // 180/135/95/90/45/0°
   measure(tx,ty); // 当前周期锁定旧 duty；新角度只在边界生效
   expectedx=25000+(((ax>1440?1440:ax)*1111)>>4);
   expectedy=25000+(((ay>1440?1440:ay)*1111)>>4);
   measure(expectedx,expectedy);
  end
  rst=0;#1;if(px||py)$fatal(1,"mid-pulse reset");
  repeat(5)@(negedge clk);rst=1;#1;measure(74995,77772);
  $display("TB_RESULT: SERVO_PWM PASS periods=%0d first_X90Y95/50Hz/fullpulse/boundary_latch/clamp/reset",checks);$finish;
 end
 initial begin #400000000;$fatal(1,"timeout");end
endmodule
