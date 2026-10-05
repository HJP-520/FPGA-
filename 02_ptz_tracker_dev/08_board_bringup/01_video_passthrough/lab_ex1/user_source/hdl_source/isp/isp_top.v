module isp_top (
    input 			axi4s_video_aclk,
    input 			I_rst_n			,
    input 			I_tlast			,
    input 			I_tuser			,
    input [39:0] 	I_tdata			,
    input 			I_tvalid		,
    input [9:0] 	I_tdest			,
    input 			I_frame_bad		,   // 评审#2（第2批）：上一帧坏帧（帧首有效）
    input 			O_tready		,
    output [127:0] 	O_tdata			,
    output 			O_tlast			,
    output 			O_tuser			,
    output 			O_tvalid		,
    output 			I_tready
);
 
wire         m_aixs_tvalid;  //synthesis keep 
  wire [127:0] m_aixs_tdata;  //synthesis keep 
  wire         m_aixs_tuser;  //synthesis keep 
  wire         m_aixs_tlast;  //synthesis keep 
  wire         m_aixs_tready;  //synthesis keep 
  
  wire [ 95:0] m_aixs_tdata_96;  //synthesis keep 


  wire         awb_O_tlast;  //synthesis keep 
  wire         awb_O_tuser;  //synthesis keep 
  wire [ 95:0] awb_O_tdata;  //synthesis keep 
  wire         awb_O_tvalid;  //synthesis keep 
  wire         awb_O_tready;  //synthesis keep 

  wire         awb_O_tuser_128;  //synthesis keep 
  wire         awb_O_tvalid_128;  //synthesis keep 
  wire [127:0] awb_O_tdata_128;  //synthesis keep 
  wire         repack_O_tlast;      // 第2批：repack 重建的行尾

  assign awb_O_tready = O_tready;
  assign O_tdata  = awb_O_tdata_128;
  // 评审#5（第1批）+ 评审#4/#8（2026-10-05 第2批）：tlast 在 repack（96→128）内重建，
  // 与 O_tdata/O_tvalid 同拍输出（行尾落在含该行最后一拍的输出字上）。
  assign O_tlast  = repack_O_tlast ;
  assign O_tuser  = awb_O_tuser_128    ;
  assign O_tvalid = awb_O_tvalid_128   ;
  
  //assign m_aixs_tready = O_tready;
  //assign O_tdata  = m_aixs_tdata;
  //assign O_tlast  = m_aixs_tlast    ;
  //assign O_tuser  = m_aixs_tuser    ;
  //assign O_tvalid = m_aixs_tvalid   ;
 
 
demosaic #(
    .IMG_HEIGHT          (720 ),  // 图像高度
    .IMG_WIDTH           (1280),  // 图像宽度
    .data_complete_delay (50  ),
    .BAYER_MODE          ("BGGR")
)
u_demosaic
(
    .I_clk   			(axi4s_video_aclk)	,   // 时钟信号
    .I_rst_n 			(I_rst_n)	,   // 复位信号，低有效
    .axi4s_video_tdata 	(I_tdata)	,  // AXI4-Stream视频数据
    .axi4s_video_tdest 	(I_tdest)	,
    .axi4s_video_tlast 	(I_tlast)	,  // 行结束信号
    .axi4s_video_tvalid	(I_tvalid)	,  // 数据有效信号
    .axi4s_video_tuser 	(I_tuser)	,  // 帧开始信号
    .axi4s_video_tready	(I_tready)	,  // 从模块准备好接受数据
    .O_tlast  			(m_aixs_tlast)	,  // 输出行结束信号
    .O_tuser  			(m_aixs_tuser)	,  // 输出帧开始信号
    .O_tdata  			(m_aixs_tdata)	,  // 输出数据
    .O_tvalid 			(m_aixs_tvalid)	,  // 输出数据有效信号
    .O_tready   		(m_aixs_tready)	   // 输出数据准备好信号
);
 
data128_96 u_data128_96 (
    .I_tdata(m_aixs_tdata),
    .O_tdata(m_aixs_tdata_96)
);

