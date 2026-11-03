`timescale 1ns/1ps
module tb_local_protocol;
 reg clk=0,rst=0,sof=0,v=0,eol=0,gray=1;reg[95:0]rgb={12{8'd100}};
 always #5 clk=~clk;
 wire ready;wire[7:0]a,b;wire[4:0]f;
 binary_local_map #(.W(64),.H(32)) dut(clk,rst,sof,v,eol,gray,rgb,a,b,f,ready);
 task cycle;@(negedge clk);endtask
 task frame(input integer bad,input integer expected);
  begin
   sof=1;v=0;eol=0;#1;
   // usable includes EOL geometry; first x=0 is valid geometry even with v=0.
   if(ready!==expected)$fatal(1,"SOF map commit bad=%0d expected=%0d",bad,expected);
   cycle;sof=0;repeat(4)cycle;
   for(integer y=0;y<32;y++)for(integer x=0;x<64;x+=4)begin
    v=1;eol=x==60;
    if(bad==1&&y==3&&x==20)eol=1;
    cycle;
   end
   v=0;eol=0;
   if(bad==2)begin v=1;cycle;v=0;end
   repeat(50)cycle;
  end
 endtask
 initial begin
  repeat(5)cycle;rst=1;repeat(5)cycle;
  frame(0,0);frame(1,1);frame(0,0);frame(2,1);frame(0,0);frame(0,1);
  gray=0;cycle;gray=1;frame(0,0);frame(0,1);
  rst=0;cycle;rst=1;frame(0,0);frame(0,1);
  $display("TB_RESULT: LOCAL_PROTOCOL PASS early_EOL/extra_tail/no_torn_map/gray_exit/reset");$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule
