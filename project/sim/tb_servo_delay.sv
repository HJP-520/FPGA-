`timescale 1ns/1ps
module tb_servo_delay;
 reg clk=0,rst=0,tick=0,valid=1,manual=0,xp=0;
 reg[10:0]nx=640,ny=360,ox=640,oy=360;
 always #5 clk=~clk;
 wire[10:0]nqx,nqy,oqx,oqy;wire nl,ol;
 gimbal_center #(.STABILITY_EN(1),.MAX_STEP(2),.INVERT_Y(1),.HOME_Y(120)) dut(
 .I_clk(clk),.I_rst_n(rst),.I_frame_tick(tick),.I_target_valid(valid),.I_target_x(nx),.I_target_y(ny),
 .I_inv_x(1'b0),.I_inv_y(1'b0),.I_manual_en(manual),.I_step_xp(xp),.I_step_xn(1'b0),.I_step_yp(1'b0),.I_step_yn(1'b0),
 .O_angle_q3_x(nqx),.O_angle_q3_y(nqy),.O_locked(nl));
 gimbal_center #(.MAX_STEP(2),.INVERT_Y(1),.HOME_Y(120)) baseline(
 .I_clk(clk),.I_rst_n(rst),.I_frame_tick(tick),.I_target_valid(valid),.I_target_x(ox),.I_target_y(oy),
 .I_inv_x(1'b0),.I_inv_y(1'b0),.I_manual_en(manual),.I_step_xp(xp),.I_step_xn(1'b0),.I_step_yp(1'b0),.I_step_yn(1'b0),
 .O_angle_q3_x(oqx),.O_angle_q3_y(oqy),.O_locked(ol));
 integer hn[0:2000],hy[0:2000],ho[0:2000],hoy[0:2000];
 integer gain,delay_n,ix,iy,jx,jy,old_min,old_max,new_min,new_max,new_ymin,new_ymax,old_osc=0,cases=0;
 integer before_x,before_y,last_x,last_y,gap_x,gap_y,dx,dy,command_count=0;
 task idle(input integer n);repeat(n)@(negedge clk);endtask
 function integer clipx(input integer v);clipx=v<0?0:v>1279?1279:v;endfunction
 function integer clipy(input integer v);clipy=v<0?0:v>719?719:v;endfunction
 task observe;
 begin
  idle(5);before_x=nqx;before_y=nqy;tick=1;idle(1);tick=0;idle(4);
  dx=$signed({1'b0,nqx})-before_x;dy=$signed({1'b0,nqy})-before_y;
  if(dx>16||dx< -16||dy>16||dy< -16)$fatal(1,"step limit");
 end endtask
 initial begin
  for(integer g=0;g<4;g++)for(integer d=0;d<4;d++)begin
   gain=8+g*8;delay_n=1+d*2;rst=0;idle(4);rst=1;idle(8);
   for(integer k=0;k<2001;k++)begin hn[k]=720;ho[k]=720;hy[k]=960;hoy[k]=960;end
   old_min=9999;old_max=0;new_min=9999;new_max=0;new_ymin=9999;new_ymax=0;
   for(integer k=0;k<900;k++)begin
    ix=clipx(840-(hn[k]*gain-720*gain)/8);iy=clipy(210+(hy[k]*gain-960*gain)/8);
    jx=clipx(840-(ho[k]*gain-720*gain)/8);jy=clipy(210+(hoy[k]*gain-960*gain)/8);
    nx=ix;ny=iy;ox=jx;oy=jy;observe();
    hn[k+delay_n]=nqx;hy[k+delay_n]=nqy;ho[k+delay_n]=oqx;hoy[k+delay_n]=oqy;
    if(k>=700)begin
     if(nqx<new_min)new_min=nqx;if(nqx>new_max)new_max=nqx;
     if(nqy<new_ymin)new_ymin=nqy;if(nqy>new_ymax)new_ymax=nqy;
     if(oqx<old_min)old_min=oqx;if(oqx>old_max)old_max=oqx;
    end
   end
   if(new_max-new_min>0||new_ymax-new_ymin>0||ix<605||ix>675||iy<325||iy>395)$fatal(1,"delayed stationary failed gain=%0d delay=%0d span=%0d/%0d err=%0d/%0d",gain,delay_n,new_max-new_min,new_ymax-new_ymin,ix-640,iy-360);
   if(old_max-old_min>0)old_osc++;
   $display("DELAY_CASE gain_px_per_deg=%0d latency_ms=%0d old_q3_span=%0d new_q3_span=%0d final_error=%0d/%0d",gain,delay_n*40,old_max-old_min,new_max-new_min,ix-640,iy-360);cases++;
   // Target moves to the other side after a stationary hold; tracking must resume.
   new_min=9999;new_max=0;new_ymin=9999;new_ymax=0;
   for(integer k=900;k<1500;k++)begin
    ix=clipx(500-(hn[k]*gain-720*gain)/8);iy=clipy(450+(hy[k]*gain-960*gain)/8);
    nx=ix;ny=iy;observe();hn[k+delay_n]=nqx;hy[k+delay_n]=nqy;
    if(k>=1300)begin
     if(nqx<new_min)new_min=nqx;if(nqx>new_max)new_max=nqx;
     if(nqy<new_ymin)new_ymin=nqy;if(nqy>new_ymax)new_ymax=nqy;
    end
   end
   if(new_max-new_min!=0||new_ymax-new_ymin!=0||ix<605||ix>675||iy<325||iy>395)$fatal(1,"moving target did not settle %0d/%0d span=%0d/%0d",ix,iy,new_max-new_min,new_ymax-new_ymin);
  end
  if(old_osc==0)$fatal(1,"delay model never exposed baseline oscillation");
  // Near center: correction no larger than 0.5 degree, at least 6 observations apart.
  rst=0;idle(4);rst=1;idle(8);nx=740;ny=360;last_x=-999;command_count=0;
  for(integer k=0;k<40;k++)begin
   observe();if(dx!=0)begin
    if(dx>4||dx< -4||k-last_x<6)$fatal(1,"near action/observe timing");last_x=k;command_count++;
   end
  end
  if(command_count<2)$fatal(1,"near test coverage");
  // Two-frame opposite-side noise must not reverse commands.
  nx=540;observe();if(dx!=0)$fatal(1,"unconfirmed reversal1");observe();if(dx!=0)$fatal(1,"unconfirmed reversal2");
  // Invalid observations freeze. Manual input remains immediate during cooldown.
  valid=0;before_x=nqx;repeat(8)observe();if(nqx!=before_x)$fatal(1,"invalid hold");
  manual=1;xp=1;idle(1);xp=0;idle(2);if(nqx!=before_x+16)$fatal(1,"manual delayed or changed");
  $display("TB_RESULT: SERVO_DELAY PASS scenarios=%0d baseline_oscillating_cases=%0d stationary/moving/near_rate/reversal/invalid/manual",cases,old_osc);$finish;
 end
endmodule
