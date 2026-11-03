`timescale 1ns/1ps
module tb_red_regions;
 localparam W=320,H=160;
 reg clk=0,rst=0,valid=0,sof=0,eol=0,grow_mask=0,seed_mask=0;reg[2:0]preset=0;reg[7:0]fid=0;
 always #5 clk=~clk;
 wire tv,lv,upd,lupd,err,lerr;wire[10:0]cx,cy,x0,x1,lx,ly,lx0,lx1;wire[9:0]y0,y1,ly0,ly1;
 wire[20:0]count,lcount;wire[7:0]rf,lf;
 track_region_accum #(.IMG_WIDTH(W),.IMG_HEIGHT(H),.RED_STABLE(1)) dut(
 .I_clk(clk),.I_rst_n(rst),.I_valid(valid),.I_sof(sof),.I_eol(eol),.I_mask(grow_mask),.I_seed(seed_mask),.I_preset(preset),.I_fid(fid),
 .O_target_valid(tv),.O_cx(cx),.O_cy(cy),.O_min_x(x0),.O_max_x(x1),.O_min_y(y0),.O_max_y(y1),.O_count(count),.O_results_upd(upd),.O_error(err),.O_fid(rf));
 track_region_accum #(.IMG_WIDTH(W),.IMG_HEIGHT(H)) legacy(
 .I_clk(clk),.I_rst_n(rst),.I_valid(valid),.I_sof(sof),.I_eol(eol),.I_mask(seed_mask),.I_seed(seed_mask),.I_preset(preset),.I_fid(fid),
 .O_target_valid(lv),.O_cx(lx),.O_cy(ly),.O_min_x(lx0),.O_max_x(lx1),.O_min_y(ly0),.O_max_y(ly1),.O_count(lcount),.O_results_upd(lupd),.O_error(lerr),.O_fid(lf));
 integer scenario=0,phase=0,updates=0,lupdates=0,checks=0,old_min=9999,old_max=0,new_min=9999,new_max=0;
 function automatic in_a(input integer xx,yy,offset);
  in_a=xx>=32+offset&&xx<96+offset&&yy>=32&&yy<80;
 endfunction
 function automatic in_b(input integer xx,yy);
  in_b=xx>=224&&xx<288&&yy>=32&&yy<96;
 endfunction
 function automatic grow_at(input integer xx,yy);
  case(scenario)
   0:grow_at=xx>=64&&xx<192&&yy>=48&&yy<112&&!(xx>=96&&xx<128);
   1:grow_at=(phase<4&&in_a(xx,yy,phase==3?16:0))||(phase>0&&in_b(xx,yy));
   2:grow_at=xx>=64&&xx<192&&yy>=48&&yy<112;
   3:grow_at=(xx>=32&&xx<96&&yy>=32&&yy<80)||(xx>=224&&xx<288&&yy>=32&&yy<96);
   4:grow_at=xx>=64&&xx<192&&yy>=48&&yy<112&&(phase==0||xx<96||xx>=160);
   default:grow_at=0;
  endcase
 endfunction
 function automatic seed_at(input integer xx,yy);
  case(scenario)
   0:seed_at=yy>=48&&yy<112&&(phase%2==0?(xx>=64&&xx<96):(xx>=160&&xx<192));
   1:seed_at=grow_at(xx,yy);
   2:seed_at=0; // grow_mask red/orange with no confident red seed must not acquire.
   3:seed_at=grow_at(xx,yy); // blue path must remain exactly legacy.
   4:seed_at=grow_at(xx,yy)&&(phase==0||(phase%2?xx>=160:xx<96));
   default:seed_at=0;
  endcase
 endfunction
 always @(posedge clk)begin
  #1;if(rst)begin
   if(err||lerr)$fatal(1,"region protocol error");
   if(upd)begin
    updates++;
    if(rf!=fid)$fatal(1,"frame tag mismatch");
    case(scenario)
     0:begin
      if(!tv||cx!=127||cy!=79||x0!=64||x1!=191||y0!=48||y1!=111||count!=6144)
       $fatal(1,"fragmented object not recovered c=%d/%d bbox=%d/%d/%d/%d n=%d",cx,cy,x0,x1,y0,y1,count);
      if(cx<new_min)new_min=cx;if(cx>new_max)new_max=cx;
     end
     1:begin
      if(phase<=2&&(!tv||cx!=63||cy!=55))$fatal(1,"larger distractor stole lock phase=%d center=%d",phase,cx);
      if(phase==3&&(!tv||cx!=79||cy!=55))$fatal(1,"moving target not followed");
      if(phase>=4&&phase<=6&&tv)$fatal(1,"unrelated object accepted before loss confirmation");
      if(phase==7&&(!tv||cx!=255||cy!=63))$fatal(1,"reacquisition after confirmed loss failed center=%d",cx);
     end
     2:if(tv)$fatal(1,"grow_mask-only region acquired without red seed");
     4:if(!tv||cx!=127||cy!=79||x0!=64||x1!=191)$fatal(1,"known object split by wide band phase=%d center=%d bbox=%d/%d",phase,cx,x0,x1);
    endcase
    checks++;
   end
   if(lupd)begin
    lupdates++;
    if(scenario==0)begin if(lx<old_min)old_min=lx;if(lx>old_max)old_max=lx;end
   end
  end
 end
 task idle(input integer n);repeat(n)@(negedge clk);endtask
 task reset;
 begin rst=0;valid=0;sof=0;eol=0;idle(6);rst=1;idle(8);end endtask
 task frame;
 integer u,l,limit;
 begin
  u=updates;l=lupdates;fid=fid+1;
  for(integer yy=0;yy<H;yy++)begin
   for(integer xx=0;xx<W;xx++)begin
    valid=1;sof=(yy==0&&xx==0);eol=xx==W-1;grow_mask=grow_at(xx,yy);seed_mask=seed_at(xx,yy);@(negedge clk);
   end
   valid=0;sof=0;eol=0;idle(2);
  end
  limit=0;while(updates==u||lupdates==l)begin idle(1);limit++;if(limit>30000)$fatal(1,"analysis did not finish");end
  idle(4);
  if(scenario==3&&{tv,cx,cy,x0,x1,y0,y1,count}!={lv,lx,ly,lx0,lx1,ly0,ly1,lcount})$fatal(1,"blue behavior changed");
 end endtask
 initial begin
  reset();scenario=0;for(integer k=0;k<12;k++)begin phase=k;frame();end
  if(new_max-new_min!=0||old_max-old_min!=96)$fatal(1,"jitter comparison invalid");
  $display("REGION_COMPARISON old_center_range=%0d px new_center_range=%0d px",old_max-old_min,new_max-new_min);
  reset();scenario=1;for(integer k=0;k<8;k++)begin phase=k;frame();end
  reset();scenario=2;repeat(3)frame();
  reset();scenario=3;preset=2;repeat(4)frame();
  reset();scenario=4;preset=0;for(integer k=0;k<7;k++)begin phase=k;frame();end
  $display("TB_RESULT: RED_REGIONS PASS checks=%0d whole_bbox/fragments/identity/motion/loss/reacquire/seed/blue_legacy",checks);$finish;
 end
 initial begin #50000000;$fatal(1,"test timeout");end
endmodule
