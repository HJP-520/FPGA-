`timescale 1ns/1ps
module tb_title;
 reg clk=0,rst=0,hit=0;reg[8:0]x=0;reg[5:0]y=0;
 always #5 clk=~clk;
 wire[1:0]coverage;
 ui_title_rom dut(.clk(clk),.rst_n(rst),.hit(hit),.x(x),.y(y),.coverage(coverage));
 reg[1:0]golden[0:15359];reg[1:0]e0=0,e1=0;integer checks=0;
 initial begin
  $readmemh("title_golden.hex",golden);
  #1;for(integer i=0;i<15360;i++)
   if((^golden[i])===1'bx)$fatal(1,"golden ROM missing/unknown pixel=%0d",i);
 end
 always @(posedge clk)begin
  if(!rst)begin e0=0;e1=0;end
  else begin
   e1=e0;e0=(hit&&x<320&&y<48)?golden[y*320+x]:0;
   #1;if((^e1)===1'bx || (^coverage)===1'bx || coverage!==e1)$fatal(1,"title mismatch at %d/%d",x,y);
   checks++;
  end
 end
 initial begin
  repeat(5)@(negedge clk);rst=1;
  for(integer row=0;row<52;row++)begin
   for(integer col=0;col<336;col++)begin
    hit=1;x=col;y=row;@(negedge clk);
   end
   hit=0;repeat(8)@(negedge clk);
  end
  repeat(5)@(negedge clk);
  $display("TB_RESULT: NATIVE_TITLE PASS checks=%0d native320x48/coverage/bounds/latency",checks);$finish;
 end
endmodule
