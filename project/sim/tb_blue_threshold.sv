`timescale 1ns/1ps
module tb_blue_threshold;
 reg clk=0,rst=0,valid=0,sof=0,eol=0;
 reg[8:0]h=0;reg[7:0]s=0,v=0;
 wire sv,ss,se,seed,gv,gs,ge,grow;
 always #5 clk=~clk;
 hsv_threshold u_seed(.I_clk(clk),.I_rst_n(rst),.I_valid(valid),.I_sof(sof),.I_eol(eol),.I_h(h),.I_s(s),.I_v(v),.I_preset_idx(3'd2),.O_valid(sv),.O_sof(ss),.O_eol(se),.O_mask(seed));
 hsv_threshold #(.GROW_BLUE(1)) u_grow(.I_clk(clk),.I_rst_n(rst),.I_valid(valid),.I_sof(sof),.I_eol(eol),.I_h(h),.I_s(s),.I_v(v),.I_preset_idx(3'd2),.O_valid(gv),.O_sof(gs),.O_eol(ge),.O_mask(grow));
 integer checks=0;integer sats[0:9];integer vals[0:7];
 initial begin
  sats[0]=0;sats[1]=35;sats[2]=36;sats[3]=47;sats[4]=48;sats[5]=59;sats[6]=60;sats[7]=79;sats[8]=80;sats[9]=255;
  vals[0]=0;vals[1]=27;vals[2]=28;vals[3]=39;vals[4]=40;vals[5]=59;vals[6]=60;vals[7]=255;
  repeat(5)@(negedge clk);rst=1;
  for(integer a=0;a<360;a++)for(integer b=0;b<10;b++)for(integer c=0;c<8;c++)begin
   h=a;s=sats[b];v=vals[c];valid=checks%7!=0;sof=checks%211==0;eol=checks%37==0;
   @(posedge clk);#1;
   if({sv,ss,se,gv,gs,ge}!={valid,sof,eol,valid,sof,eol})$fatal(1,"threshold tags/latency changed");
   if(seed!==(a>=200&&a<=250&&sats[b]>=60&&vals[c]>=40))$fatal(1,"original blue seed range changed");
   if(grow!==(a>=190&&a<=260&&sats[b]>=36&&vals[c]>=28))$fatal(1,"blue growth boundary wrong");
   if(seed&&!grow)$fatal(1,"strong seed outside growth mask");
   checks++;@(negedge clk);
  end
  $display("TB_RESULT: BLUE_THRESHOLD PASS vectors=%0d all_hues/seed_unchanged/seed_subset/growth_boundaries/tags",checks);$finish;
 end
endmodule
