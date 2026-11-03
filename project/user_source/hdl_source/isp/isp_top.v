module isp_top #(parameter [5:0] SAT_K_Q4 = 6'd28, parameter AWB_ENABLE = 1,
                 parameter CB_EN = 1'b0, parameter [8:0] CB_G_A_Q8 = 9'd256,
                 parameter [15:0] CB_G_B_OFF = 16'd0) (
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
    output 			I_tready		,
    input  wire [1:0]  I_edge_state,      // 边缘模式内状态：0=原图 1=黑白 2=叠加 3=卡通化（K4）
    input  wire        I_gray_mode,       // 仅 SW2 关：灰度变换（饱和度 K=0 出 BT.601 亮度 + CB 旁路）
    input  wire [1:0]  I_curve_sel,       // 灰度曲线档（帧首锁存）：0=线性 1=γ0.7 2=S 曲线
    // ---- 识别跟踪检测分支（2026-10-11 新增）----
    input  wire [2:0]  I_preset_idx,      // HSV 阈值组（跟踪模式内 K1 循环 0..7）
    output wire [134:0] O_det_pack,       // 135bit 目标包（IF-VISION v1.1.0，motion 字段恒 0）
    output wire        O_det_load,        // 包装载脉冲（帧级；osd_track 内 cdc_4phase 源端 load）
    output wire        O_det_valid,       // 目标有效（LED 用）
    output wire [10:0] O_det_cx,          // 质心 x（LED 用）
    output wire [10:0] O_det_cy,          // 质心 y（LED 用）
    output wire [15:0] O_det_lost         // 连续丢失帧数（LED 用）
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
    .AWB_ENABLE(AWB_ENABLE),
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

    // ---- 识别跟踪检测分支（2026-10-11 新增）：AWB 输出级纯窃流旁路 ----
    // 挂载点 = awb_O_tdata（96bit RGB888，饱和度之前）——检测永远看"干净"的 AWB 校正图，
    // 不受显示模式（灰度/边缘/卡通）影响；O_tready 恒 1，不反压、不改像素（与主线零耦合）。
    wire        det_valid, det_upd, det_ftick, det_sync_err;
    wire [10:0] det_cx, det_cy, det_minx, det_maxx;
    wire [9:0]  det_miny, det_maxy;
    wire [20:0] det_count;
    wire [15:0] det_lost;
    wire [7:0]  det_fid;
    wire [2:0] det_result_preset; // v15: 帧锁存标签，禁止用实时按键值给旧结果贴标签
    detect_top #(
        .IMG_WIDTH(1280), .IMG_HEIGHT(720), .MIN_PIXELS(30), .MOTION_EN(0), .REGION_EN(1), .STRICT_RED(1), .OBJECT_STABILITY_EN(1), .BLUE_STABILITY_EN(1)
    ) u_detect (
        .I_clk(axi4s_video_aclk), .I_rst_n(I_rst_n),
        .I_tdata(awb_O_tdata), .I_tvalid(awb_O_tvalid),
        .I_tuser(awb_O_tuser), .I_tlast(awb_O_tlast),
        .O_tready(),
        .O_tdata(), .O_tvalid(), .O_tuser(), .O_tlast(),
        .I_preset_idx(I_preset_idx),
        .O_target_valid(det_valid), .O_cx(det_cx), .O_cy(det_cy), .O_count(det_count),
        .O_min_x(det_minx), .O_max_x(det_maxx), .O_min_y(det_miny), .O_max_y(det_maxy),
        .O_lost_cnt(det_lost), .O_results_upd(det_upd), .O_frame_tick(det_ftick),
        .O_dbg_mask_valid(), .O_dbg_mask(),
        .O_mot_valid(), .O_mot_cnt(), .O_mot_minx(), .O_mot_maxx(), .O_mot_miny(), .O_mot_maxy(),
        .O_s_valid(), .O_s_sof(), .O_s_eol(), .O_s_data(),
        .O_fid(), .O_result_fid(det_fid), .O_result_preset(det_result_preset), .O_sync_err(det_sync_err)
    );

    // 目标包 135bit（IF-VISION v1.1.0；bit0 保留位必须补齐——缺位整包移位会使 OSD 恒 LOST）
    assign O_det_pack = {det_valid, 1'b0 /*algo=0 跟踪*/, det_result_preset, det_cx, det_cy,
                         det_minx, det_maxx, det_miny, det_maxy, det_fid,
                         1'b0 /*mot_valid*/, 14'd0 /*mot_cnt*/,
                         11'd0, 11'd0, 10'd0, 10'd0, 1'b0};
    assign O_det_load  = det_upd;
    assign O_det_valid = det_valid;
    assign O_det_cx    = det_cx;
    assign O_det_cy    = det_cy;
    assign O_det_lost  = det_lost;

    // ---- 饱和度增强级（2026-10-04 新增：AWB 之后、128bit 重排之前）----
    // 背景：整条链只有 demosaic+AWB，无 CCM/饱和度；画面发灰。
    // 2026-10-04 第二轮：K_Q4 21->28（1.31x->1.75x，用户反馈"还不够"）；
    // 参数位宽扩至 6bit（上限 3.94x）。整链仿真位精确对拍已通过（2x921600 像素）。
    wire        sat_O_tlast, sat_O_tuser, sat_O_tvalid;
    wire [95:0] sat_O_tdata;

    // ---- 灰度模式（2026-10-09 阶段 A，仅 SW2 关）----
    //   K=0 → 饱和度级输出 clamp(Y + ((0·d+8)>>4)) = Y（逐位等于 BT.601 亮度，全分辨率）；
    //   同时旁路 CB：CB 对 G 做 G'=(153G+2215)>>8，若不禁用会把 R=G=B 破坏成 R=B≠G。
    //   两个 mux 均为组合逻辑，**不新增流水级**（整链延迟不变）。
    wire [5:0] S_k_q4_eff  = I_gray_mode ? 6'd0  : SAT_K_Q4;
    wire       S_cb_en_eff = I_gray_mode ? 1'b0  : CB_EN;

    axis_saturation_rgb96 u_saturation (
        .I_k_q4 (S_k_q4_eff),
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

    // ---- 通道线性校正级（2026-10-06 抓帧标定：G 曲线比 R/B 陡）----
    // 标定：G' = 0.5986*G + 8.654 (Q8 A=153, B=+2215)；EN=0 时逐位旁路。
    wire        cb_O_tlast, cb_O_tuser, cb_O_tvalid;
    wire [95:0] cb_O_tdata;

    // 2026-10-10 方案 A：均匀 CB 槽位换为 Codex 色彩线的**空间色彩校正级**（同为 1 拍、位置不变）
    // 灰度模式仍由 S_cb_en_eff=0 旁路（空间级 I_en=0 逐位直通，保持 R=G=B）。
    // 原均匀 axis_channel_balance_rgb96 保留在文件末尾（死代码，供 TB 与谱系追溯）。
    axis_spatial_cb_rgb96 #(
        .FRAMES_PER_PHASE(600   ),
        .IMG_W           (1280  ),
        .G_A_Q8          (CB_G_A_Q8 ),
        .G_B_OFF         (CB_G_B_OFF)
    ) u_channel_balance (
        .I_en   (S_cb_en_eff),
        .I_clk  (axi4s_video_aclk),
        .I_rst_n(I_rst_n),
        .I_tuser(sat_O_tuser ),
        .I_tvalid(sat_O_tvalid),
        .I_tlast(sat_O_tlast ),
        .I_tdata(sat_O_tdata ),
        .O_tuser(cb_O_tuser ),
        .O_tvalid(cb_O_tvalid),
        .O_tlast(cb_O_tlast ),
        .O_tdata(cb_O_tdata )
    );

    // ---- 灰度曲线级（阶段 B，2026-10-09）：CB 之后、边缘级之前；增强版统一3拍，独立SOF/EOL与数据对齐 ----
    // 灰度模式下流为 R=G=B=Y -> 曲线作用于 Y 并复制三通道；非灰度模式该级输出不被选用。
    wire        gc_O_tlast, gc_O_tuser, gc_O_tvalid;
    wire [95:0] gc_O_tdata;
    axis_gray_curve_rgb96 #(.DETAIL_EN(1)) u_gray_curve (
        .I_clk  (axi4s_video_aclk),
        .I_rst_n(I_rst_n),
        .I_tlast(cb_O_tlast ),
        .I_tuser(cb_O_tuser ),
        .I_tdata(cb_O_tdata ),
        .I_tvalid(cb_O_tvalid),
        .I_curve(I_curve_sel),
        .I_gray_mode(I_gray_mode),
        .O_tlast(gc_O_tlast ),
        .O_tuser(gc_O_tuser ),
        .O_tdata(gc_O_tdata ),
        .O_tvalid(gc_O_tvalid)
    );

    // ---- Four edge views, after gray curves; production noise/diagonal refinement enabled. ----
    // 0=raw, 1=monochrome, 2=white overlay, 3=cartoon. EDGE_TH=60.
    wire        edge_O_tlast, edge_O_tuser, edge_O_tvalid;
    wire [95:0] edge_O_tdata;
    axis_edge_mode_rgb96 #(
        .IMG_WIDTH (1280),
        .IMG_HEIGHT(720),
        .EDGE_TH   (11'd60),
        .DENOISE_EN(1)
    ) u_edge_mode (
        .I_clk          (axi4s_video_aclk),
        .I_rst_n        (I_rst_n),
        .I_tlast        (gc_O_tlast),
        .I_tuser        (gc_O_tuser),
        .I_tdata        (gc_O_tdata),
        .I_tvalid       (gc_O_tvalid),
        .I_edge_state   (I_edge_state),
        .O_tlast        (edge_O_tlast),
        .O_tuser        (edge_O_tuser),
        .O_tdata        (edge_O_tdata),
        .O_tvalid       (edge_O_tvalid)
    );

    data_96bit_to_128bit u_data_96bit_to_128bit(
        .I_clk              ( axi4s_video_aclk  ),
        .I_rst_n            ( I_rst_n           ),
	
        .I_96b_frame_start  ( edge_O_tuser      ),
        .I_96b_valid        ( edge_O_tvalid     ),
        .I_96b_tlast        ( edge_O_tlast      ),
        .I_96b_data         ( edge_O_tdata      ),
	
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
module axis_saturation_rgb96 (
    input  wire [5:0]  I_k_q4,            // Q4.4 增益(运行时)：16=1.00x(恒等), 21≈1.31x, 28≈1.75x, 32=2.00x；
                                          // 灰度模式置 0 → 输出逐位等于 BT.601 亮度 Y（2026-10-09）
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

    function [7:0] luma_exact;
        input [7:0] r,g,b;
        reg [15:0] rr,gg,bb,total;
        begin
            rr={8'd0,r};gg={8'd0,g};bb={8'd0,b};
            total=(rr<<6)+(rr<<3)+(rr<<2)+rr
                 +(gg<<7)+(gg<<4)+(gg<<2)+(gg<<1)
                 +(bb<<5)-(bb<<1)-bb;
            luma_exact=total[15:8];
        end
    endfunction
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
                s1_y[i] <= luma_exact(I_tdata[24*i+23-:8],I_tdata[24*i+15-:8],I_tdata[24*i+7-:8]);
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
            t = d * $signed({1'b0, I_k_q4});      // 9bit x 7bit -> 16bit(signed)，|d|·K≤255×63=16065
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

// ---------------------------------------------------------------------------
// axis_channel_balance_rgb96 —— 通道线性校正级（4 像素/拍，96-bit 流）
// 2026-10-06 抓帧标定：G 通道响应曲线比 R/B 陡（暗区 G/R~0.91、亮区 ~1.22），
// 用 G' = (A*G + B_OFF) >> 8 把 G 拉回与 R/B 一致；R/B 直通。
// EN=0 时逐位旁路（仅增加 1 拍流水延迟）。字节序同 axis_saturation_rgb96。
// ---------------------------------------------------------------------------
module axis_channel_balance_rgb96 #(
    parameter [8:0]  G_A_Q8  = 9'd256,     // 256/256 = 1.000
    parameter [15:0] G_B_OFF = 16'd0       // 无偏置
)(
    input  wire        I_en,               // 运行时使能（灰度模式置 0 = 旁路，防破坏 R=G=B）
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

    function [7:0] cb_g;
        input [7:0] g;
        reg [17:0] t;
        reg [9:0]  v;
        begin
            if (!I_en) begin
                cb_g = g;
            end else begin
                t = G_A_Q8 * g + G_B_OFF;
                v = t >> 8;
                cb_g = (v > 10'd255) ? 8'd255 : v[7:0];
            end
        end
    endfunction

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_tvalid <= 1'b0;
            O_tlast  <= 1'b0;
            O_tuser  <= 1'b0;
            O_tdata  <= 96'd0;
        end else begin
            O_tvalid <= I_tvalid;
            O_tlast  <= I_tlast;
            O_tuser  <= I_tuser;
            O_tdata[23:16] <= I_tdata[23:16];
            O_tdata[15: 8] <= cb_g(I_tdata[15: 8]);
            O_tdata[ 7: 0] <= I_tdata[ 7: 0];
            O_tdata[47:40] <= I_tdata[47:40];
            O_tdata[39:32] <= cb_g(I_tdata[39:32]);
            O_tdata[31:24] <= I_tdata[31:24];
            O_tdata[71:64] <= I_tdata[71:64];
            O_tdata[63:56] <= cb_g(I_tdata[63:56]);
            O_tdata[55:48] <= I_tdata[55:48];
            O_tdata[95:88] <= I_tdata[95:88];
            O_tdata[87:80] <= cb_g(I_tdata[87:80]);
            O_tdata[79:72] <= I_tdata[79:72];
        end
    end

endmodule

// =============================================================================
// axis_spatial_cb_rgb96 —— 空间色彩校正级（来源：Codex 色彩线 v12，2026-10-10 合并）
// -----------------------------------------------------------------------------
// 来源与证据：`work/color_clean_v12/lab_ex1/.../axis_spatial_cb_rgb96.v`（位流 ce82733f，已上板确认正常），
//   本文件为**逐字复制**（唯一改动：`parameter EN` → 运行时端口 `I_en`，以便与本工程的灰度模式旁路联动）。
// 功能：按坐标（x 镜像对称 + 逐行 3 列网格插值）对 R/G/B 施加增益（G 另含偏置）校正，
//   修**空间色差**（中心/边缘色比不一致）——这是均匀 CB 做不到、径向 LSC 又未闭环的那一块。
// 延迟：像素数据 **1 拍**（系数由"提前 3 拍 lookahead"算好，因为系数只与坐标有关）✓ 与本工程 CB 槽位一致。
// 使能：I_en=0 时逐位旁路（灰度模式用；保持 R=G=B 不被破坏）。
// 说明：v11 诊断叠字（panel/mode_block/clip_flags 等）在源码中保留但 v12 已不参与输出（综合可裁剪）。
// =============================================================================
// V12: clean camera image; fixed v10 yellow coefficients; visible OSD removed.
// Retained unobserved diagnostic helpers are eligible for synthesis pruning.
// Pixel latency stays one cycle. Independent statistics pipeline: pixel/ROI -> beat sum -> accumulation.
// Yellow ROI text flags any input or corrected channel equal to 255; it is not a percentage.
// Horizontal edge coefficients are inherited from the selected v3 cyan mode.
// Center reduction fades within inner 640 pixels and rows 128..639.
// ROMs are generated for fixed 1280 width and G A=153, B=2215.
// Preload next accepted beat AND row; output/sidebands retain one-cycle latency.
// SC14: explicit initialized PH1P synchronous ROMs, fixed v12 yellow arithmetic.
// 1280x720, four RGB pixels per accepted beat. Exactly ONE pixel clock delay.
// Runtime I_en=0 is bit-exact bypass. Coefficients still advance while bypassed.
// Four .dath files must accompany this file in the same synthesis source folder.
// R/B lookup ranges are generator-checked for this fixed calibration profile.
// FRAMES_PER_PHASE remains a compatibility parameter; no OSD or phase cycling.
module axis_spatial_cb_rgb96 #(
 parameter FRAMES_PER_PHASE=600, parameter IMG_W=1280,
 parameter [8:0] G_A_Q8=153, parameter [15:0] G_B_OFF=2215
)(input wire I_clk,I_rst_n,I_tuser,I_tvalid,I_tlast,input wire [95:0] I_tdata,
 input wire I_en,
 output reg O_tuser,O_tvalid,O_tlast,output wire [95:0] O_tdata);
 reg [9:0] bx,by;
 wire [9:0] bx_eff=I_tuser?10'd0:bx;
 wire [9:0] by_eff=I_tuser?10'd0:by;
 wire [9:0] look_x=(bx_eff>=317)?bx_eff-10'd317:bx_eff+10'd3;
 wire [9:0] look_y=(bx_eff>=317)?by_eff+10'd1:by_eff;
 wire [9:0] look_row=(look_y<720)?look_y:10'd719;
 wire [7:0] look_idx=(look_x<160)?look_x[7:0]:10'd319-look_x;
 wire advance=I_tvalid && !I_tuser;
 wire [37:0] x_q;
 wire [139:0] row_q;
 // Explicit initialized PH1P ERAM, single synchronous read (NOREG).
 // No inferred read-only array in the synthesis branch.
 sc13_rom2 #(.W(38),.AW(8),.FILE("sc13_x.dath")) x_storage(
 .clk(I_clk),.ce0(advance),.ce1(1'b0),.a0(look_idx),.a1(8'd0),.q0(x_q),.q1());
 sc13_rom2 #(.W(140),.AW(10),.FILE("sc13_rows.dath")) row_storage(
 .clk(I_clk),.ce0(advance),.ce1(1'b0),.a0(look_row),.a1(10'd0),.q0(row_q),.q1());
 reg meta1_seed,meta1_right;
 reg [8:0] meta1_w;
 wire [37:0] xc=meta1_seed?{9'd256,4'd0,9'd256,16'd0}:x_q;
 wire [33:0] yc=meta1_seed?{9'd128,9'd205,16'd1108}:row_q[37:4];
 wire [3:0] dy=meta1_seed?4'd0:row_q[3:0];
 wire [26:0] lo=meta1_seed?{9'd204,9'd279,9'd243}:
                       meta1_right?row_q[88:62]:row_q[139:113];
 wire [23:0] delta=meta1_seed?24'd0:meta1_right?row_q[61:38]:row_q[112:89];
 wire [24:0] base0=(yc[33:25]>xc[37:29])?yc[24:0]:xc[24:0];
 wire [3:0] dim=(xc[28:25]<dy)?xc[28:25]:dy;
 wire [8:0] base_gain=base0[24:16]-{5'd0,dim};
 // Exact row differences fit signed 8 bits (-122..98 across all channels).
 // Storing them removes the subtractor before the interpolation multiply.
 wire signed [7:0] dr=$signed(delta[23:16]);
 wire signed [7:0] dg=$signed(delta[15:8]);
 wire signed [7:0] db=$signed(delta[7:0]);
 (* dsp_style="no" *) wire signed [20:0] pr=dr*$signed({1'b0,meta1_w});
 (* dsp_style="no" *) wire signed [20:0] pg=dg*$signed({1'b0,meta1_w});
 (* dsp_style="no" *) wire signed [20:0] pb=db*$signed({1'b0,meta1_w});
 reg [26:0] meta2_lo;
 reg signed [20:0] meta2_r,meta2_g,meta2_b;
 reg [24:0] meta2_base;
 function [8:0] grid_finish;
 input [8:0] low;input signed [20:0] product;
 reg signed [20:0] rounded;reg signed [21:0] value;
 begin rounded=product+21'sd128;value=$signed({13'd0,low})+(rounded>>>8);grid_finish=value[8:0];end
 endfunction
 wire [8:0] grid_r=grid_finish(meta2_lo[26:18],meta2_r);
 wire [8:0] grid_g=grid_finish(meta2_lo[17:9],meta2_g);
 wire [8:0] grid_b=grid_finish(meta2_lo[8:0],meta2_b);
 wire [8:0] final_r=({1'b0,grid_r}+10'd257)>>1;
 wire [8:0] final_g=({1'b0,grid_g}+{1'b0,meta2_base[24:16]}+10'd1)>>1;
 wire [8:0] final_b=({1'b0,grid_b}+10'd257)>>1;
 wire [15:0] final_off=({1'b0,meta2_base[15:0]}+17'd1)>>1;
 reg [42:0] coeff_reg;
 wire [42:0] coeff_eff=I_tuser?{9'd230,9'd268,9'd250,16'd0}:coeff_reg;
 always @(posedge I_clk or negedge I_rst_n)begin
 if(!I_rst_n)begin
 bx<=0;by<=0;coeff_reg<={9'd230,9'd268,9'd250,16'd0};
 meta1_seed<=1;meta1_right<=0;meta1_w<=0;
 meta2_lo<={9'd204,9'd279,9'd243};meta2_r<=0;meta2_g<=0;meta2_b<=0;meta2_base<={9'd256,16'd0};
 end else begin
 if(I_tuser)begin
 bx<=0;by<=0;coeff_reg<={9'd230,9'd268,9'd250,16'd0};
 meta1_seed<=1;meta1_right<=0;meta1_w<=0;
 meta2_lo<={9'd204,9'd279,9'd243};meta2_r<=0;meta2_g<=0;meta2_b<=0;meta2_base<={9'd256,16'd0};
 end
 if(I_tvalid)begin
 bx<=(bx_eff==319)?10'd0:bx_eff+10'd1;
 by<=(bx_eff==319)?by_eff+10'd1:by_eff;
 if(!I_tuser)begin
 meta1_seed<=0;meta1_right<=(look_x>=160);
 meta1_w<=(look_x<160)?((look_x<=32)?9'd0:(look_x-10'd32)<<1):((look_x>=288)?9'd256:(look_x-10'd160)<<1);
 meta2_lo<=lo;meta2_r<=pr;meta2_g<=pg;meta2_b<=pb;meta2_base<={base_gain,base0[15:0]};
 coeff_reg<={final_r,final_g,final_b,final_off};
 end end end end
 // The old pixel tables are exactly linear Q8 maps with saturation.
 // Three radix-4 Booth terms implement each small multiply in LUT/carry logic.
 // Explicit shifts/adds avoid both duplicated large ROMs and extra DSP demand.
 function signed [13:0] booth;
 input [2:0] code;input [7:0] pixel;
 reg signed [13:0] p;
 begin p=$signed({6'd0,pixel});case(code)
  3'b001,3'b010:booth=p;3'b011:booth=p<<<1;
  3'b100:booth=-(p<<<1);3'b101,3'b110:booth=-p;
  default:booth=0;endcase end
 endfunction
 function signed [13:0] mul6;
 input [5:0] c;input [7:0] pixel;
 begin mul6=booth({c[1:0],1'b0},pixel)+(booth(c[3:1],pixel)<<<2)+(booth(c[5:3],pixel)<<<4);end
 endfunction
 function [7:0] red_pixel;
 input [7:0] pixel;input [5:0] index;
 reg signed [13:0] product;reg signed [14:0] value;
 begin product=mul6(index,pixel);value=$signed({7'd0,pixel})+(product>>>8);
 red_pixel=value>255?8'd255:value[7:0];end
 endfunction
 function [7:0] blue_pixel;
 input [7:0] pixel;input [4:0] index;
 reg signed [14:0] product,base,p;
 begin p=$signed({7'd0,pixel});base=index<29?(p<<<5):(p<<<6);
 product=$signed(mul6({1'b0,index},pixel))-base;
 blue_pixel=p+(product>>>8);end
 endfunction
 reg [31:0] red_out,blue_out;
 integer rb;
 always @(posedge I_clk)begin
 for(rb=0;rb<4;rb=rb+1)begin
  red_out[8*rb+:8]<=red_pixel(I_tdata[16+24*rb+:8],coeff_eff[39:34]);
  blue_out[8*rb+:8]<=blue_pixel(I_tdata[24*rb+:8],coeff_eff[20:16]);
 end end
 function [7:0] green;
 input [7:0] pixel;input [8:0] gain;input [15:0] offset;
 reg [17:0] total;
 begin total=gain*pixel+offset;green=(total[17:8]>255)?8'd255:total[15:8];end
 endfunction
 reg [31:0] green_out;
 reg [35:0] green_pair0,green_pair1;
 wire [25:0] green_pixels0={I_tdata[32+:8],10'd0,I_tdata[8+:8]};
 wire [25:0] green_pixels1={I_tdata[80+:8],10'd0,I_tdata[56+:8]};
 wire [35:0] green_offsets={2'd0,coeff_eff[15:0],2'd0,coeff_eff[15:0]};
 wire [8:0] green_gain=coeff_eff[33:25];
 function [7:0] green_clip(input [17:0] total);begin green_clip=|total[17:16]?8'd255:total[15:8];end endfunction
 reg [95:0] bypass_data;
 reg bypass,output_started;
 integer p;
 always @(posedge I_clk or negedge I_rst_n)begin
 if(!I_rst_n)begin
 O_tuser<=0;O_tvalid<=0;O_tlast<=0;bypass_data<=0;bypass<=1;output_started<=0;green_out<=0;green_pair0<=0;green_pair1<=0;
 end else begin
 O_tuser<=I_tuser;O_tvalid<=I_tvalid;O_tlast<=I_tlast;
 bypass_data<=I_tdata;bypass<=!I_en;output_started<=1;
 green_pair0<=green_pixels0*green_gain+green_offsets;
 green_pair1<=green_pixels1*green_gain+green_offsets;
 end end
 genvar lane;
 generate for(lane=0;lane<4;lane=lane+1)begin:pack
 assign O_tdata[24*lane+:24]=!output_started?24'd0:bypass?bypass_data[24*lane+:24]:{red_out[8*lane+:8],green_clip(lane<2?green_pair0[18*(lane%2)+:18]:green_pair1[18*(lane%2)+:18]),blue_out[8*lane+:8]};
 end endgenerate
endmodule

// Native hardware is the default. SC13_SIM is only an independent RTL
// simulation model; production project must NEVER define SC13_SIM.
module sc13_rom2 #(parameter W=8,AW=8,parameter FILE="NONE")(
 input wire clk,ce0,ce1,input wire [AW-1:0] a0,a1,
 output wire [W-1:0] q0,q1);
`ifdef SC13_SIM
 reg [W-1:0] mem[0:(1<<AW)-1];
 reg [W-1:0] sim_q0,sim_q1;
 initial $readmemh(FILE,mem);
 always @(posedge clk)if(ce0)sim_q0<=mem[a0];
 always @(posedge clk)if(ce1)sim_q1<=mem[a1];
 assign q0=sim_q0;assign q1=sim_q1;
`else
 PH1P_LOGIC_ERAM #(
 .DATA_WIDTH_A(W),.DATA_WIDTH_B(W),.ADDR_WIDTH_A(AW),.ADDR_WIDTH_B(AW),
 .DATA_DEPTH_A(1<<AW),.DATA_DEPTH_B(1<<AW),.MODE("DP"),
 .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
 .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.IMPLEMENT("20K(FAST)"),
 .ECC_ENCODE("DISABLE"),.ECC_DECODE("DISABLE"),.CLKMODE("SYNC"),
 .SSROVERCE("DISABLE"),.OREGSET_A("RESET"),.OREGSET_B("RESET"),
 .RESETMODE_A("ASYNC"),.RESETMODE_B("ASYNC"),
 .ASYNC_RESET_RELEASE_A("ASYNC"),.ASYNC_RESET_RELEASE_B("ASYNC"),
 .INIT_FILE(FILE),.FILL_ALL("0")) initialized_rom(
 .dia({W{1'b0}}),.dib({W{1'b0}}),.addra(a0),.addrb(a1),
 .clka(clk),.clkb(clk),.cea(ce0),.ceb(ce1),.ocea(1'b1),.oceb(1'b1),
 .wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),
 .doa(q0),.dob(q1),.ecc_sbiterr(),.ecc_dbiterr(),
 .ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0));
`endif
endmodule
