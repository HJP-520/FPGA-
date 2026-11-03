`timescale 1ns/1ps
module view_manual_fixture(
 input wire clk,rst,ready,input wire[3:0]sw,buttons,input wire sof,
 output wire[1:0]mode,curve,edge_state,gray_state,output wire[2:0]preset,
 output wire trail,axes,info,hold_view,manual,locked_keys,output wire[3:0]servo_buttons);
 wire[3:0]stable,override_buttons;wire override_manual;
 view_manual_gate #(.SW_ON_CYCLES(3),.KEY_RELEASE_CYCLES(12)) gate(
  .clk(clk),.rst_n(rst),.inputs_ready(ready),.sw1(sw[0]),.raw_buttons(buttons),.stable_buttons(stable),
  .display_hold(hold_view),.manual(override_manual),.key_lock(locked_keys),.manual_buttons(override_buttons));
 algo_mode_ctrl #(.MANUAL_HOLD_EN(1)) config_mode(
  clk,rst,{sw[3:1],!hold_view},sof,1'b0,gray_state,mode,curve);
 algo_btn_state #(.DEBOUNCE_MAX(8),.TWO_COLOR_TRACK(1),.KEY_LOCK_EN(1)) keys(
  .I_clk(clk),.I_rst_n(rst),.I_button(buttons),.I_key_lock(locked_keys),.I_display_curve(curve),
  .I_mode_edge(mode==1),.I_mode_gray(mode==2),.I_mode_track(mode==3),
  .O_edge_state(edge_state),.O_gray_state(gray_state),.O_track_preset(preset),
  .O_track_trail(trail),.O_track_axes(axes),.O_track_info(info),.O_btn_stable(stable));
 assign manual=ready&&((sw==4'hf)||override_manual);
 assign servo_buttons=override_manual?override_buttons:stable;
endmodule

module tb_view_manual_keys;
 reg clk=0,rst=0,ready=0,sof=0;reg[3:0]sw=15,buttons=15;
 always #5 clk=~clk;
 wire[1:0]mode,curve,es,gs;wire[2:0]preset;wire trail,axes,info,held,manual,key_lock;wire[3:0]servo_btn;
 view_manual_fixture f(clk,rst,ready,sw,buttons,sof,mode,curve,es,gs,preset,trail,axes,info,held,manual,key_lock,servo_btn);
 integer checks=0;reg[13:0]snapshot;reg[3:0]original;
 wire[13:0]visible={mode,curve,es,gs,preset,trail,axes,info};
 task step;@(negedge clk);endtask
 task idle(input integer n);repeat(n)step;endtask
 task frame;begin sof=1;step;sof=0;idle(16);end endtask
 task tap(input[3:0]b);begin buttons=b;idle(25);buttons=15;idle(30);end endtask
 task select_view(input[3:0]s);begin sw=s;idle(35);repeat(3)frame;end endtask
 task same_view;begin if(visible!==snapshot)$fatal(1,"VIEW_CHANGED snapshot=%h actual=%h sw=%b",snapshot,visible,sw);checks++;end endtask
 initial begin
  idle(4);rst=1;idle(8);
  if(held||manual)$fatal(1,"UNINITIALIZED_SWITCH_TAKEOVER");ready=1;
  for(integer m=0;m<4;m++)begin
   buttons=15;original=m==0?4'hf:m==1?4'hb:m==2?4'hd:4'h7;
   select_view(original);
   if(mode!==m[1:0])$fatal(1,"SELECT_MODE");
   if(m==1)tap(13); // white overlay
   if(m==2)begin tap(7);repeat(3)frame;end // local binary
   if(m==3)begin tap(14);tap(13);tap(11);tap(7);end // blue/trail/axes/info
   snapshot=visible;sw[0]=0;#1;
   if(!held||!key_lock||!manual)$fatal(1,"TAKEOVER_NOT_IMMEDIATE");
   idle(20);
   // Every key combination is redirected, never modifies held view options.
   for(integer b=1;b<16;b++)begin
    sw={b[2:0],1'b0};buttons=15-b;idle(24);frame;same_view;
    buttons=15;idle(24);same_view;
   end
   // Short ON bounce does not release the latch.
   sw[0]=1;idle(2);sw[0]=0;idle(6);if(!held)$fatal(1,"SW_BOUNCE");same_view;
   // A late raw key press must not leak into UI after the faster SW release.
   buttons=14;step;sw=original;idle(8);
   if(held||!key_lock)$fatal(1,"EXIT_HELD_KEY_GUARD");
   idle(40);repeat(3)frame;same_view;
   buttons=15;idle(45);if(key_lock)$fatal(1,"RELEASE_GUARD_STUCK");same_view;
   if(m==0&&!manual)$fatal(1,"LEGACY_ALL_ON_MANUAL_LOST");
   if(m!=0&&manual)$fatal(1,"MANUAL_STUCK_AFTER_EXIT");
   // Fresh presses regain their original functions exactly once.
   tap(14);repeat(3)frame;
   if(m==1&&es!=0)$fatal(1,"EDGE_KEYS_NOT_RESTORED");
   if(m==2&&(gs!=0||curve!=0))$fatal(1,"GRAY_KEYS_NOT_RESTORED");
   if(m==3&&preset!=0)$fatal(1,"TRACK_KEYS_NOT_RESTORED");
   checks++;
  end
  // Gray request not yet displayed is canceled, not secretly committed later.
  select_view(4'hd);tap(14);repeat(3)frame;
  buttons=7;idle(20);if(gs!=3||curve!=0)$fatal(1,"PENDING_GRAY_SETUP");
  sw[0]=0;idle(10);repeat(3)frame;
  if(curve!=0||gs!=0||servo_btn!=15)$fatal(1,"PENDING_CURVE_OR_PREHELD_KEY");
  buttons=15;idle(30);buttons=7;idle(22);if(servo_btn!=7)$fatal(1,"MANUAL_KEY_NOT_ARMED");
  buttons=15;idle(30);sw[0]=1;idle(45);repeat(3)frame;
  if(curve!=0||gs!=0)$fatal(1,"PENDING_CURVE_REAPPLIED");checks++;
  // A pending mode switch also cannot commit during override.
  select_view(4'hb);sw=4'hd;frame;if(mode!=1)$fatal(1,"PENDING_MODE_SETUP");
  sw[0]=0;idle(10);repeat(4)frame;if(mode!=1)$fatal(1,"PENDING_MODE_NOT_CANCELED");
  // Upper switches are ignored while held, then honored at frame boundaries.
  buttons=15;sw=4'h7;idle(45);repeat(3)frame;if(mode!=3)$fatal(1,"UPPER_SWITCH_RESUME");checks++;
  // Boot with SW1 OFF starts with the reset raw view; ready prevents false use.
  rst=0;ready=0;sw=4'ha;idle(4);rst=1;idle(10);if(held)$fatal(1,"BOOT_READY_GATE");
  ready=1;idle(20);repeat(3)frame;if(!held||mode!=0||!manual)$fatal(1,"BOOT_OFF_RAW");checks++;
  $display("TB_RESULT: VIEW_MANUAL_KEYS PASS checks=%0d modes4/all_key_combinations/options_hold/SW_bounce/late_press_guard/pending_mode_curve/preheld_key/boot",checks);$finish;
 end
 initial begin #100000000;$fatal(1,"timeout");end
endmodule

module tb_view_manual_ctrl;
 reg clk=0,sc=0,rst=0,ready=0,sof=0,load=0;reg[3:0]sw=7,buttons=15;reg[134:0]pack=0;
 always #5 clk=~clk;always #10 sc=~sc;
 wire[1:0]mode,curve,es,gs;wire[2:0]preset;wire trail,axes,info,held,manual,key_lock;wire[3:0]servo_btn;
 view_manual_fixture f(clk,rst,ready,sw,buttons,sof,mode,curve,es,gs,preset,trail,axes,info,held,manual,key_lock,servo_btn);
 wire[10:0]qx,qy;wire locked,lost;
 track_servo_ctrl #(.SMOOTH_EN(1),.MAN_SMOOTH_EN(1),.STABILITY_EN(5),.MAX_STEP(4),
  .INVERT_X(1),.INVERT_Y(1),.HOME_X(90),.HOME_Y(110),.PWM_PERIOD(200),.TIMEOUT_CYCLES(20000))dut(
  .i_det_clk(clk),.i_clk_50m(sc),.i_arst_n(rst),.i_tracking(mode==3&&!held),.i_preset(preset),
  .i_frame_bad(1'b0),.i_result_load(load),.i_result(pack),.i_inv_x(1'b0),.i_inv_y(1'b0),
  .i_manual_en(manual),.i_btn(servo_btn),.o_angle_q3_x(qx),.o_angle_q3_y(qy),.o_locked(locked),.o_lost(lost));
 integer fid=1,checks=0;reg[10:0]px,py;reg[13:0]snapshot;
 wire[13:0]visible={mode,curve,es,gs,preset,trail,axes,info};
 task step;@(negedge clk);endtask
 task idle(input integer n);repeat(n)step;endtask
 task frame;begin sof=1;step;sof=0;idle(18);end endtask
 task result(input integer x,y);begin pack=0;pack[134]=1;pack[132:130]=preset;pack[129:119]=x;pack[118:108]=y;pack[65:58]=fid;fid++;load=1;step;load=0;idle(50);end endtask
 task pose;begin px=dut.emitted_x;py=dut.emitted_y;end endtask
 task unchanged_pose;begin if(dut.emitted_x!=px||dut.emitted_y!=py)$fatal(1,"UNWANTED_POSE old=%0d,%0d new=%0d,%0d",px,py,dut.emitted_x,dut.emitted_y);checks++;end endtask
 initial begin
  idle(5);rst=1;idle(6);ready=1;idle(40);repeat(3)frame;
  if(mode!=3||manual)$fatal(1,"TRACKING_START");
  repeat(4)begin result(1000,500);idle(900);end
  if(!dut.eligible||dut.emitted_x==720)$fatal(1,"AUTOMATIC_NOT_EXERCISED");
  snapshot=visible;sw[0]=0;idle(800);pose;
  repeat(5)begin result(200,100);idle(500);end
  unchanged_pose;if(!manual||!held||visible!==snapshot)$fatal(1,"MANUAL_TAKEOVER");
  buttons=7;idle(2000);if(dut.emitted_x<=px||dut.emitted_y!=py)$fatal(1,"MANUAL_K4");checks++;
  buttons=3;idle(800);pose;idle(1200);unchanged_pose; // opposing X keys
  buttons=6;idle(1800);if(dut.emitted_x<=px||dut.emitted_y<=py)$fatal(1,"MANUAL_DIAGONAL");checks++;
  buttons=15;idle(800);pose;idle(1000);unchanged_pose;
  if(visible!==snapshot)$fatal(1,"TRACK_OPTIONS_CHANGED");
  // Exit while K1 remains held: no preset change, old target cannot resume.
  buttons=14;idle(600);sw[0]=1;idle(800);pose;idle(1000);unchanged_pose;
  if(manual||held||!key_lock||dut.eligible||preset!=0)$fatal(1,"EXIT_REACQUIRE_GUARD");
  result(1000,500);idle(900);unchanged_pose;if(dut.eligible)$fatal(1,"ONE_FRAME_REACQUIRED");
  result(1000,500);idle(80);if(!dut.eligible)$fatal(1,"FRESH_RESULTS_NOT_REACQUIRED");checks++;
  buttons=15;idle(45);if(key_lock)$fatal(1,"UI_GUARD_STUCK");
  buttons=14;idle(25);buttons=15;idle(30);if(preset!=2)$fatal(1,"UI_KEYS_NOT_RESTORED");checks++;
  // Gray binary display also supports takeover; an already-held UI key is disarmed.
  sw=4'hd;idle(35);repeat(3)frame;idle(800);
  buttons=7;idle(25);repeat(3)frame;if(curve!=3)$fatal(1,"GRAY_BINARY_SETUP");
  snapshot=visible;sw[0]=0;idle(800);pose;idle(1200);unchanged_pose;
  if(servo_btn!=15||visible!==snapshot)$fatal(1,"ENTRY_PREHELD_KEY");
  buttons=15;idle(35);buttons=7;idle(1800);if(dut.emitted_x<=px||visible!==snapshot)$fatal(1,"GRAY_MANUAL_MOVE");checks++;
  buttons=15;idle(800);pose;idle(1000);unchanged_pose;
  $display("TB_RESULT: VIEW_MANUAL_CTRL PASS checks=%0d PWM_handoff/no_auto_during_manual/keys/diagonal/conflict/release/fresh_reacquire/no_UI_leak/binary_preserved",checks);$finish;
 end
 initial begin #100000000;$fatal(1,"timeout");end
endmodule
