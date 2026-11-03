`timescale 1ns/1ps
module tb_adaptive_binary;
 localparam W=16,H=8;
 reg clk=0,rst=0,iv=0,iu=0,il=0,gray=1;
 reg [1:0] curve=3;reg [95:0] data=0;
 wire ov,ou,ol,lv,lu,ll;wire [95:0] out,legacy;
 always #5 clk=~clk;
 axis_gray_curve_rgb96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H)) dut(
 .I_clk(clk),.I_rst_n(rst),.I_tlast(il),.I_tuser(iu),.I_tdata(data),.I_tvalid(iv),
 .I_curve(curve),.I_gray_mode(gray),.O_tlast(ol),.O_tuser(ou),.O_tdata(out),.O_tvalid(ov));
 v9_axis_gray_curve_rgb96 old(clk,rst,il,iu,data,iv,curve,gray,ll,lu,legacy,lv);
 integer checks=0,gt=128,candidate=128;reg ready=0,history=0;
 reg [95:0] expected;integer sum,mean,distance_tb,step;reg [7:0] value;
 task tick(input bit valid,sof,eol,input [95:0] word);
 begin
  @(negedge clk);iv=valid;iu=sof;il=eol;data=word;
  if(sof&&ready)begin gt=candidate;ready=0;end
  expected=0;
  if(valid)for(integer p=0;p<4;p++)
   expected[p*24+:24]=(word[p*24+16+:8]>gt)?24'hffffff:24'h000000;
  @(posedge clk);#1;
  if({ov,ou,ol}!=={valid,sof,eol})$fatal(1,"one-cycle tags/bubbles changed");
  if(gray&&curve==3&&out!==expected)$fatal(1,"binary pixel mismatch got=%h want=%h T=%0d",out,expected,gt);
  if((!gray||curve!=3)&&{ov,ou,ol,out}!=={lv,lu,ll,legacy})$fatal(1,"legacy gray/color changed curve=%0d",curve);
  if(dut.binary_threshold!==gt)$fatal(1,"threshold changed inside frame got=%0d want=%0d",dut.binary_threshold,gt);
  checks++;
 end endtask
 task idle(input integer n);repeat(n)tick(0,0,0,0);endtask
 function integer smooth(input integer a,m,input bit first);
 integer d,s;begin
  if(m<16)m=16;if(m>239)m=239;
  d=(m>a)?m-a:a-m;s=(d+2)/4;
  smooth=first?m:(d<=2)?a:(m>a)?a+s:a-s;
 end endfunction
 // Deterministic image with known exact sum; the first word can share SOF.
 task frame(input integer kind,input bit early,bubbles);
 reg[95:0]word;integer v;
 begin
  sum=0;
  if(early)begin tick(0,1,0,0);idle(3);end
  for(integer y=0;y<H;y++)for(integer x=0;x<W/4;x++)begin
   word=0;
   for(integer p=0;p<4;p++)begin
    case(kind)
     0:v=(x<W/8)?20:100;
     1:v=(x<W/8)?100:220;
     2:v=86;
     3:v=0;
     4:v=255;
     default:v=(y*73+x*47+p*31)%256;
    endcase
    sum+=v;word[p*24+:24]={3{8'(v)}};
   end
   if(bubbles&&(x+y)%3==0)idle(2);
   tick(1,!early&&x==0&&y==0,x==W/4-1,word);
  end
  mean=sum/(W*H);candidate=smooth(gt,mean,!history);history=1;ready=1;
  idle(40);
  if(!dut.u_threshold.pending||dut.u_threshold.candidate!==candidate)
   $fatal(1,"mean/divide/smooth mismatch candidate=%0d want=%0d sum=%0d",dut.u_threshold.candidate,candidate,sum);
 end endtask
 initial begin
  repeat(3)@(negedge clk);rst=1;idle(4);
  frame(0,1,1);frame(0,0,0);frame(1,1,1);frame(2,0,1);
  frame(3,0,0);frame(4,1,1);frame(5,0,1);
  // Consume a good result, then truncate a new frame; next SOF must discard it.
  tick(0,1,0,0);tick(1,0,0,{12{8'd255}});idle(40);
  if(dut.u_threshold.pending)$fatal(1,"truncated frame trained threshold");
  frame(0,1,1);
  // Early EOL invalidates all following words until a fresh SOF.
  tick(1,1,1,{12{8'd255}});repeat(40)tick(1,0,1,0);idle(40);
  if(dut.u_threshold.pending)$fatal(1,"malformed EOL trained threshold");
  frame(1,0,0);
  // Training runs in the other gray curves too. Existing curve pixels stay exact.
  curve=1;frame(5,1,1);curve=2;frame(0,0,1);curve=0;frame(4,1,0);
  curve=3;frame(0,0,1);
  // Leave gray: discard all statistics, restore default128 on re-entry.
  gray=0;gt=128;candidate=128;ready=0;history=0;idle(4);
  for(integer c=0;c<4;c++)begin
   curve=c;
   for(integer i=0;i<256;i++)tick(1,i==0,i%4==3,{8'(i),8'(255-i),8'(i^85),72'h1267abfedcba123456});
  end
  gray=1;
  for(integer c=0;c<3;c++)begin
   curve=c;
   for(integer i=0;i<256;i++)tick(1,0,i%4==3,{12{8'(i)}});
  end
  curve=3;frame(3,1,0);frame(4,0,1);
  rst=0;@(negedge clk);rst=1;gt=128;candidate=128;ready=0;history=0;idle(4);
  frame(4,1,1);frame(3,0,0);
  $display("TB_RESULT: ADAPTIVE_BINARY PASS checks=%0d exact_mean/clamp/smooth/deadband/early_SOF/same_word_SOF/bubbles/truncated/bad_EOL/reset/legacy_gray/color",checks);$finish;
 end
endmodule

module tb_binary_720p;
 localparam W=1280,H=720;
 reg clk=0,rst=0,iv=0,iu=0,il=0;reg[95:0]data=0;
 always #5 clk=~clk;
 wire ov,ou,ol;wire[95:0]out;
 axis_gray_curve_rgb96 dut(clk,rst,il,iu,data,iv,2'd3,1'b1,ol,ou,out,ov);
 integer checks=0,gt=128,sum=0,mean;
 reg[95:0]word,expected;integer v;
 task tick(input bit valid,sof,eol,input[95:0]d);
 begin
  @(negedge clk);iv=valid;iu=sof;il=eol;data=d;
  expected=0;for(integer p=0;p<4;p++)expected[p*24+:24]=(d[p*24+16+:8]>gt)?24'hffffff:0;
  @(posedge clk);#1;
  if({ov,ou,ol}!=={valid,sof,eol})$fatal(1,"720p tags");
  if(valid&&out!==expected)$fatal(1,"720p binary lane/threshold");
  if(dut.binary_threshold!==gt)$fatal(1,"720p threshold not frame-constant");
  if(valid)checks+=4;
 end endtask
 initial begin
  repeat(3)@(negedge clk);rst=1;
  for(integer f=0;f<3;f++)begin
   sum=0;
   for(integer y=0;y<H;y++)begin
    for(integer x=0;x<W/4;x++)begin
     if(x==0&&y==0)begin
      if(f==1)gt=127;
      if(f==2)gt=155; // First mean127; second uniform240:127+round(112/4)=155.
     end
     word=0;
     for(integer p=0;p<4;p++)begin
      v=(f==1)?240:(x*4+p+y)%256;
      sum+=v;word[p*24+:24]={3{8'(v)}};
     end
     tick(1,x==0&&y==0,x==W/4-1,word);
    end
    repeat(5)tick(0,0,0,0);
   end
   repeat(40)tick(0,0,0,0);
   mean=sum/(W*H);
   if(f==0&&mean!=127)$fatal(1,"fixture mean");
  end
  if(checks!=2764800)$fatal(1,"720p pixel count");
  $display("TB_RESULT: BINARY_720P PASS pixels=%0d three_full_frames/threshold_atomic/exact_sum/no_overflow/valid_and_EOL",checks);$finish;
 end
endmodule

