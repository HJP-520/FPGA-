// SC520 v17 UI r1. Display only; 3 cycles including initialized font ERAM.
// cfg={mode[1:0],edge[1:0],gray[1:0],preset[2:0],trail,axes,info}.
module ui_hud_v17_r1(
 input wire clk,rst_n,iv,iu,il,ivs,input wire [23:0] id,
 input wire [11:0] config_data,input wire config_load,
 input wire [134:0] result_data,input wire result_load,input wire [3:0] led_n,
 output reg ov,ou,ol,ovs,output reg [23:0] od
);
 reg [11:0] cfg_s,cfg;
 reg [3:0] led_m,led_s,led_f;
 reg [10:0] px;reg [9:0] py;
 wire [10:0] x=iu?11'd0:px;wire [9:0] y=iu?10'd0:py;
 wire tracking=cfg[11:10]==3;wire visible=cfg[11:10]!=0;
 wire axes=tracking&&cfg[1];
 wire config_reset=config_load&&((config_data[11:10]!=cfg_s[11:10])||(config_data[5:3]!=cfg_s[5:3]));
 wire result_ok=result_data[134]&&(result_data[132:130]==cfg_s[5:3])&&cfg_s[11:10]==3&&
  result_data[129:119]<1280&&result_data[118:108]<720&&
  result_data[107:97]<=result_data[96:86]&&result_data[96:86]<1280&&
  result_data[85:76]<=result_data[75:66]&&result_data[75:66]<720;
 reg sv,tv;reg [10:0] sx,sy,sx0,sx1,sy0,sy1,cx,cy,x0,x1,y0,y1;
 reg [3:0] age,lock_count;reg centered_s,centered;
 reg [7:0] last_fid;reg have_fid;reg [3:0] history_count;
 reg [10:0] hx[0:7],hy[0:7],fx[0:7],fy[0:7];
 reg trail_start;wire trail_ready;
 wire [87:0] txs,tylo,tyhi;wire [195:0] tsteps;wire [6:0] ten;
 wire [87:0] hxp,hyp;genvar g;
 generate for(g=0;g<8;g=g+1)begin:history_bus
  assign hxp[g*11+:11]=hx[g];assign hyp[g*11+:11]=hy[g];
 end endgenerate
 ui_trail_lines u_lines(.clk(clk),.rst_n(rst_n),.start(trail_start),.xs(hxp),.ys(hyp),.count(history_count),
  .ready(trail_ready),.basex(txs),.ylo(tylo),.yhi(tyhi),.steps(tsteps),.enable(ten));
 reg [10:0] line_y0[0:6],line_y1[0:6],line_base[0:6];
 reg signed [27:0] line_step[0:6],line_acc[0:6];reg [6:0] line_en;
 reg [23:0] binary[0:4],digits[0:4],s_digits[0:4],f_digits[0:4];
 reg [4:0] format_bit;reg format_busy,format_ready;
 reg negx_s,negy_s,negx,negy;
 wire [10:0] bw=result_data[96:86]-result_data[107:97]+11'd1;
 wire [10:0] bh={1'b0,result_data[75:66]}-{1'b0,result_data[85:76]}+11'd1;
 (* dsp_style="no" *) wire [21:0] box_area=bw*bh;
 function [23:0] decimal_step;
 input [23:0] bcd;input bit_in;reg [23:0] a;integer j;
 begin a=bcd;for(j=0;j<6;j=j+1)if(a[j*4+:4]>=5)a[j*4+:4]=a[j*4+:4]+3;
 decimal_step={a[22:0],bit_in};end endfunction
 integer i;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   cfg_s<=12'h003;cfg<=12'h003;led_m<=15;led_s<=15;led_f<=15;px<=0;py<=0;
   sv<=0;tv<=0;sx<=0;sy<=0;sx0<=0;sx1<=0;sy0<=0;sy1<=0;cx<=0;cy<=0;x0<=0;x1<=0;y0<=0;y1<=0;
   age<=15;lock_count<=0;centered_s<=0;centered<=0;last_fid<=0;have_fid<=0;history_count<=0;trail_start<=0;
   format_bit<=0;format_busy<=0;format_ready<=0;negx_s<=0;negy_s<=0;negx<=0;negy<=0;line_en<=0;
   for(i=0;i<8;i=i+1)begin hx[i]<=0;hy[i]<=0;fx[i]<=0;fy[i]<=0;end
   for(i=0;i<7;i=i+1)begin line_y0[i]<=0;line_y1[i]<=0;line_base[i]<=0;line_step[i]<=0;line_acc[i]<=0;end
   for(i=0;i<5;i=i+1)begin binary[i]<=0;digits[i]<=0;s_digits[i]<=0;f_digits[i]<=0;end
  end else begin
   led_m<=led_n;led_s<=led_m;trail_start<=0;
   if(config_load)cfg_s<=config_data;
   if(iv)begin
    if(iu)begin px<=1;py<=0;end else if(il)begin px<=0;py<=py+1;end else px<=px+1;
   end
   if(format_busy)begin
    for(i=0;i<5;i=i+1)begin
     digits[i]<=decimal_step(digits[i],binary[i][23]);binary[i]<=binary[i]<<1;
     if(format_bit==23)s_digits[i]<=decimal_step(digits[i],binary[i][23]);
    end
    if(format_bit==23)begin format_busy<=0;format_ready<=1;end else format_bit<=format_bit+1;
   end
   if(iv&&iu)begin
    cfg<=cfg_s;led_f<=led_s;if(age!=15)age<=age+1;
    if(age>=4)begin history_count<=0;lock_count<=0;centered_s<=0;end
    centered<=led_s[2];   // 【改动】led 输入语义改为 1=应亮
    if(!sv||age>=4||cfg_s[11:10]!=3||cfg_s[5:3]!=cfg[5:3]||config_reset)tv<=0;
    else if(format_ready&&trail_ready)tv<=1;
    // Keep the last complete drawing bank while the new result is formatting.
    if(format_ready&&trail_ready)begin
     cx<=sx;cy<=sy;x0<=sx0;x1<=sx1;y0<=sy0;y1<=sy1;negx<=negx_s;negy<=negy_s;
     for(i=0;i<5;i=i+1)f_digits[i]<=s_digits[i];
     for(i=0;i<8;i=i+1)begin fx[i]<=hx[i];fy[i]<=hy[i];end
     line_en<=ten;
     for(i=0;i<7;i=i+1)begin
      line_y0[i]<=tylo[11*i+:11];line_y1[i]<=tyhi[11*i+:11];line_base[i]<=txs[11*i+:11];
      line_step[i]<=tsteps[28*i+:28];line_acc[i]<=$signed({1'b0,txs[11*i+:11],16'd0});
     end
    end else for(i=0;i<7;i=i+1)line_acc[i]<=$signed({1'b0,line_base[i],16'd0});
   end else if(iv&&il)begin
    for(i=0;i<7;i=i+1)if(py+1>line_y0[i]&&py+1<=line_y1[i])line_acc[i]<=line_acc[i]+line_step[i];
   end
   if(result_load&&(!result_ok||!have_fid||last_fid!=result_data[65:58]))begin
    age<=0;sv<=result_ok;format_ready<=0;
    if(result_ok)begin
     sx<=result_data[129:119];sy<={1'b0,result_data[118:108]};sx0<=result_data[107:97];sx1<=result_data[96:86];
     sy0<={1'b0,result_data[85:76]};sy1<={1'b0,result_data[75:66]};
     negx_s<=result_data[129:119]<640;negy_s<=result_data[118:108]>360;
     binary[0]<=(result_data[129:119]<640)?640-result_data[129:119]:result_data[129:119]-640;
     binary[1]<=(result_data[118:108]<360)?360-result_data[118:108]:result_data[118:108]-360;
     binary[2]<=bw;binary[3]<=bh;binary[4]<={2'd0,box_area};
     for(i=0;i<5;i=i+1)digits[i]<=0;format_bit<=0;format_busy<=1;
     if(!have_fid||last_fid!=result_data[65:58])begin
      hx[0]<=result_data[129:119];hy[0]<={1'b0,result_data[118:108]};
      for(i=1;i<8;i=i+1)begin hx[i]<=hx[i-1];hy[i]<=hy[i-1];end
      if(history_count<8)history_count<=history_count+1;trail_start<=1;
      have_fid<=1;last_fid<=result_data[65:58];
      if(result_data[129:119]>=615&&result_data[129:119]<=665&&result_data[118:108]>=335&&result_data[118:108]<=385)begin
       if(lock_count<8)lock_count<=lock_count+1;centered_s<=lock_count>=7;
      end else begin lock_count<=0;centered_s<=0;end
     end
    end else begin history_count<=0;have_fid<=0;lock_count<=0;centered_s<=0;format_busy<=0;end
   end
   if(config_reset)begin sv<=0;history_count<=0;have_fid<=0;lock_count<=0;centered_s<=0;format_ready<=0;format_busy<=0;trail_start<=0;age<=15;end
  end
 end

 // Connected history polyline: row intersections advance by precomputed Q16 slopes.
 reg on_trail;reg signed [27:0] next_acc;reg signed [12:0] xa,xb,leftx,rightx;integer t;
 always @(*)begin
  on_trail=0;next_acc=0;xa=0;xb=0;leftx=0;rightx=0;
  for(t=0;t<7;t=t+1)begin
   next_acc=(y<line_y1[t])?line_acc[t]+line_step[t]:line_acc[t];
   xa=line_acc[t]>>>16;xb=next_acc>>>16;leftx=(xa<xb)?xa:xb;rightx=(xa>xb)?xa:xb;
   if(line_y0[t]==line_y1[t])begin leftx=(fx[t]<fx[t+1])?fx[t]:fx[t+1];rightx=(fx[t]>fx[t+1])?fx[t]:fx[t+1];end
   if(line_en[t]&&y>=line_y0[t]&&y<=line_y1[t]&&$signed({2'b0,x})>=leftx&&$signed({2'b0,x})<=rightx)on_trail=1;
  end
 end
 wire on_axis=axes&&((x==640)||(y==360)||
  (((x==160)||(x==320)||(x==480)||(x==800)||(x==960)||(x==1120))&&y>=356&&y<=364)||
  (((y==120)||(y==240)||(y==480)||(y==600))&&x>=636&&x<=644)||
  ((x==615||x==665)&&y>=335&&y<=385)||((y==335||y==385)&&x>=615&&x<=665));
 wire on_box=tracking&&tv&&(((x==x0||x==x1)&&y>=y0&&y<=y1)||((y==y0||y==y1)&&x>=x0&&x<=x1));
 wire on_cross=tracking&&tv&&((x==cx&&y+8>=cy&&y<=cy+8)||(y==cy&&x+8>=cx&&x<=cx+8));
 wire protected_logo=x>=16&&x<272&&y>=16&&y<96;
 wire footer=visible&&(tracking&&cfg[0]?y>=640:y>=680);
 wire separator=visible&&((tracking&&cfg[0]&&x>=1024&&x<1264&&(y==90||y==154))||
  (footer&&(x==320||x==640||x==960)));
 reg [7:0] slot;reg [5:0] col;reg [4:0] row;reg [3:0] fontbit;reg selected;
 reg [10:0] lx;reg [9:0] ly;reg font_large;reg [5:0] length;
 // Slot windows are generated below. No window overlaps the reserved logo area.
 always @(*)begin slot=0;lx=0;ly=0;font_large=0;length=0;col=0;row=0;fontbit=0;selected=0;
 if(visible&&x>=288&&x<608&&y>=16&&y<64)begin slot=1;lx=288;ly=16;font_large=1;length=10;end
 if(visible&&x>=288&&x<352&&y>=72&&y<96)begin slot=2;lx=288;ly=72;font_large=0;length=4;end
 if(tracking&&x>=768&&x<832&&y>=16&&y<40)begin slot=3;lx=768;ly=16;font_large=0;length=4;end
 if(tracking&&x>=960&&x<1024&&y>=16&&y<40)begin slot=4;lx=960;ly=16;font_large=0;length=4;end
 if(tracking&&x>=768&&x<832&&y>=44&&y<68)begin slot=5;lx=768;ly=44;font_large=0;length=4;end
 if(tracking&&cfg[0]&&x>=1024&&x<1088&&y>=64&&y<88)begin slot=6;lx=1024;ly=64;font_large=0;length=4;end
 if(tracking&&cfg[0]&&x>=1024&&x<1168&&y>=100&&y<124)begin slot=7;lx=1024;ly=100;font_large=0;length=9;end
 if(tracking&&cfg[0]&&x>=1024&&x<1168&&y>=128&&y<152)begin slot=8;lx=1024;ly=128;font_large=0;length=9;end
 if(tracking&&cfg[0]&&x>=1024&&x<1200&&y>=164&&y<188)begin slot=9;lx=1024;ly=164;font_large=0;length=11;end
 if(tracking&&cfg[0]&&x>=1024&&x<1216&&y>=196&&y<220)begin slot=10;lx=1024;ly=196;font_large=0;length=12;end
 if(tracking&&cfg[0]&&x>=16&&x<256&&y>=648&&y<672)begin slot=11;lx=16;ly=648;font_large=0;length=15;end
 if(tracking&&cfg[0]&&x>=336&&x<576&&y>=648&&y<672)begin slot=12;lx=336;ly=648;font_large=0;length=15;end
 if(tracking&&cfg[0]&&x>=656&&x<896&&y>=648&&y<672)begin slot=13;lx=656;ly=648;font_large=0;length=15;end
 if(tracking&&cfg[0]&&x>=976&&x<1216&&y>=648&&y<672)begin slot=14;lx=976;ly=648;font_large=0;length=15;end
 if(tracking&&!cfg[0]&&x>=16&&x<256&&y>=688&&y<712)begin slot=11;lx=16;ly=688;font_large=0;length=15;end
 if(tracking&&!cfg[0]&&x>=336&&x<576&&y>=688&&y<712)begin slot=12;lx=336;ly=688;font_large=0;length=15;end
 if(tracking&&!cfg[0]&&x>=656&&x<896&&y>=688&&y<712)begin slot=13;lx=656;ly=688;font_large=0;length=15;end
 if(tracking&&!cfg[0]&&x>=976&&x<1216&&y>=688&&y<712)begin slot=14;lx=976;ly=688;font_large=0;length=15;end
 if(visible&&!tracking&&x>=16&&x<256&&y>=688&&y<712)begin slot=11;lx=16;ly=688;font_large=0;length=15;end
 if(visible&&!tracking&&x>=336&&x<576&&y>=688&&y<712)begin slot=12;lx=336;ly=688;font_large=0;length=15;end
 if(visible&&!tracking&&x>=656&&x<896&&y>=688&&y<712)begin slot=13;lx=656;ly=688;font_large=0;length=15;end
 if(visible&&!tracking&&x>=976&&x<1216&&y>=688&&y<712)begin slot=14;lx=976;ly=688;font_large=0;length=15;end
 if(tracking&&cfg[0]&&x>=32&&x<176&&y>=688&&y<712)begin slot=15;lx=32;ly=688;font_large=0;length=9;end
 if(tracking&&cfg[0]&&x>=352&&x<496&&y>=688&&y<712)begin slot=16;lx=352;ly=688;font_large=0;length=9;end
 if(tracking&&cfg[0]&&x>=672&&x<816&&y>=688&&y<712)begin slot=17;lx=672;ly=688;font_large=0;length=9;end
 if(tracking&&cfg[0]&&x>=992&&x<1136&&y>=688&&y<712)begin slot=18;lx=992;ly=688;font_large=0;length=9;end
 if(axes&&x>=128&&x<192&&y>=368&&y<392)begin slot=19;lx=128;ly=368;font_large=0;length=4;end
 if(axes&&x>=288&&x<352&&y>=368&&y<392)begin slot=20;lx=288;ly=368;font_large=0;length=4;end
 if(axes&&x>=448&&x<512&&y>=368&&y<392)begin slot=21;lx=448;ly=368;font_large=0;length=4;end
 if(axes&&x>=768&&x<832&&y>=368&&y<392)begin slot=22;lx=768;ly=368;font_large=0;length=4;end
 if(axes&&x>=928&&x<992&&y>=368&&y<392)begin slot=23;lx=928;ly=368;font_large=0;length=4;end
 if(axes&&x>=1088&&x<1152&&y>=368&&y<392)begin slot=24;lx=1088;ly=368;font_large=0;length=4;end
 if(axes&&x>=652&&x<716&&y>=108&&y<132)begin slot=25;lx=652;ly=108;font_large=0;length=4;end
 if(axes&&x>=652&&x<716&&y>=228&&y<252)begin slot=26;lx=652;ly=228;font_large=0;length=4;end
 if(axes&&x>=652&&x<716&&y>=468&&y<492)begin slot=27;lx=652;ly=468;font_large=0;length=4;end
 if(axes&&x>=652&&x<716&&y>=588&&y<612)begin slot=28;lx=652;ly=588;font_large=0;length=4;end
 if(axes&&x>=652&&x<668&&y>=368&&y<392)begin slot=29;lx=652;ly=368;font_large=0;length=1;end
 if(axes&&x>=1256&&x<1272&&y>=332&&y<356)begin slot=30;lx=1256;ly=332;font_large=0;length=1;end
 if(axes&&x>=652&&x<668&&y>=0&&y<24)begin slot=31;lx=652;ly=0;font_large=0;length=1;end
 if(tracking&&tv&&x>=1120&&x<1184&&y>=16&&y<40)begin slot=32;lx=1120;ly=16;font_large=0;length=4;end
 if(slot!=0)begin col=font_large?((x-lx)>>5):((x-lx)>>4);row=font_large?((y-ly)>>1):(y-ly);fontbit=font_large?((x-lx)>>1):(x-lx);end
 if(slot>=11&&slot<=14)begin
  if(cfg[11:10]==1)selected=(slot==11&&cfg[9:8]==0)||(slot==12&&cfg[9:8]==2)||(slot==13&&cfg[9:8]==1)||(slot==14&&cfg[9:8]==3);
  else if(cfg[11:10]==2)selected=(slot==11&&cfg[7:6]==0)||(slot==12&&cfg[7:6]==2)||(slot==13&&cfg[7:6]==1)||(slot==14&&cfg[7:6]==3);
 end
end
 reg [7:0] s_slot;reg [5:0] s_col;reg [4:0] s_row;reg [3:0] s_bit;
 reg s_selected,s_visible,s_logo;reg [23:0] s_background,s_graphics;
 reg sv1,su1,sl1,ss1;
 reg [223:0] word_bits;reg [6:0] glyph;
 always @(*)begin word_bits=0;glyph=0;case(s_slot)
1:word_bits=224'h000000000000000000000000000000000000000911203c001061870d;
2:word_bits=(cfg[11:10]==3)?224'h00000000000000000000000000000000000000000000000002c54a13:(cfg[11:10]==2)?224'h00000000000000000000000000000000000000000000000003464c17:224'h00000000000000000000000000000000000000000000000003c74e1b;
3:word_bits=(cfg[5:3]==2)?224'h00000000000000000000000000000000000000000000000004280a22:224'h00000000000000000000000000000000000000000000000004280a1f;
4:word_bits=tv?224'h00000000000000000000000000000000000000000000000000078ea3:224'h00000000000000000000000000000000000000000000000004a910a0;
5:word_bits=cfg[2]?224'h00000000000000000000000000000000000000000000000005cb562b:224'h00000000000000000000000000000000000000000000000005eb562b;
6:word_bits=224'h000000000000000000000000000000000000000000000000062c10a0;
7:word_bits=224'h0000000000000000000000000000000000000000346600081022c032;
8:word_bits=224'h0000000000000000000000000000000000000000346600081022c035;
9:word_bits=224'h00000000000000000000000000000000000000408102dc00102040b6;
10:word_bits=224'h0000000000000000000000000000000000076d1981020408102e9cb8;
11:word_bits=tracking?224'h000000000000000000000000000000000000000000000113d3e0013c:(cfg[11:10]==2)?224'h0000000000000000000000000000000000000000000060bc1800013c:224'h000000000000000000000000000000000000000000000004b940013c;
12:word_bits=tracking?224'h00000000000000000000000000000000000000000000bd72c56001bc:(cfg[11:10]==2)?224'h000000000000000000000000000000000000000000890e0421a001bc:224'h000000000000000000000000000000000000000000013661c36001bc;
13:word_bits=tracking?224'h0000000000000000000000000000000000000000000001fa17c0023c:(cfg[11:10]==2)?224'h00000000000000000000000000000000000000000000023c68a0023c:224'h000000000000000000000000000000000000000000014684f9c0023c;
14:word_bits=tracking?224'h000000000000000000000000000000000000000000000003160002bc:(cfg[11:10]==2)?224'h0000000000000000000000000000000000000000000002fdeba002bc:224'h0000000000000000000000000000000000000000000002a53a4002bc;
15:word_bits=224'h000000000000000000000000000000000000000000b566c00055eb55;
16:word_bits=224'h000000000000000000000000000000000000000000b75ab80075eb55;
17:word_bits=224'h00000000000000000000000000000000000000003c1d72a80095eb55;
18:word_bits=224'h000000000000000000000000000000000000000000b162b000b5eb55;
19:word_bits=224'h0000000000000000000000000000000000000000000000000022428c;
20:word_bits=224'h0000000000000000000000000000000000000000000000000020c20c;
21:word_bits=224'h0000000000000000000000000000000000000000000000000021c10c;
22:word_bits=224'h0000000000000000000000000000000000000000000000000021c10b;
23:word_bits=224'h0000000000000000000000000000000000000000000000000020c20b;
24:word_bits=224'h0000000000000000000000000000000000000000000000000022428b;
25:word_bits=224'h0000000000000000000000000000000000000000000000000021418b;
26:word_bits=224'h0000000000000000000000000000000000000000000000000020c10b;
27:word_bits=224'h0000000000000000000000000000000000000000000000000020c10c;
28:word_bits=224'h0000000000000000000000000000000000000000000000000021418c;
29:word_bits=224'h00000000000000000000000000000000000000000000000000000001;
30:word_bits=224'h00000000000000000000000000000000000000000000000000000032;
31:word_bits=224'h00000000000000000000000000000000000000000000000000000035;
default:word_bits=0;endcase
glyph=(s_col<32)?((word_bits>>(s_col*7))&7'h7f):0;
if(s_slot==7||s_slot==8)begin if(s_col==2)glyph=(s_slot==7?negx:negy)?7'd12:7'd11;
 if(s_col>=3&&s_col<=5)glyph=tv?(7'd1+((f_digits[s_slot==7?0:1]>>((5-s_col)*4))&4'hf)):7'd12;
 if(!tv&&s_col==2)glyph=7'd0;end
if(s_slot==9)begin if(s_col>=1&&s_col<=4)glyph=tv?(7'd1+((f_digits[2]>>((4-s_col)*4))&4'hf)):7'd12;
 if(s_col>=7&&s_col<=10)glyph=tv?(7'd1+((f_digits[3]>>((10-s_col)*4))&4'hf)):7'd12;end
if(s_slot==10&&s_col>=3&&s_col<=8)glyph=tv?(7'd1+((f_digits[4]>>((8-s_col)*4))&4'hf)):7'd12;
if(s_slot==32)glyph=(((centered?224'h0000000000000000000000000000000000000000000000000009d323:224'h0000000000000000000000000000000000000000000000000549d4a8)>>(s_col*7))&7'h7f);
end
 // Native title shares the existing two-stage font latency.
 wire title_hit=visible && x>=288 && x<608 && y>=16 && y<64;
 wire [8:0] title_x=title_hit ? x-288 : 9'd0;
 wire [5:0] title_y=title_hit ? y-16 : 6'd0;
 wire [1:0] title_dot;
 ui_title_rom u_title(.clk(clk),.rst_n(rst_n),.hit(title_hit),
     .x(title_x),.y(title_y),.coverage(title_dot));
 reg s_title,p_title;
 wire [31:0] glyph_row;
 ui_font_rom u_font(.clk(clk),.addr({glyph,s_row}),.q(glyph_row));
 reg [3:0] p_bit;reg p_selected,p_visible,p_logo;reg [23:0] p_background,p_graphics;
 reg sv2,su2,sl2,ss2;
 wire [1:0] dot=(glyph_row>>(2*p_bit))&2'b11;
 wire [1:0] chosen=(cfg[11:10]==1)?((cfg[9:8]==2)?2'd1:(cfg[9:8]==1)?2'd2:cfg[9:8]):
                     ((cfg[7:6]==2)?2'd1:(cfg[7:6]==1)?2'd2:cfg[7:6]);
 wire [10:0] underline_x=(chosen==0)?11'd16:(chosen==1)?11'd336:(chosen==2)?11'd656:11'd976;
 wire underline=visible&&!tracking&&y==716&&x>=underline_x&&x<underline_x+240;
 reg [23:0] graphics;
 always @(*)begin
  graphics=footer?24'h121212:id;
  if(tracking&&tv&&cfg[2]&&on_trail)graphics=24'h36D9EF;
  if(on_box)graphics=24'hFF3030;
  if(on_cross)graphics=24'hFFD250;
  if(separator)graphics=24'hCCCCCC;
  if(on_axis)graphics=24'hB8B8B8;
  if(underline)graphics=24'hFFCA55;
  // LED dots have actual synchronized electrical states, labels stay white.
  if(tracking&&cfg[0]&&y>=696&&y<704)begin
   if(x>=16&&x<24)graphics=led_f[0]?24'h30E060:24'h555555;
   if(x>=336&&x<344)graphics=led_f[1]?24'h30E060:24'h555555;
   if(x>=656&&x<664)graphics=led_f[2]?24'h30E060:24'h555555;
   if(x>=976&&x<984)graphics=led_f[3]?24'hFF5050:24'h555555;
  end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   s_title<=0;p_title<=0;s_slot<=0;s_col<=0;s_row<=0;s_bit<=0;s_selected<=0;s_visible<=0;s_logo<=0;s_background<=0;s_graphics<=0;
   p_bit<=0;p_selected<=0;p_visible<=0;p_logo<=0;p_background<=0;p_graphics<=0;
   sv1<=0;su1<=0;sl1<=0;ss1<=0;sv2<=0;su2<=0;sl2<=0;ss2<=0;ov<=0;ou<=0;ol<=0;ovs<=0;od<=0;
  end else begin
   s_title<=title_hit;p_title<=s_title;s_slot<=slot;s_col<=col;s_row<=row;s_bit<=fontbit;s_selected<=selected;s_visible<=visible;s_logo<=protected_logo;
   s_background<=id;s_graphics<=graphics;sv1<=iv;su1<=iu;sl1<=il;ss1<=ivs;
   p_bit<=s_bit;p_selected<=s_selected;p_visible<=s_visible;p_logo<=s_logo;p_background<=s_background;p_graphics<=s_graphics;
   sv2<=sv1;su2<=su1;sl2<=sl1;ss2<=ss1;
   ov<=sv2;ou<=su2;ol<=sl2;ovs<=ss2;
   od<=(!p_visible||p_logo)?p_background:p_title?
       (title_dot==3?24'hF4F7FB:title_dot==2?24'h9BAABC:title_dot==1?24'h0C1017:p_graphics):dot[1]?(p_selected?24'hFFCA55:24'hF4F4F4):
       dot[0]?24'h101010:p_graphics;
  end
 end
endmodule

// One reusable restoring divider: no per-pixel multiplier/divider for trails.
module ui_trail_lines(input wire clk,rst_n,start,input wire [87:0] xs,ys,input wire [3:0] count,
 output reg ready,output reg [87:0] basex,ylo,yhi,output reg [195:0] steps,output reg [6:0] enable);
 reg [87:0] xbuf,ybuf;reg [3:0] n;reg [2:0] index;reg [1:0] state;
 reg [27:0] numerator,quotient;reg [11:0] remainder;reg [10:0] denominator;reg negative;reg [4:0] bitno;
 wire [10:0] ax=xbuf[index*11+:11],ay=ybuf[index*11+:11];
 wire [10:0] bx=xbuf[(index+1)*11+:11],by=ybuf[(index+1)*11+:11];
 wire swap=ay>by;wire [10:0] startx=swap?bx:ax,endx=swap?ax:bx;
 wire [11:0] rnext={remainder[10:0],numerator[27]};
 wire take=rnext>={1'b0,denominator};wire [27:0] qnext={quotient[26:0],take};
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin ready<=0;basex<=0;ylo<=0;yhi<=0;steps<=0;enable<=0;xbuf<=0;ybuf<=0;n<=0;index<=0;state<=0;
   numerator<=0;quotient<=0;remainder<=0;denominator<=0;negative<=0;bitno<=0;end
  else if(start)begin xbuf<=xs;ybuf<=ys;n<=count;index<=0;state<=1;ready<=0;enable<=0;end
  else if(state==1)begin
   basex[index*11+:11]<=startx;ylo[index*11+:11]<=swap?by:ay;yhi[index*11+:11]<=swap?ay:by;
   enable[index]<=index+1<n;negative<=endx<startx;
   if(ay==by||index+1>=n)begin
    steps[index*28+:28]<=0;
    if(index==6)begin state<=0;ready<=1;end else index<=index+1;
   end else begin
    numerator<={1'b0,(endx<startx)?(startx-endx):(endx-startx),16'd0};
    denominator<=swap?ay-by:by-ay;remainder<=0;quotient<=0;bitno<=0;state<=2;
   end
  end else if(state==2)begin
   numerator<=numerator<<1;quotient<=qnext;remainder<=take?rnext-denominator:rnext;
   if(bitno==27)begin
    steps[index*28+:28]<=negative?-$signed(qnext):$signed(qnext);
    if(index==6)begin state<=0;ready<=1;end else begin index<=index+1;state<=1;end
   end else bitno<=bitno+1;
  end
 end
endmodule

module ui_font_rom(input wire clk,input wire [11:0] addr,output wire [31:0] q);
 // Unused glyphs 96..127 and rows outside 3..22 are entirely zero.
 // Keep all 4096 addresses valid, store only 96*20 active/padded rows.
 wire [6:0] glyph=addr[11:5];wire [4:0] row=addr[4:0];
 wire active=glyph<96 && row>=3 && row<=22;
 // Main 16 rows are direct concatenation. Four bottom rows use a small
 // constant offset, avoiding a glyph*20 carry chain on the pixel clock.
 wire [3:0] main_row=row[3:0]-4'd3;
 wire [1:0] bottom_row=row[1:0]-2'd3;
 wire [8:0] bottom_glyph=9'd384+{2'd0,glyph};
 wire [10:0] compact_address=row<=18?{glyph,main_row}:{bottom_glyph,bottom_row};
 reg active_r;always @(posedge clk)active_r<=active;
 wire [31:0] data;
 assign q=active_r?data:32'd0;
`ifdef UI_FONT_SIM
 reg[31:0]mem[0:2047];reg[31:0]qr;initial $readmemh("ui_font_compact.dath",mem);
 always @(posedge clk)qr<=mem[compact_address];assign data=qr;
`else
 PH1P_LOGIC_ERAM #(.DATA_WIDTH_A(32),.DATA_WIDTH_B(32),.ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),
 .DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),.MODE("DP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
 .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.IMPLEMENT("20K(FAST)"),.ECC_ENCODE("DISABLE"),.ECC_DECODE("DISABLE"),
 .CLKMODE("SYNC"),.SSROVERCE("DISABLE"),.OREGSET_A("RESET"),.OREGSET_B("RESET"),.RESETMODE_A("ASYNC"),.RESETMODE_B("ASYNC"),
 .ASYNC_RESET_RELEASE_A("ASYNC"),.ASYNC_RESET_RELEASE_B("ASYNC"),.INIT_FILE("ui_font_compact.dath")) font_memory(
 .dia(32'd0),.dib(32'd0),.addra(compact_address),.addrb(11'd0),.clka(clk),.clkb(clk),.cea(1'b1),.ceb(1'b0),.ocea(1'b1),.oceb(1'b1),
 .wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(data),.dob(),
 .ecc_sbiterr(),.ecc_dbiterr(),.ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0));
`endif
endmodule

// Pixel-identical 320x48 title, compact 256x32 body plus two outline rows.
// Zero exterior pixels need no storage. The body is exactly 512x32 bits.
// Coverage remains two registered stages, including the outline rows.
module ui_title_rom(
 input wire clk,rst_n,hit,input wire [8:0] x,input wire [5:0] y,
 output reg [1:0] coverage
);
 localparam [255:0] TOP_OUTLINE=256'h00001fc07c1ffff00000f078780000003c000000000000000000000000000000;
 localparam [255:0] BOTTOM_OUTLINE=256'h00000000000000000003ff00000ff80000000000000000000000000000000000;
 wire body=hit && x<256 && y>=8 && y<40;
 wire [4:0] row=y[4:0]-5'd8;
 wire [8:0] addr=body ? {row,x[7:4]} : 9'd0;
 wire edge_pixel=hit && x<256 &&
     ((y==7 && TOP_OUTLINE[x[7:0]]) || (y==40 && BOTTOM_OUTLINE[x[7:0]]));
 reg [31:0] mem[0:511];reg [31:0] word_r;
 reg [3:0] select_r;reg body_r,edge_r;
 initial $readmemh("ui_title.hex",mem);
 always @(posedge clk) word_r<=mem[addr];
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin coverage<=0;select_r<=0;body_r<=0;edge_r<=0;end
  else begin
   select_r<=x[3:0];body_r<=body;edge_r<=edge_pixel;
   coverage<=body_r ? ((word_r>>(2*select_r))&2'b11) : edge_r ? 2'd1 : 2'd0;
  end
 end
endmodule
