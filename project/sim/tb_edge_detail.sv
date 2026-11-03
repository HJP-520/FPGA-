`timescale 1ns/1ps
module tb_edge_detail;
 localparam W=128,H=64,N=W*H/4;
 reg clk=0,rst=0,iv=0,iu=0,il=0;reg[95:0]data=0;reg[1:0]mode=0;
 always #5 clk=~clk;
 wire ov,ou,ol,lv,lu,ll;wire[95:0]out,oldout;
 axis_edge_mode_rgb96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.EDGE_TH(60),.DENOISE_EN(1))dut(clk,rst,il,iu,data,iv,mode,ol,ou,out,ov);
 v15_axis_edge_mode_rgb96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.EDGE_TH(60))old(clk,rst,il,iu,data,iv,mode,ll,lu,oldout,lv);
 reg[95:0]inputs[0:N-1];reg[1:0]newmask[0:N-1],oldmask[0:N-1];reg[2:0]s=0;
 integer got=0,lgot=0,checks=0,scene=0,variant=0,white=0;string name;
 function[23:0]paint(input[23:0]p,input on,input[1:0]m);
 begin case(m)
  0:paint=p;1:paint=on?24'hffffff:0;2:paint=on?24'hffffff:p;
  3:paint=on?0:{p[23:20],p[23:20],p[15:12],p[15:12],p[7:4],p[7:4]};
 endcase end endfunction
 always @(posedge clk)begin
  if(!rst)s=0;else begin
   s={s[1:0],iu};#1;
   if(ou!==s[2]||lu!==ou||lv!==ov||ll!==ol)$fatal(1,"EDGE_PROTOCOL_CHANGED");
   if(ov)begin
    if(got>=N||dut.edge_bits!==newmask[got]||old.edge_bits!==oldmask[got])$fatal(1,"EDGE_MASK_MISMATCH scene=%0d mode=%0d variant=%0d index=%0d actual=%b expected=%b old=%b oldexpected=%b",scene,mode,variant,got,dut.edge_bits,newmask[got],old.edge_bits,oldmask[got]);
    if(ol!==(got%(W/4)==W/4-1))$fatal(1,"EDGE_EOL");
    for(integer p=0;p<4;p++)begin
     if(out[95-24*p-:24]!==paint(inputs[got][95-24*p-:24],newmask[got][p/2],mode))$fatal(1,"NEW_PAINT_RAW_DETAIL");
     if(oldout[95-24*p-:24]!==paint(inputs[got][95-24*p-:24],oldmask[got][p/2],mode))$fatal(1,"FROZEN_V15_PAINT");
     if(mode==2&&newmask[got][p/2])white++;
    end
    got++;lgot++;checks+=4;
   end
  end
 end
 task step;@(negedge clk);endtask
 initial begin
  for(integer v=0;v<3;v++)for(integer a=0;a<13;a++)for(integer b=0;b<4;b++)begin
   variant=v;scene=a;mode=b;rst=0;iv=0;iu=0;il=0;repeat(4)step;got=0;lgot=0;rst=1;repeat(4)step;
   $sformat(name,"../../../sim/edge_detail_fixture/s%0d_input.hex",a);$readmemh(name,inputs);
   $sformat(name,"../../../sim/edge_detail_fixture/s%0d_new.hex",a);$readmemh(name,newmask);
   $sformat(name,"../../../sim/edge_detail_fixture/s%0d_old.hex",a);$readmemh(name,oldmask);
   if(v==2)begin iu=1;step;iu=0;repeat(5)step;end
   for(integer k=0;k<N;k++)begin
    iv=1;iu=k==0&&v!=2;il=k%(W/4)==W/4-1;data=inputs[k];step;
    iv=0;iu=0;il=0;
    if(v==1)repeat((k*17+k/13)%4)step;
    if(v!=0&&k%(W/4)==W/4-1)repeat(4)step;
   end
   repeat(12)step;
   if(got!=N||lgot!=N)$fatal(1,"EDGE_COUNT");
  end
  if(white==0)$fatal(1,"NO_WHITE_OVERLAY");
  $display("TB_RESULT: EDGE_DETAIL PASS pixels=%0d modes4/scenes13/continuous/bubbles/early_sof/white_overlay/raw_RGB_exact/frozen_v15",checks);$finish;
 end
 initial begin #1000000000;$fatal(1,"timeout");end
endmodule

module tb_edge_detail720p;
 localparam W=1280,H=720,N=W*H/4;
 reg clk=0,rst=0,iv=0,iu=0,il=0;reg[95:0]data=0;reg[1:0]mode=0;
 always #5 clk=~clk;
 wire ov,ou,ol;wire[95:0]out;
 axis_edge_mode_rgb96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.EDGE_TH(60),.DENOISE_EN(1))dut(clk,rst,il,iu,data,iv,mode,ol,ou,out,ov);
 reg[95:0]inputs[0:N-1];reg[1:0]mask[0:N-1];reg[2:0]s=0;
 integer got=0,k=0,f=0,idx,output_frame;reg[1:0]expected_mode;reg[23:0]p,expected;
 always @(posedge clk)begin
  if(!rst)s=0;else begin
   s={s[1:0],iu};#1;if(ou!==s[2])$fatal(1,"FULL_SOF");
   if(ov)begin
    if(got>=3*N)$fatal(1,"FULL_EXTRA");
    idx=got%N;output_frame=got/N;expected_mode=output_frame==0?0:output_frame==1?2:3;
    if(dut.mode!==expected_mode||dut.edge_bits!==mask[idx])$fatal(1,"FULL_EDGE_MASK idx=%0d frame=%0d got=%b expected=%b",idx,output_frame,dut.edge_bits,mask[idx]);
    if(ol!==(idx%(W/4)==W/4-1))$fatal(1,"FULL_EOL");
    for(integer j=0;j<4;j++)begin
     p=inputs[idx][95-24*j-:24];
     expected=expected_mode==0?p:expected_mode==2?(mask[idx][j/2]?24'hffffff:p):
      (mask[idx][j/2]?24'd0:{p[23:20],p[23:20],p[15:12],p[15:12],p[7:4],p[7:4]});
     if(out[95-24*j-:24]!==expected)$fatal(1,"FULL_PIXEL");
    end
    got++;
   end
  end
 end
 task step;@(negedge clk);endtask
 initial begin
  $readmemh("../../../sim/edge_detail_fixture/full_input.hex",inputs);
  $readmemh("../../../sim/edge_detail_fixture/full_new.hex",mask);
  repeat(5)step;rst=1;repeat(5)step;
  for(f=0;f<3;f++)begin
   mode=f==0?0:f==1?2:3;
   if(f==2)begin iv=0;iu=1;il=0;step;iu=0;repeat(6)step;end
   for(k=0;k<N;k++)begin
    iv=1;iu=k==0&&f!=2;il=k%(W/4)==W/4-1;data=inputs[k];step;
    // First two frames touch with no idle; final frame has internal bubbles.
    if(f==2&&k%197==0)begin iv=0;iu=0;il=0;repeat(k%3+1)step;end
   end
  end
  iv=0;iu=0;il=0;repeat(20)step;
  if(got!=3*N)$fatal(1,"FULL_DROP %0d",got);
  $display("TB_RESULT: EDGE_DETAIL720P PASS pixels=%0d three_frames/back_to_back_frames/mode_tags/early_sof/bubbles/EOL/raw_exact/white/cartoon",got*4);$finish;
 end
 initial begin #1000000000;$fatal(1,"timeout");end
endmodule