awb #(
    .IMG_HEIGHT(720 ),
    .IMG_WIDTH (1280)
) u_awb (
    .I_clk   (axi4s_video_aclk),
    .I_rst_n (I_rst_n),
    .I_frame_bad(I_frame_bad),
    .I_tlast (m_aixs_tlast),
    .I_tuser (m_aixs_tuser),
    .I_tdata (m_aixs_tdata_96),
    .I_tvalid(m_aixs_tvalid),
    .I_tready(m_aixs_tready),
    .O_tlast (awb_O_tlast ),
    .O_tuser (awb_O_tuser ),
    .O_tdata (awb_O_tdata ),
    .O_tvalid(awb_O_tvalid),
    .O_tready(awb_O_tready)
);

    // ---- 饱和度增强级（2026-10-04 新增：AWB 之后、128bit 重排之前）----
    // 背景：整条链只有 demosaic+AWB，无 CCM/饱和度；画面发灰。
    // 2026-10-04 第二轮：K_Q4 21->28（1.31x->1.75x，用户反馈"还不够"）；
    // 参数位宽扩至 6bit（上限 3.94x）。整链仿真位精确对拍已通过（2x921600 像素）。
    wire        sat_O_tlast, sat_O_tuser, sat_O_tvalid;
    wire [95:0] sat_O_tdata;

    axis_saturation_rgb96 #(
        .K_Q4(6'd28)
    ) u_saturation (
        .I_clk  (axi4s_video_aclk),
        .I_rst_n(I_rst_n),
        .I_tlast(awb_O_tlast ),
        .I_tuser(awb_O_tuser ),
        .I_tdata(awb_O_tdata ),
        .I_tvalid(awb_O_tvalid),
        .O_tlast(sat_O_tlast ),
        .O_tuser(sat_O_tuser ),
        .O_tdata(sat_O_tdata ),
        .O_tvalid(sat_O_tvalid)
    );

    data_96bit_to_128bit u_data_96bit_to_128bit(
        .I_clk              ( axi4s_video_aclk  ),
        .I_rst_n            ( I_rst_n           ),
	
        .I_96b_frame_start  ( sat_O_tuser       ),
        .I_96b_valid        ( sat_O_tvalid      ),
        .I_96b_tlast        ( sat_O_tlast       ),
        .I_96b_data         ( sat_O_tdata       ),
	
        .O_128b_frame_start ( awb_O_tuser_128  	),
        .O_128b_tlast       ( repack_O_tlast    ),
        .O_128b_valid       ( awb_O_tvalid_128 	),
        .O_128b_data        ( awb_O_tdata_128  	)
    );



//data96_128 u_data96_128 (
//    .I_tdata(awb_O_tdata),
//    .O_tdata(awb_O_tdata_128)
//);
	
endmodule


