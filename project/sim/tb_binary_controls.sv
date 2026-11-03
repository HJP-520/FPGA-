`timescale 1ns/1ps
module tb_binary_controls;
 reg clk=0,rst=0;always #5 clk=~clk;
 reg[3:0]btn=15;reg gray=1,edge_mode=0,track=0,sof=0;
 wire[1:0]gs,es,mode,curve;wire[2:0]preset;wire trail,axes,info,ix,iy;
 algo_btn_state #(.DEBOUNCE_MAX(3),.TWO_COLOR_TRACK(1)) keys(
 .I_clk(clk),.I_rst_n(rst),.I_button(btn),.I_mode_edge(edge_mode),.I_mode_gray(gray),.I_mode_track(track),
 .O_edge_state(es),.O_gray_state(gs),.O_track_preset(preset),.O_track_trail(trail),.O_track_axes(axes),.O_track_info(info),.O_inv_x(ix),.O_inv_y(iy));
 algo_mode_ctrl cfg(clk,rst,4'b1101,sof,1'b0,gs,mode,curve);
 task waitc(input integer n);repeat(n)@(negedge clk);endtask
 task tap(input[3:0]b);begin btn=b;waitc(20);btn=15;waitc(20);end endtask
 task frame;begin sof=1;waitc(1);sof=0;waitc(15);end endtask
 initial begin
  waitc(4);rst=1;waitc(20);
  btn=7;waitc(1);btn=15;waitc(15);if(gs!=0)$fatal(1,"K4 bounce accepted");
  tap(7);if(gs!=3)$fatal(1,"K4 did not select binary");
  if(curve!=0)$fatal(1,"curve changed before SOF");
  frame();if(curve!=0)$fatal(1,"curve switched without two SOFs");
  frame();if(curve!=3||mode!=2)$fatal(1,"binary config not latched");
  btn=7;waitc(100);if(gs!=3)$fatal(1,"K4 hold changed mode");btn=15;waitc(20);
  tap(11);if(gs!=1||curve!=3)$fatal(1,"K3 gamma lost or frame config torn");
  frame();frame();if(curve!=1)$fatal(1,"gamma config");
  tap(13);if(gs!=2)$fatal(1,"S curve lost");tap(14);if(gs!=0)$fatal(1,"linear lost");
  gray=0;track=1;waitc(20);tap(7);
  if(info||gs!=0||ix||iy)$fatal(1,"K4 gray action leaked to tracking");
  track=0;edge_mode=1;waitc(20);tap(7);if(es!=3)$fatal(1,"K4 cartoon lost");
  edge_mode=0;gray=1;waitc(20);if(gs!=0)$fatal(1,"gray re-entry not linear");
  $display("TB_RESULT: BINARY_CONTROLS PASS debounce/hold/K1_K4/frame_atomic/two_SOF/mode_isolation");$finish;
 end
endmodule

module tb_binary_hud;
 reg clk=0,rst=0,iv=0,iu=0,il=0,load=0;always #5 clk=~clk;
 wire ov,ou,ol,ovs;wire[23:0]od;
 ui_hud_v17_r1 dut(clk,rst,iv,iu,il,1'b0,24'h203040,12'h8c3,load,135'd0,1'b0,4'd0,ov,ou,ol,ovs,od);
 integer x,y,checks=0,fd;integer dx[0:2],dy[0:2];reg[2:0]ev=0;
 always @(posedge clk)if(rst)begin
  for(integer j=2;j>0;j--)begin dx[j]=dx[j-1];dy[j]=dy[j-1];end
  dx[0]=x;dy[0]=y;ev={ev[1:0],iv};#1;
  if(ov!==ev[2])$fatal(1,"HUD latency changed");
  if(ov)begin
   if((^od)===1'bx)$fatal(1,"HUD unknown");
   if(dy[2]==716&&dx[2]>=16&&dx[2]<1216)begin
    if(dx[2]>=976)begin if(od!==24'hffca55)$fatal(1,"K4 underline missing");end
    else if(od===24'hffca55)$fatal(1,"old gray mode underlined");
    checks++;
   end
   if(dy[2]>=680)$fdisplay(fd,"%06x",od);
  end
 end
 initial begin
  fd=$fopen("binary_hud.hex","w");repeat(4)@(negedge clk);rst=1;load=1;
  repeat(8)@(negedge clk);load=0;
  for(integer yy=0;yy<720;yy++)begin
   for(integer xx=0;xx<1280;xx++)begin
    @(negedge clk);x=xx;y=yy;iv=1;iu=(xx==0&&yy==0);il=(xx==1279);
   end
   @(negedge clk);iv=0;iu=0;il=0;repeat(4)@(negedge clk);
  end
  repeat(6)@(negedge clk);$fclose(fd);
  if(checks!=1200)$fatal(1,"HUD probes not covered");
  $display("TB_RESULT: BINARY_HUD PASS checks=%0d K4_selected/underline/font_sync",checks);$finish;
 end
endmodule
