`timescale 1ns/1ps
module tb_font_compact;
 reg clk=0;reg[11:0]addr=0;wire[31:0]q;reg[31:0]gold[0:4095];integer checks=0;
 always #5 clk=~clk;
 ui_font_rom dut(clk,addr,q);
 initial begin
  $readmemh("ui_font.dath",gold);
  for(integer pass=0;pass<2;pass++)for(integer i=0;i<4096;i++)begin
   @(negedge clk);addr=pass==0?i:(4095-i);
   @(posedge clk);#1;if(q!==gold[addr])$fatal(1,"font row changed %0d %h/%h",addr,q,gold[addr]);checks++;
  end
  $display("TB_RESULT: FONT_COMPACT PASS checks=%0d all4096addresses/32bit_pixels/forward_reverse/same_cycle",checks);$finish;
 end
endmodule