// Four-pixel RGB888 gamma stage.  The 16-segment curve approximates
// y = 255 * (x / 255)^0.7.  It lifts shadows and mid-tones while preserving
// black and white and adds one registered pipeline cycle.
module axis_gamma_rgb96 (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tlast,
    input  wire        I_tuser,
    input  wire [95:0] I_tdata,
    input  wire        I_tvalid,
    output reg         O_tlast,
    output reg         O_tuser,
    output reg  [95:0] O_tdata,
    output reg         O_tvalid
);

    function [7:0] gamma07;
        input [7:0] value;
        reg [7:0] base;
        reg [7:0] delta;
        reg [11:0] interpolation;
        begin
            case (value[7:4])
                4'h0: begin base = 8'd0;   delta = 8'd37; end
                4'h1: begin base = 8'd37;  delta = 8'd23; end
                4'h2: begin base = 8'd60;  delta = 8'd19; end
                4'h3: begin base = 8'd79;  delta = 8'd18; end
                4'h4: begin base = 8'd97;  delta = 8'd16; end
                4'h5: begin base = 8'd113; delta = 8'd16; end
                4'h6: begin base = 8'd129; delta = 8'd14; end
                4'h7: begin base = 8'd143; delta = 8'd14; end
                4'h8: begin base = 8'd157; delta = 8'd14; end
                4'h9: begin base = 8'd171; delta = 8'd13; end
                4'ha: begin base = 8'd184; delta = 8'd13; end
                4'hb: begin base = 8'd197; delta = 8'd12; end
                4'hc: begin base = 8'd209; delta = 8'd12; end
                4'hd: begin base = 8'd221; delta = 8'd12; end
                4'he: begin base = 8'd233; delta = 8'd11; end
                default: begin base = 8'd244; delta = 8'd11; end
            endcase

            interpolation = delta * value[3:0] + 8;
            if (value == 8'hff)
                gamma07 = 8'hff;
            else
                gamma07 = base + (interpolation >> 4);
        end
    endfunction

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_tlast  <= 1'b0;
            O_tuser  <= 1'b0;
            O_tdata  <= 96'd0;
            O_tvalid <= 1'b0;
        end else begin
            O_tlast  <= I_tlast;
            O_tuser  <= I_tuser;
            O_tvalid <= I_tvalid;
            if (I_tvalid) begin
                O_tdata <= {
                    gamma07(I_tdata[95:88]), gamma07(I_tdata[87:80]), gamma07(I_tdata[79:72]),
                    gamma07(I_tdata[71:64]), gamma07(I_tdata[63:56]), gamma07(I_tdata[55:48]),
                    gamma07(I_tdata[47:40]), gamma07(I_tdata[39:32]), gamma07(I_tdata[31:24]),
                    gamma07(I_tdata[23:16]), gamma07(I_tdata[15:8]),  gamma07(I_tdata[7:0])
                };
            end else begin
                O_tdata <= 96'd0;
            end
        end
    end

endmodule


// Centre crop for the ISP's four-pixel-wide RGB888 stream.  Frame start is
// intentionally forwarded at the original frame boundary so video_in can
// reset its asynchronous FIFO before the first selected row arrives.
module axis_crop_rgb96 #(
    parameter integer IN_WIDTH   = 1792,
    parameter integer IN_HEIGHT  = 1080,
    parameter integer OUT_WIDTH  = 1600,
    parameter integer OUT_HEIGHT = 900,
    parameter integer X_START    = 96,
    parameter integer Y_START    = 90
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tlast,
    input  wire        I_tuser,
    input  wire [95:0] I_tdata,
    input  wire        I_tvalid,
    output wire        O_tlast,
    output wire        O_tuser,
    output wire [95:0] O_tdata,
    output wire        O_tvalid
);

    localparam integer X_START_BEAT = X_START / 4;
    localparam integer OUT_BEATS    = OUT_WIDTH / 4;
    localparam integer X_END_BEAT   = X_START_BEAT + OUT_BEATS;

    reg [9:0]  S_hcnt;
    reg [10:0] S_vcnt;

    wire [9:0]  S_current_h = I_tuser ? 10'd0 : S_hcnt;
    wire [10:0] S_current_v = I_tuser ? 11'd0 : S_vcnt;
    wire S_inside = (S_current_h >= X_START_BEAT) &&
                    (S_current_h < X_END_BEAT) &&
                    (S_current_v >= Y_START) &&
                    (S_current_v < (Y_START + OUT_HEIGHT));

    assign O_tdata  = I_tdata;
    assign O_tvalid = I_tvalid && S_inside;
    assign O_tlast  = O_tvalid && (S_current_h == (X_END_BEAT - 1));
    assign O_tuser  = I_tuser;

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_hcnt <= 10'd0;
            S_vcnt <= 11'd0;
        end
        else if(I_tuser) begin
            S_hcnt <= (I_tvalid && !I_tlast) ? 10'd1 : 10'd0;
            S_vcnt <= (I_tvalid && I_tlast) ? 11'd1 : 11'd0;
        end
        else if(I_tvalid) begin
            if(I_tlast) begin
                S_hcnt <= 10'd0;
                S_vcnt <= (S_vcnt == IN_HEIGHT - 1) ? 11'd0 : S_vcnt + 1'b1;
            end
            else begin
                S_hcnt <= S_hcnt + 1'b1;
            end
        end
    end

endmodule


// =============================================================================


