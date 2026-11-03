/*****************************************************************
Company : MiLianKe Electronic Technology Co., Ltd.
WebSite:https://www.milianke.com
TechWeb:https://www.uisrc.com
tmall-shop:https://milianke.tmall.com
jd-shop:https://milianke.jd.com
taobao-shop: https://milianke.taobao.com
Description: 
The reference demo provided by Milianke is only used for learning. 
We cannot ensure that the demo itself is free of bugs, so users 
should be responsible for the technical problems and consequences
caused by the use of their own products.
@Author      :   XiaoQingquan 
@Time        :   2024/10 
version:     :   
@Description :   在原基础上删去了一些赘余的代码，并且优化了时序，加入BRAM IP核，
                 让从除法器出来的每一个数据都可以对上相应的像素数据进行增益，使
                 得它的适用行更加广泛了。
*****************************************************************/
module awb  #(   
    parameter IMG_HEIGHT = 1080,
    parameter IMG_WIDTH  = 1920,
    parameter AWB_ENABLE = 1,
    parameter integer STAT_MIN_BEATS = 20480,
    parameter integer FRAME_MAX_BEATS = IMG_WIDTH * IMG_HEIGHT / 4 + IMG_WIDTH / 4
) 
(
    input                   I_clk  ,
    input                   I_rst_n,


    input                   I_tlast  ,
    input                   I_tuser  ,
    input                   I_frame_bad ,   // 评审#2（第2批）：上一帧坏帧标志（帧首有效）
    input [95:0]            I_tdata  ,
    input                   I_tvalid , 
    output                  I_tready ,

    output                  O_tlast  ,
    output                  O_tuser  ,
    output [95:0]           O_tdata  ,
    output                  O_tvalid ,
    input                   O_tready
);

/*****************************************************************
                          RGB565תRGB888                                        
*****************************************************************/

    // //RGB565??????888
    // wire [4:0]  rgb565_r   = I_st_data[11+:5];
    // wire [5:0]  rgb565_g   = I_st_data[5+:6];
    // wire [4:0]  rgb565_b   = I_st_data[0+:5];
    
    // wire [23:0] rgb888     = {{rgb565_r[4:0],rgb565_r[2:0]},{rgb565_g[5:0],rgb565_g[1:0]},{rgb565_b[4:0],rgb565_b[2:0]}};
    
    // wire [7:0]  rgb888_r   = rgb888[16+:8];
    // wire [7:0]  rgb888_g   = rgb888[8+:8] ;
    // wire [7:0]  rgb888_b   = rgb888[0+:8] ;
    
  /*****************************************************************
                          中间信号                                        
*****************************************************************/


  reg         I_tvalid_r0,I_tvalid_r1;
  reg  [95:0] I_tdata_d0,I_tdata_d1;


  //累加RGB通道的�??
  reg  [31:0]         sum_r[0:3];
  reg  [31:0]         sum_g[0:3];
  reg  [31:0]         sum_b[0:3];

  
  wire  [95:0]        data_d0 ;
  wire                valid_d0;
  wire                I_tuser_r0;    

  reg                 I_tuser_r1;

  reg   [95:0]        data_d1 ;
  reg                 valid_d1;
  reg   [9:0]         rgb_sum[0:3];//每个像素点RGB的和
  /*****************************************************************
                            平均值计�??                                      
*****************************************************************/

// 对输入数据和有效信号进行寄存，形成流水线
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        I_tdata_d0  <= 0;
        I_tdata_d1  <= 0;
        {I_tvalid_r0,I_tvalid_r1} <= 0;
    end else begin
        I_tdata_d0  <= I_tdata   ;
        I_tdata_d1  <= I_tdata_d0;
        I_tvalid_r0 <= I_tvalid;
        I_tvalid_r1 <= I_tvalid_r0;
    end
end

// Frame statistics are collected in the same one-cycle delayed domain as
// the pixels. This includes the previous frame's final beat even when the
// next SOF arrives immediately, and includes a valid beat coincident with SOF.
reg I_tuser_d0, I_frame_bad_d0;
reg [1:0] sample_phase;
reg frame_seen;
reg [31:0] stat_beats, frame_beats_total;
reg [31:0] sum_r_p, sum_g_p, sum_b_p;
wire [1:0] sample_eff = I_tuser_d0 ? sample_phase + 2'd1 : sample_phase;
wire [23:0] stat_pixel = (sample_eff == 0) ? I_tdata_d0[23:0] :
                         (sample_eff == 1) ? I_tdata_d0[47:24] :
                         (sample_eff == 2) ? I_tdata_d0[71:48] : I_tdata_d0[95:72];
