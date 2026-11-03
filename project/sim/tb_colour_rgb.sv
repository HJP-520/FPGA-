`timescale 1ns/1ps
module tb_colour_rgb;
 localparam W=320,H=160;
 reg clk=0,rst=0,iv=0,isu=0,iel=0;reg[95:0]data=0;reg[2:0]preset=0;
 always #5 clk=~clk;
 function automatic [23:0] blue_pixel(input [23:0] red_pixel);
 begin blue_pixel=(red_pixel==24'hc84100) ? 24'h3200c8 : {red_pixel[7:0],red_pixel[15:8],red_pixel[23:16]};end
 endfunction
 wire tv,lv,upd,lupd,err,lerr;wire[10:0]cx,cy,x0,x1,lx,ly,lx0,lx1;wire[9:0]y0,y1,ly0,ly1;
 wire[20:0]count,lcount;wire[95:0]pass;wire pv,ps,pe;wire[7:0]nfid,lfid;wire[2:0]npreset,lpreset;
 detect_top #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.REGION_EN(1),.STRICT_RED(1),.OBJECT_STABILITY_EN(1),.BLUE_STABILITY_EN(1)) dut(
 .I_clk(clk),.I_rst_n(rst),.I_tdata(data),.I_tvalid(iv),.I_tuser(isu),.I_tlast(iel),.I_preset_idx(preset),
 .O_tdata(pass),.O_tvalid(pv),.O_tuser(ps),.O_tlast(pe),
 .O_target_valid(tv),.O_cx(cx),.O_cy(cy),.O_min_x(x0),.O_max_x(x1),.O_min_y(y0),.O_max_y(y1),.O_count(count),.O_results_upd(upd),.O_sync_err(err),.O_result_fid(nfid),.O_result_preset(npreset));
 detect_top #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.REGION_EN(1),.STRICT_RED(1),.OBJECT_STABILITY_EN(1),.BLUE_STABILITY_EN(1)) blue_dut(
 .I_clk(clk),.I_rst_n(rst),.I_tdata({blue_pixel(data[95-:24]),blue_pixel(data[71-:24]),blue_pixel(data[47-:24]),blue_pixel(data[23-:24])}),.I_tvalid(iv),.I_tuser(isu),.I_tlast(iel),.I_preset_idx(3'd2),
 .O_target_valid(lv),.O_cx(lx),.O_cy(ly),.O_min_x(lx0),.O_max_x(lx1),.O_min_y(ly0),.O_max_y(ly1),.O_count(lcount),.O_results_upd(lupd),.O_sync_err(lerr),.O_result_fid(lfid),.O_result_preset(lpreset));
 integer frame_no=0,updates=0,lupdates=0,checks=0,new_min=9999,new_max=0,old_min=9999,old_max=0;
 integer phone_old_min=9999,phone_old_max=0,phone_new_min=9999,phone_new_max=0;
 function automatic [23:0] pixel(input integer f,xx,yy);
 integer dx,dy;reg circle,rectangle;
 begin
  dx=xx-140;dy=yy-80;circle=dx*dx+dy*dy<=48*48;
  rectangle=xx>=48&&xx<256&&yy>=40&&yy<120;
  pixel=24'h303030;
  case(f)
   0,1,2,3:if(circle)pixel=((f%2==0&&xx<140)||(f%2==1&&xx>=140))?24'hdc1e1e:24'h461414;
   4,5:if(rectangle)begin
    pixel=24'hb41e1e;
    if((f==4&&yy>=63&&yy<=80)||(f==5&&yy>=95&&yy<=112))pixel=24'h180202;
   end
   6:if(rectangle)pixel=24'hc84100; // near-red/orange growth but no strong red seed
   7:if(circle)pixel=24'h0000dc;
  endcase
 end endfunction
 always @(posedge clk)begin
  #1;if(rst)begin
   if({pass,pv,ps,pe}!={data,iv,isu,iel})$fatal(1,"main video changed");
   if(err||lerr||dut.u_ser.O_drop_cnt!=0||blue_dut.u_ser.O_drop_cnt!=0)$fatal(1,"RGB stream error/drop");
   if(upd)begin
    if(nfid!=frame_no+1||npreset!=preset)$fatal(1,"new frame/colour tag changed");
    $display("RGB_RED frame=%0d valid=%0d cx=%0d cy=%0d x0=%0d x1=%0d y0=%0d y1=%0d count=%0d",frame_no,tv,cx,cy,x0,x1,y0,y1,count);
    updates++;checks++;
    if(frame_no<4)begin
     if(!tv||cx<139||cx>141||cy<79||cy>83||x1-x0<90||y1-y0<90)$fatal(1,"whole red sphere not recovered frame=%d center=%d/%d bbox=%d/%d/%d/%d",frame_no,cx,cy,x0,x1,y0,y1);
     if(cx<new_min)new_min=cx;if(cx>new_max)new_max=cx;
    end
    if(frame_no==4||frame_no==5)begin
     if(!tv||x1-x0<200||y1-y0<75)$fatal(1,"phone red image fragmented");
     if(cy<phone_new_min)phone_new_min=cy;if(cy>phone_new_max)phone_new_max=cy;
    end
    if(frame_no==6&&tv)$fatal(1,"orange acquired without confident seed");
   end
   if(lupd)begin
    if(lfid!=frame_no+1||lpreset!=2)$fatal(1,"reference frame/colour tag changed");
    $display("RGB_BLUE frame=%0d valid=%0d cx=%0d cy=%0d x0=%0d x1=%0d y0=%0d y1=%0d count=%0d",frame_no,lv,lx,ly,lx0,lx1,ly0,ly1,lcount);
    lupdates++;
    if(frame_no<4)begin if(lx<old_min)old_min=lx;if(lx>old_max)old_max=lx;end
    if(frame_no==4||frame_no==5)begin if(ly<phone_old_min)phone_old_min=ly;if(ly>phone_old_max)phone_old_max=ly;end
   end
  end
 end
 task idle(input integer n);repeat(n)@(negedge clk);endtask
 task frame(input integer f);
 integer u,l,limit,fd;
 begin
  frame_no=f;preset=0;u=updates;l=lupdates;idle(10);
  fd=$fopen($sformatf("rgb_input_%0d.hex",f),"w");if(!fd)$fatal(1,"RGB capture failed");
  for(integer yy=0;yy<H;yy++)begin
   for(integer b=0;b<W/4;b++)begin
    for(integer k=0;k<4;k++)begin data[95-24*k-:24]=pixel(f,b*4+k,yy);$fdisplay(fd,"%06x",pixel(f,b*4+k,yy));end
    iv=1;isu=(yy==0&&b==0);iel=(b==W/4-1);idle(1);
    iv=0;isu=0;iel=0;idle(3);
   end
   idle(8);
  end
  $fclose(fd);
  limit=0;while(updates==u||lupdates==l)begin idle(1);limit++;if(limit>40000)$fatal(1,"RGB analysis timeout");end
  idle(5);
  if({tv,cx,cy,x0,x1,y0,y1,count}!={lv,lx,ly,lx0,lx1,ly0,ly1,lcount})$fatal(1,"red/blue region result mismatch");
 end endtask
 initial begin
  idle(8);rst=1;idle(10);
  for(integer f=0;f<7;f++)frame(f);
  if(new_max-new_min!=0||old_max-old_min!=0)$fatal(1,"sphere center jitter comparison invalid %d/%d",old_max-old_min,new_max-new_min);
  if(phone_new_max-phone_new_min!=0||phone_old_max-phone_old_min!=0)$fatal(1,"phone dark-band comparison invalid");
  $display("RGB_COMPARISON sphere_blue_x_range=%0d red_x_range=%0d phone_blue_y_range=%0d red_y_range=%0d",old_max-old_min,new_max-new_min,phone_old_max-phone_old_min,phone_new_max-phone_new_min);
  $display("TB_RESULT: COLOUR_RGB PASS frames=%0d full_pipeline/sphere_shading/phone_bands/seed_gate/red_blue_equal/passthrough",checks);$finish;
 end
 initial begin #50000000;$fatal(1,"timeout");end
endmodule
