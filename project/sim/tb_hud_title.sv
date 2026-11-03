`timescale 1ns/1ps
module tb_hud_title;
 reg clk=0,rst=0,iv=0,iu=0,il=0,ivs=0,cload=0;reg[23:0]id=24'h2e3642;
 always #5 clk=~clk;
 wire ov,ou,ol,ovs;wire[23:0]od;
 ui_hud_v17_r1 dut(.clk(clk),.rst_n(rst),.iv(iv),.iu(iu),.il(il),.ivs(ivs),.id(id),
 .config_data(12'h403),.config_load(cload),.result_data(135'd0),.result_load(1'b0),.led_n(4'd0),
 .ov(ov),.ou(ou),.ol(ol),.ovs(ovs),.od(od));
 reg[1:0]title[0:15359];reg[23:0]logo[0:20479];
 reg[23:0]expected[0:2];reg[2:0]ev=0,eu=0,el=0,es=0,checkrgb=0;
 reg[23:0]pixel;integer x=0,y=0,checks=0,fd;
 initial begin
  $readmemh("title_golden.hex",title);$readmemh("logo_rgb888.hex",logo);
  #1;for(integer j=0;j<15360;j++)if((^title[j])===1'bx)$fatal(1,"missing title golden");
  fd=$fopen("hud_frame.hex","w");if(!fd)$fatal(1,"capture open failure");
 end
 function[23:0]color(input[1:0]v);
  case(v)0:color=24'h2e3642;1:color=24'h0c1017;2:color=24'h9baabc;3:color=24'hf4f7fb;endcase
 endfunction
 always @(posedge clk)begin
  if(!rst)begin
   for(integer j=0;j<3;j++)expected[j]=0;ev=0;eu=0;el=0;es=0;checkrgb=0;
  end else begin
   pixel=id;
   if(iv&&x>=288&&x<608&&y>=16&&y<64)pixel=color(title[(y-16)*320+x-288]);
   expected[2]=expected[1];expected[1]=expected[0];expected[0]=pixel;
   checkrgb={checkrgb[1:0],iv&&((x>=288&&x<608&&y>=16&&y<64)||(x>=16&&x<272&&y>=16&&y<96))};
   ev={ev[1:0],iv};eu={eu[1:0],iu};el={el[1:0],il};es={es[1:0],ivs};
   #1;
   if({ov,ou,ol,ovs}!=={ev[2],eu[2],el[2],es[2]})$fatal(1,"HUD markers misaligned");
   if(checkrgb[2]&&(od!==expected[2]||(^od)===1'bx))$fatal(1,"HUD title/logo pixel mismatch x=%d y=%d %h/%h",x,y,od,expected[2]);
   if(ov)begin $fdisplay(fd,"%06x",od);checks++;end
  end
 end
 initial begin
  repeat(5)@(negedge clk);rst=1;cload=1;ivs=1;@(negedge clk);cload=0;repeat(5)@(negedge clk);ivs=0;
  for(integer row=0;row<104;row++)begin
   for(integer col=0;col<1280;col++)begin
    x=col;y=row;iv=1;iu=(row==0&&col==0);il=col==1279;id=24'h2e3642;
    if(x>=16&&x<272&&y>=16&&y<96)id=logo[(y-16)*256+x-16];
    @(negedge clk);
   end
   iv=0;iu=0;il=0;repeat(8)@(negedge clk);
  end
  repeat(8)@(negedge clk);$fclose(fd);
  if(checks!=133120)$fatal(1,"pixel count");
  $display("TB_RESULT: HUD_TITLE PASS pixels=%0d native_title/logo_protection/stream_alignment",checks);$finish;
 end
endmodule
