`timescale 1ns/1ps
module tb_manual_smooth_unit;
 reg clk=0,rst=0,en=0,tick=0,p=0,n=0;reg[10:0]seed=720;
 always #10 clk=~clk;
 wire[10:0]x,y;
 servo_manual_axis #(.HOME(90),.MIN_Q3(0),.MAX_Q3(1440)) ax(clk,rst,en,tick,p,n,seed,x);
 servo_manual_axis #(.HOME(110),.MIN_Q3(760),.MAX_Q3(1440)) ay(clk,rst,en,tick,p,n,seed,y);
 integer checks=0,oldx,oldy,wantx,wanty;
 task idle(input integer k);repeat(k)@(negedge clk);endtask
 task frame;tick=1;idle(1);tick=0;idle(2);endtask
 task check(input integer ex,ey);begin
  if(x!==ex||y!==ey)$fatal(1,"manual axis got=%0d/%0d expected=%0d/%0d",x,y,ex,ey);checks++;
 end endtask
 initial begin
  idle(5);rst=1;idle(3);check(720,760);
  for(integer s=0;s<=1500;s++)begin
   en=0;p=0;n=0;seed=s;idle(2);oldx=s>1440?1440:s;oldy=s<760?760:s>1440?1440:s;
   check(oldx,oldy);en=1;p=1;idle(2);
   for(integer k=0;k<7;k++)begin
    frame;wantx=oldx+(k<4?2:3);wanty=oldy+(k<4?2:3);
    if(wantx>1440)wantx=1440;if(wanty>1440)wanty=1440;check(wantx,wanty);oldx=x;oldy=y;
   end
   // Direct reversal has a stationary frame, then lower initial speed.
   p=0;n=1;idle(2);frame;check(oldx,oldy);
   frame;check(oldx<2?0:oldx-2,oldy<762?760:oldy-2);
   oldx=x;oldy=y;p=1;idle(2);repeat(4)frame;check(oldx,oldy); // opposing keys
   p=0;n=0;idle(2);repeat(3)frame;check(oldx,oldy); // no queued residual
  end
  $display("TB_RESULT: MANUAL_SMOOTH_UNIT PASS checks=%0d exhaustive_seed/clamp/ramp/stop/reverse/conflict/no_windup",checks);$finish;
 end
 initial begin #100000000;$fatal(1,"unit timeout");end
endmodule
