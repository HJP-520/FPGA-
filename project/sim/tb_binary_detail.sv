`timescale 1ns/1ps
module tb_binary_detail;
 parameter W=256,H=96,F=12;
 localparam N=W/4*(H*F-(F>5?H-8:0));
 reg clk=0,rst=0,v=0,u=0,l=0,gray=1;reg[1:0]curve=3;reg[95:0]data=0;
 always #5 clk=~clk;
 wire ov,ou,ol,lv,lu,ll;wire[95:0]od,ld;
 axis_gray_curve_rgb96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.DETAIL_EN(1)) dut(clk,rst,l,u,data,v,curve,gray,ol,ou,od,ov);
 axis_gray_curve_rgb96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H)) legacy(clk,rst,l,u,data,v,curve,gray,ll,lu,ld,lv);
 reg[95:0]inputs[0:N-1],gold[0:N-1];reg[20:0]mapgold[0:N-1];
 reg[95:0]g0=0,g1=0,g2=0,ld0=0,ld1=0;reg[2:0]vp=0,up=0,lp=0,localp=0;
 reg[1:0]cp0=0,cp1=0,cp2=0;integer idx=0,checked=0,localchecked=0,fcur=0,rows=0;reg ready=0;
 always @(posedge clk)begin
  if(rst)begin
   g2<=g1;g1<=g0;g0<=v?gold[idx]:0;
   cp2<=cp1;cp1<=cp0;cp0<=curve;
   vp<={vp[1:0],v};up<={up[1:0],u};lp<={lp[1:0],l};localp<={localp[1:0],ready&&gray&&curve==3};
   ld1<=ld0;ld0<=ld;
   if(v)begin
    if(dut.local_gray.detail.map.usable!==ready)$fatal(1,"map readiness f=%0d idx=%0d",fcur,idx);
    if(ready&&{dut.local_gray.detail.ml,dut.local_gray.detail.mr,dut.local_gray.detail.frac}!==mapgold[idx])
     $fatal(1,"map interpolation f=%0d x=%0d y=%0d got=%h expected=%h",fcur,dut.local_gray.detail.map.x,dut.local_gray.detail.map.y,{dut.local_gray.detail.ml,dut.local_gray.detail.mr,dut.local_gray.detail.frac},mapgold[idx]);
    idx++;
   end
   #1;
   if({ov,ou,ol}!=={vp[2],up[2],lp[2]})$fatal(1,"three clock tags");
   if(ov)begin
    if(od!==(localp[2]?g2:ld1))$fatal(1,"pixels count=%0d local=%0d got=%h expected=%h",checked,localp[2],od,localp[2]?g2:ld1);
    checked++;if(localp[2])localchecked++;
   end
  end
 end
 task idle(input integer n);repeat(n)@(negedge clk);endtask
 initial begin
  $readmemh($sformatf("input_%0d.hex",W),inputs);$readmemh($sformatf("gold_%0d.hex",W),gold);$readmemh($sformatf("map_%0d.hex",W),mapgold);
  idle(5);rst=1;idle(5);
  for(integer f=0;f<F;f++)begin
   fcur=f;gray=f!=8;curve=(f==8||f==11)?0:f==9?2:f==10?1:3;
   ready=f!=0&&f!=6&&f!=8&&f!=9;
   rows=f==5?8:H;
   if(f%2==1)begin u=1;idle(1);u=0;idle(3);end
   for(integer y=0;y<rows;y++)begin
    for(integer x=0;x<W;x+=4)begin
     v=1;u=f%2==0&&x==0&&y==0;l=x==W-4;data=inputs[idx];idle(1);v=0;u=0;l=0;
     if(f%3==2)idle((x/4+y)%3);
    end
   end
   idle(64);
  end
  idle(20);
  if(checked!=N||idx!=N||localchecked==0)$fatal(1,"count %0d/%0d/%0d",checked,idx,N);
  $display("DETAIL_PIXELS width=%0d pixels=%0d local_pixels=%0d",W,checked*4,localchecked*4); if(W==1280) $display("TB_RESULT: BINARY_DETAIL720P PASS"); else $display("TB_RESULT: BINARY_DETAIL PASS");$finish;
 end
 initial begin #200000000;$fatal(1,"timeout");end
endmodule