wire [9:0] stat_rgb_sum = {2'd0,stat_pixel[23:16]} +
                         {2'd0,stat_pixel[15:8]} + {2'd0,stat_pixel[7:0]};
wire stat_eligible = (stat_rgb_sum > 10'd45) && (stat_rgb_sum < 10'd720);
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        I_tuser_d0 <= 0; I_frame_bad_d0 <= 0;
    end else begin
        I_tuser_d0 <= I_tuser;
        I_frame_bad_d0 <= I_frame_bad;
    end
end
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        sum_r[0] <= 1; sum_g[0] <= 1; sum_b[0] <= 1;
        sum_r_p <= 1; sum_g_p <= 1; sum_b_p <= 1;
        stat_beats <= 0; frame_beats_total <= 0;
        sample_phase <= 3; frame_seen <= 0;
    end else if (I_tuser_d0) begin
        // Total beats are separate from accepted brightness-window samples.
        // Saturating at MAX+1 prevents a long/missing-SOF frame wrapping valid.
        if (frame_seen && stat_beats > STAT_MIN_BEATS &&
            frame_beats_total <= FRAME_MAX_BEATS && !I_frame_bad_d0) begin
            sum_r_p <= sum_r[0]; sum_g_p <= sum_g[0]; sum_b_p <= sum_b[0];
        end
        sample_phase <= sample_phase + 2'd1;
        frame_seen <= 1;
        frame_beats_total <= I_tvalid_r0 ? 1 : 0;
        stat_beats <= (I_tvalid_r0 && stat_eligible) ? 1 : 0;
        sum_r[0] <= 1 + ((I_tvalid_r0 && stat_eligible) ? stat_pixel[23:16] : 0);
        sum_g[0] <= 1 + ((I_tvalid_r0 && stat_eligible) ? stat_pixel[15:8] : 0);
        sum_b[0] <= 1 + ((I_tvalid_r0 && stat_eligible) ? stat_pixel[7:0] : 0);
    end else if (frame_seen && I_tvalid_r0) begin
        if (frame_beats_total <= FRAME_MAX_BEATS)
            frame_beats_total <= frame_beats_total + 1;
        if (frame_beats_total < FRAME_MAX_BEATS && stat_eligible) begin
            stat_beats <= stat_beats + 1;
            sum_r[0] <= sum_r[0] + stat_pixel[23:16];
            sum_g[0] <= sum_g[0] + stat_pixel[15:8];
            sum_b[0] <= sum_b[0] + stat_pixel[7:0];
        end
    end
end

  /*****************************************************************
                           计算增益                                       
*****************************************************************/

  wire [47:0] dout_R[3:0];
  wire [47:0] dout_B[3:0];

  wire done[3:0];

  wire [47:0] in_r_x1;
  wire [47:0] in_b_x1;
  assign in_r_x1 = dout_R[0][47:0];
  assign in_b_x1 = dout_B[0][47:0];



/*****************************************************************
                   IP 调用                                    
*****************************************************************/
    //为了保证合理的延迟，这里使用了除法器

      // 评审#1：输入改用"上一帧统计"（帧内恒定）——增益不再随帧内累加漂移
      divider div_gen_G_R_r1 (
          .clk(I_clk),  // input wire aclk
          .rst(!I_rst_n),
          .start(I_tvalid_r1),
          .denominator(sum_r_p),  // input wire [31 : 0] s_axis_divisor_tdata
          .numerator({sum_g_p,16'd0}),  // input wire [47 : 0] s_axis_dividend_tdata
          .quotient(dout_R[0]),  // output wire [79 : 0] m_axis_dout_tdata
          .done(done[0])
      );

      divider divide_G_B_r1 (
          .clk(I_clk),  // input wire aclk
          .rst(!I_rst_n),
          .start(I_tvalid_r1),
          .denominator(sum_b_p),  // input wire [31 : 0] s_axis_divisor_tdata
          .numerator({sum_g_p,16'd0}),  // input wire [47 : 0] s_axis_dividend_tdata
          .quotient(dout_B[0]),  // output wire [79 : 0] m_axis_dout_tdata
          .done()
      );

     
    signal_delay #(
        .IMG_HEIGHT   (IMG_HEIGHT),
        .IMG_WIDTH    (IMG_WIDTH ),
        .DATA_WIDTH   (96  ),
        .DELAY_CYCLE  (50)
    )signal_delay_d (
        /*input                       */ .I_clk  (I_clk  ),
        /*input                       */ .I_rst_n(I_rst_n),
        /*input                       */ .I_tuser(I_tuser),  //synthesis keep 
        /*input  wire                 */ .I_valid(I_tvalid_r1),  //synthesis keep 
        /*input  wire [DATA_WIDTH-1:0]*/ .I_data (I_tdata_d1 ),   //synthesis keep 
        /*output wire                 */ .O_valid(valid_d0   ),  //synthesis keep 
        /*output wire [DATA_WIDTH-1:0]*/ .O_data (data_d0    ),   //synthesis keep 
        /*output wire                 */ .O_tuser(I_tuser_r0 )
    );

    

/*****************************************************************
                            ��������                                      
*****************************************************************/

    // ---- 评审#1（2026-10-04 第1批）：整帧恒定增益 + 限幅 + 跨帧平滑 ----
    // 修复点：原代码在 I_tuser 处把增益复位为 1.0、帧内随统计持续更新 →
    //         每帧顶部"无色偏→修正色"的色彩瞬态。现改为：
    //   ① 目标增益 = clamp(上一帧统计商, 0.5x~3.0x)（商基于 prev 统计，帧内恒定）；
    //   ② 增益仅在帧边界（tuser）向目标按 ±GAIN_STEP 步进（跨帧平滑，无帧内变化）；
    //   ③ 复位只在 !rst_n 时（不再每帧复位）。
    localparam [19:0] GAIN_MIN  = 20'h08000;   // 0.5x
    localparam [19:0] GAIN_MAX  = 20'h30000;   // 3.0x
    localparam [19:0] GAIN_STEP = 20'h02000;   // 0.125x/帧

    wire [19:0] tgt_r = (in_r_x1 > {28'd0, GAIN_MAX}) ? GAIN_MAX :
                        (in_r_x1 < {28'd0, GAIN_MIN}) ? GAIN_MIN : in_r_x1[19:0];
    wire [19:0] tgt_b = (in_b_x1 > {28'd0, GAIN_MAX}) ? GAIN_MAX :
                        (in_b_x1 < {28'd0, GAIN_MIN}) ? GAIN_MIN : in_b_x1[19:0];

    reg  [19:0] tgt_r_r, tgt_b_r;
    always @(posedge I_clk or negedge I_rst_n)begin
        if(!I_rst_n)begin
            tgt_r_r <= 20'h10000;              // 起始 1.0x
            tgt_b_r <= 20'h10000;
        end
        else if(done[0])begin                  // 商每拍刷新（值帧内恒定），寄存一档
            tgt_r_r <= tgt_r;
            tgt_b_r <= tgt_b;
        end
    end

    reg  [19:0]   in_r_r1;
    reg  [19:0]   in_b_r1;
    always @(posedge I_clk or negedge I_rst_n)begin 
        if(!I_rst_n)begin
            in_r_r1 <= 20'h10000;              // 仅复位为 1.0x（不再每帧复位）
            in_b_r1 <= 20'h10000;
        end
        else if(I_tuser && AWB_ENABLE)begin                  // 帧边界：向目标步进（跨帧平滑）
            if(tgt_r_r > in_r_r1 + GAIN_STEP)       in_r_r1 <= in_r_r1 + GAIN_STEP;
            else if(tgt_r_r + GAIN_STEP < in_r_r1)  in_r_r1 <= in_r_r1 - GAIN_STEP;
            else                                    in_r_r1 <= tgt_r_r;
            if(tgt_b_r > in_b_r1 + GAIN_STEP)       in_b_r1 <= in_b_r1 + GAIN_STEP;
            else if(tgt_b_r + GAIN_STEP < in_b_r1)  in_b_r1 <= in_b_r1 - GAIN_STEP;
            else                                    in_b_r1 <= tgt_b_r;
        end
    end


    ////信号同步
    always @(posedge I_clk or negedge I_rst_n) begin
      if (!I_rst_n) begin
          valid_d1 <= 0;
          data_d1  <= 0;
          I_tuser_r1 <= 0;
      end else begin
          valid_d1 <= valid_d0;
          data_d1  <= data_d0 ;
          I_tuser_r1 <= I_tuser_r0;
      end
    end
/*****************************************************************
                           ��������                                       
*****************************************************************/

    reg [27:0] R_new_r1;
    reg [27:0] G_new_r1;
    reg [27:0] B_new_r1;

    reg [27:0] R_new_r2;
    reg [27:0] G_new_r2;
    reg [27:0] B_new_r2;

    reg [27:0] R_new_r3;
    reg [27:0] G_new_r3;
    reg [27:0] B_new_r3;

    reg [27:0] R_new_r4;
    reg [27:0] G_new_r4;
    reg [27:0] B_new_r4;


    wire   [7:0] rgb888_r_d1[0:3];
    wire   [7:0] rgb888_g_d1[0:3];
    wire   [7:0] rgb888_b_d1[0:3];

    assign  rgb888_r_d1[0] = data_d1[16+:8];
    assign  rgb888_g_d1[0] = data_d1[8+:8];
    assign  rgb888_b_d1[0] = data_d1[0+:8];

    assign  rgb888_r_d1[1] = data_d1[40+:8];
    assign  rgb888_g_d1[1] = data_d1[32+:8];
    assign  rgb888_b_d1[1] = data_d1[24+:8];

    assign  rgb888_r_d1[2] = data_d1[64+:8];
    assign  rgb888_g_d1[2] = data_d1[56+:8];
    assign  rgb888_b_d1[2] = data_d1[48+:8];

    assign  rgb888_r_d1[3] = data_d1[88+:8];
    assign  rgb888_g_d1[3] = data_d1[80+:8];
    assign  rgb888_b_d1[3] = data_d1[72+:8];
    always @(posedge I_clk or negedge I_rst_n)begin 
        if(!I_rst_n)begin
            R_new_r1 <= 0;
            G_new_r1 <= 0;
            B_new_r1 <= 0;

            R_new_r2 <= 0;
            G_new_r2 <= 0;
            B_new_r2 <= 0;

            R_new_r3 <= 0;
            G_new_r3 <= 0;
            B_new_r3 <= 0;

            R_new_r4 <= 0;
            G_new_r4 <= 0;
            B_new_r4 <= 0;
        end
        else if(valid_d1) begin
            R_new_r1 <= in_r_r1 * rgb888_r_d1[0];
            G_new_r1 <=           rgb888_g_d1[0];
            B_new_r1 <= in_b_r1 * rgb888_b_d1[0];

            R_new_r2 <= in_r_r1 * rgb888_r_d1[1];
            G_new_r2 <=           rgb888_g_d1[1];
            B_new_r2 <= in_b_r1 * rgb888_b_d1[1];

            R_new_r3 <= in_r_r1 * rgb888_r_d1[2];
            G_new_r3 <=           rgb888_g_d1[2];
            B_new_r3 <= in_b_r1 * rgb888_b_d1[2];

            R_new_r4 <= in_r_r1 * rgb888_r_d1[3];
            G_new_r4 <=           rgb888_g_d1[3];
            B_new_r4 <= in_b_r1 * rgb888_b_d1[3];
        end
    end

/*****************************************************************
                            �������???                                      
*****************************************************************/

    wire [7:0] R_new_x1;
    wire [7:0] G_new_x1;
    wire [7:0] B_new_x1;

    wire [7:0] R_new_x2;
    wire [7:0] G_new_x2;
    wire [7:0] B_new_x2;

    wire [7:0] R_new_x3;
    wire [7:0] G_new_x3;
    wire [7:0] B_new_x3;

    wire [7:0] R_new_x4;
    wire [7:0] G_new_x4;
    wire [7:0] B_new_x4;

    assign R_new_x1 = (R_new_r1[27:24])?255:R_new_r1[23:16];
    assign G_new_x1 =  G_new_r1;
    assign B_new_x1 = (B_new_r1[27:24])?255:B_new_r1[23:16];

    assign R_new_x2 = (R_new_r2[27:24])?255:R_new_r2[23:16];
    assign G_new_x2 =  G_new_r2;
    assign B_new_x2 = (B_new_r2[27:24])?255:B_new_r2[23:16];

    assign R_new_x3 = (R_new_r3[27:24])?255:R_new_r3[23:16];
    assign G_new_x3 =  G_new_r3;
    assign B_new_x3 = (B_new_r3[27:24])?255:B_new_r3[23:16];

    assign R_new_x4 = (R_new_r4[27:24])?255:R_new_r4[23:16];
    assign G_new_x4 =  G_new_r4;
    assign B_new_x4 = (B_new_r4[27:24])?255:B_new_r4[23:16];
/*****************************************************************
                           ͬ���ź�                                       
*****************************************************************/

    reg valid_d2,I_tuser_r2;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n)begin
            valid_d2 <= 0;
            I_tuser_r2 <= 0;
        end
        else begin
            valid_d2 <= valid_d1;
            I_tuser_r2 <= I_tuser_r1;
        end
    end


    reg [13:0] output_beat;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n || I_tuser) output_beat <= 0;
        else if (O_tvalid) output_beat <= (output_beat == IMG_WIDTH/4-1) ? 0 : output_beat+1;
    end
    assign O_tlast = O_tvalid && (output_beat == IMG_WIDTH/4-1);   
    // video_in uses frame_start to reset its asynchronous input FIFO.
    // Keep this pulse ahead of the delayed AWB pixels so the reset has
    // completed before the first output data reaches the FIFO.
    assign  O_tuser  = I_tuser;   
    assign  O_tvalid = valid_d2;

    assign  O_tdata = O_tvalid?{R_new_x4,G_new_x4,B_new_x4,
                       R_new_x3,G_new_x3,B_new_x3,
                       R_new_x2,G_new_x2,B_new_x2,
                       R_new_x1,G_new_x1,B_new_x1}:0;
    // assign O_t_data = {R_new[7-:5],G_new[7-:6],B_new[7-:5]};
    assign  I_tready = O_tready;
 
endmodule



