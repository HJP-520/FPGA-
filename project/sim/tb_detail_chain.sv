`timescale 1ns/1ps
module tb_detail_chain;
 localparam W=1280,H=720,F=3,BYTES=W*H*3;
 reg clk=0,rst=0,v=0,u=0,l=0;reg[95:0]data=0;
 always #5 clk=~clk;
 wire ev,eu,el,pv,pu,pl;wire[95:0]ed;wire[127:0]pd;
 wire gv,gu,gl;wire[95:0]gd;
 axis_gray_curve_rgb96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.DETAIL_EN(1)) gray_path(clk,rst,l,u,data,v,2'd0,1'b0,gl,gu,gd,gv);
 axis_edge_mode_rgb96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H)) edge_path(clk,rst,gl,gu,gd,gv,2'd0,el,eu,ed,ev);
 data_96bit_to_128bit repack(clk,rst,eu,ev,el,ed,pu,pl,pv,pd);
 integer words=0,sof_count=0;reg[127:0]gold;
 function[23:0]pix(input integer f,x,y);
  pix={8'(x*13+y*3+f*7),8'(x*5+y*11+f*19),8'(x*23+y*17+f*31)};
 endfunction
 function[7:0]byte_at(input integer index);
  integer f,p,x,y,c;reg[23:0]rgb;
  begin f=index/BYTES;p=(index%BYTES)/3;c=index%3;x=p%W;y=p/W;rgb=pix(f,x,y);case(c)0:byte_at=rgb[23:16];1:byte_at=rgb[15:8];2:byte_at=rgb[7:0];endcase end
 endfunction
 always @(posedge clk)begin #1;if(rst)begin
  if(pu)sof_count++;
  if(pv)begin
   for(integer b=0;b<16;b++)gold[127-8*b-:8]=byte_at(words*16+b);
   if(pd!==gold)$fatal(1,"video/repack bytes changed word=%0d actual=%h expected=%h",words,pd,gold);
   if(pl!==(words%(W*3/16)==W*3/16-1))$fatal(1,"video EOL changed");words++;
  end
 end end
 task idle(input integer n);repeat(n)@(negedge clk);endtask
 initial begin
  idle(5);rst=1;idle(5);
  for(integer f=0;f<F;f++)begin
   if(f==1)begin u=1;idle(1);u=0;idle(64);end
   for(integer y=0;y<H;y++)begin
    for(integer x=0;x<W;x+=4)begin
     v=1;u=f!=1&&x==0&&y==0;l=x==W-4;
     for(integer k=0;k<4;k++)data[95-24*k-:24]=pix(f,x+k,y);
     idle(1);v=0;u=0;l=0;if(f==2)idle((x/4+y)%3);
    end
    if(f!=0)idle(5);
   end
   // Frame 0 -> 1 includes early SOF; 1 -> 2 has no reset and direct SOF.
  end
  v=0;u=0;l=0;idle(40);
  if(words!=F*BYTES/16||sof_count!=F)$fatal(1,"video counts %0d/%0d",words,sof_count);
  $display("TB_RESULT: DETAIL_CHAIN PASS pixels=%0d raw_RGB_exact/repack/EOL/early_SOF/back_to_back_frames/bubbles",F*W*H);$finish;
 end
 initial begin #100000000;$fatal(1,"timeout");end
endmodule
