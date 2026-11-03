`timescale 1ns/1ps
module tb_red_720p;
 localparam W=1280,H=720;
 reg clk=0,rst=0,valid=0,sof=0,eol=0,mask=0,seed_mask=0;reg[7:0]fid=0;
 always #5 clk=~clk;
 wire target,upd,err;wire[10:0]cx,cy,x0,x1;wire[9:0]y0,y1;wire[20:0]count;wire[7:0]rf;
 track_region_accum #(.RED_STABLE(1)) dut(.I_clk(clk),.I_rst_n(rst),.I_valid(valid),.I_sof(sof),.I_eol(eol),.I_mask(mask),.I_seed(seed_mask),.I_fid(fid),.I_preset(3'd0),
 .O_target_valid(target),.O_cx(cx),.O_cy(cy),.O_min_x(x0),.O_max_x(x1),.O_min_y(y0),.O_max_y(y1),.O_count(count),.O_results_upd(upd),.O_error(err),.O_fid(rf));
 integer cycles=0,updates=0,max_latency=0;integer ends[0:3];
 always @(posedge clk)begin
  #1;cycles++;
  if(rst)begin
   if(err)$fatal(1,"720p error/overrun");
   if(upd)begin
    if(!target||count!=W*H||cx!=639||cy!=359||x0!=0||x1!=1279||y0!=0||y1!=719)$fatal(1,"720p full-frame overflow/geometry");
    if(cycles-ends[rf]>180000)$fatal(1,"analysis cannot keep up with frame cadence");
    if(cycles-ends[rf]>max_latency)max_latency=cycles-ends[rf];updates++;
   end
  end
 end
 task idle(input integer n);repeat(n)@(negedge clk);endtask
 initial begin
  idle(8);rst=1;idle(8);
  for(integer f=1;f<=3;f++)begin
   fid=f;
   for(integer yy=0;yy<H;yy++)for(integer xx=0;xx<W;xx++)begin
    valid=1;sof=(yy==0&&xx==0);eol=(xx==W-1);mask=1;
    seed_mask=xx>=(f%2?200:1000)&&xx<(f%2?264:1064)&&yy>=320&&yy<384;
    if(yy==H-1&&xx==W-1)ends[f]=cycles;
    @(negedge clk);
   end
  end
  valid=0;sof=0;eol=0;idle(180000);
  if(updates!=3)$fatal(1,"720p result dropped %d",updates);
  $display("TB_RESULT: RED_720P PASS frames=%0d pixels=%0d max_analysis_cycles=%0d double_bank/no_drop/full_frame",updates,3*W*H,max_latency);$finish;
 end
 initial begin #50000000;$fatal(1,"timeout");end
endmodule
