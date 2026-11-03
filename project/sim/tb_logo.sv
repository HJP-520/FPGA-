`timescale 1ns/1ps
module tb_logo;
 reg clk=0,rst=0,de=0,vs=0;reg[23:0] data=0;
 always #5 clk=~clk;
 wire[23:0] out;wire od,ov;
 ui_logo_page dut(.I_clk(clk),.I_rst_n(rst),.I_de(de),.I_vsync(vs),
 .I_cam_data(data),.O_data(out),.O_de(od),.O_vsync(ov));
 reg[23:0] golden[0:20479];
 reg[23:0] expected[0:3];reg[3:0] ed=0,ev=0;
 reg[23:0] pixel;integer x=-1,y=-1,count=0;
 initial $readmemh("logo_rgb888.hex",golden);
 always @(posedge clk)begin
  if(!rst)begin
   for(integer j=0;j<4;j++)expected[j]=0;ed=0;ev=0;
  end else begin
   pixel=data;
   if(de && x>=16 && x<272 && y>=16 && y<96)begin
    pixel=golden[(y-16)*256+x-16];
    // 2026-10-26：白底(FFFFFF) + 近白抗锯齿(BABEC6/DCDFE3/FBDFE0) 键控为透明，该处透出视频
    if(pixel==24'hFFFFFF||pixel==24'hBABEC6||pixel==24'hDCDFE3||pixel==24'hFBDFE0)pixel=data;
   end
   for(integer j=3;j>0;j--)expected[j]=expected[j-1];
   expected[0]=pixel;ed={ed[2:0],de};ev={ev[2:0],vs};
   #1;
   if(od!==ed[3] || ov!==ev[3] || out!==expected[3])
    $fatal(1,"video/ROM alignment x=%0d y=%0d out=%h expected=%h",x,y,out,expected[3]);
   if(od)count++;
  end
 end
 initial begin
  repeat(5)@(negedge clk);rst=1;vs=1;
  repeat(5)@(negedge clk);vs=0;
  for(integer row=0;row<104;row++)begin
   for(integer col=0;col<1280;col++)begin
    de=1;x=col;y=row;data={row[7:0],col[7:0],8'h63};@(negedge clk);
   end
   de=0;repeat(8)@(negedge clk);
  end
  repeat(8)@(negedge clk);
  if(count!=133120)$fatal(1,"de count mismatch");
  $display("TB_RESULT: LOGO PASS pixels=%0d native256x80 RGB/de/vsync",count);$finish;
 end
endmodule
