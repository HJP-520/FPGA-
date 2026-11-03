// Paired-pixel contours; raw, monochrome, white overlay and cartoon modes.
module axis_edge_mode_rgb96 #(
 parameter IMG_WIDTH=1280,IMG_HEIGHT=720,parameter EDGE_TH=11'd80,parameter DENOISE_EN=0
)(input I_clk,I_rst_n,I_tlast,I_tuser,input[95:0]I_tdata,input I_tvalid,
 input[1:0]I_edge_state,output O_tlast,O_tuser,output[95:0]O_tdata,output O_tvalid);
 wire[1:0]edge_bits,mode;wire[95:0]rgb;
 edge_detect_96 #(.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT),.EDGE_TH(EDGE_TH),.DENOISE_EN(DENOISE_EN)) u_edge_detect_96(
 .I_clk(I_clk),.I_rst_n(I_rst_n),.I_tlast(I_tlast),.I_tuser(I_tuser),.I_tdata(I_tdata),.I_tvalid(I_tvalid),
 .I_tready(1'b1),.I_mode(I_edge_state),.O_tlast(O_tlast),.O_tuser(O_tuser),.O_tvalid(O_tvalid),
 .O_edge(edge_bits),.O_tready(),.O_aligned_data(rgb),.O_mode(mode));
 function[23:0]paint;
 input[23:0]p;input edge_on;input[1:0]m;
 begin
  case(m)
   0:paint=p;
   1:paint=edge_on?24'hffffff:24'd0;
   2:paint=edge_on?24'hffffff:p;
   3:paint=edge_on?24'd0:{p[23:20],p[23:20],p[15:12],p[15:12],p[7:4],p[7:4]};
  endcase
 end endfunction
 // The Sobel first pair is the HIGH 48 bits of the incoming video word.
 assign O_tdata={paint(rgb[95:72],edge_bits[0],mode),paint(rgb[71:48],edge_bits[0],mode),
                 paint(rgb[47:24],edge_bits[1],mode),paint(rgb[23:0],edge_bits[1],mode)};
endmodule



