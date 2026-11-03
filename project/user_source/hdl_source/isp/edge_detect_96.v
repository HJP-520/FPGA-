// Pixel-pair Sobel with packed synchronous ERAM and valid-aware lookahead.
// EOL flushes without waiting for another input beat; its last pair is masked.
module edge_detect_96 #(
 parameter IMG_WIDTH=1280,IMG_HEIGHT=720,parameter EDGE_TH=11'd80,parameter DENOISE_EN=0
)(input I_clk,I_rst_n,I_tlast,I_tuser,input[95:0]I_tdata,
 input I_tvalid,I_tready,input[1:0]I_mode,
 output reg O_tlast,output wire O_tuser,output reg O_tvalid,
 output reg[1:0]O_edge,output wire O_tready,
 output reg[95:0]O_aligned_data,output reg[1:0]O_mode);
 localparam G=IMG_WIDTH/4,AW=$clog2(G);
 assign O_tready=I_tready;
 function[7:0]gray(input[23:0]p);
  gray={2'b0,p[23:18]}+{1'b0,p[15:9]}+{2'b0,p[7:2]};
 endfunction
 wire[8:0]sum0={1'b0,gray(I_tdata[95:72])}+{1'b0,gray(I_tdata[71:48])};
 wire[8:0]sum1={1'b0,gray(I_tdata[47:24])}+{1'b0,gray(I_tdata[23:0])};
 wire[15:0]bot_in={sum0[8:1],sum1[8:1]};
 reg[AW-1:0]x;reg[10:0]y;
 wire[AW-1:0]xx=I_tuser?{AW{1'b0}}:x;
 wire[10:0]yy=I_tuser?11'd0:y;
 reg v0,last0;reg[AW-1:0]x0;reg[10:0]y0;reg[15:0]bot0;reg[95:0]rgb0;reg[1:0]mode0;
 wire[31:0]rows;
 edge_line_ram #(.AW(AW)) row_memory(
 .clk(I_clk),.we(v0),.wa(x0),.wd({rows[15:0],bot0}),
 .re(I_tvalid),.ra(xx),.q(rows));
 reg[2:0]sof_pipe;
 assign O_tuser=sof_pipe[2]; // Preserve the ISP's early FIFO-reset SOF pulse.
 always @(posedge I_clk or negedge I_rst_n)begin
  if(!I_rst_n)begin
   x<=0;y<=0;v0<=0;last0<=0;x0<=0;y0<=0;bot0<=0;rgb0<=0;mode0<=0;sof_pipe<=0;
  end else begin
   sof_pipe<={sof_pipe[1:0],I_tuser};v0<=I_tvalid;
   if(I_tuser)begin x<=0;y<=0;end
   if(I_tvalid)begin
    x0<=xx;y0<=yy;last0<=I_tlast;bot0<=bot_in;rgb0<=I_tdata;mode0<=I_mode;
    if(I_tlast)begin x<=0;y<=yy==IMG_HEIGHT-1?0:yy+1'b1;end
    else begin x<=xx+1'b1;y<=yy;end
   end
  end
 end
 reg pending,p_last;reg[AW-1:0]p_x;reg[10:0]p_y;
 reg[15:0]p_top,p_mid,p_bot;reg[95:0]p_rgb;reg[1:0]p_mode;
 reg[7:0]left_top,left_mid,left_bot;
 // Gray<=253, |gx|/|gy|<=1012, so 11 signed bits suffice.
 // Require support from at least two rows or columns with consistent polarity.
 // Signed median rejects one large directional outlier. No extra line RAM
 // or pipeline stage: keep raw RGB and early SOF alignment unchanged.
 function signed[8:0]median_delta;
 input signed[8:0]a,b,c;
 begin median_delta=a>b?(b>c?b:(a>c?c:a)):(a>c?a:(b>c?c:b));end
 endfunction
 function[7:0]min3;
 input[7:0]a,b,c;reg[7:0]m;
 begin m=a<b?a:b;min3=m<c?m:c;end endfunction
 function[7:0]max3;
 input[7:0]a,b,c;reg[7:0]m;
 begin m=a>b?a:b;max3=m>c?m:c;end endfunction
 function edge_at;
  input[7:0]a,b,c,d,e,f,g,h,i;
  reg signed[10:0]gx,gy;
  reg signed[8:0]dx0,dx1,dx2,dy0,dy1,dy2;
  reg[10:0]ax,ay;reg[11:0]mag;
  integer hp,hn,vp,vn,th;
  reg signed[8:0]mx,my;reg[8:0]amx,amy;reg[9:0]robust_contrast;
  reg[7:0]cross_min,cross_max,diagonal_min0,diagonal_max0,diagonal_min1,diagonal_max1;
  reg[10:0]ridge_th;reg ridge;

  begin
   dx0=$signed({1'b0,c})-$signed({1'b0,a});dx1=$signed({1'b0,f})-$signed({1'b0,d});dx2=$signed({1'b0,i})-$signed({1'b0,g});
   dy0=$signed({1'b0,a})-$signed({1'b0,g});dy1=$signed({1'b0,b})-$signed({1'b0,h});dy2=$signed({1'b0,c})-$signed({1'b0,i});
   gx=$signed(dx0)+($signed({{2{dx1[8]}},dx1})<<<1)+$signed(dx2);
   gy=$signed(dy0)+($signed({{2{dy1[8]}},dy1})<<<1)+$signed(dy2);
   ax=gx[10]?-gx:gx;ay=gy[10]?-gy:gy;mag={1'b0,ax}+{1'b0,ay};
   th=(EDGE_TH>>3)>0?(EDGE_TH>>3):1;
   hp=(dx0>=th)+(dx1>=th)+(dx2>=th);hn=(dx0<=-th)+(dx1<=-th)+(dx2<=-th);
   vp=(dy0>=th)+(dy1>=th)+(dy2>=th);vn=(dy0<=-th)+(dy1<=-th)+(dy2<=-th);
   edge_at=(mag>=EDGE_TH)&&((hp>=2)||(hn>=2)||(vp>=2)||(vn>=2));
   if(DENOISE_EN)begin
    mx=median_delta(dx0,dx1,dx2);my=median_delta(dy0,dy1,dy2);
    amx=mx[8]?-mx:mx;amy=my[8]?-my:my;
    robust_contrast={1'b0,amx}+{1'b0,amy};
    cross_min=min3(b,d,f);if(h<cross_min)cross_min=h;
    cross_max=max3(b,d,f);if(h>cross_max)cross_max=h;
    diagonal_min0=min3(a,e,i);diagonal_max0=max3(a,e,i);
    diagonal_min1=min3(c,e,g);diagonal_max1=max3(c,e,g);
    ridge_th=({1'b0,EDGE_TH}+12'd3)>>2;if(ridge_th==0)ridge_th=1;
    // A coherent three-point diagonal can have zero Sobel gradient. Require
    // all three diagonal samples to differ from all four axial neighbors.
    ridge=({1'b0,diagonal_min0}>={1'b0,cross_max}+ridge_th)||
          ({1'b0,diagonal_min1}>={1'b0,cross_max}+ridge_th)||
          ({1'b0,diagonal_max0}+ridge_th<={1'b0,cross_min})||
          ({1'b0,diagonal_max1}+ridge_th<={1'b0,cross_min});
    // This median bound implies the legacy two-row/column support bound;
    // do not retain its redundant comparators in the production datapath.
    edge_at=((mag>=EDGE_TH)&&(robust_contrast!=0)&&
             (({2'b0,robust_contrast}<<2)>=EDGE_TH))||ridge;
   end
  end
 endfunction
 wire first_edge=edge_at(left_top,p_top[15:8],p_top[7:0],left_mid,p_mid[15:8],p_mid[7:0],left_bot,p_bot[15:8],p_bot[7:0]);
 wire second_edge=edge_at(p_top[15:8],p_top[7:0],rows[31:24],p_mid[15:8],p_mid[7:0],rows[15:8],p_bot[15:8],p_bot[7:0],bot0[15:8]);
 wire emit=pending&&(v0||p_last);
 always @(posedge I_clk or negedge I_rst_n)begin
  if(!I_rst_n)begin
   pending<=0;p_last<=0;p_x<=0;p_y<=0;p_top<=0;p_mid<=0;p_bot<=0;p_rgb<=0;p_mode<=0;
   left_top<=0;left_mid<=0;left_bot<=0;
   O_tlast<=0;O_tvalid<=0;O_edge<=0;O_aligned_data<=0;O_mode<=0;
  end else begin
   O_tvalid<=emit;O_tlast<=emit&&p_last;O_edge<=0;
   if(emit)begin
    O_aligned_data<=p_rgb;O_mode<=p_mode;
    O_edge[0]<=p_y>=2 && p_x!=0 && first_edge;
    O_edge[1]<=p_y>=2 && !p_last && second_edge;
    pending<=0;
   end
   if(v0)begin
    if(x0==0)begin left_top<=0;left_mid<=0;left_bot<=0;end
    else begin left_top<=p_top[7:0];left_mid<=p_mid[7:0];left_bot<=p_bot[7:0];end
    pending<=1;p_last<=last0;p_x<=x0;p_y<=y0;
    p_top<=rows[31:16];p_mid<=rows[15:0];p_bot<=bot0;p_rgb<=rgb0;p_mode<=mode0;
   end
  end
 end
endmodule

module edge_line_ram #(parameter AW=9)(
 input clk,we,input[AW-1:0]wa,input[31:0]wd,input re,input[AW-1:0]ra,output[31:0]q);
`ifdef EDGE_RAM_SIM
 reg[31:0]mem[0:(1<<AW)-1];reg[31:0]qr;
 always @(posedge clk)begin if(we)mem[wa]<=wd;if(re)qr<=mem[ra];end
 assign q=qr;
`else
 PH1P_LOGIC_ERAM #(
 .DATA_WIDTH_A(32),.DATA_WIDTH_B(32),.ADDR_WIDTH_A(AW),.ADDR_WIDTH_B(AW),
 .DATA_DEPTH_A(1<<AW),.DATA_DEPTH_B(1<<AW),.MODE("DP"),
 .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.IMPLEMENT("20K(FAST)"),
 .ECC_ENCODE("DISABLE"),.ECC_DECODE("DISABLE"),.CLKMODE("SYNC"),.SSROVERCE("DISABLE"),
 .OREGSET_A("RESET"),.OREGSET_B("RESET"),.RESETMODE_A("ASYNC"),.RESETMODE_B("ASYNC"),
 .ASYNC_RESET_RELEASE_A("ASYNC"),.ASYNC_RESET_RELEASE_B("ASYNC"),.INIT_FILE("NONE"),.FILL_ALL("0")) native_ram(
 .dia(wd),.dib(32'd0),.addra(wa),.addrb(ra),.clka(clk),.clkb(clk),.cea(we),.ceb(re),.ocea(1'b1),.oceb(1'b1),
 .wea(we),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(),.dob(q),.ecc_sbiterr(),.ecc_dbiterr(),
 .ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0));
`endif
endmodule
