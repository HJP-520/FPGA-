`timescale 1ns/1ps
module tb_tracking_keys;
 reg clk=0,dc=0,rst=0,track=0,edge_mode=0,gray_mode=0,load=0;
 reg[3:0]btn=15;reg[134:0]pack=0;
 always #10 clk=~clk;always #4.83 dc=~dc;
 wire[1:0]edge_state,gray_state;wire[2:0]preset;
 wire trail,axes,info,inv_x,inv_y;wire[3:0]stable;
 algo_btn_state #(.DEBOUNCE_MAX(3),.TWO_COLOR_TRACK(1)) buttons(
 .I_clk(clk),.I_rst_n(rst),.I_button(btn),.I_mode_edge(edge_mode),.I_mode_gray(gray_mode),.I_mode_track(track),
 .O_edge_state(edge_state),.O_gray_state(gray_state),.O_track_preset(preset),
 .O_track_trail(trail),.O_track_axes(axes),.O_track_info(info),.O_inv_x(inv_x),.O_inv_y(inv_y),.O_btn_stable(stable));
 wire[10:0]qx,qy;
 wire manual=!(track||edge_mode||gray_mode);
 track_servo_ctrl #(.PWM_PERIOD(512),.TIMEOUT_CYCLES(4096),.CTL_DIV(1),.INVERT_X(1),.INVERT_Y(1)) servo(
 .i_det_clk(dc),.i_clk_50m(clk),.i_arst_n(rst),.i_tracking(track),.i_preset(preset),
 .i_frame_bad(1'b0),.i_result_load(load),.i_result(pack),.i_inv_x(inv_x),.i_inv_y(inv_y),
 .i_manual_en(manual),.i_btn(stable),.o_angle_q3_x(qx),.o_angle_q3_y(qy));
 always @(posedge clk)if(rst&&(inv_x||inv_y))$fatal(1,"key direction flip returned");
 integer checks=0,fid=0;reg[10:0]sx,sy;
 task waitclk(input integer n);repeat(n)@(negedge clk);endtask
 task tap(input[3:0]b);begin btn=b;waitclk(24);btn=15;waitclk(24);checks++;end endtask
 task frame(input integer x,y);
 begin
  @(negedge dc);pack=0;pack[134]=1;pack[132:130]=preset;pack[129:119]=x;pack[118:108]=y;
  pack[65:58]=fid;fid=(fid+1)%256;load=1;@(negedge dc);load=0;waitclk(600);checks++;
 end endtask
 initial begin
  waitclk(8);rst=1;waitclk(25);track=1;waitclk(30);
  if(preset!=0||trail||!axes||!info)$fatal(1,"tracking defaults");
  tap(14);if(preset!=2)$fatal(1,"K1 must select blue");
  tap(14);if(preset!=0)$fatal(1,"K1 must restore red");
  tap(13);if(!trail)$fatal(1,"K2 trail toggle");
  // Electrical bounce must not count as a press.
  btn=11;waitclk(1);btn=15;waitclk(20);if(!axes)$fatal(1,"K3 bounce accepted");
  frame(640,360);frame(640,360);sx=qx;sy=qy;
  tap(11);if(axes||!info||preset!=0||qx!=sx||qy!=sy)$fatal(1,"K3 must only hide axes");
  frame(280,100);if(qx<=sx||qy<=sy)$fatal(1,"K3 changed fixed servo direction");
  sx=qx;sy=qy;tap(7);if(info||axes||preset!=0||qx!=sx||qy!=sy)$fatal(1,"K4 must only hide info");
  frame(280,100);if(qx<=sx||qy<=sy)$fatal(1,"K4 changed fixed servo direction");
  tap(11);if(!axes||info)$fatal(1,"independent axes restore");
  tap(7);if(!axes||!info)$fatal(1,"independent info restore");
  btn=11;waitclk(200);if(axes)$fatal(1,"held K3 toggled more than once");
  btn=15;waitclk(24);tap(11);if(!axes)$fatal(1,"K3 release/press");
  // All-open/manual: the same physical keys still move the gimbal.
  track=0;waitclk(600);sx=qx;sy=qy;
  tap(11);if(qx!=sx-16||qy!=sy)$fatal(1,"manual K3 left lost");
  tap(7);if(qx!=sx||qy!=sy)$fatal(1,"manual K4 right lost");
  tap(14);if(qy!=sy+16)$fatal(1,"manual K1 up lost");
  tap(13);if(qy!=sy)$fatal(1,"manual K2 down lost");
  if(!axes||!info||trail||preset!=0)$fatal(1,"mode reset defaults");
  btn=11;waitclk(24);track=1;waitclk(30);
  if(!axes)$fatal(1,"held manual key leaked into tracking");
  btn=15;waitclk(24);
  track=0;edge_mode=1;waitclk(30);tap(11);if(edge_state!=1)$fatal(1,"edge K3 changed");
  tap(7);if(edge_state!=3)$fatal(1,"edge K4 changed");
  edge_mode=0;gray_mode=1;waitclk(30);tap(11);if(gray_state!=1)$fatal(1,"gray K3 changed");
  tap(13);if(gray_state!=2)$fatal(1,"gray K2 changed");
  tap(14);if(gray_state!=0)$fatal(1,"gray K1 changed");
  $display("TB_RESULT: TRACKING_KEYS PASS checks=%0d red_blue/trail/axes/info/debounce/hold/fixed_direction/manual/modes",checks);$finish;
 end
endmodule
