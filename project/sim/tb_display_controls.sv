`timescale 1ns/1ps
module tb_display_controls;
 reg clk=0,rst=0,iv=0,iu=0,il=0,ivs=0,cload=0,rload=0;reg[134:0]target=0;reg[23:0]id=24'h203040;reg[11:0]cfg=12'hc03;
 always #5 clk=~clk;
 wire ov,ou,ol,ovs;wire[23:0]od;
 ui_hud_v17_r1 dut(.clk(clk),.rst_n(rst),.iv(iv),.iu(iu),.il(il),.ivs(ivs),.id(id),
 .config_data(cfg),.config_load(cload),.result_data(target),.result_load(rload),.led_n(4'd0),
 .ov(ov),.ou(ou),.ol(ol),.ovs(ovs),.od(od));
 reg[23:0]logo[0:20479];integer xx[0:2],yy[0:2],ff[0:2];reg[2:0]ev=0,eu=0,el=0,es=0;
 integer x=0,y=0,f=0,checks=0,info_pixels=0,axis_hits=0,logo_pixels=0,box_hits=0,fd;
 reg want_axes=1,want_info=1;
 initial begin $readmemh("logo_rgb888.hex",logo);fd=$fopen("display_controls.hex","w");end
 always @(posedge clk)begin
  if(!rst)begin ev=0;eu=0;el=0;es=0;
   for(integer j=0;j<3;j++)begin xx[j]=0;yy[j]=0;ff[j]=0;end
  end else begin
   for(integer j=2;j>0;j--)begin xx[j]=xx[j-1];yy[j]=yy[j-1];ff[j]=ff[j-1];end
   xx[0]=x;yy[0]=y;ff[0]=f;
   ev={ev[1:0],iv};eu={eu[1:0],iu};el={el[1:0],il};es={es[1:0],ivs};
   #1;if({ov,ou,ol,ovs}!=={ev[2],eu[2],el[2],es[2]})$fatal(1,"display sync changed");
   if(ov)begin
    if((^od)===1'bx)$fatal(1,"unknown display pixel");
    checks++;
    if(xx[2]>=16&&xx[2]<272&&yy[2]>=16&&yy[2]<96)begin
     if(od!==logo[(yy[2]-16)*256+xx[2]-16])$fatal(1,"info toggle hid/corrupted logo");
     logo_pixels++;
    end
    if(xx[2]>=1024&&xx[2]<1264&&yy[2]>=64&&yy[2]<220)begin
     if(!want_info&&od!==24'h203040)$fatal(1,"K4 info remained visible at %d/%d",xx[2],yy[2]);
     if(od!=24'h203040)info_pixels++;
    end
    if((xx[2]==600&&yy[2]==360)||(xx[2]==640&&yy[2]==300))begin
     if(od!==(want_axes?24'hb8b8b8:24'h203040))$fatal(1,"K3 axes pixel mismatch f=%0d x=%0d y=%0d",ff[2],xx[2],yy[2]);
     axis_hits++;
    end
    if(xx[2]==500&&yy[2]==300)begin
     if(od!==24'hff3030)$fatal(1,"display controls hid target box f=%0d od=%h valid=%b box=%d/%d/%d/%d sv=%b",ff[2],od,dut.tv,dut.x0,dut.x1,dut.y0,dut.y1,dut.sv);box_hits++;
    end
    if(xx[2]==520&&yy[2]==300&&od!==24'hffd250)$fatal(1,"display controls hid target cross");
    if(yy[2]<104)$fdisplay(fd,"%06x",od);
   end
  end
 end
 initial begin
  repeat(5)@(negedge clk);rst=1;
  target[134]=1;target[129:119]=520;target[118:108]=300;
  target[107:97]=500;target[96:86]=540;target[85:76]=280;target[75:66]=320;
  for(integer frame=0;frame<4;frame++)begin
   f=frame;want_axes=(frame%2==0);want_info=(frame<2);
   cfg=12'hc00|(want_axes?12'h002:12'h000)|(want_info?12'h001:12'h000);
   target[65:58]=frame+1;
   cload=1;ivs=1;@(negedge clk);cload=0;rload=1;repeat(5)@(negedge clk);ivs=0;rload=0;repeat(400)@(negedge clk);
   info_pixels=0;axis_hits=0;logo_pixels=0;box_hits=0;
   for(integer row=0;row<400;row++)begin
    for(integer col=0;col<1280;col++)begin
     x=col;y=row;iv=1;iu=(row==0&&col==0);il=(col==1279);id=24'h203040;
     if(x>=16&&x<272&&y>=16&&y<96)id=logo[(y-16)*256+x-16];
     @(negedge clk);
    end
    iv=0;iu=0;il=0;repeat(8)@(negedge clk);
   end
   repeat(8)@(negedge clk);
   if(axis_hits!=2||logo_pixels!=20480||box_hits!=1)$fatal(1,"probe coverage missing");
   if(want_info&&info_pixels<100)$fatal(1,"enabled info absent");
   $display("DISPLAY_CASE axes=%0d info=%0d info_pixels=%0d logo_pixels=%0d",want_axes,want_info,info_pixels,logo_pixels);
  end
  $fclose(fd);if(checks!=2048000)$fatal(1,"frame pixel count");
  $display("TB_RESULT: DISPLAY_CONTROLS PASS pixels=%0d four_states/axes/info/visible_logo/sync",checks);$finish;
 end
endmodule