// =============================================================================
// axis_saturation_rgb96.v —— RGB 饱和度增强级（4 像素/拍，96-bit 流）
// -----------------------------------------------------------------------------
// 背景：板上画面"发灰、饱和度低"的根因是 ISP 链路只有 demosaic + AWB，
//       没有色彩校正（CCM）也没有饱和度处理；本模块补一个最小可用的饱和度级。
//
// 公式（全整数，与 tools/sat_tool.py 严格一致，可位精确对拍）：
//     Y   = (77*R + 150*G + 29*B) >> 8      // BT.601 亮度近似，8bit
//     d   = ch - Y                          // 有符号
//     out = clamp(Y + ((K_Q4 * d + 8) >> 4))// Q4.4 增益, 16=1.00x, 28≈1.75x, 32=2.00x
//
// 接口风格与 isp_top 内 axis_gamma_rgb96 一致：单时钟、无背压、2 拍流水；
// tvalid/tlast/tuser 同步延迟 2 拍，与数据严格对齐（帧边界不受影响）。
//
// 字节序约定：与 AWB 输出一致 —— 每 24bit 一个像素 {R[23:16], G[15:8], B[7:0]}，
//             [23:0]=第 0 像素 … [95:72]=第 3 像素；模块逐通道原位变换，不改布局。
// =============================================================================
module axis_saturation_rgb96 #(
    parameter [5:0] K_Q4 = 6'd21          // Q4.4 增益: 16=1.00x(恒等), 21≈1.31x, 28≈1.75x, 32=2.00x, 上限 63≈3.94x
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tlast,
    input  wire        I_tuser,
    input  wire [95:0] I_tdata,
    input  wire        I_tvalid,
    output reg         O_tlast,
    output reg         O_tuser,
    output reg  [95:0] O_tdata,
    output reg         O_tvalid
);

    // ---------------- 第一级：每像素亮度 Y + 原色寄存 ----------------
    reg [7:0] s1_c [0:11];                // 4 像素 x {R,G,B}：3*i+0=R, +1=G, +2=B
    reg [7:0] s1_y [0:3];
    reg       s1_valid, s1_last, s1_user;
    integer   i;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            s1_valid <= 1'b0;
            s1_last  <= 1'b0;
            s1_user  <= 1'b0;
        end else begin
            s1_valid <= I_tvalid;
            s1_last  <= I_tlast;
            s1_user  <= I_tuser;
            for (i = 0; i < 4; i = i + 1) begin
                s1_c[3*i+0] <= I_tdata[24*i + 23 -: 8];   // R
                s1_c[3*i+1] <= I_tdata[24*i + 15 -: 8];   // G
                s1_c[3*i+2] <= I_tdata[24*i +  7 -: 8];   // B
                s1_y[i]     <= (77  * I_tdata[24*i + 23 -: 8]
                              + 150 * I_tdata[24*i + 15 -: 8]
                              + 29  * I_tdata[24*i +  7 -: 8]) >> 8;
            end
        end
    end

    // ---------------- 第二级：饱和增益 + 限幅 ----------------
    function [7:0] sat_ch;
        input [7:0] c;
        input [7:0] y;
        reg signed [8:0]  d;
        reg signed [15:0] t;
        reg signed [11:0] v;                   // 12bit：K≤63 满量程（评审#7：原10bit 在 K≥33 时先于限幅溢出）
        begin
            d = $signed({1'b0, c}) - $signed({1'b0, y});
            t = d * $signed({1'b0, K_Q4});        // 9bit x 7bit -> 16bit(signed)，|d|·K≤255×63=16065
            t = t + 16'sd8;                        // 四舍五入(+0.5)
            v = $signed({1'b0, y}) + (t >>> 4);    // 算术右移 = floor，与 Python >> 一致
            if (v < 0)          sat_ch = 8'd0;
            else if (v > 16'sd255) sat_ch = 8'd255;
            else                sat_ch = v[7:0];
        end
    endfunction

    reg [7:0] s2_o [0:11];
    reg       s2_valid, s2_last, s2_user;
    integer   j;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            s2_valid <= 1'b0;
            s2_last  <= 1'b0;
            s2_user  <= 1'b0;
        end else begin
            s2_valid <= s1_valid;
            s2_last  <= s1_last;
            s2_user  <= s1_user;
            for (j = 0; j < 4; j = j + 1) begin
                s2_o[3*j+0] <= sat_ch(s1_c[3*j+0], s1_y[j]);
                s2_o[3*j+1] <= sat_ch(s1_c[3*j+1], s1_y[j]);
                s2_o[3*j+2] <= sat_ch(s1_c[3*j+2], s1_y[j]);
            end
        end
    end

    // ---------------- 输出寄存（总延迟 2 拍） ----------------
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_tvalid <= 1'b0;
            O_tlast  <= 1'b0;
            O_tuser  <= 1'b0;
            O_tdata  <= 96'd0;
        end else begin
            O_tvalid <= s2_valid;
            O_tlast  <= s2_last;
            O_tuser  <= s2_user;
            O_tdata  <= { s2_o[ 9], s2_o[10], s2_o[11],   // 像素3 (95:72)
                          s2_o[ 6], s2_o[ 7], s2_o[ 8],   // 像素2 (71:48)
                          s2_o[ 3], s2_o[ 4], s2_o[ 5],   // 像素1 (47:24)
                          s2_o[ 0], s2_o[ 1], s2_o[ 2] }; // 像素0 (23:0)
        end
    end

endmodule
