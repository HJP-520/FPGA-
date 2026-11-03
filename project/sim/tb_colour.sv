`timescale 1ns/1ps
module tb_colour;
 reg clk=0,rst=0,valid=0;reg[23:0]rgb=0;reg[2:0]preset=7;
 always #5 clk=~clk;
 wire hv,hs,he;wire[8:0]h;wire[7:0]s,v;wire mv,mask;
 rgb2hsv #(.FULL_HUE(1)) hsv(.I_clk(clk),.I_rst_n(rst),.I_valid(valid),.I_sof(1'b0),.I_eol(1'b0),.I_data(rgb),
 .O_valid(hv),.O_sof(hs),.O_eol(he),.O_h(h),.O_s(s),.O_v(v));
 hsv_threshold #(.STRICT_RED(1)) thr(.I_clk(clk),.I_rst_n(rst),.I_valid(hv),.I_sof(hs),.I_eol(he),
 .I_h(h),.I_s(s),.I_v(v),.I_preset_idx(preset),.O_valid(mv),.O_mask(mask));
 integer checks=0;
 task sample(input[23:0]c,input[2:0]p,input expected);
 begin
  @(negedge clk);rgb=c;preset=p;valid=1;
  @(negedge clk);valid=0;
  @(negedge clk);@(negedge clk);
  if(!mv||mask!==expected)$fatal(1,"colour threshold RGB=%h preset=%d mask=%b wanted=%b HSV=%d/%d/%d limits=%d/%d",c,p,mask,expected,h,s,v,thr.h_lo,thr.h_hi);
  checks++;
 end endtask
 initial begin
  repeat(5)@(negedge clk);rst=1;
  repeat(200)begin
   sample(24'hff0000,0,1);sample(24'hc8001e,0,1);sample(24'hc81e00,0,1);
   sample(24'hff5064,0,1);sample(24'hff6400,0,0);sample(24'h808080,0,0);
   sample(24'h320000,0,0);sample(24'h00ff00,0,0);sample(24'h0000ff,0,0);
   sample(24'h0000ff,2,1);sample(24'hff0000,2,0);
  end
  $display("TB_RESULT: COLOUR PASS samples=%0d red_wrap/pink/orange/gray/dark/red_blue_switch",checks);$finish;
 end
endmodule