// =============================================================================
// 说明（2026-10-09）：算法模式控制模块 `algo_mode_ctrl` 放在本文件内。
// 原因：TD 工程的源文件清单（.al）带有 GUI 维护的缓存，手工新增文件不会被综合读取
// （实测 syn 报 "algo_mode_ctrl is a black box"）；本工程既有风格也是"模块内嵌于已列文件"
// （isp_top.v 内即内嵌饱和度/CB/gamma/crop 四个模块）。故将模式控制与算法 mux 放在同一文件。
// =============================================================================
// =============================================================================
// algo_mode_ctrl.v —— 算法模式解码 + 帧首锁存（2026-10-09 灰度模式阶段 A）
// -----------------------------------------------------------------------------
// 输入 I_sw[3:0] = 拨码（已 2FF 同步到本时钟域）：I_sw[3]=SW4 … I_sw[0]=SW1，
// 高电平 = 开关"开"（板载拨码 PULLUP）。
//
// 语义（用户定义）："仅某一个开关关"选中对应算法，其余三个必须为开；
//   其余 12 种组合（含全开）一律落回原图 —— 安全默认，杜绝两个模式同时命中。
//   O_mode: 0=原图  1=边缘检测（仅 SW3 关）  2=灰度变换（仅 SW2 关）  3=跟踪预留（仅 SW4 关）
//
// 帧首锁存 + 连续两帧一致才生效：
//   灰度模式的 K 与 CB 旁路处在 ISP 链的不同深度（饱和度 3 级 / CB 1 级）。若模式在帧
//   中途切换，中间那段像素会拿到"(新 K, 旧 CB)" → R=G=B 之后又被 CB 的 G 校正破坏，
//   出现短暂色偏。故模式配置在帧首(I_frame_start, ISP 域 tuser 脉冲)锁存、帧内恒定；
//   拨码是机械件，另要求连续两个帧首取值一致才生效（防抖）。
//   参考设计：AMD mini-isp 的配置寄存器"下一帧首统一生效"。
// =============================================================================
module algo_mode_ctrl #(parameter MANUAL_HOLD_EN=0) (
    input  wire       I_clk,
    input  wire       I_rst_n,
    input  wire [3:0] I_sw,            // 已同步的拨码（SW4..SW1 = [3]..[0]）
    input  wire       I_frame_start,   // ISP 域帧首脉冲（tuser，与帧首有效拍同拍）
    input  wire       I_data_valid,    // ISP 输入数据有效（用于"上一帧流水已排空"判定）
    input  wire [1:0] I_curve,         // 灰度曲线档（按键派生）：0=线性 1=γ0.7 2=S 曲线 3=自适应二值化
    output reg  [1:0] O_mode,          // 帧首锁存后的模式（帧内恒定）
    output reg  [1:0] O_curve          // 帧首锁存后的曲线档（与模式同一份帧级配置）
);

    wire sw4 = I_sw[3];
    wire sw3 = I_sw[2];
    wire sw2 = I_sw[1];
    wire sw1 = I_sw[0];

    // ---- 严格"仅一个开关关"（其余三个必须为开）----
    wire mode_gray     =  sw4 &  sw3 & ~sw2 &  sw1;   // 仅 SW2 关 -> 灰度变换
    wire mode_edge     =  sw4 & ~sw3 &  sw2 &  sw1;   // 仅 SW3 关 -> 边缘检测
    wire mode_tracking = ~sw4 &  sw3 &  sw2 &  sw1;   // 仅 SW4 关 -> 跟踪预留
    // 全开与其它 12 种组合 -> 原图
    wire [1:0] mode_in = mode_gray     ? 2'd2 :
                         mode_edge     ? 2'd1 :
                         mode_tracking ? 2'd3 : 2'd0;

    // ---- 排空判定（2026-10-09 复核 P0）----
    // 帧首锁存只保证"帧内恒定"，还不够：tuser 与帧首有效拍同拍，若帧间空档不足，
    // 上一帧尾部像素仍在饱和度(3 级)/CB(1 级)流水级里，会读到新配置 -> 旧帧尾部被误灰度化/旁路。
    // 故：切换必须等"距上一次有效拍的空档 >= 受配置影响的流水深度"，否则推迟到下一个帧首
    // （帧首那一拍读到的是"过去"的计数，正是我们要的）。取 8 拍余量（深度 4）。
    // 兜底：若空档条件长期不满足（理论上的无消隐连续流），在连续 5 个帧首后仍按帧首生效，
    // 保证模式最终一定切换（真实传感器帧间必有消隐，正常路径第一次就生效）。
    localparam [3:0] DRAIN_CYCLES = 4'd8;
    reg [3:0] gap_cnt;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) gap_cnt <= 4'hF;
        else if (I_data_valid) gap_cnt <= 4'd0;
        else if (gap_cnt != 4'hF) gap_cnt <= gap_cnt + 4'd1;
    end
    wire drained = (gap_cnt >= DRAIN_CYCLES);

    // ---- 帧首锁存 + 连续两帧一致 + 排空/兜底 ----
    // 配置字 = {模式[1:0], 曲线档[1:0]} —— 一份帧级配置，整帧恒定（2026-10-09 阶段 B）
    wire [3:0] cfg_in = {mode_in, I_curve};
    reg  [3:0] cfg_pend;
    reg  [2:0] stable_cnt;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            cfg_pend   <= 4'd0;
            stable_cnt <= 3'd0;
            O_mode     <= 2'd0;
            O_curve    <= 2'd0;
        end else if (MANUAL_HOLD_EN && !sw1) begin
            // Freeze the actually displayed configuration, discard uncommitted
            // requests. Live pixels continue through the video pipeline.
            cfg_pend <= {O_mode,O_curve}; stable_cnt <= 0;
        end else if (I_frame_start) begin
            if (cfg_in != cfg_pend) begin
                // 与上一帧首不一致：登记新配置，等下一个帧首确认（"连续两帧一致"）
                cfg_pend   <= cfg_in;
                stable_cnt <= 3'd0;
            end else begin
                // 与上一帧首一致 = 连续第二个帧首 -> 允许生效；
                // 生效前提：上一帧流水已排空（gap>=DRAIN_CYCLES），否则推迟到后续帧首
                // （stable_cnt 记录已等待的帧首数，>=5 时兜底生效，保证不会死锁）
                if (drained || (stable_cnt >= 3'd5)) begin
                    O_mode  <= cfg_pend[3:2];
                    O_curve <= cfg_pend[1:0];
                end
                if (stable_cnt != 3'd7) stable_cnt <= stable_cnt + 3'd1;
            end
        end
    end

endmodule

// =============================================================================
// axis_gray_curve_rgb96.v —— 灰度曲线级（阶段 B，2026-10-09）
// -----------------------------------------------------------------------------
// 位置：CB 之后、边缘级之前（isp_top 内）。1 拍延迟（旁路档同样 1 拍，三档延迟一致）。
// 曲线：16 段等间距分段线性（PWL），三档（I_curve）：0=线性(旁路) 1=γ0.7 提亮 2=S 曲线增强。
// 实现：每像素 seg=Y[7:4]、frac=Y[3:0]；查 base/delta（两套表按 I_curve 选）
//       → out = base + ((delta*frac + 8)>>4)；delta*frac 用**显式移位加法**（不占 DSP）。
// 表值由主机定点模型生成（tools 见 work/gray_mode/）：γ0.7 定点最大误差 4.91 LSB（仅最暗段，
// Y≥16 后 ≤0.6）；S 曲线 1.26 LSB。表值 = round(f(seg*16))，delta = 相邻段差（和=255）。
// 灰度模式下 R=G=B=Y → 只需算一路再复制三通道；**非灰度模式（或线性档）逐位直通**（见输出级）。
// =============================================================================
module axis_gray_curve_rgb96 #(parameter IMG_WIDTH=1280, IMG_HEIGHT=720, DETAIL_EN=0) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tlast,
    input  wire        I_tuser,
    input  wire [95:0] I_tdata,
    input  wire        I_tvalid,
    input  wire [1:0]  I_curve,        // 0=线性 1=γ0.7 2=S 曲线 3=自适应二值化
    input  wire        I_gray_mode,    // 灰度模式（帧首锁存）：非灰度模式必须逐位旁路！
    output reg         O_tlast,
    output reg         O_tuser,
    output reg  [95:0] O_tdata,
    output reg         O_tvalid
);

    // K4=3: full-frame adaptive binary; preserve the existing one-cycle latency.
    wire [7:0] binary_threshold;
    gray_frame_threshold #(.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT)) u_threshold(
     .clk(I_clk),.rst_n(I_rst_n),.sof(I_tuser),.valid(I_tvalid),.eol(I_tlast),
     .gray_mode(I_gray_mode),.rgb(I_tdata),.threshold(binary_threshold));

    // ---- 曲线表（16 段 base/delta；{curve, seg} 扁平 case）----
    function [7:0] tbl_base;
        input [1:0] c;
        input [3:0] seg;
        reg [5:0] k;
        begin
            k = {c, seg};
            case (k)
                // γ0.7：base = [0,37,60,79,97,113,129,143,157,171,184,197,209,221,233,244]
                6'b01_0000: tbl_base = 8'd0;   6'b01_0001: tbl_base = 8'd37;  6'b01_0010: tbl_base = 8'd60;
                6'b01_0011: tbl_base = 8'd79;  6'b01_0100: tbl_base = 8'd97;  6'b01_0101: tbl_base = 8'd113;
                6'b01_0110: tbl_base = 8'd129; 6'b01_0111: tbl_base = 8'd143; 6'b01_1000: tbl_base = 8'd157;
                6'b01_1001: tbl_base = 8'd171; 6'b01_1010: tbl_base = 8'd184; 6'b01_1011: tbl_base = 8'd197;
                6'b01_1100: tbl_base = 8'd209; 6'b01_1101: tbl_base = 8'd221; 6'b01_1110: tbl_base = 8'd233;
                6'b01_1111: tbl_base = 8'd244;
                // S 曲线：base = [0,3,11,24,40,60,81,104,128,152,175,197,216,232,245,252]
                6'b10_0000: tbl_base = 8'd0;   6'b10_0001: tbl_base = 8'd3;   6'b10_0010: tbl_base = 8'd11;
                6'b10_0011: tbl_base = 8'd24;  6'b10_0100: tbl_base = 8'd40;  6'b10_0101: tbl_base = 8'd60;
                6'b10_0110: tbl_base = 8'd81;  6'b10_0111: tbl_base = 8'd104; 6'b10_1000: tbl_base = 8'd128;
                6'b10_1001: tbl_base = 8'd152; 6'b10_1010: tbl_base = 8'd175; 6'b10_1011: tbl_base = 8'd197;
                6'b10_1100: tbl_base = 8'd216; 6'b10_1101: tbl_base = 8'd232; 6'b10_1110: tbl_base = 8'd245;
                6'b10_1111: tbl_base = 8'd252;
                default:    tbl_base = {seg, 4'h0};       // 线性：base = seg*16
            endcase
        end
    endfunction

    function [7:0] tbl_delta;
        input [1:0] c;
        input [3:0] seg;
        reg [5:0] k;
        begin
            k = {c, seg};
            case (k)
                // γ0.7：delta = [37,23,19,18,16,16,14,14,14,13,13,12,12,12,11,11]
                6'b01_0000: tbl_delta = 8'd37;  6'b01_0001: tbl_delta = 8'd23;  6'b01_0010: tbl_delta = 8'd19;
                6'b01_0011: tbl_delta = 8'd18;  6'b01_0100: tbl_delta = 8'd16;  6'b01_0101: tbl_delta = 8'd16;
                6'b01_0110: tbl_delta = 8'd14;  6'b01_0111: tbl_delta = 8'd14;  6'b01_1000: tbl_delta = 8'd14;
                6'b01_1001: tbl_delta = 8'd13;  6'b01_1010: tbl_delta = 8'd13;  6'b01_1011: tbl_delta = 8'd12;
                6'b01_1100: tbl_delta = 8'd12;  6'b01_1101: tbl_delta = 8'd12;  6'b01_1110: tbl_delta = 8'd11;
                6'b01_1111: tbl_delta = 8'd11;
                // S 曲线：delta = [3,8,13,16,20,21,23,24,24,23,22,19,16,13,7,3]
                6'b10_0000: tbl_delta = 8'd3;   6'b10_0001: tbl_delta = 8'd8;   6'b10_0010: tbl_delta = 8'd13;
                6'b10_0011: tbl_delta = 8'd16;  6'b10_0100: tbl_delta = 8'd20;  6'b10_0101: tbl_delta = 8'd21;
                6'b10_0110: tbl_delta = 8'd23;  6'b10_0111: tbl_delta = 8'd24;  6'b10_1000: tbl_delta = 8'd24;
                6'b10_1001: tbl_delta = 8'd23;  6'b10_1010: tbl_delta = 8'd22;  6'b10_1011: tbl_delta = 8'd19;
                6'b10_1100: tbl_delta = 8'd16;  6'b10_1101: tbl_delta = 8'd13;  6'b10_1110: tbl_delta = 8'd7;
                6'b10_1111: tbl_delta = 8'd3;
                default:    tbl_delta = 8'd16;             // 线性：delta = 16
            endcase
        end
    endfunction

    // ---- 单通道曲线（组合）：旁路档逐位直通；非线性档查表 + 移位加法插值 ----
    function [7:0] curve1;
        input [7:0] y;
        input [1:0] c;
        reg [7:0] b, d;
        reg [11:0] s;
        begin
            if (c == 2'd0) begin
                curve1 = y;                                // 线性：逐位旁路（无表、无算术）
            end else begin
                b = tbl_base (c, y[7:4]);
                d = tbl_delta(c, y[7:4]);
                // delta*frac 的显式移位加法（frac = y[3:0]），避免综合出 DSP
                s = (y[3] ? {1'b0, d, 3'b000} : 12'd0)
                  + (y[2] ? {2'b0, d, 2'b00}  : 12'd0)
                  + (y[1] ? {3'b0, d, 1'b0}   : 12'd0)
                  + (y[0] ? {4'b0, d}         : 12'd0);
                curve1 = (y == 8'hff) ? 8'hff : b + ((s + 12'd8) >> 4);
            end
        end
    endfunction

    // ---- 4 像素并行 + 输出寄存（1 拍延迟，三档一致）----
    wire [7:0] y0 = I_tdata[23:16];   // 灰度模式下三通道相同，取 R 通道即可
    wire [7:0] y1 = I_tdata[47:40];
    wire [7:0] y2 = I_tdata[71:64];
    wire [7:0] y3 = I_tdata[95:88];
    wire [7:0] c0 = curve1(y0, I_curve);
    wire [7:0] c1 = curve1(y1, I_curve);
    wire [7:0] c2 = curve1(y2, I_curve);
    wire [7:0] c3 = curve1(y3, I_curve);

    generate if(!DETAIL_EN)begin:legacy_gray
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
                // ⚠ 关键：非灰度模式（或线性档）必须**逐位直通**——
                //    本级的曲线只对"灰度流（R=G=B=Y）"有意义；若在彩色流上做"取 R 复制三通道"，
                //    会把正常画面整体变成灰度（2026-10-09 实测事故：默认模式一直是黑白）。
                if (!I_gray_mode || I_curve == 2'd0)
                    O_tdata <= I_tdata;
                else if (I_curve == 2'd3)
                    O_tdata <= {{24{y3 > binary_threshold}}, {24{y2 > binary_threshold}},
                                {24{y1 > binary_threshold}}, {24{y0 > binary_threshold}}};
                else
                    O_tdata <= {c3,c3,c3, c2,c2,c2, c1,c1,c1, c0,c0,c0};
            end else begin
                O_tdata <= 96'd0;
            end
        end
    end

    end else begin:local_gray
        wire[95:0]normal_data=(!I_gray_mode||I_curve==0)?I_tdata:
            I_curve==3?{{24{y3>binary_threshold}},{24{y2>binary_threshold}},
                         {24{y1>binary_threshold}},{24{y0>binary_threshold}}}:
                         {c3,c3,c3,c2,c2,c2,c1,c1,c1,c0,c0,c0};
        wire dv,du,dl;wire[95:0]dd;
        binary_detail_rgb96 #(.W(IMG_WIDTH),.H(IMG_HEIGHT)) detail(
          .clk(I_clk),.rst_n(I_rst_n),.iv(I_tvalid),.iu(I_tuser),.il(I_tlast),
          .gray(I_gray_mode),.binary_mode(I_gray_mode&&I_curve==3),.rgb(I_tdata),.normal_data(normal_data),
          .ov(dv),.ou(du),.ol(dl),.od(dd));
        always @(posedge I_clk or negedge I_rst_n)
          if(!I_rst_n)begin O_tvalid<=0;O_tuser<=0;O_tlast<=0;O_tdata<=0;end
          else begin O_tvalid<=dv;O_tuser<=du;O_tlast<=dl;O_tdata<=dd;end
    end endgenerate
endmodule


// =============================================================================
// algo_btn_state.v —— 按键去抖 + 模式内状态机（边缘四态 / 灰度四档）
// -----------------------------------------------------------------------------
// 输入：I_button[3:0]（低有效；K1..K4 = [0]..[3]）、I_mode_edge / I_mode_gray（帧级锁存后的模式）
// 输出：O_edge_state[1:0]：0=原图 1=黑白轮廓 2=叠加 3=卡通化（K4）
//       O_gray_state[1:0]：0=线性 1=γ0.7 2=S 曲线 3=自适应二值化
// 约定（用户定义）：进模式默认"原图/线性"；离开该模式时状态归零；按键即时生效（单级 mux）。
// 机械按键：2FF 同步 + ~20ms 去抖（DEBOUNCE_MAX 参数化，默认 2_000_000 @100MHz，TB 可缩短）。
// 抽出为独立模块的原因：顶层内联状态机无法被 TB 覆盖，曾漏掉 K4 映射（上板"按 K4 没反应"）。
// =============================================================================
module algo_btn_state #(parameter [20:0] DEBOUNCE_MAX = 21'd2_000_000, parameter TWO_COLOR_TRACK=0, parameter KEY_LOCK_EN=0) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire [3:0]  I_button,
    input  wire        I_mode_edge,
    input  wire        I_mode_gray,
    input  wire        I_mode_track,      // 跟踪模式（仅 SW4 关）：K1 循环阈值组 0..7
    output reg  [1:0]  O_edge_state,
    output reg  [1:0]  O_gray_state,
    output reg  [2:0]  O_track_preset,
    output reg O_track_trail, O_track_axes, O_track_info,
    output reg O_inv_x, O_inv_y,           // 2026-10-21：跟踪模式 K3=翻转 X 闭环极性、K4=翻转 Y
    output wire [3:0] O_btn_stable,        // 2026-10-22：去抖后的按键电平（低有效），供手动云台使用
    input wire I_key_lock,
    input wire [1:0] I_display_curve
);
    reg [3:0]  btn_meta, btn_sync, btn_stable, btn_prev;
    reg [20:0] btn_cnt;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            btn_meta <= 4'hF; btn_sync <= 4'hF; btn_stable <= 4'hF; btn_prev <= 4'hF;
            O_track_trail<=0; O_track_axes<=1; O_track_info<=1;
            btn_cnt  <= 21'd0; O_edge_state <= 2'd0; O_gray_state <= 2'd0; O_track_preset <= 3'd0;
            O_inv_x  <= 1'b0; O_inv_y <= 1'b0;
        end else begin
            btn_meta <= I_button;
            btn_sync <= btn_meta;
            if (btn_sync == btn_stable)                btn_cnt <= 21'd0;
            else if (btn_cnt == DEBOUNCE_MAX) begin    btn_stable <= btn_sync; btn_cnt <= 21'd0; end
            else                                       btn_cnt <= btn_cnt + 21'd1;
            btn_prev <= btn_stable;

            if (KEY_LOCK_EN && I_key_lock) begin
                // Keep the visible curve, including entry between a key event
                // and its later frame-boundary commit.
                if(I_mode_gray)O_gray_state<=I_display_curve;
            end else begin
            // 边缘模式四态：K3=黑白轮廓、K2=叠加、K4=卡通化、K1=原图
            if (!I_mode_edge)                      O_edge_state <= 2'd0;
            else if (btn_prev[2] & ~btn_stable[2]) O_edge_state <= 2'd1;   // K3
            else if (btn_prev[1] & ~btn_stable[1]) O_edge_state <= 2'd2;   // K2
            else if (btn_prev[3] & ~btn_stable[3]) O_edge_state <= 2'd3;   // K4 -> 卡通化
            else if (btn_prev[0] & ~btn_stable[0]) O_edge_state <= 2'd0;   // K1

            // 灰度四档：K3=γ0.7、K2=S 曲线、K4=自适应二值化、K1=线性
            if (!I_mode_gray)                      O_gray_state <= 2'd0;
            else if (btn_prev[2] & ~btn_stable[2]) O_gray_state <= 2'd1;   // K3
            else if (btn_prev[1] & ~btn_stable[1]) O_gray_state <= 2'd2;   // K2
            else if (btn_prev[3] & ~btn_stable[3]) O_gray_state <= 2'd3;   // K4: adaptive binary
            else if (btn_prev[0] & ~btn_stable[0]) O_gray_state <= 2'd0;   // K1

            // 跟踪模式：K1 切换红/蓝阈值组、K2 开关轨迹、K3 开关坐标轴、K4 开关左上角信息
            // 2026-10-26：取消 K3/K4 的闭环极性翻转（误按会让云台躲着目标跑）；
            // 极性固定由 design_top_wrapper 的 SERVO_INVERT_X/Y 决定，O_inv_x/O_inv_y 恒为 0。
            if (!I_mode_track) begin
                O_track_preset<=0; O_track_trail<=0; O_track_axes<=1; O_track_info<=1;
            end else begin
                if(btn_prev[0] & ~btn_stable[0]) O_track_preset<=TWO_COLOR_TRACK ? ((O_track_preset==0)?3'd2:3'd0) : O_track_preset+3'd1;
                if(TWO_COLOR_TRACK)begin
                    if(btn_prev[1] & ~btn_stable[1])O_track_trail<=!O_track_trail;
                    if(btn_prev[2] & ~btn_stable[2])O_track_axes<=!O_track_axes;   // K3：坐标轴显示开关
                    if(btn_prev[3] & ~btn_stable[3])O_track_info<=!O_track_info;   // K4：左上角信息显示开关
                end
            end
            end
        end
    end

    assign O_btn_stable = btn_stable;
endmodule

// Full-frame global adaptive threshold. No frame/line RAM and no DSP.
// SOF is an independent pulse (AWB may assert it before the first valid word).
// A malformed/incomplete frame is discarded, never used to train the threshold.
// Statistics run in all gray curves. Candidate threshold is committed only at SOF.
module gray_frame_threshold #(
 parameter integer IMG_WIDTH=1280, IMG_HEIGHT=720
)(input wire clk,rst_n,sof,valid,eol,gray_mode,input wire [95:0] rgb,
 output wire [7:0] threshold);
 localparam integer COLS=IMG_WIDTH/4;
 localparam integer PIXELS=IMG_WIDTH*IMG_HEIGHT;
 localparam integer SW=$clog2(PIXELS*255+1);
 localparam integer CW=(COLS<2)?1:$clog2(COLS);
 localparam integer RH=(IMG_HEIGHT<2)?1:$clog2(IMG_HEIGHT);
 localparam integer DW=$clog2(PIXELS+1);
 localparam [DW:0] DENOM=PIXELS;
 reg collecting,history,pending,busy;
 reg [CW-1:0] col;
 reg [RH-1:0] row;
 reg [SW-1:0] total,numerator;
 reg [DW-1:0] remainder;
 reg [7:0] quotient,active,candidate;
 reg [$clog2(SW)-1:0] bitno;
 wire [9:0] beat_sum=({2'b0,rgb[95:88]}+{2'b0,rgb[71:64]})+
                      ({2'b0,rgb[47:40]}+{2'b0,rgb[23:16]});
 wire [CW-1:0] x=sof?{CW{1'b0}}:col;
 wire [RH-1:0] y=sof?{RH{1'b0}}:row;
 wire [SW-1:0] sum_next=(sof?{SW{1'b0}}:total)+beat_sum;
 wire [DW:0] trial={remainder,numerator[SW-1]};
 wire take=trial>=DENOM;
 wire [7:0] qnext={quotient[6:0],take};
 wire [7:0] limited=(qnext<16)?8'd16:(qnext>239)?8'd239:qnext;
 wire [7:0] distance=(limited>=active)?limited-active:active-limited;
 wire [8:0] rounded={1'b0,distance}+9'd2;
 wire [7:0] increment=rounded>>2;
 wire [7:0] smoothed=(distance<=2)?active:
                      (limited>active)?active+increment:active-increment;
 // Also use the committed threshold on the first word when SOF and valid coincide.
 assign threshold=(sof&&pending)?candidate:active;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   collecting<=0;history<=0;pending<=0;busy<=0;col<=0;row<=0;total<=0;
   numerator<=0;remainder<=0;quotient<=0;bitno<=0;active<=128;candidate<=128;
  end else if(!gray_mode)begin
   collecting<=0;history<=0;pending<=0;busy<=0;col<=0;row<=0;total<=0;
   numerator<=0;remainder<=0;quotient<=0;bitno<=0;active<=128;candidate<=128;
  end else begin
   if(sof)begin
    collecting<=1;col<=0;row<=0;total<=0;
    if(pending)begin active<=candidate;pending<=0;end
   end
   if(busy)begin
    numerator<=numerator<<1;quotient<=qnext;
    remainder<=take?(trial-DENOM):trial;
    if(bitno==SW-1)begin
     busy<=0;candidate<=history?smoothed:limited;history<=1;pending<=1;
    end else bitno<=bitno+1'b1;
   end
   if(valid&&(collecting||sof))begin
    // Exactly COLS valid words per row; valid bubbles do not advance position.
    if(eol!=(x==COLS-1))begin collecting<=0;total<=0;end
    else begin
     total<=sum_next;
     if(x==COLS-1)begin
      col<=0;
      if(y==IMG_HEIGHT-1)begin
       collecting<=0;
       // Normal frames are vastly longer than SW clocks. Never overwrite an
       // unfinished calculation if a corrupt source supplies frames too fast.
       if(!busy&&!pending)begin
        numerator<=sum_next;remainder<=0;quotient<=0;bitno<=0;busy<=1;
       end
      end else row<=y+1'b1;
     end else col<=x+1'b1;
    end
   end
  end
 end
endmodule


// Previous complete-frame32x16 means, bilinearly interpolated at tile centers.
// Only the threshold map is smoothed; original pixel luma is never blurred.
// Two2048x8 ping-pong maps: incomplete frames never become a valid map.
module binary_local_map #(parameter W=1280,H=720)(
 input wire clk,rst_n,sof,valid,eol,gray,input wire[95:0]rgb,
 output wire[7:0] mean_left,mean_right,output wire[4:0] fraction,
 output wire usable);
 localparam C=W/32,R=H/16;
 localparam IW=(C<2)?1:$clog2(C);
 reg[10:0]px;reg[9:0]py;
 wire[10:0]x=sof?0:px;wire[9:0]y=sof?0:py;
 wire line_start=valid&&x==0;
 wire shift_rows=line_start&&y>=24&&y[3:0]==8;
 reg capturing,complete,head_ready,map_valid,write_bank,read_bank;
 // Eight input beats form one32-pixel tile row. Accumulate those beats
 // locally; persist only the completed row sum in synchronous ERAM.
 // Prefetch the following column on the last beat, hiding RAM latency.
 reg[16:0] tile_acc;
 wire[16:0] stored_sum;
 reg[7:0] head0[0:C-1],head1[0:C-1],row0[0:C-1],row1[0:C-1],nextrow[0:C-1];
 // Two distributed scanline caches rotate roles instead of copying40
 // bytes in parallel at every line start. First row reads head0 directly.
 (* ram_style="distributed" *) reg[7:0]line_cache0[0:C-1],line_cache1[0:C-1];
 reg line_bank;
 wire[IW-1:0]column=x>>5;
 wire col_ok=(x<W);
 wire[9:0]beat_sum={2'b0,rgb[95:88]}+{2'b0,rgb[71:64]}+{2'b0,rgb[47:40]}+{2'b0,rgb[23:16]};
 wire tile_start=x[4:0]==0;
 wire tile_end=x[4:0]==28;
 wire[16:0]sum_base=tile_start?(y[3:0]==0?17'd0:stored_sum):tile_acc;
 wire[16:0]sum_new=sum_base+beat_sum;
 wire geometry_good=(eol==(x==W-4))&&col_ok&&y<H;
 wire sum_write=gray&&valid&&(capturing||sof)&&geometry_good&&tile_end;
 wire wr=sum_write&&y[3:0]==15;
 wire[IW-1:0]prefetch_col=tile_end?(column==C-1?{IW{1'b0}}:column+1'b1):column;
 wire[9:0]sum_wa=column,sum_ra=prefetch_col;
 binary_sum_ram sum_memory(clk,sum_write,sum_wa,sum_new,sum_ra,stored_sum);
 // Constant row stride is shift/add, preventing DSP inference for addresses.
 function[10:0]row_base;
 input[5:0]r;integer k;reg[10:0]acc;
 begin acc=0;for(k=0;k<6;k=k+1)if((C>>k)&1)acc=acc+({5'd0,r}<<k);row_base=acc;end
 endfunction
 wire[10:0]wa=row_base(y[9:4])+column;
 wire[7:0]wd=sum_new[16:9];
 wire next_map=gray&&complete&&head_ready;
 assign usable=gray&&(sof?next_map:map_valid)&&geometry_good;

 // One read per clock loads the next vertical row before it is needed16 lines later.
 reg pf_busy,rd_valid;reg[IW-1:0]pf_col,rd_col;reg[5:0]pf_row;
 wire rd=pf_busy&&map_valid&&!sof;
 wire[10:0]ra=row_base(pf_row)+pf_col;
 wire[7:0]q0,q1;wire[7:0]rq=read_bank?q1:q0;
 binary_mean_ram m0(clk,wr&&!write_bank,wa,wd,rd&&!read_bank,ra,q0);
 binary_mean_ram m1(clk,wr&& write_bank,wa,wd,rd&& read_bank,ra,q1);

 // Compute the next scanline's vertical interpolation sequentially.40 cycles
 // fit into320 valid clocks per production line, independent of blanking.
 reg calc_busy,calc_shift;reg[IW-1:0]calc_col;reg[3:0]calc_f;
 wire[9:0]next_y=y+1'b1;
 wire[7:0]calc_a=calc_shift?row1[calc_col]:row0[calc_col];
 wire[7:0]calc_b=calc_shift?nextrow[calc_col]:row1[calc_col];
 function[7:0]vertical;
 input[7:0]a,b;input[3:0]f;reg[12:0]u,v;reg[4:0]inv;
 begin
  inv=16-{1'b0,f};
  u=(inv[4]?{a,4'd0}:13'd0)+(inv[3]?{1'b0,a,3'd0}:13'd0)+
    (inv[2]?{2'd0,a,2'd0}:13'd0)+(inv[1]?{3'd0,a,1'b0}:13'd0)+(inv[0]?{4'd0,a}:13'd0);
  v=(f[3]?{1'b0,b,3'd0}:13'd0)+(f[2]?{2'd0,b,2'd0}:13'd0)+
    (f[1]?{3'd0,b,1'b0}:13'd0)+(f[0]?{4'd0,b}:13'd0);
  vertical=(u+v+13'd8)>>4;
 end endfunction
 // Read mux, interpolation arithmetic and distributed cache write are separate
 // stages. C+3 clocks per scanline fit even W=32 (8 valid input clocks).
 reg cv1,cv2;reg[IW-1:0]cc1,cc2;reg[7:0]ca1,cb1,cm2;reg[3:0]cf1;
 integer j;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   px<=0;py<=0;capturing<=0;complete<=0;head_ready<=0;map_valid<=0;write_bank<=0;read_bank<=1;line_bank<=0;
   pf_busy<=0;rd_valid<=0;pf_col<=0;rd_col<=0;pf_row<=0;
   calc_busy<=0;calc_shift<=0;calc_col<=0;calc_f<=0;cv1<=0;cv2<=0;cc1<=0;cc2<=0;ca1<=0;cb1<=0;cm2<=0;cf1<=0;
  end else if(!gray)begin
   px<=0;py<=0;capturing<=0;complete<=0;head_ready<=0;map_valid<=0;
   pf_busy<=0;rd_valid<=0;calc_busy<=0;cv1<=0;cv2<=0;
  end else begin
   rd_valid<=rd;if(rd)rd_col<=pf_col;
   if(rd_valid)nextrow[rd_col]<=rq;
   if(rd)begin if(pf_col==C-1)pf_busy<=0;else pf_col<=pf_col+1'b1;end
   cv1<=calc_busy;cv2<=cv1;
   if(cv1)begin cm2<=vertical(ca1,cb1,cf1);cc2<=cc1;end
   if(cv2)begin
    if(line_bank)line_cache0[cc2]<=cm2;else line_cache1[cc2]<=cm2;
   end
   if(calc_busy)begin
    ca1<=calc_a;cb1<=calc_b;cf1<=calc_f;cc1<=calc_col;
    if(calc_col==C-1)calc_busy<=0;else calc_col<=calc_col+1'b1;
   end
   if(sof)begin
    px<=0;py<=0;capturing<=1;complete<=0;head_ready<=0;
    map_valid<=next_map;read_bank<=write_bank;write_bank<=!write_bank;line_bank<=0;
    pf_busy<=next_map;pf_col<=0;pf_row<=R>2?2:R-1;rd_valid<=0;calc_busy<=0;cv1<=0;cv2<=0;
    for(j=0;j<C;j=j+1)begin
     row0[j]<=head0[j];row1[j]<=head1[j];
    end
   end
   if(line_start&&!sof&&map_valid)begin
    if(y!=0)line_bank<=!line_bank;
    if(shift_rows)begin
     for(j=0;j<C;j=j+1)begin row0[j]<=row1[j];row1[j]<=nextrow[j];end
     pf_busy<=1;pf_col<=0;pf_row<=pf_row<R-1?pf_row+1'b1:R-1;
    end
   end
   if(line_start&&(sof?next_map:map_valid))begin
    calc_busy<=1;calc_col<=0;
    calc_shift<=next_y>=24&&next_y[3:0]==8;
    calc_f<=next_y<8||next_y>=(R-1)*16+8?0:(next_y-8)&15;
   end
   if(valid)begin
    if(eol)begin px<=0;py<=y+1'b1;end else begin px<=x+4;py<=y;end
    if((capturing||sof)&&geometry_good)begin
     tile_acc<=sum_new;
     if(wr)begin
      if((y>>4)==0)begin head0[column]<=wd;if(R==1)head1[column]<=wd;end
      if((y>>4)==1)head1[column]<=wd;
      if(((y>>4)==(R>1?1:0))&&column==C-1)head_ready<=1;
     end
     if(eol&&y==H-1)begin capturing<=0;complete<=1;end
    end else begin capturing<=0;complete<=0;map_valid<=0;end
   end
  end
 end
 wire[IW-1:0]lc=x<16?0:x>=(C-1)*32+16?C-1:(x-16)>>5;
 wire[IW-1:0]rc=(x<16||x>=(C-1)*32+16)?lc:lc+1'b1;
 assign fraction=(x<16||x>=(C-1)*32+16)?0:(x-16)&31;
 wire current_line_bank=(line_start&&y!=0)?!line_bank:line_bank;
 assign mean_left=(sof||y==0)?head0[lc]:(current_line_bank?line_cache1[lc]:line_cache0[lc]);
 assign mean_right=(sof||y==0)?head0[rc]:(current_line_bank?line_cache1[rc]:line_cache0[rc]);
`ifdef BINARY_DETAIL_SIM
 initial if(W%32||H%16||C*R>2048||W<32||H<16)$fatal(1,"LOCAL_MAP_GEOMETRY");
`endif
endmodule


// 40x17 production sums use one18-bit ERAM rather than an asynchronous
// register-file read mux. Explicit forwarding makes C=1 read/write overlap
// deterministic and independent of primitive collision output behavior.
module binary_sum_ram(input wire clk,we,input wire[9:0]wa,input wire[16:0]wd,
 input wire[9:0]ra,output wire[16:0]q);
 wire[17:0]raw_q;
 reg same_address;reg[16:0]forward_data;
 always @(posedge clk)begin
  same_address<=we&&(wa==ra);
  if(we)forward_data<=wd;
 end
 assign q=same_address?forward_data:raw_q[16:0];
`ifdef BINARY_DETAIL_SIM
 reg[17:0]mem[0:1023];reg[17:0]qr;
 always @(posedge clk)begin if(we)mem[wa]<={1'b0,wd};qr<=mem[ra];end
 assign raw_q=qr;
`else
 PH1P_LOGIC_ERAM #(.DATA_WIDTH_A(18),.DATA_WIDTH_B(18),.ADDR_WIDTH_A(10),.ADDR_WIDTH_B(10),
 .DATA_DEPTH_A(1024),.DATA_DEPTH_B(1024),.MODE("DP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
 .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.IMPLEMENT("20K(FAST)"),.ECC_ENCODE("DISABLE"),.ECC_DECODE("DISABLE"),
 .CLKMODE("SYNC"),.SSROVERCE("DISABLE"),.OREGSET_A("RESET"),.OREGSET_B("RESET"),.RESETMODE_A("ASYNC"),.RESETMODE_B("ASYNC"),
 .ASYNC_RESET_RELEASE_A("ASYNC"),.ASYNC_RESET_RELEASE_B("ASYNC")) memory(
 .dia({1'b0,wd}),.dib(18'd0),.addra(wa),.addrb(ra),.clka(clk),.clkb(clk),.cea(we),.ceb(1'b1),.ocea(1'b1),.oceb(1'b1),
 .wea(we),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(),.dob(raw_q),
 .ecc_sbiterr(),.ecc_dbiterr(),.ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0));
`endif
endmodule

module binary_mean_ram(input wire clk,we,input wire[10:0]wa,input wire[7:0]wd,
 input wire re,input wire[10:0]ra,output wire[7:0]q);
`ifdef BINARY_DETAIL_SIM
 reg[7:0]mem[0:2047];reg[7:0]qr;
 always @(posedge clk)begin if(we)mem[wa]<=wd;if(re)qr<=mem[ra];end
 assign q=qr;
`else
 PH1P_LOGIC_ERAM #(.DATA_WIDTH_A(8),.DATA_WIDTH_B(8),.ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),
 .DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),.MODE("DP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
 .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.IMPLEMENT("20K(FAST)"),.ECC_ENCODE("DISABLE"),.ECC_DECODE("DISABLE"),
 .CLKMODE("SYNC"),.SSROVERCE("DISABLE"),.OREGSET_A("RESET"),.OREGSET_B("RESET"),.RESETMODE_A("ASYNC"),.RESETMODE_B("ASYNC"),
 .ASYNC_RESET_RELEASE_A("ASYNC"),.ASYNC_RESET_RELEASE_B("ASYNC")) memory(
 .dia(wd),.dib(8'd0),.addra(wa),.addrb(ra),.clka(clk),.clkb(clk),.cea(we),.ceb(re),.ocea(1'b1),.oceb(1'b1),
 .wea(we),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(),.dob(q),
 .ecc_sbiterr(),.ecc_dbiterr(),.ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0));
`endif
endmodule

// Two registered stages; parent adds the final output stage (three total).
module binary_detail_rgb96 #(parameter W=1280,H=720,OFFSET=4)(
 input wire clk,rst_n,iv,iu,il,gray,binary_mode,input wire[95:0]rgb,normal_data,
 output reg ov,ou,ol,output reg[95:0]od);
 wire[7:0]ml,mr;wire[4:0]frac;wire local_ready;
 binary_local_map #(.W(W),.H(H)) map(clk,rst_n,iu,iv,il,gray,rgb,ml,mr,frac,local_ready);
 reg v0,u0,l0,use0;reg[7:0]a0,b0;reg[4:0]f0;reg[95:0]raw0,normal0;
 function[7:0]threshold;
 input[7:0]a,b;input[4:0]f;reg signed[8:0]delta;
 reg signed[14:0]d,lo,hi,last,base,s;reg[7:0]m;
 begin
  delta=$signed({1'b0,b})-$signed({1'b0,a});d={{6{delta[8]}},delta};
  // The low five bits of a*32 are zero. Insert rounding16 directly,
  // then balance the partial sums rather than chaining seven additions.
  base=$signed({2'd0,a,5'b10000});
  lo=(f[0]?d:15'sd0)+(f[1]?(d<<<1):15'sd0);
  hi=(f[2]?(d<<<2):15'sd0)+(f[3]?(d<<<3):15'sd0);
  last=f[4]?(d<<<4):15'sd0;
  s=(base+lo)+(hi+last);
  m=s>>>5;threshold=m<OFFSET+4?8'd4:m-OFFSET;
 end endfunction
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin v0<=0;u0<=0;l0<=0;use0<=0;a0<=0;b0<=0;f0<=0;raw0<=0;normal0<=0;ov<=0;ou<=0;ol<=0;od<=0;end
  else begin
   v0<=iv;u0<=iu;l0<=il;use0<=binary_mode&&local_ready;a0<=ml;b0<=mr;f0<=frac;raw0<=rgb;normal0<=normal_data;
   ov<=v0;ou<=u0;ol<=l0;
   if(!v0)od<=0;
   else if(use0)od<={{24{raw0[95:88]>threshold(a0,b0,f0)}},{24{raw0[71:64]>threshold(a0,b0,f0+5'd1)}},
                    {24{raw0[47:40]>threshold(a0,b0,f0+5'd2)}},{24{raw0[23:16]>threshold(a0,b0,f0+5'd3)}}};
   else od<=normal0;
  end
 end
endmodule

// SW1 manual takeover. Inputs use the camera/ISP clock; SW1 is already2FF
// synchronized by top. Freeze immediately on OFF, release only after stable
// ON. Keep UI keys locked until both raw and debounced keys have released.
module view_manual_gate #(parameter SW_ON_CYCLES=1000000,KEY_RELEASE_CYCLES=2000004)(
 input wire clk,rst_n,inputs_ready,sw1,input wire[3:0]raw_buttons,stable_buttons,
 output wire display_hold,manual,output wire key_lock,output wire[3:0]manual_buttons);
 localparam SWW=SW_ON_CYCLES<2?1:$clog2(SW_ON_CYCLES);
 localparam KWW=KEY_RELEASE_CYCLES<2?1:$clog2(KEY_RELEASE_CYCLES);
 reg held,guard,manual_armed;reg[SWW-1:0]on_count;reg[KWW-1:0]release_count;
 (* async_reg="true" *)reg[3:0]raw_meta,raw_sync;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin raw_meta<=4'hf;raw_sync<=4'hf;end
  else begin raw_meta<=raw_buttons;raw_sync<=raw_meta;end
 end
 assign display_hold=inputs_ready&&(!sw1||held);
 assign manual=display_hold;
 assign key_lock=display_hold||guard;
 assign manual_buttons=manual_armed?stable_buttons:4'hf;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin held<=0;on_count<=0;guard<=0;release_count<=0;manual_armed<=0;end
  else if(!inputs_ready)begin held<=0;on_count<=0;guard<=0;release_count<=0;manual_armed<=0;end
  else begin
   if(!display_hold)manual_armed<=0;
   else if(raw_sync==4'hf&&stable_buttons==4'hf)manual_armed<=1;
   if(!sw1)begin held<=1;on_count<=0;end
   else if(held)begin
    if(on_count==SW_ON_CYCLES-1)begin held<=0;on_count<=0;end
    else on_count<=on_count+1'b1;
   end else on_count<=0;
   if(display_hold)begin guard<=1;release_count<=0;end
   else if(guard)begin
    if(raw_sync!=4'hf||stable_buttons!=4'hf)release_count<=0;
    else if(release_count==KEY_RELEASE_CYCLES-1)begin guard<=0;release_count<=0;end
    else release_count<=release_count+1'b1;
   end else release_count<=0;
  end
 end
endmodule
