// =============================================================================
// vision_track.v —— 识别跟踪分支（移植自 D:/fpga-ptz-tracker 视觉软件包，2026-10-11）
// -----------------------------------------------------------------------------
// 内容：
//   检测链：ser96to24 -> rgb2hsv(+hsv_inv_lut) -> hsv_threshold -> bin_smooth3x3 -> centroid_accum
//   包装：  detect_top（96bit 纯窃流旁路，O_tready 恒 1，不反压、不改像素）
//   OSD：   osd_track（内含 cdc_4phase 跨域 + font_rom_8x16 x2 + marquee_rom_64）
//   可选：  motion_detect（由 detect_top 的 MOTION_EN 门控，默认 0 = 不例化）
//   新增：  led_indicator（F4 四灯语义）、vpix_de_vsync（显示域时序适配）
// -----------------------------------------------------------------------------
// 移植来源 SHA256 见各模块头；v15 的本地修复有【SC520 本工程改动】标注。原移植阶段仅 detect_top 增加
// MOTION_EN 参数（省约 57 块 ERAM）。改动处均有【SC520 本工程改动】标注。
// 来源工程：D:/fpga-ptz-tracker（视觉软件包，仿真级成熟）；接口契约 06_interfaces/current。
// =============================================================================
// ===== [移植] ser96to24.v —— 逐字复制，来源 08_board_bringup/02_td_synth_gate/ser96to24.v，SHA256 086aa49c5b0e2688 =====
// =============================================================================
// ser96to24.v —— 96bit(4像素/拍) AXI4-S -> 1 像素/拍 vpix 串化器（v4，弹性缓冲重写）
// -----------------------------------------------------------------------------
// 视觉检测链入口适配层。挂在官方 ISP 的 AWB 96bit 输出上（4 像素 RGB888 打包，
// tuser=帧首、tlast=行尾，两者均在有效拍上；见 system_top 的抽头与迭代记录 #N+6）。
//
// v4 重写缘由（2026-10-03 架构级复审后实测坐实）：
//   官方 ISP 的 AWB 输出为"行级突发"：每行 320 连续 beat（=1280px @4px/拍），
//   行间有消隐间隔（实测 2160 段=3 帧×720 行，长度全部精确 320，无合并、无丢行）。
//   v3 的 128 像素缓冲（合 32 beat）净缺 3px/拍、连续 42 拍即溢出；且满缓冲后
//   SOF 无法入队导致 resync 不可恢复——与 system_top 同接法的实测输出仅
//   188/2764800 像素、零 SOF/EOL（功能性全灭）。
// v4 选型（数据驱动）：
//   缓冲深度 = 2048 像素（512 beat）：覆盖实测最坏 320-beat 行突发的峰值缺口
//     （320×(4-1)=960px）两倍余量；平均输入率 <1px/拍 时长期不增长。
//   读出改"寄存器读"（输出相对输入 +1 拍）：同时兼容 LUTRAM / ERAM 两种映射，
//     消除"组合读被综合成同步 RAM 会整帧错行"的实现依赖风险（复审 Gate 2 根治）。
//
// 语义：
//   O_sof=帧首像素；O_eol=行尾像素；O_valid=数据有效（滞后 I_tvalid 1 拍）。
//   无反压（O_tready 恒 1，窃流语义）；溢出丢弃 + 帧级重同步（SOF 能入队才解除，
//   损害限定当前帧）；O_drop_cnt 计数（饱和）。
//
// v4.1 加固（2026-10-03 第 7 轮外部复审，[中] 异常恢复缺口）：
//   原语义下 resync 只由"真实 tuser 入队"解除——若 tuser 永久缺失（帧同步契约被破坏），
//   模块将进入永久丢弃态（O_valid 恒 0、drop 饱和）。v4.1 增加：
//   1) 帧同步看门狗：resync 期间计 valid beat，超过 SYNC_TIMEOUT（默认 2 帧预算）
//      仍未等到真实 tuser → 置 O_sync_err（粘滞至下一次真实 tuser 入队）；
//   2) tlast 门控受控恢复：超时后，下一个 tlast 拍被当作"合成 SOF"入队并解除 resync
//      （tlast 是真实行边界标记，恢复后帧相位可能偏移若干行——对 SOF 复位的下游
//      无害；若 tlast 也缺失则保持丢弃等复位，不猜 SOF）；
//   3) 观测量：O_occ_max（缓冲最大占用水位，ChipWatcher/维修诊断用）。
// =============================================================================
module ser96to24 #(
    parameter [23:0] SYNC_TIMEOUT = 24'd460800   // resync 看门狗阈值（beat；默认 2 帧）
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    // 96bit AXI4-Stream 视频输入（仅有效像素拍）
    input  wire [95:0] I_tdata,
    input  wire        I_tvalid,
    input  wire        I_tuser,
    input  wire        I_tlast,
    output wire        O_tready,
    // 1 像素/拍 vpix 输出（相对输入滞后 1 拍）
    output reg         O_valid,
    output reg         O_sof,
    output reg         O_eol,
    output reg  [23:0] O_data,
    // 调试：因缓冲满被拒的 beat 计数（饱和）
    output reg  [15:0] O_drop_cnt,
    // 调试：帧同步错误（看门狗触发；下一次真实 tuser 入队时清除）
    output reg         O_sync_err,
    // 调试：缓冲最大占用水位（像素）
    output reg  [11:0] O_occ_max
);

    localparam DEPTH = 2048;   // 像素缓冲深度（=512 beat；实测行突发 320 beat 的 2 倍余量）
    localparam PW    = 11;     // 指针位宽（DEPTH = 2^PW）
    localparam CW    = 12;     // 计数位宽（0..DEPTH）

    assign O_tready = 1'b1;    // 窃流分支，绝不反压上游

    // 像素缓冲（数据+标志同址）
    // 【SC520 本工程改动 v15】4 路单写 RAM，避免同一数组多写地址的器件映射歧义。
    // 写指针每次 +4，低两位恒零；SOF/EOL 与对应 lane 像素同存。
    (* ram_style = "block" *) reg [24:0] bank0 [0:DEPTH/4-1];
    (* ram_style = "block" *) reg [23:0] bank1 [0:DEPTH/4-1];
    (* ram_style = "block" *) reg [23:0] bank2 [0:DEPTH/4-1];
    (* ram_style = "block" *) reg [24:0] bank3 [0:DEPTH/4-1];
    reg [PW-1:0] wp;           // 写指针
    reg [PW-1:0] rp;           // 读指针
    reg [CW-1:0] cnt;          // 缓冲像素数（0..DEPTH）

    wire [PW-1:0] wp_n  = wp + 11'd1;
    wire [PW-1:0] wp_n2 = wp + 11'd2;
    wire [PW-1:0] wp_n3 = wp + 11'd3;
    wire [PW-1:0] rp_n  = rp + 11'd1;

    wire [23:0] p0 = I_tdata[95:72];
    wire [23:0] p1 = I_tdata[71:48];
    wire [23:0] p2 = I_tdata[47:24];
    wire [23:0] p3 = I_tdata[23:0];

    wire can_wr = (cnt <= (DEPTH - 4));

    // 满载丢弃后帧级重同步（v3 语义）+ v4.1 看门狗/受控恢复
    reg  resync;
    reg  [23:0] sync_cnt;      // resync 期间的 valid beat 计数（看门狗计时）
    wire sync_timeout = (sync_cnt >= SYNC_TIMEOUT);
    // 可入队的"帧首"：真实 tuser，或（超时后）tlast 门控的合成帧首
    wire wr_as_sof = I_tuser | (resync & sync_timeout & I_tlast);

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)
            resync <= 1'b0;
        else if (I_tvalid && wr_as_sof && can_wr)
            resync <= 1'b0;                       // 仅当帧首拍真正能入队才解除
        else if (I_tvalid && !can_wr)
            resync <= 1'b1;
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)
            sync_cnt <= 24'd0;
        else if (!resync)
            sync_cnt <= 24'd0;
        else if (I_tvalid && (sync_cnt < SYNC_TIMEOUT))
            sync_cnt <= sync_cnt + 24'd1;
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)
            O_sync_err <= 1'b0;
        else if (I_tvalid && I_tuser && can_wr)
            O_sync_err <= 1'b0;                   // 真实帧首恢复 -> 清错误
        else if (resync && sync_timeout)
            O_sync_err <= 1'b1;                   // 看门狗触发（粘滞）
    end

    wire do_wr = I_tvalid & O_tready & can_wr & (~resync | wr_as_sof);
    wire do_rd = (cnt != {CW{1'b0}});

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            wp  <= {PW{1'b0}};
            rp  <= {PW{1'b0}};
            cnt <= {CW{1'b0}};
            O_valid <= 1'b0;
            O_sof   <= 1'b0;
            O_eol   <= 1'b0;
            O_data  <= 24'd0;
            O_drop_cnt <= 16'd0;
            O_occ_max  <= 12'd0;
        end else begin
            // 写口：4 像素入队（分辨率宽为 4 的倍数，末拍必满 4 像素）
            if (do_wr) begin
                bank0[wp[PW-1:2]] <= {wr_as_sof, p0};
                bank1[wp[PW-1:2]] <= p1;
                bank2[wp[PW-1:2]] <= p2;
                bank3[wp[PW-1:2]] <= {I_tlast, p3};
                wp <= wp + 11'd4;
            end
            // 读口：寄存器读（rp 当拍指向的像素在下一拍出现在输出寄存器上）
            case (rp[1:0])
                2'd0: O_data <= bank0[rp[PW-1:2]][23:0];
                2'd1: O_data <= bank1[rp[PW-1:2]];
                2'd2: O_data <= bank2[rp[PW-1:2]];
                2'd3: O_data <= bank3[rp[PW-1:2]][23:0];
            endcase
            O_sof <= (rp[1:0] == 2'd0) && bank0[rp[PW-1:2]][24];
            O_eol <= (rp[1:0] == 2'd3) && bank3[rp[PW-1:2]][24];
            O_valid <= do_rd;
            if (do_rd)
                rp <= rp_n;
            // 缓冲像素数 + 最大占用水位（诊断）
            case ({do_wr, do_rd})
                2'b10:   cnt <= cnt + 12'd4;
                2'b01:   cnt <= cnt - 12'd1;
                2'b11:   cnt <= cnt + 12'd3;
                default: cnt <= cnt;
            endcase
            if (cnt > O_occ_max)
                O_occ_max <= cnt;                   // 占用水位单调记录（复位清零）
            if (I_tvalid && !do_wr && (O_drop_cnt != 16'hFFFF))
                O_drop_cnt <= O_drop_cnt + 16'd1;   // 缓冲满导致的丢弃（饱和计数）
        end
    end

    // synthesis translate_off
    reg drop_dbg_seen;
    always @(posedge I_clk) begin
        if (!I_rst_n) drop_dbg_seen <= 1'b0;
        else if ((cnt > (DEPTH - 4)) && I_tvalid && !drop_dbg_seen) begin
            drop_dbg_seen <= 1'b1;
            $display("SER96TO24_DROP_FIRST: buffer full cnt=%0d t=%0t", cnt, $time);
        end
    end
    // synthesis translate_on

endmodule

// ===== [移植] pulse_sync.v —— 逐字复制，来源 03_vision/step1_video_link/03_project/rtl/pulse_sync.v，SHA256 9d6f6b9fd5c70e6d =====
// =============================================================================
// pulse_sync.v —— 单 bit 脉冲跨时钟域（toggle 同步器）
// -----------------------------------------------------------------------------
// 源域脉冲 -> 目标域固定 1 拍脉冲（外脑评审措辞修正：与源脉冲宽度无关）。用于 frame_tick（检测域 -> 云台/PWM 域）。
// 约束：源脉冲间隔 > 目标域 3 个时钟周期（帧级脉冲天然满足）。
// =============================================================================
module pulse_sync (
    input  wire I_clk_src,
    input  wire I_rst_src_n,
    input  wire I_pulse_src,
    input  wire I_clk_dst,
    input  wire I_rst_dst_n,
    output wire O_pulse_dst
);

    reg toggle_src;
    always @(posedge I_clk_src or negedge I_rst_src_n) begin
        if (!I_rst_src_n)
            toggle_src <= 1'b0;
        else if (I_pulse_src)
            toggle_src <= ~toggle_src;
    end

    reg [2:0] sync_dst;
    always @(posedge I_clk_dst or negedge I_rst_dst_n) begin
        if (!I_rst_dst_n)
            sync_dst <= 3'b000;
        else
            sync_dst <= {sync_dst[1:0], toggle_src};
    end

    assign O_pulse_dst = sync_dst[1] ^ sync_dst[2];

endmodule

// ===== [移植] cdc_4phase.v —— 逐字复制，来源 03_vision/step1_video_link/03_project/rtl/cdc_4phase.v，SHA256 9e9d7579bf19b9af =====
// =============================================================================
// cdc_4phase.v —— N bit 数据跨时钟域（4 相握手，电平比较式）
// -----------------------------------------------------------------------------
// 用途：检测域 -> OSD/控制域 的目标坐标/状态传递（每帧一次，低速）。
// 协议：req/ack 为电平（翻转式）握手。源域 load 时锁存数据并翻转 req；
// 目标域发现 req != ack（2FF 同步后）即锁存数据、翻转 ack、给出 1 拍
// O_dst_valid；源域发现 ack_2ff == req（对端已应答）即解除 busy。
// 数据在 req 翻转前即稳定，且整个握手期间保持不变——跨域采样安全。
//
// 【复位契约（三版外部评审共识，务必遵守）】
//   两侧复位必须**同源**（同一板级复位网络）：允许存在释放时刻的域间偏斜
//   （vision_top 内已用各域同步释放 + tb_cdc_reset_skew 固化验证），
//   但**禁止运行时单独复位其中一侧**——单侧复位会使 req/ack 失配，
//   产生一次伪 O_dst_valid（重复消费上一包）。若未来确需独立复位，
//   必须在此模块内增加 epoch/re-arm 协议。
// =============================================================================
module cdc_4phase #(
    parameter WIDTH = 67
)(
    // 源域
    input  wire             I_clk_src,
    input  wire             I_rst_src_n,
    input  wire [WIDTH-1:0] I_src_data,
    input  wire             I_src_load,
    output wire             O_src_busy,
    // 目标域
    input  wire             I_clk_dst,
    input  wire             I_rst_dst_n,
    output reg  [WIDTH-1:0] O_dst_data,
    output reg              O_dst_valid
);

    reg ack_dst;    // 目标域应答电平（跨域线，前向声明）

    // ---------------- 源域 ----------------
    reg [WIDTH-1:0] data_hold;
    reg             req;
    reg             busy;
    reg             ack_meta, ack_2ff;

    always @(posedge I_clk_src or negedge I_rst_src_n) begin
        if (!I_rst_src_n) begin
            data_hold <= {WIDTH{1'b0}};
            req       <= 1'b0;
            busy      <= 1'b0;
            ack_meta  <= 1'b0;
            ack_2ff   <= 1'b0;
        end else begin
            ack_meta <= ack_dst;
            ack_2ff  <= ack_meta;
            if (!busy) begin
                if (I_src_load) begin
                    data_hold <= I_src_data;
                    req       <= ~req;
                    busy      <= 1'b1;
                end
            end else if (ack_2ff == req) begin
                busy <= 1'b0;            // 对端已确认（ack 已翻到 req 新值）
            end
        end
    end

    assign O_src_busy = busy;

    // ---------------- 目标域 ----------------
    reg req_meta, req_2ff;

    always @(posedge I_clk_dst or negedge I_rst_dst_n) begin
        if (!I_rst_dst_n) begin
            req_meta    <= 1'b0;
            req_2ff     <= 1'b0;
            ack_dst     <= 1'b0;
            O_dst_data  <= {WIDTH{1'b0}};
            O_dst_valid <= 1'b0;
        end else begin
            req_meta <= req;
            req_2ff  <= req_meta;
            O_dst_valid <= 1'b0;
            if (req_2ff != ack_dst) begin
                O_dst_data  <= data_hold;   // req 变化时数据早已稳定
                ack_dst     <= ~ack_dst;    // 翻到与 req 一致
                O_dst_valid <= 1'b1;
            end
        end
    end

endmodule

// ===== [移植] rgb2hsv.v —— 逐字复制，来源 03_vision/step2_color_centroid/03_project/rtl/rgb2hsv.v，SHA256 f73d47303318a1cc =====
// =============================================================================
// rgb2hsv.v —— RGB888 -> HSV 色彩空间转换（2 级流水，1 像素/拍）
// -----------------------------------------------------------------------------
// 定点算术与 tools/golden_model.py::rgb_to_hsv 逐位一致（见文件头注释）：
//   V = max(R,G,B); S = max-min（未归一化饱和度代理）
//   inv[d] = floor(3840/d) 查表；h = (差值*inv)>>>6 后截断到 [0,60]
//   3 扇区优先级 R>G>B；delta==0 时 H=0。
// 已知特性：H 仅落在 {0..60, 120..180, 240..300}（详见 01_方案对比）。
// 资源：256x12 ROM + 1 个 9x13 有符号乘法（可综合到 DSP/逻辑）。
// =============================================================================
module rgb2hsv #(parameter FULL_HUE=0) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_valid,
    input  wire        I_sof,
    input  wire        I_eol,
    input  wire [23:0] I_data,      // {R[7:0], G[7:0], B[7:0]}
    output reg         O_valid,
    output reg         O_sof,
    output reg         O_eol,
    output reg  [8:0]  O_h,         // 0..359
    output reg  [7:0]  O_s,         // = delta
    output reg  [7:0]  O_v          // = max
);

    // ---------------- 第 0 拍：max/min/差值 ----------------
    wire [7:0] r = I_data[23:16];
    wire [7:0] g = I_data[15:8];
    wire [7:0] b = I_data[7:0];

    wire [7:0] rg_max = (r > g) ? r : g;
    wire [7:0] mx     = (rg_max > b) ? rg_max : b;
    wire [7:0] rg_min = (r < g) ? r : g;
    wire [7:0] mn     = (rg_min < b) ? rg_min : b;
    wire [7:0] d      = mx - mn;

    wire is_r = (r >= g) && (r >= b);
    wire is_g = ~is_r && (g >= r) && (g >= b);

    reg signed [8:0] diff_r;     // 扇区所需差值
    always @(*) begin
        if (is_r)      diff_r = $signed({1'b0, g}) - $signed({1'b0, b}); // G-B
        else if (is_g) diff_r = $signed({1'b0, b}) - $signed({1'b0, r}); // B-R
        else           diff_r = $signed({1'b0, r}) - $signed({1'b0, g}); // R-G
    end

    reg [7:0] d_r;
    reg       isg_r, isb_r;
    reg signed [8:0] diff_r1;
    reg [7:0] v_r, s_r;
    reg       valid_r, sof_r, eol_r;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            d_r <= 8'd0; isg_r <= 1'b0; isb_r <= 1'b0; diff_r1 <= 9'sd0;
            v_r <= 8'd0; s_r <= 8'd0;
            valid_r <= 1'b0; sof_r <= 1'b0; eol_r <= 1'b0;
        end else begin
            d_r     <= d;
            isg_r   <= is_g;
            isb_r   <= ~is_r && ~is_g;
            diff_r1 <= diff_r;
            v_r     <= mx;
            s_r     <= d;
            valid_r <= I_valid;
            sof_r   <= I_sof;
            eol_r   <= I_eol;
        end
    end

    // ---------------- 第 1 拍：倒数查表 + 乘法 + 扇区 ----------------
    wire [11:0] inv;
    hsv_inv_lut u_inv (.I_d(d_r), .O_inv(inv));

    wire signed [12:0] inv_s  = {1'b0, inv};                    // 0..3840
    wire signed [21:0] prod   = diff_r1 * inv_s;                // 有符号乘
    wire signed [21:0] h_raw  = prod >>> 6;                     // floor
    wire signed [6:0]  h_clip = (h_raw < 0)   ? 7'sd0 :
                                (h_raw > 60)  ? 7'sd60 :
                                                h_raw[6:0];
    wire [8:0] h_sec = isg_r ? (9'd120 + {2'b0, h_clip}) :
                       isb_r ? (9'd240 + {2'b0, h_clip}) :
                               ({3'b0, h_clip});
    // v17: preserve signed sector offsets; negative red sector wraps through 360.
    wire signed [9:0] hue_signed=(isg_r?10'sd120:isb_r?10'sd240:10'sd0)+$signed(h_raw[9:0]);
    wire [8:0] hue_full=hue_signed<0?hue_signed+10'sd360:hue_signed[8:0];
    wire [8:0] h_fin = (d_r == 8'd0) ? 9'd0 : FULL_HUE?hue_full:h_sec;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_valid <= 1'b0; O_sof <= 1'b0; O_eol <= 1'b0;
            O_h <= 9'd0; O_s <= 8'd0; O_v <= 8'd0;
        end else begin
            O_valid <= valid_r;
            O_sof   <= sof_r;
            O_eol   <= eol_r;
            O_h     <= h_fin;
            O_s     <= s_r;
            O_v     <= v_r;
        end
    end

endmodule

// ===== [移植] hsv_inv_lut.v —— 逐字复制，来源 03_vision/step2_color_centroid/03_project/rtl/hsv_inv_lut.v，SHA256 626fbc2c460fa6a5 =====
// 自动生成：tools/gen_vectors.py  inv[d]=floor(3840/d) d=1..255
// 供 rgb2hsv.v 求色调用，综合为 Block ROM
module hsv_inv_lut (
    input  wire [7:0]  I_d,
    output reg  [11:0] O_inv
);
always @(*) begin
    case (I_d)
        8'd1: O_inv = 12'd3840;
        8'd2: O_inv = 12'd1920;
        8'd3: O_inv = 12'd1280;
        8'd4: O_inv = 12'd960;
        8'd5: O_inv = 12'd768;
        8'd6: O_inv = 12'd640;
        8'd7: O_inv = 12'd548;
        8'd8: O_inv = 12'd480;
        8'd9: O_inv = 12'd426;
        8'd10: O_inv = 12'd384;
        8'd11: O_inv = 12'd349;
        8'd12: O_inv = 12'd320;
        8'd13: O_inv = 12'd295;
        8'd14: O_inv = 12'd274;
        8'd15: O_inv = 12'd256;
        8'd16: O_inv = 12'd240;
        8'd17: O_inv = 12'd225;
        8'd18: O_inv = 12'd213;
        8'd19: O_inv = 12'd202;
        8'd20: O_inv = 12'd192;
        8'd21: O_inv = 12'd182;
        8'd22: O_inv = 12'd174;
        8'd23: O_inv = 12'd166;
        8'd24: O_inv = 12'd160;
        8'd25: O_inv = 12'd153;
        8'd26: O_inv = 12'd147;
        8'd27: O_inv = 12'd142;
        8'd28: O_inv = 12'd137;
        8'd29: O_inv = 12'd132;
        8'd30: O_inv = 12'd128;
        8'd31: O_inv = 12'd123;
        8'd32: O_inv = 12'd120;
        8'd33: O_inv = 12'd116;
        8'd34: O_inv = 12'd112;
        8'd35: O_inv = 12'd109;
        8'd36: O_inv = 12'd106;
        8'd37: O_inv = 12'd103;
        8'd38: O_inv = 12'd101;
        8'd39: O_inv = 12'd98;
        8'd40: O_inv = 12'd96;
        8'd41: O_inv = 12'd93;
        8'd42: O_inv = 12'd91;
        8'd43: O_inv = 12'd89;
        8'd44: O_inv = 12'd87;
        8'd45: O_inv = 12'd85;
        8'd46: O_inv = 12'd83;
        8'd47: O_inv = 12'd81;
        8'd48: O_inv = 12'd80;
        8'd49: O_inv = 12'd78;
        8'd50: O_inv = 12'd76;
        8'd51: O_inv = 12'd75;
        8'd52: O_inv = 12'd73;
        8'd53: O_inv = 12'd72;
        8'd54: O_inv = 12'd71;
        8'd55: O_inv = 12'd69;
        8'd56: O_inv = 12'd68;
        8'd57: O_inv = 12'd67;
        8'd58: O_inv = 12'd66;
        8'd59: O_inv = 12'd65;
        8'd60: O_inv = 12'd64;
        8'd61: O_inv = 12'd62;
        8'd62: O_inv = 12'd61;
        8'd63: O_inv = 12'd60;
        8'd64: O_inv = 12'd60;
        8'd65: O_inv = 12'd59;
        8'd66: O_inv = 12'd58;
        8'd67: O_inv = 12'd57;
        8'd68: O_inv = 12'd56;
        8'd69: O_inv = 12'd55;
        8'd70: O_inv = 12'd54;
        8'd71: O_inv = 12'd54;
        8'd72: O_inv = 12'd53;
        8'd73: O_inv = 12'd52;
        8'd74: O_inv = 12'd51;
        8'd75: O_inv = 12'd51;
        8'd76: O_inv = 12'd50;
        8'd77: O_inv = 12'd49;
        8'd78: O_inv = 12'd49;
        8'd79: O_inv = 12'd48;
        8'd80: O_inv = 12'd48;
        8'd81: O_inv = 12'd47;
        8'd82: O_inv = 12'd46;
        8'd83: O_inv = 12'd46;
        8'd84: O_inv = 12'd45;
        8'd85: O_inv = 12'd45;
        8'd86: O_inv = 12'd44;
        8'd87: O_inv = 12'd44;
        8'd88: O_inv = 12'd43;
        8'd89: O_inv = 12'd43;
        8'd90: O_inv = 12'd42;
        8'd91: O_inv = 12'd42;
        8'd92: O_inv = 12'd41;
        8'd93: O_inv = 12'd41;
        8'd94: O_inv = 12'd40;
        8'd95: O_inv = 12'd40;
        8'd96: O_inv = 12'd40;
        8'd97: O_inv = 12'd39;
        8'd98: O_inv = 12'd39;
        8'd99: O_inv = 12'd38;
        8'd100: O_inv = 12'd38;
        8'd101: O_inv = 12'd38;
        8'd102: O_inv = 12'd37;
        8'd103: O_inv = 12'd37;
        8'd104: O_inv = 12'd36;
        8'd105: O_inv = 12'd36;
        8'd106: O_inv = 12'd36;
        8'd107: O_inv = 12'd35;
        8'd108: O_inv = 12'd35;
        8'd109: O_inv = 12'd35;
        8'd110: O_inv = 12'd34;
        8'd111: O_inv = 12'd34;
        8'd112: O_inv = 12'd34;
        8'd113: O_inv = 12'd33;
        8'd114: O_inv = 12'd33;
        8'd115: O_inv = 12'd33;
        8'd116: O_inv = 12'd33;
        8'd117: O_inv = 12'd32;
        8'd118: O_inv = 12'd32;
        8'd119: O_inv = 12'd32;
        8'd120: O_inv = 12'd32;
        8'd121: O_inv = 12'd31;
        8'd122: O_inv = 12'd31;
        8'd123: O_inv = 12'd31;
        8'd124: O_inv = 12'd30;
        8'd125: O_inv = 12'd30;
        8'd126: O_inv = 12'd30;
        8'd127: O_inv = 12'd30;
        8'd128: O_inv = 12'd30;
        8'd129: O_inv = 12'd29;
        8'd130: O_inv = 12'd29;
        8'd131: O_inv = 12'd29;
        8'd132: O_inv = 12'd29;
        8'd133: O_inv = 12'd28;
        8'd134: O_inv = 12'd28;
        8'd135: O_inv = 12'd28;
        8'd136: O_inv = 12'd28;
        8'd137: O_inv = 12'd28;
        8'd138: O_inv = 12'd27;
        8'd139: O_inv = 12'd27;
        8'd140: O_inv = 12'd27;
        8'd141: O_inv = 12'd27;
        8'd142: O_inv = 12'd27;
        8'd143: O_inv = 12'd26;
        8'd144: O_inv = 12'd26;
        8'd145: O_inv = 12'd26;
        8'd146: O_inv = 12'd26;
        8'd147: O_inv = 12'd26;
        8'd148: O_inv = 12'd25;
        8'd149: O_inv = 12'd25;
        8'd150: O_inv = 12'd25;
        8'd151: O_inv = 12'd25;
        8'd152: O_inv = 12'd25;
        8'd153: O_inv = 12'd25;
        8'd154: O_inv = 12'd24;
        8'd155: O_inv = 12'd24;
        8'd156: O_inv = 12'd24;
        8'd157: O_inv = 12'd24;
        8'd158: O_inv = 12'd24;
        8'd159: O_inv = 12'd24;
        8'd160: O_inv = 12'd24;
        8'd161: O_inv = 12'd23;
        8'd162: O_inv = 12'd23;
        8'd163: O_inv = 12'd23;
        8'd164: O_inv = 12'd23;
        8'd165: O_inv = 12'd23;
        8'd166: O_inv = 12'd23;
        8'd167: O_inv = 12'd22;
        8'd168: O_inv = 12'd22;
        8'd169: O_inv = 12'd22;
        8'd170: O_inv = 12'd22;
        8'd171: O_inv = 12'd22;
        8'd172: O_inv = 12'd22;
        8'd173: O_inv = 12'd22;
        8'd174: O_inv = 12'd22;
        8'd175: O_inv = 12'd21;
        8'd176: O_inv = 12'd21;
        8'd177: O_inv = 12'd21;
        8'd178: O_inv = 12'd21;
        8'd179: O_inv = 12'd21;
        8'd180: O_inv = 12'd21;
        8'd181: O_inv = 12'd21;
        8'd182: O_inv = 12'd21;
        8'd183: O_inv = 12'd20;
        8'd184: O_inv = 12'd20;
        8'd185: O_inv = 12'd20;
        8'd186: O_inv = 12'd20;
        8'd187: O_inv = 12'd20;
        8'd188: O_inv = 12'd20;
        8'd189: O_inv = 12'd20;
        8'd190: O_inv = 12'd20;
        8'd191: O_inv = 12'd20;
        8'd192: O_inv = 12'd20;
        8'd193: O_inv = 12'd19;
        8'd194: O_inv = 12'd19;
        8'd195: O_inv = 12'd19;
        8'd196: O_inv = 12'd19;
        8'd197: O_inv = 12'd19;
        8'd198: O_inv = 12'd19;
        8'd199: O_inv = 12'd19;
        8'd200: O_inv = 12'd19;
        8'd201: O_inv = 12'd19;
        8'd202: O_inv = 12'd19;
        8'd203: O_inv = 12'd18;
        8'd204: O_inv = 12'd18;
        8'd205: O_inv = 12'd18;
        8'd206: O_inv = 12'd18;
        8'd207: O_inv = 12'd18;
        8'd208: O_inv = 12'd18;
        8'd209: O_inv = 12'd18;
        8'd210: O_inv = 12'd18;
        8'd211: O_inv = 12'd18;
        8'd212: O_inv = 12'd18;
        8'd213: O_inv = 12'd18;
        8'd214: O_inv = 12'd17;
        8'd215: O_inv = 12'd17;
        8'd216: O_inv = 12'd17;
        8'd217: O_inv = 12'd17;
        8'd218: O_inv = 12'd17;
        8'd219: O_inv = 12'd17;
        8'd220: O_inv = 12'd17;
        8'd221: O_inv = 12'd17;
        8'd222: O_inv = 12'd17;
        8'd223: O_inv = 12'd17;
        8'd224: O_inv = 12'd17;
        8'd225: O_inv = 12'd17;
        8'd226: O_inv = 12'd16;
        8'd227: O_inv = 12'd16;
        8'd228: O_inv = 12'd16;
        8'd229: O_inv = 12'd16;
        8'd230: O_inv = 12'd16;
        8'd231: O_inv = 12'd16;
        8'd232: O_inv = 12'd16;
        8'd233: O_inv = 12'd16;
        8'd234: O_inv = 12'd16;
        8'd235: O_inv = 12'd16;
        8'd236: O_inv = 12'd16;
        8'd237: O_inv = 12'd16;
        8'd238: O_inv = 12'd16;
        8'd239: O_inv = 12'd16;
        8'd240: O_inv = 12'd16;
        8'd241: O_inv = 12'd15;
        8'd242: O_inv = 12'd15;
        8'd243: O_inv = 12'd15;
        8'd244: O_inv = 12'd15;
        8'd245: O_inv = 12'd15;
        8'd246: O_inv = 12'd15;
        8'd247: O_inv = 12'd15;
        8'd248: O_inv = 12'd15;
        8'd249: O_inv = 12'd15;
        8'd250: O_inv = 12'd15;
        8'd251: O_inv = 12'd15;
        8'd252: O_inv = 12'd15;
        8'd253: O_inv = 12'd15;
        8'd254: O_inv = 12'd15;
        8'd255: O_inv = 12'd15;
        default: O_inv = 12'd0;
    endcase
end
endmodule

// ===== [移植] hsv_threshold.v —— 逐字复制，来源 03_vision/step2_color_centroid/03_project/rtl/hsv_threshold.v，SHA256 951932cfea1467fa =====
// =============================================================================
// hsv_threshold.v —— HSV 阈值分割（8 组预置阈值，1 拍延迟）
// -----------------------------------------------------------------------------
// mask = H∈[h_lo..h_hi]（支持环绕窗口，用于红色 335..25）且 S>=s_lo
//        且 v_lo<=V<=v_hi
// 阈值组与 golden_model.py::HSV_PRESETS 一致；I_preset_idx 由按键/拨码
// 切换（上板时接嵌入式方向的键控模块）。
// =============================================================================
module hsv_threshold #(parameter STRICT_RED=0, GROW_RED=0, GROW_BLUE=0) (
    input  wire       I_clk,
    input  wire       I_rst_n,
    input  wire       I_valid,
    input  wire       I_sof,
    input  wire       I_eol,
    input  wire [8:0] I_h,
    input  wire [7:0] I_s,
    input  wire [7:0] I_v,
    input  wire [2:0] I_preset_idx,
    output reg        O_valid,
    output reg        O_sof,
    output reg        O_eol,
    output reg        O_mask
);

    reg [8:0] h_lo, h_hi;
    reg [7:0] s_lo, v_lo, v_hi;

    // 8 组预置阈值（位精确对齐 golden_model.HSV_PRESETS）
    always @(*) begin
        case (I_preset_idx)
            3'd0: begin h_lo = (STRICT_RED&&!GROW_RED)?9'd345:9'd335; h_hi = STRICT_RED?9'd15:9'd25; s_lo = GROW_RED?8'd48:8'd80; v_lo = GROW_RED?8'd40:8'd60;  v_hi = 8'd255; end // 红
            3'd1: begin h_lo = 9'd110; h_hi = 9'd145; s_lo = 8'd60; v_lo = 8'd40;  v_hi = 8'd255; end // 绿
            3'd2: begin h_lo = GROW_BLUE?9'd190:9'd200; h_hi = GROW_BLUE?9'd260:9'd250; s_lo = GROW_BLUE?8'd36:8'd60; v_lo = GROW_BLUE?8'd28:8'd40;  v_hi = 8'd255; end // 蓝
            3'd3: begin h_lo = 9'd20;  h_hi = 9'd70;  s_lo = 8'd80; v_lo = 8'd80;  v_hi = 8'd255; end // 橙黄
            3'd4: begin h_lo = 9'd170; h_hi = 9'd195; s_lo = 8'd60; v_lo = 8'd60;  v_hi = 8'd255; end // 青
            3'd5: begin h_lo = 9'd300; h_hi = 9'd330; s_lo = 8'd60; v_lo = 8'd40;  v_hi = 8'd255; end // 品红
            3'd6: begin h_lo = 9'd0;   h_hi = 9'd359; s_lo = 8'd10; v_lo = 8'd220; v_hi = 8'd255; end // 白
            default: begin h_lo = 9'd0; h_hi = 9'd359; s_lo = 8'd0; v_lo = 8'd0; v_hi = 8'd60;    end // 黑
        endcase
    end

    wire in_h;
    assign in_h = (h_lo <= h_hi) ? (I_h >= h_lo) && (I_h <= h_hi)
                                 : (I_h >= h_lo) || (I_h <= h_hi);
    wire mask_c = in_h && (I_s >= s_lo) && (I_v >= v_lo) && (I_v <= v_hi);

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_valid <= 1'b0; O_sof <= 1'b0; O_eol <= 1'b0; O_mask <= 1'b0;
        end else begin
            O_valid <= I_valid;
            O_sof   <= I_sof;
            O_eol   <= I_eol;
            O_mask  <= mask_c;
        end
    end

endmodule

// ===== [移植] bin_smooth3x3.v —— 逐字复制，来源 03_vision/step2_color_centroid/03_project/rtl/bin_smooth3x3.v，SHA256 f691760db3ef1d21 =====
// =============================================================================
// bin_smooth3x3.v —— 二值掩码 3x3 多数表决平滑（v7：索引行缓存，自对齐结构）
// -----------------------------------------------------------------------------
// 规则（与 golden_model.py::smooth3x3_majority 逐位一致）：
//   窗口 9 bit 求和 >= 5 -> 输出 1；边界行/列复制（replicate）。
//
// 架构（v7，采用官方例程 edge_detect_96 同款"索引读写行缓存"）：
//   line1_arr[x] 存 row y-2、line0_arr[x] 存 row y-1，读写同用列指针 x：
//   先读旧值（d1/d0 = 上两行的当前列）后写新值（line0_arr[x]<=mask、
//   line1_arr[x]<=d0），读指针==写指针 -> 垂直数据天然对齐，不存在
//   移位延迟线的 ±1 相位问题（v3~v6 的教训，见 04_迭代文件）。
//   水平方向每行用 2 拍 FF 抽头（x-2, x-1）+ 当拍 x 组成 3 列窗口。
// 输出（每令牌恰一输出，流连续有序）：
//     x>=1          -> 中心 (x-1, y)   列 {x-2, x-1, x}，行 {y-2, y-1, y}
//     x==0 且已启动 -> 中心 (W-1, y-1) 列 {W-2, W-1, W-1复制}，行 {y-3, y-2, y-1}
//   两个窗口全部取自抽头寄存器（行尾窗口不读行缓存），与输出同拍组合。
// =============================================================================
module bin_smooth3x3 #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720
)(
    input  wire I_clk,
    input  wire I_rst_n,
    input  wire I_valid,
    input  wire I_sof,
    input  wire I_eol,
    input  wire I_mask,
    output reg  O_valid,
    output reg  O_sof,
    output reg  O_eol,
    output reg  O_mask
);

    localparam W = IMG_WIDTH;

    // ---------------- 坐标计数 ----------------
    reg [10:0] x;
    reg [9:0]  y;
    // 【SC520 本工程改动 v15】EOL 后下一时钟自主输出右边界，不借用下一行/下一帧。
    reg flush_pending;
    wire [10:0] x_eff = I_sof ? 11'd0 : x;
    wire [9:0] y_eff = I_sof ? 10'd0 : y;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) flush_pending <= 1'b0;
        else flush_pending <= I_valid && I_eol;
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            x <= 11'd0; y <= 10'd0;
        end else if (I_valid) begin
            if (I_sof) begin
                x <= 11'd1; y <= 10'd0;
            end else if (I_eol) begin
                x <= 11'd0;
                y <= (y == IMG_HEIGHT - 1) ? 10'd0 : y + 10'd1;
            end else begin
                x <= x + 11'd1;
            end
        end
    end

    // ---------------- 索引行缓存（分布式 RAM） ----------------
    (* ram_style = "distributed" *) reg line0_arr [0:W-1];   // row y-1
    (* ram_style = "distributed" *) reg line1_arr [0:W-1];   // row y-2

    // 读旧值（写前读，读指针==写指针==x）
    wire d0 = line0_arr[x_eff];          // row y-1 列 x
    wire d1 = line1_arr[x_eff];          // row y-2 列 x

    // 写新值：当前行进 line0，被挤出的 d0 进 line1（行滚动）
    always @(posedge I_clk) begin
        if (I_valid) begin
            line1_arr[x_eff] <= d0;
            line0_arr[x_eff] <= I_mask;
        end
    end

    // ---------------- 行选择（垂直复制规则） ----------------
    // t* 管道载运 row y-2、m* 载运 row y-1、b* 载运 row y（当前行）
    wire t_sel_r = (y_eff == 10'd0) ? I_mask :
                   (y_eff == 10'd1) ? d0    : d1;
    wire m_sel_r = (y_eff == 10'd0) ? I_mask : d0;
    wire b_sel_r = I_mask;

    // ---------------- 水平 FF 抽头 ----------------
    reg t0, t1, m0, m1, b0, b1;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            {t0,t1} <= 2'b00; {m0,m1} <= 2'b00; {b0,b1} <= 2'b00;
        end else if (I_valid) begin
            t0 <= t_sel_r; m0 <= m_sel_r; b0 <= b_sel_r;
            t1 <= t0;      m1 <= m0;      b1 <= b0;
            if (x_eff == 11'd0) begin
                // 左边界复制：列 -1 复用列 0 的值（中心 0 的窗口需要）
                t1 <= t_sel_r; m1 <= m_sel_r; b1 <= b_sel_r;
            end
        end
    end

    // ---------------- 窗口组合（与输出同拍） ----------------
    // 主窗口：中心 (x-1, y)（x>=1），列 {x-2, x-1, x}
    wire [3:0] win_main = {3'd0, t1} + {3'd0, t0} + {3'd0, t_sel_r} +
                          {3'd0, m1} + {3'd0, m0} + {3'd0, m_sel_r} +
                          {3'd0, b1} + {3'd0, b0} + {3'd0, b_sel_r};
    // 行尾窗口：中心 (W-1, y-1)（x==0），列 {W-2, W-1, W-1复制}，全用抽头
    wire [3:0] win_last = {3'd0, t1} + {3'd0, t0} + {3'd0, t0} +
                          {3'd0, m1} + {3'd0, m0} + {3'd0, m0} +
                          {3'd0, b1} + {3'd0, b0} + {3'd0, b0};

    wire main_en = (x_eff >= 11'd1) && !I_sof;
    wire last_en = flush_pending;

    // ---------------- 输出 ----------------
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_valid <= 1'b0; O_sof <= 1'b0; O_eol <= 1'b0; O_mask <= 1'b0;
        end else begin
            O_valid <= last_en || (I_valid && main_en);
            O_sof   <= I_valid && main_en && (y_eff == 10'd0) && (x == 11'd1);
            O_eol   <= last_en;      // 行尾窗口即每行最后一个输出
            O_mask  <= last_en ? (win_last >= 4'd5) : (I_valid && main_en && (win_main >= 4'd5));
        end
    end

endmodule

// ===== [移植] centroid_accum.v —— 逐字复制，来源 03_vision/step2_color_centroid/03_project/rtl/centroid_accum.v，SHA256 34eefc86cce61a59 =====
// =============================================================================
// centroid_accum.v —— 帧内累加求质心/包围框 + 帧末除法（除零保护）
// -----------------------------------------------------------------------------
// 与 golden_model.py::centroid_bbox 逐位一致：
//   count = Σmask；sum_x = Σ x·mask；sum_y = Σ y·mask（对平滑后掩码）
//   count >= MIN_PIXELS 才有效；cx = floor(sum_x/count)，cy 同理。
// 帧定界：内部 x/y 计数器（与 bin_smooth3x3 输出约定一致：sof/eol 自带）。
// 帧末（最后一行 eol 后一拍）启动恢复法除法状态机，两轴共 ~2*DIVW 拍，
// 在场消隐期内完成；结果锁存到下一帧。lost_cnt 记录连续无效帧数。
// =============================================================================
module centroid_accum #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720,
    parameter MIN_PIXELS = 30
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_valid,
    input  wire        I_sof,
    input  wire        I_eol,
    input  wire        I_mask,
    output reg         O_target_valid,
    output reg  [10:0] O_cx,
    output reg  [10:0] O_cy,
    output reg  [20:0] O_count,
    output reg  [10:0] O_min_x,
    output reg  [10:0] O_max_x,
    output reg  [9:0]  O_min_y,
    output reg  [9:0]  O_max_y,
    output reg  [15:0] O_lost_cnt,
    output reg         O_results_upd,   // 结果刷新脉冲（除法完成拍）
    output wire        O_frame_tick     // 帧末脉冲（帧最后一个像素后一拍）
);

    // ---------------- 像素坐标计数 ----------------
    reg [10:0] x;
    reg [9:0]  y;
    // 【SC520 本工程改动 v15】SOF 同拍从 (0,0) 开始，帧首命中也参与统计。
    wire [10:0] x_eff = I_sof ? 11'd0 : x;
    wire [9:0] y_eff = I_sof ? 10'd0 : y;
    wire last_line = (y_eff == IMG_HEIGHT - 1);

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            x <= 11'd0; y <= 10'd0;
        end else if (I_valid) begin
            if (I_sof) begin
                x <= I_eol ? 11'd0 : 11'd1;
                y <= I_eol ? 10'd1 : 10'd0;
            end else if (I_eol) begin
                x <= 11'd0;
                y <= last_line ? 10'd0 : y + 10'd1;
            end else begin
                x <= x + 11'd1;
            end
        end
    end

    // ---------------- 帧累加器 ----------------
    reg [31:0] sum_x, sum_y;
    reg [20:0] cnt;
    reg        seen;
    reg [10:0] bmin_x, bmax_x;
    reg [9:0]  bmin_y, bmax_y;

    wire hit = I_valid && I_mask;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            sum_x <= 32'd0; sum_y <= 32'd0; cnt <= 21'd0; seen <= 1'b0;
            bmin_x <= 11'd0; bmax_x <= 11'd0; bmin_y <= 10'd0; bmax_y <= 10'd0;
        end else if (I_valid && I_sof) begin
            sum_x <= 32'd0; sum_y <= 32'd0; cnt <= I_mask ? 21'd1 : 21'd0; seen <= I_mask; // 帧首像素坐标为零，sum 保持零
            bmin_x <= 0; bmax_x <= 0; bmin_y <= 0; bmax_y <= 0;
        end else if (hit) begin
            sum_x <= sum_x + {21'd0, x_eff};
            sum_y <= sum_y + {22'd0, y_eff};
            cnt   <= cnt + 21'd1;
            if (!seen) begin
                seen   <= 1'b1;
                bmin_x <= x_eff; bmax_x <= x_eff; bmin_y <= y_eff; bmax_y <= y_eff;
            end else begin
                if (x_eff < bmin_x) bmin_x <= x_eff;
                if (x_eff > bmax_x) bmax_x <= x_eff;
                if (y_eff < bmin_y) bmin_y <= y_eff;
                if (y_eff > bmax_y) bmax_y <= y_eff;
            end
        end
    end

    // ---------------- 帧末脉冲 ----------------
    reg tick_r;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)
            tick_r <= 1'b0;
        else
            tick_r <= I_valid && I_eol && last_line;
    end
    assign O_frame_tick = tick_r;

    // ---------------- 恢复法除法状态机（sum/cnt，两轴串行） ----------------
    localparam S_IDLE = 2'd0, S_DIV_X = 2'd1, S_DIV_Y = 2'd2, S_LATCH = 2'd3;
    reg [1:0]  st;
    reg [31:0] dividend;
    reg [20:0] divisor;
    reg [31:0] quotient;
    reg [21:0] remainder;
    reg [5:0]  bit_cnt;      // 32 位商逐位恢复
    // 除法快照：tick 时刻定格，下一帧 sof 清零累加器不影响本次结果
    reg [31:0] snap_sumx, snap_sumy;
    reg [20:0] snap_cnt;
    reg [10:0] snap_minx, snap_maxx;
    reg [9:0]  snap_miny, snap_maxy;

    wire [53:0] rem_sh   = {remainder, dividend[31]};
    wire [21:0] rem_sub  = rem_sh[21:0] - divisor;
    wire        rem_ge   = (rem_sh[21:0] >= divisor);

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            st <= S_IDLE; dividend <= 32'd0; divisor <= 21'd0;
            quotient <= 32'd0; remainder <= 22'd0; bit_cnt <= 6'd0;
        end else begin
            case (st)
                S_IDLE: if (tick_r) begin
                    snap_sumx <= sum_x; snap_sumy <= sum_y;
                    snap_cnt  <= cnt;
                    snap_minx <= bmin_x; snap_maxx <= bmax_x;
                    snap_miny <= bmin_y; snap_maxy <= bmax_y;
                    if (cnt < MIN_PIXELS) begin
                        st <= S_LATCH;                    // 无目标：直接锁存无效
                    end else begin
                        dividend <= sum_x; divisor <= cnt;
                        quotient <= 32'd0; remainder <= 22'd0;
                        bit_cnt  <= 6'd32;
                        st       <= S_DIV_X;
                    end
                end
                S_DIV_X, S_DIV_Y: begin
                    if (rem_ge) begin
                        remainder <= rem_sub;
                        quotient  <= {quotient[30:0], 1'b1};
                    end else begin
                        remainder <= rem_sh[21:0];
                        quotient  <= {quotient[30:0], 1'b0};
                    end
                    dividend <= {dividend[30:0], 1'b0};
                    bit_cnt  <= bit_cnt - 6'd1;
                    if (bit_cnt == 6'd1) begin
                        remainder <= 22'd0;
                        if (st == S_DIV_X) begin
                            dividend <= snap_sumy;          // 切换 Y 轴（用快照）
                            quotient <= 32'd0;
                            bit_cnt  <= 6'd32;
                            st       <= S_DIV_Y;
                        end else begin
                            st <= S_LATCH;
                        end
                    end
                end
                S_LATCH: st <= S_IDLE;
                default: st <= S_IDLE;
            endcase
        end
    end

    // ---------------- 结果锁存 ----------------
    // 商末位与移位同步预测（与 quotient 最后一次移位同拍）
    reg [31:0] q_x, q_y;
    always @(posedge I_clk) begin
        if (st == S_DIV_X && bit_cnt == 6'd1)
            q_x <= {quotient[30:0], rem_ge};
        if (st == S_DIV_Y && bit_cnt == 6'd1)
            q_y <= {quotient[30:0], rem_ge};
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_target_valid <= 1'b0; O_cx <= 11'd0; O_cy <= 11'd0;
            O_count <= 21'd0; O_lost_cnt <= 16'd0;
            O_min_x <= 11'd0; O_max_x <= 11'd0; O_min_y <= 10'd0; O_max_y <= 10'd0;
            O_results_upd <= 1'b0;
        end else begin
            O_results_upd <= 1'b0;
            if (st == S_LATCH) begin
                O_results_upd <= 1'b1;
                if (snap_cnt >= MIN_PIXELS) begin
                    O_target_valid <= 1'b1;
                    O_cx <= q_x[10:0];
                    O_cy <= q_y[10:0];
                    O_count <= snap_cnt;
                    O_min_x <= snap_minx; O_max_x <= snap_maxx;
                    O_min_y <= snap_miny; O_max_y <= snap_maxy;
                    O_lost_cnt <= 16'd0;
                end else begin
                    O_target_valid <= 1'b0;
                    O_cx <= 11'd0; O_cy <= 11'd0;
                    O_count <= snap_cnt;
                    O_min_x <= 11'd0; O_max_x <= 11'd0;
                    O_min_y <= 10'd0; O_max_y <= 10'd0;
                    if (O_lost_cnt != 16'hFFFF)
                        O_lost_cnt <= O_lost_cnt + 16'd1;
                end
            end
        end
    end

    // synthesis translate_off
    always @(posedge I_clk) begin
        if (I_rst_n && I_valid && I_sof && (x != 11'd0) )
            $display("CENTROID_ALIGN_WARN: sof at x=%0d y=%0d t=%0t", x, y, $time);
    end
    // synthesis translate_on

endmodule

// ===== [移植] detect_top.v —— 逐字复制，来源 08_board_bringup/02_td_synth_gate/detect_top.v，SHA256 db6be227d0dfea80 =====
// =============================================================================
// detect_top.v —— 目标检测分支顶层（96bit 窃流 -> 1ppc 检测链 -> 坐标输出）
// -----------------------------------------------------------------------------
// 挂载点：官方链路 isp_top 输出（AWB 之后、data128_96 之前）的 96bit
// AXI4-Stream。本模块为纯旁路：O_* 直通输入（时序零改动），检测链
// ser96to24 -> rgb2hsv -> hsv_threshold -> bin_smooth3x3 -> centroid_accum
// 并行工作，不反压、不修改视频流（OSD 在显示侧叠加）。
// 输出：每帧目标坐标/包围框/计数 + 帧脉冲（供云台控制与 OSD 用）。
// =============================================================================
module detect_top #(
    parameter IMG_WIDTH   = 1280,
    parameter IMG_HEIGHT  = 720,
    parameter MIN_PIXELS  = 30,
    // 【SC520 本工程改动 2026-10-11】motion_detect 需整帧 prev_mem（约 57 块 ERAM），
    // 超出本工程 ERAM 预算 → 默认关闭：不例化、输出恒 0。置 1 前必须先复核 ERAM 余量。
    parameter MOTION_EN   = 0,
    parameter REGION_EN = 0, STRICT_RED = 0, OBJECT_STABILITY_EN = 0, BLUE_STABILITY_EN = 0
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    // 96bit AXI4-Stream 视频输入（窃流，不影响主线）
    input  wire [95:0] I_tdata,
    input  wire        I_tvalid,
    input  wire        I_tuser,
    input  wire        I_tlast,
    output wire        O_tready,
    // 直通输出（与输入逐拍一致，供继续传输/比对）
    output wire [95:0] O_tdata,
    output wire        O_tvalid,
    output wire        O_tuser,
    output wire        O_tlast,
    // 阈值组选择（接按键/拨码）
    input  wire [2:0]  I_preset_idx,
    // 检测结果（帧率更新，帧末锁存）
    output wire         O_target_valid,
    output wire [10:0]  O_cx,
    output wire [10:0]  O_cy,
    output wire [20:0]  O_count,
    output wire [10:0]  O_min_x,
    output wire [10:0]  O_max_x,
    output wire [9:0]   O_min_y,
    output wire [9:0]   O_max_y,
    output wire [15:0]  O_lost_cnt,
    output wire         O_results_upd,
    output wire         O_frame_tick,
    // 调试：1ppc 掩码流（可选观察）
    output wire         O_dbg_mask_valid,
    output wire         O_dbg_mask,
    // 进阶④：运动检测输出（帧级锁存）
    output wire         O_mot_valid,
    output wire [13:0]  O_mot_cnt,
    output wire [10:0]  O_mot_minx,
    output wire [10:0]  O_mot_maxx,
    output wire [9:0]   O_mot_miny,
    output wire [9:0]   O_mot_maxy,
    // 串化后 1ppc 原始流（供 OSD 叠加层取底图）
    output wire         O_s_valid,
    output wire         O_s_sof,
    output wire         O_s_eol,
    output wire [23:0]  O_s_data,
    // 进阶③：采集帧号（每输入帧 sof 自增，随目标包携带用于延迟测量）
    output wire [7:0]   O_fid,
    output wire [7:0]   O_result_fid, // v15: 结果对应的采集帧号，原 O_fid 计数接口保持
    output wire [2:0]   O_result_preset, // v15: 与本次结果同帧的阈值组
    // 串化器帧同步错误（v4.1 看门狗：帧契约破坏后的持久丢弃态指示；0=正常）
    output wire         O_sync_err
);

    assign O_tready = 1'b1;
    assign O_tdata  = I_tdata;
    assign O_tvalid = I_tvalid;
    assign O_tuser  = I_tuser;
    assign O_tlast  = I_tlast;

    // 【SC520 本工程改动 v15】主链 SOF 是提前 FIFO 复位脉冲，检测入口单独对齐到首个有效 beat。
    // 仅改变窃流支路元数据；上方 O_tdata/O_tvalid/O_tuser/O_tlast 仍逐拍直通。
    reg sof_pending;
    wire detect_sof = I_tvalid && (I_tuser || sof_pending);
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) sof_pending <= 1'b0;
        else if (I_tvalid) sof_pending <= 1'b0;
        else if (I_tuser) sof_pending <= 1'b1;
    end
    // 96 -> 1 像素/拍
    wire        s_valid, s_sof, s_eol, s_sync_err;
    wire [23:0] s_data;
    ser96to24 u_ser (
        .I_clk(I_clk), .I_rst_n(I_rst_n),
        .I_tdata(I_tdata), .I_tvalid(I_tvalid),
        .I_tuser(detect_sof), .I_tlast(I_tlast),
        .O_tready(),
        .O_valid(s_valid), .O_sof(s_sof), .O_eol(s_eol), .O_data(s_data),
        .O_sync_err(s_sync_err)
    );
    wire region_error;
    assign O_sync_err = s_sync_err | region_error;

    assign O_s_valid = s_valid;
    assign O_s_sof   = s_sof;
    assign O_s_eol   = s_eol;
    assign O_s_data  = s_data;

    // 进阶③：采集帧号计数器
    wire m_valid, m_sof, m_eol, m_mask;
    reg [2:0] preset_input, preset_q;
    reg [7:0] fid;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)
            fid <= 8'd0;
        else if (detect_sof)
            fid <= fid + 8'd1;
    end
    // 【SC520 本工程改动 v15】在处理帧末锁定标签，下一帧到来不改写上一结果的帧号/档位。
    reg [7:0] frame_fid, result_fid;
    reg [2:0] frame_preset, result_preset;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            frame_fid <= 0; result_fid <= 0; frame_preset <= 0; result_preset <= 0;
        end else begin
            if (m_valid && m_sof) begin frame_fid <= fid; frame_preset <= preset_q; end
            if (O_frame_tick) begin
                result_fid <= frame_fid;
                result_preset <= frame_preset;
            end
        end
    end
    assign O_fid = fid;
    wire [7:0] region_fid;wire [2:0] region_preset;
    assign O_result_fid = REGION_EN?region_fid:result_fid;
    assign O_result_preset = REGION_EN?region_preset:result_preset;

    // RGB -> HSV（2 拍延迟）
    wire        h_valid, h_sof, h_eol;
    wire [8:0]  h_h;
    wire [7:0]  h_s, h_v;
    rgb2hsv #(.FULL_HUE(STRICT_RED)) u_hsv (
        .I_clk(I_clk), .I_rst_n(I_rst_n),
        .I_valid(s_valid), .I_sof(s_sof), .I_eol(s_eol), .I_data(s_data),
        .O_valid(h_valid), .O_sof(h_sof), .O_eol(h_eol),
        .O_h(h_h), .O_s(h_s), .O_v(h_v)
    );

    // 阈值组帧首锁存（外脑评审: 按键帧中切换会造成半帧旧半帧新掩码）
    // 【SC520 本工程改动 v15】输入帧首暂存；HSV 帧首换装，等待 FIFO 的上一帧尾部仍用旧档位。

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin preset_input <= 0; preset_q <= 0; end
        else begin
            if (detect_sof) preset_input <= I_preset_idx;
            if (h_valid && h_sof) preset_q <= preset_input;
        end
    end

    // 阈值分割（1 拍延迟）
    wire        t_valid, t_sof, t_eol, t_mask;
    hsv_threshold #(.STRICT_RED(STRICT_RED)) u_thr (
        .I_clk(I_clk), .I_rst_n(I_rst_n),
        .I_valid(h_valid), .I_sof(h_sof), .I_eol(h_eol),
        .I_h(h_h), .I_s(h_s), .I_v(h_v),
        .I_preset_idx(h_sof ? preset_input : preset_q),
        .O_valid(t_valid), .O_sof(t_sof), .O_eol(t_eol), .O_mask(t_mask)
    );

    // Strong seed and weak growth streams use identical filtering/geometry.
    // Only red gets the wider growth threshold; blue is unchanged.
    wire grow_valid,grow_sof,grow_eol,grow_mask;
    wire strong_valid,strong_sof,strong_eol,strong_mask;
    generate if(OBJECT_STABILITY_EN)begin:g_object_masks
        hsv_threshold #(.STRICT_RED(STRICT_RED),.GROW_RED(1),.GROW_BLUE(BLUE_STABILITY_EN)) u_grow_thr(
            .I_clk(I_clk),.I_rst_n(I_rst_n),.I_valid(h_valid),.I_sof(h_sof),.I_eol(h_eol),
            .I_h(h_h),.I_s(h_s),.I_v(h_v),.I_preset_idx(h_sof ? preset_input : preset_q),
            .O_valid(grow_valid),.O_sof(grow_sof),.O_eol(grow_eol),.O_mask(grow_mask));
        bin_smooth3x3 #(.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT)) u_strong_smooth(
            .I_clk(I_clk),.I_rst_n(I_rst_n),.I_valid(t_valid),.I_sof(t_sof),.I_eol(t_eol),.I_mask(t_mask),
            .O_valid(strong_valid),.O_sof(strong_sof),.O_eol(strong_eol),.O_mask(strong_mask));
    end else begin:g_original_mask
        assign grow_valid=t_valid;assign grow_sof=t_sof;assign grow_eol=t_eol;assign grow_mask=t_mask;
        assign strong_valid=m_valid;assign strong_sof=m_sof;assign strong_eol=m_eol;assign strong_mask=m_mask;
    end endgenerate
    bin_smooth3x3 #(.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT)) u_smooth(
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_valid(grow_valid),.I_sof(grow_sof),.I_eol(grow_eol),.I_mask(grow_mask),
        .O_valid(m_valid),.O_sof(m_sof),.O_eol(m_eol),.O_mask(m_mask));
    // synthesis translate_off
    always @(posedge I_clk)if(I_rst_n&&OBJECT_STABILITY_EN)begin
        if({strong_valid,strong_sof,strong_eol}!={m_valid,m_sof,m_eol})$fatal(1,"SEED_GROW_STREAM_ALIGNMENT");
        if(m_valid&&strong_mask&&!m_mask)$fatal(1,"STRONG_MASK_NOT_SUBSET_OF_GROWTH");
    end
    // synthesis translate_on

    // v17: optional largest tile-connected region, legacy accumulation retained for regression.
    generate if(REGION_EN)begin:g_region
    track_region_accum #(.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT),.MIN_PIXELS(MIN_PIXELS),.RED_STABLE(OBJECT_STABILITY_EN),.BLUE_STABLE(OBJECT_STABILITY_EN && BLUE_STABILITY_EN)) u_region(
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_valid(m_valid),.I_sof(m_sof),.I_eol(m_eol),.I_mask(m_mask),.I_seed(strong_mask),
        .I_fid(fid),.I_preset(preset_q),.O_target_valid(O_target_valid),.O_cx(O_cx),.O_cy(O_cy),
        .O_count(O_count),.O_min_x(O_min_x),.O_max_x(O_max_x),.O_min_y(O_min_y),.O_max_y(O_max_y),
        .O_lost_cnt(O_lost_cnt),.O_results_upd(O_results_upd),.O_frame_tick(O_frame_tick),
        .O_fid(region_fid),.O_preset(region_preset),.O_error(region_error));
    end else begin:g_legacy_cent
    assign region_error=1'b0;assign region_fid=0;assign region_preset=0;
    // 质心/包围框累加
    centroid_accum #(
        .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT),
        .MIN_PIXELS(MIN_PIXELS)
    ) u_cent (
        .I_clk(I_clk), .I_rst_n(I_rst_n),
        .I_valid(m_valid), .I_sof(m_sof), .I_eol(m_eol), .I_mask(m_mask),
        .O_target_valid(O_target_valid), .O_cx(O_cx), .O_cy(O_cy),
        .O_count(O_count),
        .O_min_x(O_min_x), .O_max_x(O_max_x),
        .O_min_y(O_min_y), .O_max_y(O_max_y),
        .O_lost_cnt(O_lost_cnt),
        .O_results_upd(O_results_upd),
        .O_frame_tick(O_frame_tick)
    );

    end endgenerate

    assign O_dbg_mask_valid = m_valid;
    assign O_dbg_mask       = m_mask;

    // 进阶④：帧差运动检测分支（与 centroid 共享平滑掩码流）
    wire         md_hit;
    wire [13:0]  md_cnt;
    wire [10:0]  md_minx, md_maxx;
    wire [9:0]   md_miny, md_maxy;
    // 【SC520 本工程改动 2026-10-11】MOTION_EN 门控（默认 0 = 不例化，省约 57 块 ERAM）
    generate if (MOTION_EN) begin : g_motion
    motion_detect #(
        .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT), .MOT_TH(64)
    ) u_motion (
        .I_clk(I_clk), .I_rst_n(I_rst_n),
        .I_valid(m_valid), .I_sof(m_sof), .I_eol(m_eol), .I_mask(m_mask),
        .O_mot_valid(md_hit), .O_mot_cnt(md_cnt),
        .O_mot_minx(md_minx), .O_mot_maxx(md_maxx),
        .O_mot_miny(md_miny), .O_mot_maxy(md_maxy)
    );
        assign O_mot_valid = md_hit;
        assign O_mot_cnt   = md_cnt;
        assign O_mot_minx  = md_minx; assign O_mot_maxx = md_maxx;
        assign O_mot_miny  = md_miny; assign O_mot_maxy = md_maxy;
    end else begin : g_no_motion
        assign O_mot_valid = 1'b0;
        assign O_mot_cnt   = 14'd0;
        assign O_mot_minx  = 11'd0; assign O_mot_maxx = 11'd0;
        assign O_mot_miny  = 10'd0; assign O_mot_maxy = 10'd0;
    end endgenerate


endmodule

// ===== [移植] osd_track.v —— 逐字复制，来源 08_board_bringup/02_td_synth_gate/osd_track.v，SHA256 3d0f73e668e175eb =====
// =============================================================================
// osd_track.v —— 跟踪信息 OSD 叠加层 v3（三行文本 + 跑马灯 + 双框 + 坐标双缓冲）
// -----------------------------------------------------------------------------
// v3 变更（2026-09-20，消撕裂）：
//   CDC 送来的目标包（pack_valid）可能落在一帧中间。v2 及之前直接更新绘制
//   寄存器，导致同帧上半部分用旧坐标、下半部分用新坐标（可见的框撕裂）。
//   v3 引入影子寄存器组：pack_valid 只写影子；绘制寄存器仅在 I_sof 拍从
//   影子整组换装（vsync 语义），整帧恒用同一快照。
//   注：sof 拍本身（像素 (0,0)）仍用旧值绘制一拍，OSD 起始在 x=16，无视觉影响。
// v2 变更（配合 step5 拓展）：
//   目标包 68bit -> 135bit（IF-VISION v1.1.0）：
//     {valid, algo, preset[2:0], cx[10:0], cy[10:0], minx[10:0], maxx[10:0],
//      miny[9:0], maxy[9:0], fid[7:0], mot_valid, mot_cnt[13:0],
//      mot_minx[10:0], mot_maxx[10:0], mot_miny[9:0], mot_maxy[9:0]}
//   三行文本：
//     L1 y=16:  "<TRK|EDG><n> <LOCK|LOST> X####Y####"
//     L2 y=40:  "D%02d B%+03d C%03d M%04d"
//     L3 y=64:  跑马灯（64 字符消息逐像素滚动，2px/帧）
//   双框：绿色准星 + 红色目标框；运动有效时叠加橙色运动包围框
// 绘制优先级：文字 > 准星 > 目标框 > 运动框 > 底图
// =============================================================================
module osd_track #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720,
    parameter TXT_X0     = 16,
    parameter TXT_Y0     = 16,
    parameter TXT2_Y0    = 40,
    parameter TXT3_Y0    = 64,
    parameter AXIS_EN = 0, parameter STABILIZE_EN = 0
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_valid,
    input  wire        I_sof,
    input  wire        I_eol,
    input  wire [23:0] I_data,
    input  wire        I_det_clk,
    input  wire        I_det_rst_n,
    input  wire [134:0] I_det_pack,
    input  wire        I_det_load,
    output wire        O_det_busy,
    input  wire [6:0]  I_bright,       // -64..+63
    input  wire [7:0]  I_contrast,     // Q6, 64=1.0
    output reg         O_valid,
    output reg         O_sof,
    output reg         O_eol,
    output reg  [23:0] O_data,
    output wire [134:0] O_display_pack, output wire O_display_load
);

    wire [134:0] pack_dst, raw_pack_dst;
    wire         pack_valid, raw_pack_valid;
    cdc_4phase #(.WIDTH(135)) u_cdc (
        .I_clk_src(I_det_clk), .I_rst_src_n(I_det_rst_n),
        .I_src_data(I_det_pack), .I_src_load(I_det_load), .O_src_busy(O_det_busy),
        .I_clk_dst(I_clk), .I_rst_dst_n(I_rst_n),
        .O_dst_data(raw_pack_dst), .O_dst_valid(raw_pack_valid)
    );

    // 【SC520 本工程改动 v16】仅显示结果稳定化，原检测包、LED 与像素主链不变。
    generate if(STABILIZE_EN)begin:g_stable
      track_pack_stabilizer #(.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT))u_stable(
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_load(raw_pack_valid),.I_pack(raw_pack_dst),
        .O_load(pack_valid),.O_pack(pack_dst));
    end else begin:g_raw
      assign pack_dst=raw_pack_dst;assign pack_valid=raw_pack_valid;
    end endgenerate

    assign O_display_pack=pack_dst; assign O_display_load=pack_valid;
    reg [7:0] disp_cnt;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) disp_cnt <= 8'd0;
        else if (I_valid && I_sof) disp_cnt <= disp_cnt + 8'd1;
    end

    // ---------------- 影子寄存器组（CDC 域写入，sof 换装） ----------------
    reg        s_tv, s_algo_edg;
    reg [2:0]  s_preset;
    reg [10:0] s_cx, s_cy, s_bminx, s_bmaxx;
    reg [9:0]  s_bminy, s_bmaxy;
    reg [7:0]  s_lat;
    reg        s_mv;
    reg [13:0] s_mcnt;
    reg [10:0] s_mminx, s_mmaxx;
    reg [9:0]  s_mminy, s_mmaxy;
    reg [7:0]  txt1_s [0:19];
    reg [7:0]  txt2_s [0:19];

    // ---------------- 绘制寄存器组（sof 拍整组换装，帧内恒定） ----------------
    reg        tv, algo_edg;
    reg [2:0]  preset_q;
    reg [10:0] cx, cy, bminx, bmaxx;
    reg [9:0]  bminy, bmaxy;
    reg [7:0]  lat_q;
    reg        mv;
    reg [13:0] mcnt;
    reg [10:0] mminx, mmaxx;
    reg [9:0]  mminy, mmaxy;
    reg [7:0]  txt1 [0:19];
    reg [7:0]  txt2 [0:19];
    integer    k;

    function [31:0] to_digits4;
        input [13:0] val;
        reg [13:0] r;
        begin
            to_digits4[31:24] = 8'd48 + val / 14'd1000;
            r = val % 14'd1000;
            to_digits4[23:16] = 8'd48 + r / 14'd100;
            r = r % 14'd100;
            to_digits4[15:8]  = 8'd48 + r / 14'd10;
            to_digits4[7:0]   = 8'd48 + r % 14'd10;
        end
    endfunction
    // 【SC520 本工程改动 v16】中心坐标，X 向右、Y 向上；显示符号+三位数。
    function [31:0] signed_axis4;
      input [10:0] val;
      input [10:0] center;
      input invert;
      reg negative;reg [10:0] mag;reg [31:0] digits;
      begin
        negative=(val<center)^invert;
        mag=(val>=center)?val-center:center-val;
        digits=to_digits4(mag);
        signed_axis4={(mag==0||!negative)?8'd43:8'd45,digits[23:0]};
      end
    endfunction
    function [15:0] to_digits2;
        input [7:0] val;
        begin
            to_digits2[15:8] = 8'd48 + val / 8'd10;
            to_digits2[7:0]   = 8'd48 + val % 8'd10;
        end
    endfunction

    reg [31:0] d_x, d_y, d_mot;
    reg [15:0] d_lat;
    reg [7:0]  b_abs;
    // 外脑评审修复：D 字段应使用本包延迟（原读旧 s_lat，文本滞后一包）
    wire [7:0] lat_new = disp_cnt - pack_dst[65:58];

    // 影子写入：CDC 包到达时（可能在帧中间）
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            s_tv <= 0; s_algo_edg <= 0; s_preset <= 0;
            s_cx <= 0; s_cy <= 0;
            s_bminx <= 0; s_bmaxx <= 0; s_bminy <= 0; s_bmaxy <= 0;
            s_lat <= 0; s_mv <= 0; s_mcnt <= 0;
            s_mminx <= 0; s_mmaxx <= 0; s_mminy <= 0; s_mmaxy <= 0;
            for (k = 0; k < 20; k = k + 1) begin
                txt1_s[k] <= 8'd32; txt2_s[k] <= 8'd32;
            end
        end else if (pack_valid) begin
            s_tv       <= pack_dst[134];
            s_algo_edg <= pack_dst[133];
            s_preset   <= pack_dst[132:130];
            s_cx       <= pack_dst[129:119];
            s_cy       <= pack_dst[118:108];
            s_bminx    <= pack_dst[107:97];
            s_bmaxx    <= pack_dst[96:86];
            s_bminy    <= pack_dst[85:76];
            s_bmaxy    <= pack_dst[75:66];
            s_lat      <= lat_new;
            s_mv       <= pack_dst[57];
            s_mcnt     <= pack_dst[56:43];
            s_mminx    <= pack_dst[42:32];
            s_mmaxx    <= pack_dst[31:21];
            s_mminy    <= pack_dst[20:11];
            s_mmaxy    <= pack_dst[10:1];

            txt1_s[0] <= pack_dst[133] ? "E" : "T";
            txt1_s[1] <= pack_dst[133] ? "D" : "R";
            txt1_s[2] <= pack_dst[133] ? "G" : "K";
            txt1_s[3] <= 8'd48 + {5'd0, pack_dst[132:130]};
            txt1_s[4] <= " ";
            txt1_s[5] <= "L"; txt1_s[6] <= "O";
            if (pack_dst[134]) begin
                txt1_s[7] <= "C"; txt1_s[8] <= "K";
            end else begin
                txt1_s[7] <= "S"; txt1_s[8] <= "T";
            end
            txt1_s[9] <= " "; txt1_s[10] <= "X";
            d_x = AXIS_EN ? signed_axis4(pack_dst[129:119],IMG_WIDTH/2,1'b0) : to_digits4(pack_dst[134] ? pack_dst[129:119] : 11'd0);
            d_y = AXIS_EN ? signed_axis4(pack_dst[118:108],IMG_HEIGHT/2,1'b1) : to_digits4(pack_dst[134] ? pack_dst[118:108] : 11'd0);
            if (!pack_dst[134]) begin
                d_x = 32'h2D2D2D2D; d_y = 32'h2D2D2D2D;
            end
            txt1_s[11] <= d_x[31:24]; txt1_s[12] <= d_x[23:16];
            txt1_s[13] <= d_x[15:8];  txt1_s[14] <= d_x[7:0];
            txt1_s[15] <= "Y";
            txt1_s[16] <= d_y[31:24]; txt1_s[17] <= d_y[23:16];
            txt1_s[18] <= d_y[15:8];  txt1_s[19] <= d_y[7:0];

            d_lat = to_digits2((lat_new > 8'd99) ? 8'd99 : lat_new);
            txt2_s[0] <= "D";
            txt2_s[1] <= d_lat[15:8]; txt2_s[2] <= d_lat[7:0];
            txt2_s[3] <= " ";
            txt2_s[4] <= "B";
            txt2_s[5] <= I_bright[6] ? "-" : "+";
            b_abs = I_bright[6] ? (~I_bright + 1'b1) : I_bright;
            d_lat = to_digits2(b_abs);
            txt2_s[6] <= d_lat[15:8]; txt2_s[7] <= d_lat[7:0];
            txt2_s[8] <= " ";
            txt2_s[9] <= "C";
            d_lat = to_digits2(I_contrast[7:3]);
            txt2_s[10] <= d_lat[15:8]; txt2_s[11] <= d_lat[7:0];
            txt2_s[12] <= " ";
            txt2_s[13] <= "M";
            // 外脑评审覆盖测试抓出的真 bug：原读 s_mcnt（同块 NBA 旧值）,
            // M 字段永远滞后一包（与 D 字段同类的"读旧值"错误）。
            // 改用本包 live 值。
            d_mot = to_digits4((pack_dst[56:43] > 14'd9999) ? 14'd9999 : pack_dst[56:43]);
            txt2_s[14] <= d_mot[31:24]; txt2_s[15] <= d_mot[23:16];
            txt2_s[16] <= d_mot[15:8];  txt2_s[17] <= d_mot[7:0];
            txt2_s[18] <= " "; txt2_s[19] <= " ";
        end
    end

    // vsync 换装：sof 拍整组影子 -> 绘制（帧内恒定，消撕裂）
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            tv <= 0; algo_edg <= 0; preset_q <= 0;
            cx <= 0; cy <= 0;
            bminx <= 0; bmaxx <= 0; bminy <= 0; bmaxy <= 0;
            lat_q <= 0; mv <= 0; mcnt <= 0;
            mminx <= 0; mmaxx <= 0; mminy <= 0; mmaxy <= 0;
            for (k = 0; k < 20; k = k + 1) begin
                txt1[k] <= 8'd32; txt2[k] <= 8'd32;
            end
        end else if (I_valid && I_sof) begin
            tv       <= s_tv;
            algo_edg <= s_algo_edg;
            preset_q <= s_preset;
            cx       <= s_cx;
            cy       <= s_cy;
            bminx    <= s_bminx;
            bmaxx    <= s_bmaxx;
            bminy    <= s_bminy;
            bmaxy    <= s_bmaxy;
            lat_q    <= s_lat;
            mv       <= s_mv;
            mcnt     <= s_mcnt;
            mminx    <= s_mminx;
            mmaxx    <= s_mmaxx;
            mminy    <= s_mminy;
            mmaxy    <= s_mmaxy;
            for (k = 0; k < 20; k = k + 1) begin
                txt1[k] <= txt1_s[k];
                txt2[k] <= txt2_s[k];
            end
        end
    end

    reg [10:0] px;
    reg [9:0]  py;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            px <= 0; py <= 0;
        end else if (I_valid) begin
            if (I_sof) begin
                px <= 11'd1; py <= 10'd0;
            end else if (I_eol) begin
                px <= 11'd0; py <= py + 10'd1;
            end else begin
                px <= px + 11'd1;
            end
        end
    end

    // 跑马灯：消息 "2026 FPGA CONTEST - ANLOGIC PH1P35 VISION TRACKER - " 共 63 字符
    // 偏移 = disp_cnt × 2 px/帧，取模 504（63×8），字符索引 = (px-TXT_X0+off)>>3
    wire [9:0]  mar_off  = {disp_cnt[7:0], 1'b0};               // 0..510
    // 外脑评审: 原 mar_pos[8:3] 截断高位——mar_pos>=512 后字符索引错位。
    // 正确 (mar_pos>>3) mod 63: 63*3=189, 连减三次(索引最大 221)
    wire [11:0] mar_pos  = (px >= TXT_X0) ? (px - TXT_X0 + {2'b00, mar_off}) : 12'd0;
    wire [2:0]  mar_bit  = 3'd7 - mar_pos[2:0];
    wire [3:0]  mar_row  = py - TXT3_Y0;
    wire        in_mar   = (py >= TXT3_Y0) && (py < TXT3_Y0 + 16) &&
                           (px >= TXT_X0) && (px < TXT_X0 + 1280);

    // ---- 跑马灯流水（2026-10-03：TD 将 1024x8 ROM 映射为 ~10 级 LUT3 mux 链，
    //      是 74.25MHz 域的唯一关键路径。此处把"地址计算 + ROM 读"整体提前 4 像素，
    //      ROM 输出经 4 级移位与当前像素对齐——ROM 获得整拍预算，混合级仅剩
    //      位选 + 区域门控 3~4 级逻辑。功能位精确等价（tb_osd_track 逐像素复验）。----
    // 前瞻位姿 (px+4) 需处理行尾跨越：越过 1279 -> 下一行的 px/py。
    // 语义核对：n = px - TXT_X0 + mar_off（虚拟文本坐标，TXT_X0 为 8 的倍数）；
    //           字符 = (n>>3) mod 63；位选 = 7 - (n&7)。
    wire [11:0] px_4  = px + 12'd4;
    wire        xw    = (px_4 > 12'd1279) && (py < 10'd719);   // 行内跨越才换行
    wire [11:0] px_c  = xw ? (px_4 - 12'd1280) : px_4;
    wire [9:0]  py_c  = xw ? (py + 10'd1) : py;

    wire [11:0] mar_pos_c = (px_c >= TXT_X0) ? (px_c - TXT_X0 + {2'b00, mar_off}) : 12'd0;
    wire [7:0]  ci_full_c = {1'b0, mar_pos_c[10:3]};
    wire [7:0]  ci_r1_c   = (ci_full_c >= 8'd252) ? ci_full_c - 8'd252 :
                            (ci_full_c >= 8'd189) ? ci_full_c - 8'd189 :
                            (ci_full_c >= 8'd126) ? ci_full_c - 8'd126 :
                            (ci_full_c >= 8'd63)  ? ci_full_c - 8'd63  : ci_full_c;
    wire [5:0]  mar_ci_c  = ci_r1_c[5:0];
    wire [3:0]  mar_row_c = py_c - TXT3_Y0;
    wire [7:0]  mar_glyph_c;
    marquee_rom_64 u_marq (.I_addr({mar_ci_c, mar_row_c}), .O_bits(mar_glyph_c));

    // 4 级移位对齐：g3 在当拍恰为"本像素"的 ROM 输出（仅在有效像素拍推进）
    reg [7:0] mg0, mg1, mg2, mg3;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            mg0 <= 8'd0; mg1 <= 8'd0; mg2 <= 8'd0; mg3 <= 8'd0;
        end else if (I_valid) begin
            mg0 <= mar_glyph_c;
            mg1 <= mg0;
            mg2 <= mg1;
            mg3 <= mg2;
        end
    end
    wire on_mar = in_mar && mg3[mar_bit];

    // L1 状态行
    wire in_txt1 = (py >= TXT_Y0) && (py < TXT_Y0 + 16) &&
                   (px >= TXT_X0) && (px < TXT_X0 + 160);
    wire [4:0]  ch1_idx = (px - TXT_X0) >> 3;
    wire [3:0]  ch1_row = py - TXT_Y0;
    wire [10:0] dxp     = px - TXT_X0;
    wire [2:0]  bit_sel = 3'd7 - dxp[2:0];
    wire [7:0]  g1;
    font_rom_8x16 u_f1 (.I_addr({txt1[ch1_idx], ch1_row}), .O_bits(g1));
    wire on_txt1 = in_txt1 && g1[bit_sel];

    // L2 遥测行
    wire in_txt2 = (py >= TXT2_Y0) && (py < TXT2_Y0 + 16) &&
                   (px >= TXT_X0) && (px < TXT_X0 + 160);
    wire [4:0]  ch2_idx = (px - TXT_X0) >> 3;
    wire [3:0]  ch2_row = py - TXT2_Y0;
    wire [7:0]  g2;
    font_rom_8x16 u_f2 (.I_addr({txt2[ch2_idx], ch2_row}), .O_bits(g2));
    wire on_txt2 = in_txt2 && g2[bit_sel];

    // 【SC520 本工程改动 v16】1280x720 中心坐标轴，刻度 X=160px / Y=120px。
    // 只在跟踪显示支路使能；图像像素坐标和检测协议仍保持左上角原点。
    localparam AX_CX=IMG_WIDTH/2,AX_CY=IMG_HEIGHT/2;
    wire x_tick=(px==160)||(px==320)||(px==480)||(px==640)||
                (px==800)||(px==960)||(px==1120);
    wire y_tick=(py==120)||(py==240)||(py==360)||(py==480)||(py==600);
    wire axis_h=(py==AX_CY)||(x_tick&&(py>=AX_CY-4)&&(py<=AX_CY+4));
    wire axis_v=(px==AX_CX)||(y_tick&&(px>=AX_CX-4)&&(px<=AX_CX+4));
    wire arrow_x=((px==1274)&&(py>=358)&&(py<=362))||
                 ((px==1275)&&(py>=359)&&(py<=361))||(px==1276&&py==360);
    wire arrow_y=((py==5)&&(px>=638)&&(px<=642))||
                 ((py==4)&&(px>=639)&&(px<=641))||(py==3&&px==640);
    wire on_axis=AXIS_EN&&(axis_h||axis_v||arrow_x||arrow_y);
    reg axis_label_on;
    reg [31:0] axis_word;
    reg [10:0] label_x;
    reg [9:0] label_y;
    always @(*)begin
      axis_label_on=0;axis_word="    ";label_x=0;label_y=0;
      if(AXIS_EN)begin
        // 水平刻度标在轴下方，垂直刻度标在轴右侧。
        if(py>=368&&py<384)begin
          label_y=368;
          if(px>=144&&px<176)begin axis_label_on=1;axis_word="-480";label_x=144;end
          else if(px>=304&&px<336)begin axis_label_on=1;axis_word="-320";label_x=304;end
          else if(px>=464&&px<496)begin axis_label_on=1;axis_word="-160";label_x=464;end
          else if(px>=784&&px<816)begin axis_label_on=1;axis_word="+160";label_x=784;end
          else if(px>=944&&px<976)begin axis_label_on=1;axis_word="+320";label_x=944;end
          else if(px>=1104&&px<1136)begin axis_label_on=1;axis_word="+480";label_x=1104;end
        end
        if(px>=652&&px<684)begin
          label_x=652;
          if(py>=112&&py<128)begin axis_label_on=1;axis_word="+240";label_y=112;end
          else if(py>=232&&py<248)begin axis_label_on=1;axis_word="+120";label_y=232;end
          else if(py>=472&&py<488)begin axis_label_on=1;axis_word="-120";label_y=472;end
          else if(py>=592&&py<608)begin axis_label_on=1;axis_word="-240";label_y=592;end
        end
        if(px>=648&&px<656&&py>=368&&py<384)begin
          axis_label_on=1;axis_word="0   ";label_x=648;label_y=368;
        end
        if(px>=1248&&px<1256&&py>=340&&py<356)begin
          axis_label_on=1;axis_word="X   ";label_x=1248;label_y=340;
        end
        if(px>=648&&px<656&&py>=4&&py<20)begin
          axis_label_on=1;axis_word="Y   ";label_x=648;label_y=4;
        end
      end
    end
    wire [10:0] axis_dx=px-label_x;
    wire [9:0] axis_dy=py-label_y;
    reg [7:0] axis_char;
    always @(*)case(axis_dx[4:3])
      0:axis_char=axis_word[31:24];1:axis_char=axis_word[23:16];
      2:axis_char=axis_word[15:8];default:axis_char=axis_word[7:0];
    endcase
    wire [7:0] axis_glyph;
    font_rom_8x16 u_axis_font(.I_addr({axis_char,axis_dy[3:0]}),.O_bits(axis_glyph));
    wire on_axis_text=AXIS_EN&&axis_label_on&&axis_glyph[3'd7-axis_dx[2:0]];

    // 准星/框
    wire signed [12:0] dx_c = $signed({1'b0, px}) - $signed({1'b0, cx});
    wire signed [12:0] dy_c = $signed({1'b0, py}) - $signed({1'b0, cy});
    wire ax = (dx_c >= -13'sd12) && (dx_c <= 13'sd12) &&
              ((dx_c <= -13'sd3) || (dx_c >= 13'sd3));
    wire ay = (dy_c >= -13'sd12) && (dy_c <= 13'sd12) &&
              ((dy_c <= -13'sd3) || (dy_c >= 13'sd3));
    wire on_cross = tv && ((ay && (dx_c == 13'sd0)) || (ax && (dy_c == 13'sd0)));

    wire x_edge = (px == bminx) || (px == bminx + 11'd1) ||
                  (px == bmaxx - 11'd1) || (px == bmaxx);
    wire y_edge = (py == bminy) || (py == bminy + 10'd1) ||
                  (py == bmaxy - 10'd1) || (py == bmaxy);
    wire in_bx = (px >= bminx) && (px <= bmaxx);
    wire in_by = (py >= bminy) && (py <= bmaxy);
    wire on_box = tv && ((x_edge && in_by) || (y_edge && in_bx));

    wire mx_e = (px == mminx) || (px == mminx + 11'd1) ||
                (px == mmaxx - 11'd1) || (px == mmaxx);
    wire my_e = (py == mminy) || (py == mminy + 10'd1) ||
                (py == mmaxy - 10'd1) || (py == mmaxy);
    wire in_mx = (px >= mminx) && (px <= mmaxx);
    wire in_my = (py >= mminy) && (py <= mmaxy);
    wire on_mbox = mv && ((mx_e && in_my) || (my_e && in_mx));

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_valid <= 0; O_sof <= 0; O_eol <= 0; O_data <= 0;
        end else begin
            O_valid <= I_valid;
            O_sof   <= I_sof;
            O_eol   <= I_eol;
            O_data  <= on_txt1 ? 24'hFF_FF_FF :
                       on_txt2 ? 24'hFF_FF_FF :
                       on_mar  ? 24'h00_FF_FF :
                       on_cross ? 24'h00_FF_00 :
                       on_box  ? 24'hFF_00_00 :
                       on_mbox ? 24'hFF_80_00 :
                       on_axis_text ? 24'hC0_D0_D0 :
                       on_axis ? 24'h70_80_80 : I_data;
        end
    end

endmodule

// ===== [移植] font_rom_8x16.v —— 逐字复制，来源 03_vision/step4_osd_integration/03_project/rtl/font_rom_8x16.v，SHA256 fb6dd53fad6affe9 =====
// 自动生成：tools/gen_vectors.py (cv2 Hershey->8x16 点阵)
// 地址 {char[7:0], row[3:0]} -> 该行 8 位点阵（MSB=最左像素）
module font_rom_8x16 (
    input  wire [11:0] I_addr,
    output reg  [7:0]  O_bits
);
always @(*) begin
    case (I_addr)
        12'h200: O_bits = 8'h00;  // ' ' row0
        12'h201: O_bits = 8'h00;  // ' ' row1
        12'h202: O_bits = 8'h00;  // ' ' row2
        12'h203: O_bits = 8'h00;  // ' ' row3
        12'h204: O_bits = 8'h00;  // ' ' row4
        12'h205: O_bits = 8'h00;  // ' ' row5
        12'h206: O_bits = 8'h00;  // ' ' row6
        12'h207: O_bits = 8'h00;  // ' ' row7
        12'h208: O_bits = 8'h00;  // ' ' row8
        12'h209: O_bits = 8'h00;  // ' ' row9
        12'h20A: O_bits = 8'h00;  // ' ' row10
        12'h20B: O_bits = 8'h00;  // ' ' row11
        12'h20C: O_bits = 8'h00;  // ' ' row12
        12'h20D: O_bits = 8'h00;  // ' ' row13
        12'h20E: O_bits = 8'h00;  // ' ' row14
        12'h20F: O_bits = 8'h00;  // ' ' row15
        12'h300: O_bits = 8'h00;  // '0' row0
        12'h301: O_bits = 8'h00;  // '0' row1
        12'h302: O_bits = 8'h00;  // '0' row2
        12'h303: O_bits = 8'h3F;  // '0' row3
        12'h304: O_bits = 8'h73;  // '0' row4
        12'h305: O_bits = 8'h63;  // '0' row5
        12'h306: O_bits = 8'h65;  // '0' row6
        12'h307: O_bits = 8'h65;  // '0' row7
        12'h308: O_bits = 8'h69;  // '0' row8
        12'h309: O_bits = 8'h69;  // '0' row9
        12'h30A: O_bits = 8'h79;  // '0' row10
        12'h30B: O_bits = 8'h71;  // '0' row11
        12'h30C: O_bits = 8'h37;  // '0' row12
        12'h30D: O_bits = 8'h1E;  // '0' row13
        12'h30E: O_bits = 8'h00;  // '0' row14
        12'h30F: O_bits = 8'h00;  // '0' row15
        12'h310: O_bits = 8'h00;  // '1' row0
        12'h311: O_bits = 8'h00;  // '1' row1
        12'h312: O_bits = 8'h00;  // '1' row2
        12'h313: O_bits = 8'h0C;  // '1' row3
        12'h314: O_bits = 8'h3C;  // '1' row4
        12'h315: O_bits = 8'h7C;  // '1' row5
        12'h316: O_bits = 8'h0C;  // '1' row6
        12'h317: O_bits = 8'h0C;  // '1' row7
        12'h318: O_bits = 8'h0C;  // '1' row8
        12'h319: O_bits = 8'h0C;  // '1' row9
        12'h31A: O_bits = 8'h0C;  // '1' row10
        12'h31B: O_bits = 8'h0C;  // '1' row11
        12'h31C: O_bits = 8'h0E;  // '1' row12
        12'h31D: O_bits = 8'h7F;  // '1' row13
        12'h31E: O_bits = 8'h00;  // '1' row14
        12'h31F: O_bits = 8'h00;  // '1' row15
        12'h320: O_bits = 8'h00;  // '2' row0
        12'h321: O_bits = 8'h00;  // '2' row1
        12'h322: O_bits = 8'h00;  // '2' row2
        12'h323: O_bits = 8'h3F;  // '2' row3
        12'h324: O_bits = 8'h33;  // '2' row4
        12'h325: O_bits = 8'h61;  // '2' row5
        12'h326: O_bits = 8'h01;  // '2' row6
        12'h327: O_bits = 8'h03;  // '2' row7
        12'h328: O_bits = 8'h07;  // '2' row8
        12'h329: O_bits = 8'h0E;  // '2' row9
        12'h32A: O_bits = 8'h1C;  // '2' row10
        12'h32B: O_bits = 8'h38;  // '2' row11
        12'h32C: O_bits = 8'h70;  // '2' row12
        12'h32D: O_bits = 8'h7F;  // '2' row13
        12'h32E: O_bits = 8'h00;  // '2' row14
        12'h32F: O_bits = 8'h00;  // '2' row15
        12'h330: O_bits = 8'h00;  // '3' row0
        12'h331: O_bits = 8'h00;  // '3' row1
        12'h332: O_bits = 8'h00;  // '3' row2
        12'h333: O_bits = 8'h7F;  // '3' row3
        12'h334: O_bits = 8'h03;  // '3' row4
        12'h335: O_bits = 8'h06;  // '3' row5
        12'h336: O_bits = 8'h0C;  // '3' row6
        12'h337: O_bits = 8'h1C;  // '3' row7
        12'h338: O_bits = 8'h1F;  // '3' row8
        12'h339: O_bits = 8'h01;  // '3' row9
        12'h33A: O_bits = 8'h01;  // '3' row10
        12'h33B: O_bits = 8'h61;  // '3' row11
        12'h33C: O_bits = 8'h73;  // '3' row12
        12'h33D: O_bits = 8'h3E;  // '3' row13
        12'h33E: O_bits = 8'h00;  // '3' row14
        12'h33F: O_bits = 8'h00;  // '3' row15
        12'h340: O_bits = 8'h00;  // '4' row0
        12'h341: O_bits = 8'h00;  // '4' row1
        12'h342: O_bits = 8'h00;  // '4' row2
        12'h343: O_bits = 8'h07;  // '4' row3
        12'h344: O_bits = 8'h0F;  // '4' row4
        12'h345: O_bits = 8'h0B;  // '4' row5
        12'h346: O_bits = 8'h1B;  // '4' row6
        12'h347: O_bits = 8'h33;  // '4' row7
        12'h348: O_bits = 8'h23;  // '4' row8
        12'h349: O_bits = 8'h63;  // '4' row9
        12'h34A: O_bits = 8'hFF;  // '4' row10
        12'h34B: O_bits = 8'h03;  // '4' row11
        12'h34C: O_bits = 8'h03;  // '4' row12
        12'h34D: O_bits = 8'h03;  // '4' row13
        12'h34E: O_bits = 8'h00;  // '4' row14
        12'h34F: O_bits = 8'h00;  // '4' row15
        12'h350: O_bits = 8'h00;  // '5' row0
        12'h351: O_bits = 8'h00;  // '5' row1
        12'h352: O_bits = 8'h00;  // '5' row2
        12'h353: O_bits = 8'h3F;  // '5' row3
        12'h354: O_bits = 8'h20;  // '5' row4
        12'h355: O_bits = 8'h20;  // '5' row5
        12'h356: O_bits = 8'h20;  // '5' row6
        12'h357: O_bits = 8'h7F;  // '5' row7
        12'h358: O_bits = 8'h73;  // '5' row8
        12'h359: O_bits = 8'h01;  // '5' row9
        12'h35A: O_bits = 8'h01;  // '5' row10
        12'h35B: O_bits = 8'h61;  // '5' row11
        12'h35C: O_bits = 8'h73;  // '5' row12
        12'h35D: O_bits = 8'h3E;  // '5' row13
        12'h35E: O_bits = 8'h00;  // '5' row14
        12'h35F: O_bits = 8'h00;  // '5' row15
        12'h360: O_bits = 8'h00;  // '6' row0
        12'h361: O_bits = 8'h00;  // '6' row1
        12'h362: O_bits = 8'h00;  // '6' row2
        12'h363: O_bits = 8'h06;  // '6' row3
        12'h364: O_bits = 8'h0C;  // '6' row4
        12'h365: O_bits = 8'h18;  // '6' row5
        12'h366: O_bits = 8'h1C;  // '6' row6
        12'h367: O_bits = 8'h3F;  // '6' row7
        12'h368: O_bits = 8'h61;  // '6' row8
        12'h369: O_bits = 8'h61;  // '6' row9
        12'h36A: O_bits = 8'h61;  // '6' row10
        12'h36B: O_bits = 8'h61;  // '6' row11
        12'h36C: O_bits = 8'h33;  // '6' row12
        12'h36D: O_bits = 8'h1E;  // '6' row13
        12'h36E: O_bits = 8'h00;  // '6' row14
        12'h36F: O_bits = 8'h00;  // '6' row15
        12'h370: O_bits = 8'h00;  // '7' row0
        12'h371: O_bits = 8'h00;  // '7' row1
        12'h372: O_bits = 8'h00;  // '7' row2
        12'h373: O_bits = 8'h7F;  // '7' row3
        12'h374: O_bits = 8'h01;  // '7' row4
        12'h375: O_bits = 8'h03;  // '7' row5
        12'h376: O_bits = 8'h03;  // '7' row6
        12'h377: O_bits = 8'h06;  // '7' row7
        12'h378: O_bits = 8'h06;  // '7' row8
        12'h379: O_bits = 8'h04;  // '7' row9
        12'h37A: O_bits = 8'h0C;  // '7' row10
        12'h37B: O_bits = 8'h0C;  // '7' row11
        12'h37C: O_bits = 8'h18;  // '7' row12
        12'h37D: O_bits = 8'h18;  // '7' row13
        12'h37E: O_bits = 8'h00;  // '7' row14
        12'h37F: O_bits = 8'h00;  // '7' row15
        12'h380: O_bits = 8'h00;  // '8' row0
        12'h381: O_bits = 8'h00;  // '8' row1
        12'h382: O_bits = 8'h00;  // '8' row2
        12'h383: O_bits = 8'h3F;  // '8' row3
        12'h384: O_bits = 8'h61;  // '8' row4
        12'h385: O_bits = 8'h61;  // '8' row5
        12'h386: O_bits = 8'h61;  // '8' row6
        12'h387: O_bits = 8'h3F;  // '8' row7
        12'h388: O_bits = 8'h3F;  // '8' row8
        12'h389: O_bits = 8'h61;  // '8' row9
        12'h38A: O_bits = 8'h41;  // '8' row10
        12'h38B: O_bits = 8'h61;  // '8' row11
        12'h38C: O_bits = 8'h73;  // '8' row12
        12'h38D: O_bits = 8'h3F;  // '8' row13
        12'h38E: O_bits = 8'h00;  // '8' row14
        12'h38F: O_bits = 8'h00;  // '8' row15
        12'h390: O_bits = 8'h00;  // '9' row0
        12'h391: O_bits = 8'h00;  // '9' row1
        12'h392: O_bits = 8'h00;  // '9' row2
        12'h393: O_bits = 8'h3F;  // '9' row3
        12'h394: O_bits = 8'h73;  // '9' row4
        12'h395: O_bits = 8'h61;  // '9' row5
        12'h396: O_bits = 8'h61;  // '9' row6
        12'h397: O_bits = 8'h61;  // '9' row7
        12'h398: O_bits = 8'h73;  // '9' row8
        12'h399: O_bits = 8'h3F;  // '9' row9
        12'h39A: O_bits = 8'h06;  // '9' row10
        12'h39B: O_bits = 8'h0C;  // '9' row11
        12'h39C: O_bits = 8'h0C;  // '9' row12
        12'h39D: O_bits = 8'h18;  // '9' row13
        12'h39E: O_bits = 8'h00;  // '9' row14
        12'h39F: O_bits = 8'h00;  // '9' row15
        12'h410: O_bits = 8'h00;  // 'A' row0
        12'h411: O_bits = 8'h00;  // 'A' row1
        12'h412: O_bits = 8'h00;  // 'A' row2
        12'h413: O_bits = 8'h0E;  // 'A' row3
        12'h414: O_bits = 8'h0E;  // 'A' row4
        12'h415: O_bits = 8'h1A;  // 'A' row5
        12'h416: O_bits = 8'h1B;  // 'A' row6
        12'h417: O_bits = 8'h13;  // 'A' row7
        12'h418: O_bits = 8'h31;  // 'A' row8
        12'h419: O_bits = 8'h21;  // 'A' row9
        12'h41A: O_bits = 8'h7F;  // 'A' row10
        12'h41B: O_bits = 8'h7F;  // 'A' row11
        12'h41C: O_bits = 8'h40;  // 'A' row12
        12'h41D: O_bits = 8'hC0;  // 'A' row13
        12'h41E: O_bits = 8'h00;  // 'A' row14
        12'h41F: O_bits = 8'h00;  // 'A' row15
        12'h420: O_bits = 8'h00;  // 'B' row0
        12'h421: O_bits = 8'h00;  // 'B' row1
        12'h422: O_bits = 8'h00;  // 'B' row2
        12'h423: O_bits = 8'h7F;  // 'B' row3
        12'h424: O_bits = 8'h61;  // 'B' row4
        12'h425: O_bits = 8'h60;  // 'B' row5
        12'h426: O_bits = 8'h60;  // 'B' row6
        12'h427: O_bits = 8'h7F;  // 'B' row7
        12'h428: O_bits = 8'h7F;  // 'B' row8
        12'h429: O_bits = 8'h60;  // 'B' row9
        12'h42A: O_bits = 8'h60;  // 'B' row10
        12'h42B: O_bits = 8'h60;  // 'B' row11
        12'h42C: O_bits = 8'h63;  // 'B' row12
        12'h42D: O_bits = 8'h7F;  // 'B' row13
        12'h42E: O_bits = 8'h00;  // 'B' row14
        12'h42F: O_bits = 8'h00;  // 'B' row15
        12'h430: O_bits = 8'h00;  // 'C' row0
        12'h431: O_bits = 8'h00;  // 'C' row1
        12'h432: O_bits = 8'h00;  // 'C' row2
        12'h433: O_bits = 8'h1F;  // 'C' row3
        12'h434: O_bits = 8'h31;  // 'C' row4
        12'h435: O_bits = 8'h60;  // 'C' row5
        12'h436: O_bits = 8'h60;  // 'C' row6
        12'h437: O_bits = 8'h60;  // 'C' row7
        12'h438: O_bits = 8'h60;  // 'C' row8
        12'h439: O_bits = 8'h60;  // 'C' row9
        12'h43A: O_bits = 8'h60;  // 'C' row10
        12'h43B: O_bits = 8'h60;  // 'C' row11
        12'h43C: O_bits = 8'h3B;  // 'C' row12
        12'h43D: O_bits = 8'h1F;  // 'C' row13
        12'h43E: O_bits = 8'h00;  // 'C' row14
        12'h43F: O_bits = 8'h00;  // 'C' row15
        12'h440: O_bits = 8'h00;  // 'D' row0
        12'h441: O_bits = 8'h00;  // 'D' row1
        12'h442: O_bits = 8'h00;  // 'D' row2
        12'h443: O_bits = 8'h7F;  // 'D' row3
        12'h444: O_bits = 8'h63;  // 'D' row4
        12'h445: O_bits = 8'h60;  // 'D' row5
        12'h446: O_bits = 8'h60;  // 'D' row6
        12'h447: O_bits = 8'h60;  // 'D' row7
        12'h448: O_bits = 8'h60;  // 'D' row8
        12'h449: O_bits = 8'h60;  // 'D' row9
        12'h44A: O_bits = 8'h60;  // 'D' row10
        12'h44B: O_bits = 8'h60;  // 'D' row11
        12'h44C: O_bits = 8'h63;  // 'D' row12
        12'h44D: O_bits = 8'h7F;  // 'D' row13
        12'h44E: O_bits = 8'h00;  // 'D' row14
        12'h44F: O_bits = 8'h00;  // 'D' row15
        12'h450: O_bits = 8'h00;  // 'E' row0
        12'h451: O_bits = 8'h00;  // 'E' row1
        12'h452: O_bits = 8'h00;  // 'E' row2
        12'h453: O_bits = 8'h7F;  // 'E' row3
        12'h454: O_bits = 8'h60;  // 'E' row4
        12'h455: O_bits = 8'h60;  // 'E' row5
        12'h456: O_bits = 8'h60;  // 'E' row6
        12'h457: O_bits = 8'h60;  // 'E' row7
        12'h458: O_bits = 8'h7F;  // 'E' row8
        12'h459: O_bits = 8'h60;  // 'E' row9
        12'h45A: O_bits = 8'h60;  // 'E' row10
        12'h45B: O_bits = 8'h60;  // 'E' row11
        12'h45C: O_bits = 8'h60;  // 'E' row12
        12'h45D: O_bits = 8'h7F;  // 'E' row13
        12'h45E: O_bits = 8'h00;  // 'E' row14
        12'h45F: O_bits = 8'h00;  // 'E' row15
        12'h460: O_bits = 8'h00;  // 'F' row0
        12'h461: O_bits = 8'h00;  // 'F' row1
        12'h462: O_bits = 8'h00;  // 'F' row2
        12'h463: O_bits = 8'h7F;  // 'F' row3
        12'h464: O_bits = 8'h60;  // 'F' row4
        12'h465: O_bits = 8'h60;  // 'F' row5
        12'h466: O_bits = 8'h60;  // 'F' row6
        12'h467: O_bits = 8'h60;  // 'F' row7
        12'h468: O_bits = 8'h7F;  // 'F' row8
        12'h469: O_bits = 8'h60;  // 'F' row9
        12'h46A: O_bits = 8'h60;  // 'F' row10
        12'h46B: O_bits = 8'h60;  // 'F' row11
        12'h46C: O_bits = 8'h60;  // 'F' row12
        12'h46D: O_bits = 8'h60;  // 'F' row13
        12'h46E: O_bits = 8'h00;  // 'F' row14
        12'h46F: O_bits = 8'h00;  // 'F' row15
        12'h470: O_bits = 8'h00;  // 'G' row0
        12'h471: O_bits = 8'h00;  // 'G' row1
        12'h472: O_bits = 8'h00;  // 'G' row2
        12'h473: O_bits = 8'h1F;  // 'G' row3
        12'h474: O_bits = 8'h31;  // 'G' row4
        12'h475: O_bits = 8'h60;  // 'G' row5
        12'h476: O_bits = 8'h60;  // 'G' row6
        12'h477: O_bits = 8'h60;  // 'G' row7
        12'h478: O_bits = 8'h63;  // 'G' row8
        12'h479: O_bits = 8'h60;  // 'G' row9
        12'h47A: O_bits = 8'h60;  // 'G' row10
        12'h47B: O_bits = 8'h60;  // 'G' row11
        12'h47C: O_bits = 8'h39;  // 'G' row12
        12'h47D: O_bits = 8'h1F;  // 'G' row13
        12'h47E: O_bits = 8'h00;  // 'G' row14
        12'h47F: O_bits = 8'h00;  // 'G' row15
        12'h480: O_bits = 8'h00;  // 'H' row0
        12'h481: O_bits = 8'h00;  // 'H' row1
        12'h482: O_bits = 8'h00;  // 'H' row2
        12'h483: O_bits = 8'h60;  // 'H' row3
        12'h484: O_bits = 8'h60;  // 'H' row4
        12'h485: O_bits = 8'h60;  // 'H' row5
        12'h486: O_bits = 8'h60;  // 'H' row6
        12'h487: O_bits = 8'h60;  // 'H' row7
        12'h488: O_bits = 8'h7F;  // 'H' row8
        12'h489: O_bits = 8'h60;  // 'H' row9
        12'h48A: O_bits = 8'h60;  // 'H' row10
        12'h48B: O_bits = 8'h60;  // 'H' row11
        12'h48C: O_bits = 8'h60;  // 'H' row12
        12'h48D: O_bits = 8'h60;  // 'H' row13
        12'h48E: O_bits = 8'h00;  // 'H' row14
        12'h48F: O_bits = 8'h00;  // 'H' row15
        12'h490: O_bits = 8'h00;  // 'I' row0
        12'h491: O_bits = 8'h00;  // 'I' row1
        12'h492: O_bits = 8'h00;  // 'I' row2
        12'h493: O_bits = 8'h60;  // 'I' row3
        12'h494: O_bits = 8'h60;  // 'I' row4
        12'h495: O_bits = 8'h60;  // 'I' row5
        12'h496: O_bits = 8'h60;  // 'I' row6
        12'h497: O_bits = 8'h60;  // 'I' row7
        12'h498: O_bits = 8'h60;  // 'I' row8
        12'h499: O_bits = 8'h60;  // 'I' row9
        12'h49A: O_bits = 8'h60;  // 'I' row10
        12'h49B: O_bits = 8'h60;  // 'I' row11
        12'h49C: O_bits = 8'h60;  // 'I' row12
        12'h49D: O_bits = 8'h60;  // 'I' row13
        12'h49E: O_bits = 8'h00;  // 'I' row14
        12'h49F: O_bits = 8'h00;  // 'I' row15
        12'h4A0: O_bits = 8'h00;  // 'J' row0
        12'h4A1: O_bits = 8'h00;  // 'J' row1
        12'h4A2: O_bits = 8'h00;  // 'J' row2
        12'h4A3: O_bits = 8'h7F;  // 'J' row3
        12'h4A4: O_bits = 8'h01;  // 'J' row4
        12'h4A5: O_bits = 8'h01;  // 'J' row5
        12'h4A6: O_bits = 8'h01;  // 'J' row6
        12'h4A7: O_bits = 8'h01;  // 'J' row7
        12'h4A8: O_bits = 8'h01;  // 'J' row8
        12'h4A9: O_bits = 8'h01;  // 'J' row9
        12'h4AA: O_bits = 8'h41;  // 'J' row10
        12'h4AB: O_bits = 8'h61;  // 'J' row11
        12'h4AC: O_bits = 8'h77;  // 'J' row12
        12'h4AD: O_bits = 8'h3E;  // 'J' row13
        12'h4AE: O_bits = 8'h00;  // 'J' row14
        12'h4AF: O_bits = 8'h00;  // 'J' row15
        12'h4B0: O_bits = 8'h00;  // 'K' row0
        12'h4B1: O_bits = 8'h00;  // 'K' row1
        12'h4B2: O_bits = 8'h00;  // 'K' row2
        12'h4B3: O_bits = 8'h61;  // 'K' row3
        12'h4B4: O_bits = 8'h63;  // 'K' row4
        12'h4B5: O_bits = 8'h66;  // 'K' row5
        12'h4B6: O_bits = 8'h6C;  // 'K' row6
        12'h4B7: O_bits = 8'h78;  // 'K' row7
        12'h4B8: O_bits = 8'h70;  // 'K' row8
        12'h4B9: O_bits = 8'h78;  // 'K' row9
        12'h4BA: O_bits = 8'h6C;  // 'K' row10
        12'h4BB: O_bits = 8'h66;  // 'K' row11
        12'h4BC: O_bits = 8'h63;  // 'K' row12
        12'h4BD: O_bits = 8'h61;  // 'K' row13
        12'h4BE: O_bits = 8'h00;  // 'K' row14
        12'h4BF: O_bits = 8'h00;  // 'K' row15
        12'h4C0: O_bits = 8'h00;  // 'L' row0
        12'h4C1: O_bits = 8'h00;  // 'L' row1
        12'h4C2: O_bits = 8'h00;  // 'L' row2
        12'h4C3: O_bits = 8'h60;  // 'L' row3
        12'h4C4: O_bits = 8'h60;  // 'L' row4
        12'h4C5: O_bits = 8'h60;  // 'L' row5
        12'h4C6: O_bits = 8'h60;  // 'L' row6
        12'h4C7: O_bits = 8'h60;  // 'L' row7
        12'h4C8: O_bits = 8'h60;  // 'L' row8
        12'h4C9: O_bits = 8'h60;  // 'L' row9
        12'h4CA: O_bits = 8'h60;  // 'L' row10
        12'h4CB: O_bits = 8'h60;  // 'L' row11
        12'h4CC: O_bits = 8'h60;  // 'L' row12
        12'h4CD: O_bits = 8'h7F;  // 'L' row13
        12'h4CE: O_bits = 8'h00;  // 'L' row14
        12'h4CF: O_bits = 8'h00;  // 'L' row15
        12'h4D0: O_bits = 8'h00;  // 'M' row0
        12'h4D1: O_bits = 8'h00;  // 'M' row1
        12'h4D2: O_bits = 8'h00;  // 'M' row2
        12'h4D3: O_bits = 8'h60;  // 'M' row3
        12'h4D4: O_bits = 8'h70;  // 'M' row4
        12'h4D5: O_bits = 8'h70;  // 'M' row5
        12'h4D6: O_bits = 8'h78;  // 'M' row6
        12'h4D7: O_bits = 8'h69;  // 'M' row7
        12'h4D8: O_bits = 8'h6D;  // 'M' row8
        12'h4D9: O_bits = 8'h67;  // 'M' row9
        12'h4DA: O_bits = 8'h66;  // 'M' row10
        12'h4DB: O_bits = 8'h60;  // 'M' row11
        12'h4DC: O_bits = 8'h60;  // 'M' row12
        12'h4DD: O_bits = 8'h60;  // 'M' row13
        12'h4DE: O_bits = 8'h00;  // 'M' row14
        12'h4DF: O_bits = 8'h00;  // 'M' row15
        12'h4E0: O_bits = 8'h00;  // 'N' row0
        12'h4E1: O_bits = 8'h00;  // 'N' row1
        12'h4E2: O_bits = 8'h00;  // 'N' row2
        12'h4E3: O_bits = 8'h60;  // 'N' row3
        12'h4E4: O_bits = 8'h70;  // 'N' row4
        12'h4E5: O_bits = 8'h78;  // 'N' row5
        12'h4E6: O_bits = 8'h78;  // 'N' row6
        12'h4E7: O_bits = 8'h6C;  // 'N' row7
        12'h4E8: O_bits = 8'h66;  // 'N' row8
        12'h4E9: O_bits = 8'h66;  // 'N' row9
        12'h4EA: O_bits = 8'h63;  // 'N' row10
        12'h4EB: O_bits = 8'h61;  // 'N' row11
        12'h4EC: O_bits = 8'h61;  // 'N' row12
        12'h4ED: O_bits = 8'h60;  // 'N' row13
        12'h4EE: O_bits = 8'h00;  // 'N' row14
        12'h4EF: O_bits = 8'h00;  // 'N' row15
        12'h4F0: O_bits = 8'h00;  // 'O' row0
        12'h4F1: O_bits = 8'h00;  // 'O' row1
        12'h4F2: O_bits = 8'h00;  // 'O' row2
        12'h4F3: O_bits = 8'h1F;  // 'O' row3
        12'h4F4: O_bits = 8'h31;  // 'O' row4
        12'h4F5: O_bits = 8'h60;  // 'O' row5
        12'h4F6: O_bits = 8'h60;  // 'O' row6
        12'h4F7: O_bits = 8'h60;  // 'O' row7
        12'h4F8: O_bits = 8'h60;  // 'O' row8
        12'h4F9: O_bits = 8'h60;  // 'O' row9
        12'h4FA: O_bits = 8'h60;  // 'O' row10
        12'h4FB: O_bits = 8'h60;  // 'O' row11
        12'h4FC: O_bits = 8'h3B;  // 'O' row12
        12'h4FD: O_bits = 8'h1F;  // 'O' row13
        12'h4FE: O_bits = 8'h00;  // 'O' row14
        12'h4FF: O_bits = 8'h00;  // 'O' row15
        12'h500: O_bits = 8'h00;  // 'P' row0
        12'h501: O_bits = 8'h00;  // 'P' row1
        12'h502: O_bits = 8'h00;  // 'P' row2
        12'h503: O_bits = 8'h7F;  // 'P' row3
        12'h504: O_bits = 8'h61;  // 'P' row4
        12'h505: O_bits = 8'h60;  // 'P' row5
        12'h506: O_bits = 8'h60;  // 'P' row6
        12'h507: O_bits = 8'h61;  // 'P' row7
        12'h508: O_bits = 8'h7F;  // 'P' row8
        12'h509: O_bits = 8'h7E;  // 'P' row9
        12'h50A: O_bits = 8'h60;  // 'P' row10
        12'h50B: O_bits = 8'h60;  // 'P' row11
        12'h50C: O_bits = 8'h60;  // 'P' row12
        12'h50D: O_bits = 8'h60;  // 'P' row13
        12'h50E: O_bits = 8'h00;  // 'P' row14
        12'h50F: O_bits = 8'h00;  // 'P' row15
        12'h510: O_bits = 8'h00;  // 'Q' row0
        12'h511: O_bits = 8'h00;  // 'Q' row1
        12'h512: O_bits = 8'h00;  // 'Q' row2
        12'h513: O_bits = 8'h1F;  // 'Q' row3
        12'h514: O_bits = 8'h31;  // 'Q' row4
        12'h515: O_bits = 8'h60;  // 'Q' row5
        12'h516: O_bits = 8'h60;  // 'Q' row6
        12'h517: O_bits = 8'h60;  // 'Q' row7
        12'h518: O_bits = 8'h60;  // 'Q' row8
        12'h519: O_bits = 8'h60;  // 'Q' row9
        12'h51A: O_bits = 8'h60;  // 'Q' row10
        12'h51B: O_bits = 8'h60;  // 'Q' row11
        12'h51C: O_bits = 8'h3B;  // 'Q' row12
        12'h51D: O_bits = 8'h1F;  // 'Q' row13
        12'h51E: O_bits = 8'h00;  // 'Q' row14
        12'h51F: O_bits = 8'h00;  // 'Q' row15
        12'h520: O_bits = 8'h00;  // 'R' row0
        12'h521: O_bits = 8'h00;  // 'R' row1
        12'h522: O_bits = 8'h00;  // 'R' row2
        12'h523: O_bits = 8'h7F;  // 'R' row3
        12'h524: O_bits = 8'h61;  // 'R' row4
        12'h525: O_bits = 8'h60;  // 'R' row5
        12'h526: O_bits = 8'h60;  // 'R' row6
        12'h527: O_bits = 8'h61;  // 'R' row7
        12'h528: O_bits = 8'h7F;  // 'R' row8
        12'h529: O_bits = 8'h7F;  // 'R' row9
        12'h52A: O_bits = 8'h63;  // 'R' row10
        12'h52B: O_bits = 8'h61;  // 'R' row11
        12'h52C: O_bits = 8'h61;  // 'R' row12
        12'h52D: O_bits = 8'h60;  // 'R' row13
        12'h52E: O_bits = 8'h00;  // 'R' row14
        12'h52F: O_bits = 8'h00;  // 'R' row15
        12'h530: O_bits = 8'h00;  // 'S' row0
        12'h531: O_bits = 8'h00;  // 'S' row1
        12'h532: O_bits = 8'h00;  // 'S' row2
        12'h533: O_bits = 8'h3F;  // 'S' row3
        12'h534: O_bits = 8'h63;  // 'S' row4
        12'h535: O_bits = 8'h61;  // 'S' row5
        12'h536: O_bits = 8'h60;  // 'S' row6
        12'h537: O_bits = 8'h38;  // 'S' row7
        12'h538: O_bits = 8'h1F;  // 'S' row8
        12'h539: O_bits = 8'h03;  // 'S' row9
        12'h53A: O_bits = 8'h01;  // 'S' row10
        12'h53B: O_bits = 8'h61;  // 'S' row11
        12'h53C: O_bits = 8'h73;  // 'S' row12
        12'h53D: O_bits = 8'h3F;  // 'S' row13
        12'h53E: O_bits = 8'h00;  // 'S' row14
        12'h53F: O_bits = 8'h00;  // 'S' row15
        12'h540: O_bits = 8'h00;  // 'T' row0
        12'h541: O_bits = 8'h00;  // 'T' row1
        12'h542: O_bits = 8'h00;  // 'T' row2
        12'h543: O_bits = 8'hFF;  // 'T' row3
        12'h544: O_bits = 8'h0C;  // 'T' row4
        12'h545: O_bits = 8'h08;  // 'T' row5
        12'h546: O_bits = 8'h08;  // 'T' row6
        12'h547: O_bits = 8'h08;  // 'T' row7
        12'h548: O_bits = 8'h08;  // 'T' row8
        12'h549: O_bits = 8'h08;  // 'T' row9
        12'h54A: O_bits = 8'h08;  // 'T' row10
        12'h54B: O_bits = 8'h08;  // 'T' row11
        12'h54C: O_bits = 8'h08;  // 'T' row12
        12'h54D: O_bits = 8'h08;  // 'T' row13
        12'h54E: O_bits = 8'h00;  // 'T' row14
        12'h54F: O_bits = 8'h00;  // 'T' row15
        12'h550: O_bits = 8'h00;  // 'U' row0
        12'h551: O_bits = 8'h00;  // 'U' row1
        12'h552: O_bits = 8'h00;  // 'U' row2
        12'h553: O_bits = 8'h60;  // 'U' row3
        12'h554: O_bits = 8'h60;  // 'U' row4
        12'h555: O_bits = 8'h60;  // 'U' row5
        12'h556: O_bits = 8'h60;  // 'U' row6
        12'h557: O_bits = 8'h60;  // 'U' row7
        12'h558: O_bits = 8'h60;  // 'U' row8
        12'h559: O_bits = 8'h60;  // 'U' row9
        12'h55A: O_bits = 8'h60;  // 'U' row10
        12'h55B: O_bits = 8'h20;  // 'U' row11
        12'h55C: O_bits = 8'h3B;  // 'U' row12
        12'h55D: O_bits = 8'h1F;  // 'U' row13
        12'h55E: O_bits = 8'h00;  // 'U' row14
        12'h55F: O_bits = 8'h00;  // 'U' row15
        12'h560: O_bits = 8'h00;  // 'V' row0
        12'h561: O_bits = 8'h00;  // 'V' row1
        12'h562: O_bits = 8'h00;  // 'V' row2
        12'h563: O_bits = 8'h40;  // 'V' row3
        12'h564: O_bits = 8'h60;  // 'V' row4
        12'h565: O_bits = 8'h61;  // 'V' row5
        12'h566: O_bits = 8'h21;  // 'V' row6
        12'h567: O_bits = 8'h31;  // 'V' row7
        12'h568: O_bits = 8'h33;  // 'V' row8
        12'h569: O_bits = 8'h13;  // 'V' row9
        12'h56A: O_bits = 8'h1A;  // 'V' row10
        12'h56B: O_bits = 8'h1E;  // 'V' row11
        12'h56C: O_bits = 8'h0E;  // 'V' row12
        12'h56D: O_bits = 8'h0C;  // 'V' row13
        12'h56E: O_bits = 8'h00;  // 'V' row14
        12'h56F: O_bits = 8'h00;  // 'V' row15
        12'h570: O_bits = 8'h00;  // 'W' row0
        12'h571: O_bits = 8'h00;  // 'W' row1
        12'h572: O_bits = 8'h00;  // 'W' row2
        12'h573: O_bits = 8'h40;  // 'W' row3
        12'h574: O_bits = 8'h60;  // 'W' row4
        12'h575: O_bits = 8'h62;  // 'W' row5
        12'h576: O_bits = 8'h67;  // 'W' row6
        12'h577: O_bits = 8'h67;  // 'W' row7
        12'h578: O_bits = 8'h25;  // 'W' row8
        12'h579: O_bits = 8'h3D;  // 'W' row9
        12'h57A: O_bits = 8'h3D;  // 'W' row10
        12'h57B: O_bits = 8'h38;  // 'W' row11
        12'h57C: O_bits = 8'h38;  // 'W' row12
        12'h57D: O_bits = 8'h18;  // 'W' row13
        12'h57E: O_bits = 8'h00;  // 'W' row14
        12'h57F: O_bits = 8'h00;  // 'W' row15
        12'h580: O_bits = 8'h00;  // 'X' row0
        12'h581: O_bits = 8'h00;  // 'X' row1
        12'h582: O_bits = 8'h00;  // 'X' row2
        12'h583: O_bits = 8'h60;  // 'X' row3
        12'h584: O_bits = 8'h61;  // 'X' row4
        12'h585: O_bits = 8'h33;  // 'X' row5
        12'h586: O_bits = 8'h1E;  // 'X' row6
        12'h587: O_bits = 8'h1E;  // 'X' row7
        12'h588: O_bits = 8'h0C;  // 'X' row8
        12'h589: O_bits = 8'h1E;  // 'X' row9
        12'h58A: O_bits = 8'h33;  // 'X' row10
        12'h58B: O_bits = 8'h33;  // 'X' row11
        12'h58C: O_bits = 8'h61;  // 'X' row12
        12'h58D: O_bits = 8'hC0;  // 'X' row13
        12'h58E: O_bits = 8'h00;  // 'X' row14
        12'h58F: O_bits = 8'h00;  // 'X' row15
        12'h590: O_bits = 8'h00;  // 'Y' row0
        12'h591: O_bits = 8'h00;  // 'Y' row1
        12'h592: O_bits = 8'h00;  // 'Y' row2
        12'h593: O_bits = 8'h40;  // 'Y' row3
        12'h594: O_bits = 8'h61;  // 'Y' row4
        12'h595: O_bits = 8'h31;  // 'Y' row5
        12'h596: O_bits = 8'h33;  // 'Y' row6
        12'h597: O_bits = 8'h1A;  // 'Y' row7
        12'h598: O_bits = 8'h0E;  // 'Y' row8
        12'h599: O_bits = 8'h0C;  // 'Y' row9
        12'h59A: O_bits = 8'h0C;  // 'Y' row10
        12'h59B: O_bits = 8'h0C;  // 'Y' row11
        12'h59C: O_bits = 8'h0C;  // 'Y' row12
        12'h59D: O_bits = 8'h0C;  // 'Y' row13
        12'h59E: O_bits = 8'h00;  // 'Y' row14
        12'h59F: O_bits = 8'h00;  // 'Y' row15
        12'h5A0: O_bits = 8'h00;  // 'Z' row0
        12'h5A1: O_bits = 8'h00;  // 'Z' row1
        12'h5A2: O_bits = 8'h00;  // 'Z' row2
        12'h5A3: O_bits = 8'h7F;  // 'Z' row3
        12'h5A4: O_bits = 8'h03;  // 'Z' row4
        12'h5A5: O_bits = 8'h03;  // 'Z' row5
        12'h5A6: O_bits = 8'h06;  // 'Z' row6
        12'h5A7: O_bits = 8'h0C;  // 'Z' row7
        12'h5A8: O_bits = 8'h0C;  // 'Z' row8
        12'h5A9: O_bits = 8'h18;  // 'Z' row9
        12'h5AA: O_bits = 8'h30;  // 'Z' row10
        12'h5AB: O_bits = 8'h70;  // 'Z' row11
        12'h5AC: O_bits = 8'h60;  // 'Z' row12
        12'h5AD: O_bits = 8'h7F;  // 'Z' row13
        12'h5AE: O_bits = 8'h00;  // 'Z' row14
        12'h5AF: O_bits = 8'h00;  // 'Z' row15
        12'h3A0: O_bits = 8'h00;  // ':' row0
        12'h3A1: O_bits = 8'h00;  // ':' row1
        12'h3A2: O_bits = 8'h00;  // ':' row2
        12'h3A3: O_bits = 8'h00;  // ':' row3
        12'h3A4: O_bits = 8'h00;  // ':' row4
        12'h3A5: O_bits = 8'h00;  // ':' row5
        12'h3A6: O_bits = 8'h20;  // ':' row6
        12'h3A7: O_bits = 8'h60;  // ':' row7
        12'h3A8: O_bits = 8'h00;  // ':' row8
        12'h3A9: O_bits = 8'h00;  // ':' row9
        12'h3AA: O_bits = 8'h00;  // ':' row10
        12'h3AB: O_bits = 8'h00;  // ':' row11
        12'h3AC: O_bits = 8'h60;  // ':' row12
        12'h3AD: O_bits = 8'h60;  // ':' row13
        12'h3AE: O_bits = 8'h00;  // ':' row14
        12'h3AF: O_bits = 8'h00;  // ':' row15
        12'h2E0: O_bits = 8'h00;  // '.' row0
        12'h2E1: O_bits = 8'h00;  // '.' row1
        12'h2E2: O_bits = 8'h00;  // '.' row2
        12'h2E3: O_bits = 8'h00;  // '.' row3
        12'h2E4: O_bits = 8'h00;  // '.' row4
        12'h2E5: O_bits = 8'h00;  // '.' row5
        12'h2E6: O_bits = 8'h00;  // '.' row6
        12'h2E7: O_bits = 8'h00;  // '.' row7
        12'h2E8: O_bits = 8'h00;  // '.' row8
        12'h2E9: O_bits = 8'h00;  // '.' row9
        12'h2EA: O_bits = 8'h00;  // '.' row10
        12'h2EB: O_bits = 8'h00;  // '.' row11
        12'h2EC: O_bits = 8'h60;  // '.' row12
        12'h2ED: O_bits = 8'h60;  // '.' row13
        12'h2EE: O_bits = 8'h00;  // '.' row14
        12'h2EF: O_bits = 8'h00;  // '.' row15
        12'h2D0: O_bits = 8'h00;  // '-' row0
        12'h2D1: O_bits = 8'h00;  // '-' row1
        12'h2D2: O_bits = 8'h00;  // '-' row2
        12'h2D3: O_bits = 8'h00;  // '-' row3
        12'h2D4: O_bits = 8'h00;  // '-' row4
        12'h2D5: O_bits = 8'h00;  // '-' row5
        12'h2D6: O_bits = 8'h00;  // '-' row6
        12'h2D7: O_bits = 8'h00;  // '-' row7
        12'h2D8: O_bits = 8'h3C;  // '-' row8
        12'h2D9: O_bits = 8'h7E;  // '-' row9
        12'h2DA: O_bits = 8'h00;  // '-' row10
        12'h2DB: O_bits = 8'h00;  // '-' row11
        12'h2DC: O_bits = 8'h00;  // '-' row12
        12'h2DD: O_bits = 8'h00;  // '-' row13
        12'h2DE: O_bits = 8'h00;  // '-' row14
        12'h2DF: O_bits = 8'h00;  // '-' row15
        12'h2B0: O_bits = 8'h00;  // '+' row0
        12'h2B1: O_bits = 8'h00;  // '+' row1
        12'h2B2: O_bits = 8'h00;  // '+' row2
        12'h2B3: O_bits = 8'h00;  // '+' row3
        12'h2B4: O_bits = 8'h00;  // '+' row4
        12'h2B5: O_bits = 8'h0C;  // '+' row5
        12'h2B6: O_bits = 8'h0C;  // '+' row6
        12'h2B7: O_bits = 8'h0C;  // '+' row7
        12'h2B8: O_bits = 8'h7F;  // '+' row8
        12'h2B9: O_bits = 8'h7F;  // '+' row9
        12'h2BA: O_bits = 8'h0C;  // '+' row10
        12'h2BB: O_bits = 8'h0C;  // '+' row11
        12'h2BC: O_bits = 8'h0C;  // '+' row12
        12'h2BD: O_bits = 8'h00;  // '+' row13
        12'h2BE: O_bits = 8'h00;  // '+' row14
        12'h2BF: O_bits = 8'h00;  // '+' row15
        12'h2F0: O_bits = 8'h00;  // '/' row0
        12'h2F1: O_bits = 8'h02;  // '/' row1
        12'h2F2: O_bits = 8'h02;  // '/' row2
        12'h2F3: O_bits = 8'h06;  // '/' row3
        12'h2F4: O_bits = 8'h04;  // '/' row4
        12'h2F5: O_bits = 8'h0C;  // '/' row5
        12'h2F6: O_bits = 8'h08;  // '/' row6
        12'h2F7: O_bits = 8'h18;  // '/' row7
        12'h2F8: O_bits = 8'h18;  // '/' row8
        12'h2F9: O_bits = 8'h10;  // '/' row9
        12'h2FA: O_bits = 8'h30;  // '/' row10
        12'h2FB: O_bits = 8'h20;  // '/' row11
        12'h2FC: O_bits = 8'h60;  // '/' row12
        12'h2FD: O_bits = 8'h40;  // '/' row13
        12'h2FE: O_bits = 8'h40;  // '/' row14
        12'h2FF: O_bits = 8'h00;  // '/' row15
        default: O_bits = 8'h00;
    endcase
end
endmodule

// ===== [移植] marquee_rom_64.v —— 逐字复制，来源 08_board_bringup/02_td_synth_gate/marquee_rom_64.v，SHA256 885f8d1d58d8edf5 =====
// 自动生成：tools/gen_marquee_rom.py（由 case 版逐值转为数组 ROM，位值不变）
// 地址 {char_idx[5:0], row[3:0]} -> 该行 8 位点阵（MSB=最左像素）
// 2026-10-03 转换缘由：case 版被 TD 映射为 ~10 级 mux 树，是 74.25MHz 域
//   WNS -0.113ns 的唯一关键路径（gate 报告 8 个违规端点全部同源）；
//   数组 ROM 异步读映射为 LUTRAM（1-2 级），功能零变化（tb_osd_track 逐像素复验）。
module marquee_rom_64 (
    input  wire [9:0]  I_addr,
    output wire [7:0]  O_bits
);

    (* rom_style = "distributed" *) (* syn_ramstyle = "distributed" *) (* ramstyle = "distributed" *) reg [7:0] mem [0:1023];

    initial begin
        mem[10'h000] = 8'h00;  //'A' row0
        mem[10'h001] = 8'h00;  //'A' row1
        mem[10'h002] = 8'h00;  //'A' row2
        mem[10'h003] = 8'h0E;  //'A' row3
        mem[10'h004] = 8'h0E;  //'A' row4
        mem[10'h005] = 8'h1A;  //'A' row5
        mem[10'h006] = 8'h1B;  //'A' row6
        mem[10'h007] = 8'h13;  //'A' row7
        mem[10'h008] = 8'h31;  //'A' row8
        mem[10'h009] = 8'h21;  //'A' row9
        mem[10'h00A] = 8'h7F;  //'A' row10
        mem[10'h00B] = 8'h7F;  //'A' row11
        mem[10'h00C] = 8'h40;  //'A' row12
        mem[10'h00D] = 8'hC0;  //'A' row13
        mem[10'h00E] = 8'h00;  //'A' row14
        mem[10'h00F] = 8'h00;  //'A' row15
        mem[10'h010] = 8'h00;  //'N' row0
        mem[10'h011] = 8'h00;  //'N' row1
        mem[10'h012] = 8'h00;  //'N' row2
        mem[10'h013] = 8'h60;  //'N' row3
        mem[10'h014] = 8'h70;  //'N' row4
        mem[10'h015] = 8'h78;  //'N' row5
        mem[10'h016] = 8'h78;  //'N' row6
        mem[10'h017] = 8'h6C;  //'N' row7
        mem[10'h018] = 8'h66;  //'N' row8
        mem[10'h019] = 8'h66;  //'N' row9
        mem[10'h01A] = 8'h63;  //'N' row10
        mem[10'h01B] = 8'h61;  //'N' row11
        mem[10'h01C] = 8'h61;  //'N' row12
        mem[10'h01D] = 8'h60;  //'N' row13
        mem[10'h01E] = 8'h00;  //'N' row14
        mem[10'h01F] = 8'h00;  //'N' row15
        mem[10'h020] = 8'h00;  //'L' row0
        mem[10'h021] = 8'h00;  //'L' row1
        mem[10'h022] = 8'h00;  //'L' row2
        mem[10'h023] = 8'h60;  //'L' row3
        mem[10'h024] = 8'h60;  //'L' row4
        mem[10'h025] = 8'h60;  //'L' row5
        mem[10'h026] = 8'h60;  //'L' row6
        mem[10'h027] = 8'h60;  //'L' row7
        mem[10'h028] = 8'h60;  //'L' row8
        mem[10'h029] = 8'h60;  //'L' row9
        mem[10'h02A] = 8'h60;  //'L' row10
        mem[10'h02B] = 8'h60;  //'L' row11
        mem[10'h02C] = 8'h60;  //'L' row12
        mem[10'h02D] = 8'h7F;  //'L' row13
        mem[10'h02E] = 8'h00;  //'L' row14
        mem[10'h02F] = 8'h00;  //'L' row15
        mem[10'h030] = 8'h00;  //'O' row0
        mem[10'h031] = 8'h00;  //'O' row1
        mem[10'h032] = 8'h00;  //'O' row2
        mem[10'h033] = 8'h1F;  //'O' row3
        mem[10'h034] = 8'h31;  //'O' row4
        mem[10'h035] = 8'h60;  //'O' row5
        mem[10'h036] = 8'h60;  //'O' row6
        mem[10'h037] = 8'h60;  //'O' row7
        mem[10'h038] = 8'h60;  //'O' row8
        mem[10'h039] = 8'h60;  //'O' row9
        mem[10'h03A] = 8'h60;  //'O' row10
        mem[10'h03B] = 8'h60;  //'O' row11
        mem[10'h03C] = 8'h3B;  //'O' row12
        mem[10'h03D] = 8'h1F;  //'O' row13
        mem[10'h03E] = 8'h00;  //'O' row14
        mem[10'h03F] = 8'h00;  //'O' row15
        mem[10'h040] = 8'h00;  //'G' row0
        mem[10'h041] = 8'h00;  //'G' row1
        mem[10'h042] = 8'h00;  //'G' row2
        mem[10'h043] = 8'h1F;  //'G' row3
        mem[10'h044] = 8'h31;  //'G' row4
        mem[10'h045] = 8'h60;  //'G' row5
        mem[10'h046] = 8'h60;  //'G' row6
        mem[10'h047] = 8'h60;  //'G' row7
        mem[10'h048] = 8'h63;  //'G' row8
        mem[10'h049] = 8'h60;  //'G' row9
        mem[10'h04A] = 8'h60;  //'G' row10
        mem[10'h04B] = 8'h60;  //'G' row11
        mem[10'h04C] = 8'h39;  //'G' row12
        mem[10'h04D] = 8'h1F;  //'G' row13
        mem[10'h04E] = 8'h00;  //'G' row14
        mem[10'h04F] = 8'h00;  //'G' row15
        mem[10'h050] = 8'h00;  //'I' row0
        mem[10'h051] = 8'h00;  //'I' row1
        mem[10'h052] = 8'h00;  //'I' row2
        mem[10'h053] = 8'h60;  //'I' row3
        mem[10'h054] = 8'h60;  //'I' row4
        mem[10'h055] = 8'h60;  //'I' row5
        mem[10'h056] = 8'h60;  //'I' row6
        mem[10'h057] = 8'h60;  //'I' row7
        mem[10'h058] = 8'h60;  //'I' row8
        mem[10'h059] = 8'h60;  //'I' row9
        mem[10'h05A] = 8'h60;  //'I' row10
        mem[10'h05B] = 8'h60;  //'I' row11
        mem[10'h05C] = 8'h60;  //'I' row12
        mem[10'h05D] = 8'h60;  //'I' row13
        mem[10'h05E] = 8'h00;  //'I' row14
        mem[10'h05F] = 8'h00;  //'I' row15
        mem[10'h060] = 8'h00;  //'C' row0
        mem[10'h061] = 8'h00;  //'C' row1
        mem[10'h062] = 8'h00;  //'C' row2
        mem[10'h063] = 8'h1F;  //'C' row3
        mem[10'h064] = 8'h31;  //'C' row4
        mem[10'h065] = 8'h60;  //'C' row5
        mem[10'h066] = 8'h60;  //'C' row6
        mem[10'h067] = 8'h60;  //'C' row7
        mem[10'h068] = 8'h60;  //'C' row8
        mem[10'h069] = 8'h60;  //'C' row9
        mem[10'h06A] = 8'h60;  //'C' row10
        mem[10'h06B] = 8'h60;  //'C' row11
        mem[10'h06C] = 8'h3B;  //'C' row12
        mem[10'h06D] = 8'h1F;  //'C' row13
        mem[10'h06E] = 8'h00;  //'C' row14
        mem[10'h06F] = 8'h00;  //'C' row15
        mem[10'h070] = 8'h00;  //' ' row0
        mem[10'h071] = 8'h00;  //' ' row1
        mem[10'h072] = 8'h00;  //' ' row2
        mem[10'h073] = 8'h00;  //' ' row3
        mem[10'h074] = 8'h00;  //' ' row4
        mem[10'h075] = 8'h00;  //' ' row5
        mem[10'h076] = 8'h00;  //' ' row6
        mem[10'h077] = 8'h00;  //' ' row7
        mem[10'h078] = 8'h00;  //' ' row8
        mem[10'h079] = 8'h00;  //' ' row9
        mem[10'h07A] = 8'h00;  //' ' row10
        mem[10'h07B] = 8'h00;  //' ' row11
        mem[10'h07C] = 8'h00;  //' ' row12
        mem[10'h07D] = 8'h00;  //' ' row13
        mem[10'h07E] = 8'h00;  //' ' row14
        mem[10'h07F] = 8'h00;  //' ' row15
        mem[10'h080] = 8'h00;  //'P' row0
        mem[10'h081] = 8'h00;  //'P' row1
        mem[10'h082] = 8'h00;  //'P' row2
        mem[10'h083] = 8'h7F;  //'P' row3
        mem[10'h084] = 8'h61;  //'P' row4
        mem[10'h085] = 8'h60;  //'P' row5
        mem[10'h086] = 8'h60;  //'P' row6
        mem[10'h087] = 8'h61;  //'P' row7
        mem[10'h088] = 8'h7F;  //'P' row8
        mem[10'h089] = 8'h7E;  //'P' row9
        mem[10'h08A] = 8'h60;  //'P' row10
        mem[10'h08B] = 8'h60;  //'P' row11
        mem[10'h08C] = 8'h60;  //'P' row12
        mem[10'h08D] = 8'h60;  //'P' row13
        mem[10'h08E] = 8'h00;  //'P' row14
        mem[10'h08F] = 8'h00;  //'P' row15
        mem[10'h090] = 8'h00;  //'H' row0
        mem[10'h091] = 8'h00;  //'H' row1
        mem[10'h092] = 8'h00;  //'H' row2
        mem[10'h093] = 8'h60;  //'H' row3
        mem[10'h094] = 8'h60;  //'H' row4
        mem[10'h095] = 8'h60;  //'H' row5
        mem[10'h096] = 8'h60;  //'H' row6
        mem[10'h097] = 8'h60;  //'H' row7
        mem[10'h098] = 8'h7F;  //'H' row8
        mem[10'h099] = 8'h60;  //'H' row9
        mem[10'h09A] = 8'h60;  //'H' row10
        mem[10'h09B] = 8'h60;  //'H' row11
        mem[10'h09C] = 8'h60;  //'H' row12
        mem[10'h09D] = 8'h60;  //'H' row13
        mem[10'h09E] = 8'h00;  //'H' row14
        mem[10'h09F] = 8'h00;  //'H' row15
        mem[10'h0A0] = 8'h00;  //'1' row0
        mem[10'h0A1] = 8'h00;  //'1' row1
        mem[10'h0A2] = 8'h00;  //'1' row2
        mem[10'h0A3] = 8'h0C;  //'1' row3
        mem[10'h0A4] = 8'h3C;  //'1' row4
        mem[10'h0A5] = 8'h7C;  //'1' row5
        mem[10'h0A6] = 8'h0C;  //'1' row6
        mem[10'h0A7] = 8'h0C;  //'1' row7
        mem[10'h0A8] = 8'h0C;  //'1' row8
        mem[10'h0A9] = 8'h0C;  //'1' row9
        mem[10'h0AA] = 8'h0C;  //'1' row10
        mem[10'h0AB] = 8'h0C;  //'1' row11
        mem[10'h0AC] = 8'h0E;  //'1' row12
        mem[10'h0AD] = 8'h7F;  //'1' row13
        mem[10'h0AE] = 8'h00;  //'1' row14
        mem[10'h0AF] = 8'h00;  //'1' row15
        mem[10'h0B0] = 8'h00;  //'P' row0
        mem[10'h0B1] = 8'h00;  //'P' row1
        mem[10'h0B2] = 8'h00;  //'P' row2
        mem[10'h0B3] = 8'h7F;  //'P' row3
        mem[10'h0B4] = 8'h61;  //'P' row4
        mem[10'h0B5] = 8'h60;  //'P' row5
        mem[10'h0B6] = 8'h60;  //'P' row6
        mem[10'h0B7] = 8'h61;  //'P' row7
        mem[10'h0B8] = 8'h7F;  //'P' row8
        mem[10'h0B9] = 8'h7E;  //'P' row9
        mem[10'h0BA] = 8'h60;  //'P' row10
        mem[10'h0BB] = 8'h60;  //'P' row11
        mem[10'h0BC] = 8'h60;  //'P' row12
        mem[10'h0BD] = 8'h60;  //'P' row13
        mem[10'h0BE] = 8'h00;  //'P' row14
        mem[10'h0BF] = 8'h00;  //'P' row15
        mem[10'h0C0] = 8'h00;  //'3' row0
        mem[10'h0C1] = 8'h00;  //'3' row1
        mem[10'h0C2] = 8'h00;  //'3' row2
        mem[10'h0C3] = 8'h7F;  //'3' row3
        mem[10'h0C4] = 8'h03;  //'3' row4
        mem[10'h0C5] = 8'h06;  //'3' row5
        mem[10'h0C6] = 8'h0C;  //'3' row6
        mem[10'h0C7] = 8'h1C;  //'3' row7
        mem[10'h0C8] = 8'h1F;  //'3' row8
        mem[10'h0C9] = 8'h01;  //'3' row9
        mem[10'h0CA] = 8'h01;  //'3' row10
        mem[10'h0CB] = 8'h61;  //'3' row11
        mem[10'h0CC] = 8'h73;  //'3' row12
        mem[10'h0CD] = 8'h3E;  //'3' row13
        mem[10'h0CE] = 8'h00;  //'3' row14
        mem[10'h0CF] = 8'h00;  //'3' row15
        mem[10'h0D0] = 8'h00;  //'5' row0
        mem[10'h0D1] = 8'h00;  //'5' row1
        mem[10'h0D2] = 8'h00;  //'5' row2
        mem[10'h0D3] = 8'h3F;  //'5' row3
        mem[10'h0D4] = 8'h20;  //'5' row4
        mem[10'h0D5] = 8'h20;  //'5' row5
        mem[10'h0D6] = 8'h20;  //'5' row6
        mem[10'h0D7] = 8'h7F;  //'5' row7
        mem[10'h0D8] = 8'h73;  //'5' row8
        mem[10'h0D9] = 8'h01;  //'5' row9
        mem[10'h0DA] = 8'h01;  //'5' row10
        mem[10'h0DB] = 8'h61;  //'5' row11
        mem[10'h0DC] = 8'h73;  //'5' row12
        mem[10'h0DD] = 8'h3E;  //'5' row13
        mem[10'h0DE] = 8'h00;  //'5' row14
        mem[10'h0DF] = 8'h00;  //'5' row15
        mem[10'h0E0] = 8'h00;  //' ' row0
        mem[10'h0E1] = 8'h00;  //' ' row1
        mem[10'h0E2] = 8'h00;  //' ' row2
        mem[10'h0E3] = 8'h00;  //' ' row3
        mem[10'h0E4] = 8'h00;  //' ' row4
        mem[10'h0E5] = 8'h00;  //' ' row5
        mem[10'h0E6] = 8'h00;  //' ' row6
        mem[10'h0E7] = 8'h00;  //' ' row7
        mem[10'h0E8] = 8'h00;  //' ' row8
        mem[10'h0E9] = 8'h00;  //' ' row9
        mem[10'h0EA] = 8'h00;  //' ' row10
        mem[10'h0EB] = 8'h00;  //' ' row11
        mem[10'h0EC] = 8'h00;  //' ' row12
        mem[10'h0ED] = 8'h00;  //' ' row13
        mem[10'h0EE] = 8'h00;  //' ' row14
        mem[10'h0EF] = 8'h00;  //' ' row15
        mem[10'h0F0] = 8'h00;  //'F' row0
        mem[10'h0F1] = 8'h00;  //'F' row1
        mem[10'h0F2] = 8'h00;  //'F' row2
        mem[10'h0F3] = 8'h7F;  //'F' row3
        mem[10'h0F4] = 8'h60;  //'F' row4
        mem[10'h0F5] = 8'h60;  //'F' row5
        mem[10'h0F6] = 8'h60;  //'F' row6
        mem[10'h0F7] = 8'h60;  //'F' row7
        mem[10'h0F8] = 8'h7F;  //'F' row8
        mem[10'h0F9] = 8'h60;  //'F' row9
        mem[10'h0FA] = 8'h60;  //'F' row10
        mem[10'h0FB] = 8'h60;  //'F' row11
        mem[10'h0FC] = 8'h60;  //'F' row12
        mem[10'h0FD] = 8'h60;  //'F' row13
        mem[10'h0FE] = 8'h00;  //'F' row14
        mem[10'h0FF] = 8'h00;  //'F' row15
        mem[10'h100] = 8'h00;  //'P' row0
        mem[10'h101] = 8'h00;  //'P' row1
        mem[10'h102] = 8'h00;  //'P' row2
        mem[10'h103] = 8'h7F;  //'P' row3
        mem[10'h104] = 8'h61;  //'P' row4
        mem[10'h105] = 8'h60;  //'P' row5
        mem[10'h106] = 8'h60;  //'P' row6
        mem[10'h107] = 8'h61;  //'P' row7
        mem[10'h108] = 8'h7F;  //'P' row8
        mem[10'h109] = 8'h7E;  //'P' row9
        mem[10'h10A] = 8'h60;  //'P' row10
        mem[10'h10B] = 8'h60;  //'P' row11
        mem[10'h10C] = 8'h60;  //'P' row12
        mem[10'h10D] = 8'h60;  //'P' row13
        mem[10'h10E] = 8'h00;  //'P' row14
        mem[10'h10F] = 8'h00;  //'P' row15
        mem[10'h110] = 8'h00;  //'G' row0
        mem[10'h111] = 8'h00;  //'G' row1
        mem[10'h112] = 8'h00;  //'G' row2
        mem[10'h113] = 8'h1F;  //'G' row3
        mem[10'h114] = 8'h31;  //'G' row4
        mem[10'h115] = 8'h60;  //'G' row5
        mem[10'h116] = 8'h60;  //'G' row6
        mem[10'h117] = 8'h60;  //'G' row7
        mem[10'h118] = 8'h63;  //'G' row8
        mem[10'h119] = 8'h60;  //'G' row9
        mem[10'h11A] = 8'h60;  //'G' row10
        mem[10'h11B] = 8'h60;  //'G' row11
        mem[10'h11C] = 8'h39;  //'G' row12
        mem[10'h11D] = 8'h1F;  //'G' row13
        mem[10'h11E] = 8'h00;  //'G' row14
        mem[10'h11F] = 8'h00;  //'G' row15
        mem[10'h120] = 8'h00;  //'A' row0
        mem[10'h121] = 8'h00;  //'A' row1
        mem[10'h122] = 8'h00;  //'A' row2
        mem[10'h123] = 8'h0E;  //'A' row3
        mem[10'h124] = 8'h0E;  //'A' row4
        mem[10'h125] = 8'h1A;  //'A' row5
        mem[10'h126] = 8'h1B;  //'A' row6
        mem[10'h127] = 8'h13;  //'A' row7
        mem[10'h128] = 8'h31;  //'A' row8
        mem[10'h129] = 8'h21;  //'A' row9
        mem[10'h12A] = 8'h7F;  //'A' row10
        mem[10'h12B] = 8'h7F;  //'A' row11
        mem[10'h12C] = 8'h40;  //'A' row12
        mem[10'h12D] = 8'hC0;  //'A' row13
        mem[10'h12E] = 8'h00;  //'A' row14
        mem[10'h12F] = 8'h00;  //'A' row15
        mem[10'h130] = 8'h00;  //' ' row0
        mem[10'h131] = 8'h00;  //' ' row1
        mem[10'h132] = 8'h00;  //' ' row2
        mem[10'h133] = 8'h00;  //' ' row3
        mem[10'h134] = 8'h00;  //' ' row4
        mem[10'h135] = 8'h00;  //' ' row5
        mem[10'h136] = 8'h00;  //' ' row6
        mem[10'h137] = 8'h00;  //' ' row7
        mem[10'h138] = 8'h00;  //' ' row8
        mem[10'h139] = 8'h00;  //' ' row9
        mem[10'h13A] = 8'h00;  //' ' row10
        mem[10'h13B] = 8'h00;  //' ' row11
        mem[10'h13C] = 8'h00;  //' ' row12
        mem[10'h13D] = 8'h00;  //' ' row13
        mem[10'h13E] = 8'h00;  //' ' row14
        mem[10'h13F] = 8'h00;  //' ' row15
        mem[10'h140] = 8'h00;  //'V' row0
        mem[10'h141] = 8'h00;  //'V' row1
        mem[10'h142] = 8'h00;  //'V' row2
        mem[10'h143] = 8'h40;  //'V' row3
        mem[10'h144] = 8'h60;  //'V' row4
        mem[10'h145] = 8'h61;  //'V' row5
        mem[10'h146] = 8'h21;  //'V' row6
        mem[10'h147] = 8'h31;  //'V' row7
        mem[10'h148] = 8'h33;  //'V' row8
        mem[10'h149] = 8'h13;  //'V' row9
        mem[10'h14A] = 8'h1A;  //'V' row10
        mem[10'h14B] = 8'h1E;  //'V' row11
        mem[10'h14C] = 8'h0E;  //'V' row12
        mem[10'h14D] = 8'h0C;  //'V' row13
        mem[10'h14E] = 8'h00;  //'V' row14
        mem[10'h14F] = 8'h00;  //'V' row15
        mem[10'h150] = 8'h00;  //'I' row0
        mem[10'h151] = 8'h00;  //'I' row1
        mem[10'h152] = 8'h00;  //'I' row2
        mem[10'h153] = 8'h60;  //'I' row3
        mem[10'h154] = 8'h60;  //'I' row4
        mem[10'h155] = 8'h60;  //'I' row5
        mem[10'h156] = 8'h60;  //'I' row6
        mem[10'h157] = 8'h60;  //'I' row7
        mem[10'h158] = 8'h60;  //'I' row8
        mem[10'h159] = 8'h60;  //'I' row9
        mem[10'h15A] = 8'h60;  //'I' row10
        mem[10'h15B] = 8'h60;  //'I' row11
        mem[10'h15C] = 8'h60;  //'I' row12
        mem[10'h15D] = 8'h60;  //'I' row13
        mem[10'h15E] = 8'h00;  //'I' row14
        mem[10'h15F] = 8'h00;  //'I' row15
        mem[10'h160] = 8'h00;  //'S' row0
        mem[10'h161] = 8'h00;  //'S' row1
        mem[10'h162] = 8'h00;  //'S' row2
        mem[10'h163] = 8'h3F;  //'S' row3
        mem[10'h164] = 8'h63;  //'S' row4
        mem[10'h165] = 8'h61;  //'S' row5
        mem[10'h166] = 8'h60;  //'S' row6
        mem[10'h167] = 8'h38;  //'S' row7
        mem[10'h168] = 8'h1F;  //'S' row8
        mem[10'h169] = 8'h03;  //'S' row9
        mem[10'h16A] = 8'h01;  //'S' row10
        mem[10'h16B] = 8'h61;  //'S' row11
        mem[10'h16C] = 8'h73;  //'S' row12
        mem[10'h16D] = 8'h3F;  //'S' row13
        mem[10'h16E] = 8'h00;  //'S' row14
        mem[10'h16F] = 8'h00;  //'S' row15
        mem[10'h170] = 8'h00;  //'I' row0
        mem[10'h171] = 8'h00;  //'I' row1
        mem[10'h172] = 8'h00;  //'I' row2
        mem[10'h173] = 8'h60;  //'I' row3
        mem[10'h174] = 8'h60;  //'I' row4
        mem[10'h175] = 8'h60;  //'I' row5
        mem[10'h176] = 8'h60;  //'I' row6
        mem[10'h177] = 8'h60;  //'I' row7
        mem[10'h178] = 8'h60;  //'I' row8
        mem[10'h179] = 8'h60;  //'I' row9
        mem[10'h17A] = 8'h60;  //'I' row10
        mem[10'h17B] = 8'h60;  //'I' row11
        mem[10'h17C] = 8'h60;  //'I' row12
        mem[10'h17D] = 8'h60;  //'I' row13
        mem[10'h17E] = 8'h00;  //'I' row14
        mem[10'h17F] = 8'h00;  //'I' row15
        mem[10'h180] = 8'h00;  //'O' row0
        mem[10'h181] = 8'h00;  //'O' row1
        mem[10'h182] = 8'h00;  //'O' row2
        mem[10'h183] = 8'h1F;  //'O' row3
        mem[10'h184] = 8'h31;  //'O' row4
        mem[10'h185] = 8'h60;  //'O' row5
        mem[10'h186] = 8'h60;  //'O' row6
        mem[10'h187] = 8'h60;  //'O' row7
        mem[10'h188] = 8'h60;  //'O' row8
        mem[10'h189] = 8'h60;  //'O' row9
        mem[10'h18A] = 8'h60;  //'O' row10
        mem[10'h18B] = 8'h60;  //'O' row11
        mem[10'h18C] = 8'h3B;  //'O' row12
        mem[10'h18D] = 8'h1F;  //'O' row13
        mem[10'h18E] = 8'h00;  //'O' row14
        mem[10'h18F] = 8'h00;  //'O' row15
        mem[10'h190] = 8'h00;  //'N' row0
        mem[10'h191] = 8'h00;  //'N' row1
        mem[10'h192] = 8'h00;  //'N' row2
        mem[10'h193] = 8'h60;  //'N' row3
        mem[10'h194] = 8'h70;  //'N' row4
        mem[10'h195] = 8'h78;  //'N' row5
        mem[10'h196] = 8'h78;  //'N' row6
        mem[10'h197] = 8'h6C;  //'N' row7
        mem[10'h198] = 8'h66;  //'N' row8
        mem[10'h199] = 8'h66;  //'N' row9
        mem[10'h19A] = 8'h63;  //'N' row10
        mem[10'h19B] = 8'h61;  //'N' row11
        mem[10'h19C] = 8'h61;  //'N' row12
        mem[10'h19D] = 8'h60;  //'N' row13
        mem[10'h19E] = 8'h00;  //'N' row14
        mem[10'h19F] = 8'h00;  //'N' row15
        mem[10'h1A0] = 8'h00;  //' ' row0
        mem[10'h1A1] = 8'h00;  //' ' row1
        mem[10'h1A2] = 8'h00;  //' ' row2
        mem[10'h1A3] = 8'h00;  //' ' row3
        mem[10'h1A4] = 8'h00;  //' ' row4
        mem[10'h1A5] = 8'h00;  //' ' row5
        mem[10'h1A6] = 8'h00;  //' ' row6
        mem[10'h1A7] = 8'h00;  //' ' row7
        mem[10'h1A8] = 8'h00;  //' ' row8
        mem[10'h1A9] = 8'h00;  //' ' row9
        mem[10'h1AA] = 8'h00;  //' ' row10
        mem[10'h1AB] = 8'h00;  //' ' row11
        mem[10'h1AC] = 8'h00;  //' ' row12
        mem[10'h1AD] = 8'h00;  //' ' row13
        mem[10'h1AE] = 8'h00;  //' ' row14
        mem[10'h1AF] = 8'h00;  //' ' row15
        mem[10'h1B0] = 8'h00;  //'P' row0
        mem[10'h1B1] = 8'h00;  //'P' row1
        mem[10'h1B2] = 8'h00;  //'P' row2
        mem[10'h1B3] = 8'h7F;  //'P' row3
        mem[10'h1B4] = 8'h61;  //'P' row4
        mem[10'h1B5] = 8'h60;  //'P' row5
        mem[10'h1B6] = 8'h60;  //'P' row6
        mem[10'h1B7] = 8'h61;  //'P' row7
        mem[10'h1B8] = 8'h7F;  //'P' row8
        mem[10'h1B9] = 8'h7E;  //'P' row9
        mem[10'h1BA] = 8'h60;  //'P' row10
        mem[10'h1BB] = 8'h60;  //'P' row11
        mem[10'h1BC] = 8'h60;  //'P' row12
        mem[10'h1BD] = 8'h60;  //'P' row13
        mem[10'h1BE] = 8'h00;  //'P' row14
        mem[10'h1BF] = 8'h00;  //'P' row15
        mem[10'h1C0] = 8'h00;  //'T' row0
        mem[10'h1C1] = 8'h00;  //'T' row1
        mem[10'h1C2] = 8'h00;  //'T' row2
        mem[10'h1C3] = 8'hFF;  //'T' row3
        mem[10'h1C4] = 8'h0C;  //'T' row4
        mem[10'h1C5] = 8'h08;  //'T' row5
        mem[10'h1C6] = 8'h08;  //'T' row6
        mem[10'h1C7] = 8'h08;  //'T' row7
        mem[10'h1C8] = 8'h08;  //'T' row8
        mem[10'h1C9] = 8'h08;  //'T' row9
        mem[10'h1CA] = 8'h08;  //'T' row10
        mem[10'h1CB] = 8'h08;  //'T' row11
        mem[10'h1CC] = 8'h08;  //'T' row12
        mem[10'h1CD] = 8'h08;  //'T' row13
        mem[10'h1CE] = 8'h00;  //'T' row14
        mem[10'h1CF] = 8'h00;  //'T' row15
        mem[10'h1D0] = 8'h00;  //'Z' row0
        mem[10'h1D1] = 8'h00;  //'Z' row1
        mem[10'h1D2] = 8'h00;  //'Z' row2
        mem[10'h1D3] = 8'h7F;  //'Z' row3
        mem[10'h1D4] = 8'h03;  //'Z' row4
        mem[10'h1D5] = 8'h03;  //'Z' row5
        mem[10'h1D6] = 8'h06;  //'Z' row6
        mem[10'h1D7] = 8'h0C;  //'Z' row7
        mem[10'h1D8] = 8'h0C;  //'Z' row8
        mem[10'h1D9] = 8'h18;  //'Z' row9
        mem[10'h1DA] = 8'h30;  //'Z' row10
        mem[10'h1DB] = 8'h70;  //'Z' row11
        mem[10'h1DC] = 8'h60;  //'Z' row12
        mem[10'h1DD] = 8'h7F;  //'Z' row13
        mem[10'h1DE] = 8'h00;  //'Z' row14
        mem[10'h1DF] = 8'h00;  //'Z' row15
        mem[10'h1E0] = 8'h00;  //' ' row0
        mem[10'h1E1] = 8'h00;  //' ' row1
        mem[10'h1E2] = 8'h00;  //' ' row2
        mem[10'h1E3] = 8'h00;  //' ' row3
        mem[10'h1E4] = 8'h00;  //' ' row4
        mem[10'h1E5] = 8'h00;  //' ' row5
        mem[10'h1E6] = 8'h00;  //' ' row6
        mem[10'h1E7] = 8'h00;  //' ' row7
        mem[10'h1E8] = 8'h00;  //' ' row8
        mem[10'h1E9] = 8'h00;  //' ' row9
        mem[10'h1EA] = 8'h00;  //' ' row10
        mem[10'h1EB] = 8'h00;  //' ' row11
        mem[10'h1EC] = 8'h00;  //' ' row12
        mem[10'h1ED] = 8'h00;  //' ' row13
        mem[10'h1EE] = 8'h00;  //' ' row14
        mem[10'h1EF] = 8'h00;  //' ' row15
        mem[10'h1F0] = 8'h00;  //'T' row0
        mem[10'h1F1] = 8'h00;  //'T' row1
        mem[10'h1F2] = 8'h00;  //'T' row2
        mem[10'h1F3] = 8'hFF;  //'T' row3
        mem[10'h1F4] = 8'h0C;  //'T' row4
        mem[10'h1F5] = 8'h08;  //'T' row5
        mem[10'h1F6] = 8'h08;  //'T' row6
        mem[10'h1F7] = 8'h08;  //'T' row7
        mem[10'h1F8] = 8'h08;  //'T' row8
        mem[10'h1F9] = 8'h08;  //'T' row9
        mem[10'h1FA] = 8'h08;  //'T' row10
        mem[10'h1FB] = 8'h08;  //'T' row11
        mem[10'h1FC] = 8'h08;  //'T' row12
        mem[10'h1FD] = 8'h08;  //'T' row13
        mem[10'h1FE] = 8'h00;  //'T' row14
        mem[10'h1FF] = 8'h00;  //'T' row15
        mem[10'h200] = 8'h00;  //'R' row0
        mem[10'h201] = 8'h00;  //'R' row1
        mem[10'h202] = 8'h00;  //'R' row2
        mem[10'h203] = 8'h7F;  //'R' row3
        mem[10'h204] = 8'h61;  //'R' row4
        mem[10'h205] = 8'h60;  //'R' row5
        mem[10'h206] = 8'h60;  //'R' row6
        mem[10'h207] = 8'h61;  //'R' row7
        mem[10'h208] = 8'h7F;  //'R' row8
        mem[10'h209] = 8'h7F;  //'R' row9
        mem[10'h20A] = 8'h63;  //'R' row10
        mem[10'h20B] = 8'h61;  //'R' row11
        mem[10'h20C] = 8'h61;  //'R' row12
        mem[10'h20D] = 8'h60;  //'R' row13
        mem[10'h20E] = 8'h00;  //'R' row14
        mem[10'h20F] = 8'h00;  //'R' row15
        mem[10'h210] = 8'h00;  //'A' row0
        mem[10'h211] = 8'h00;  //'A' row1
        mem[10'h212] = 8'h00;  //'A' row2
        mem[10'h213] = 8'h0E;  //'A' row3
        mem[10'h214] = 8'h0E;  //'A' row4
        mem[10'h215] = 8'h1A;  //'A' row5
        mem[10'h216] = 8'h1B;  //'A' row6
        mem[10'h217] = 8'h13;  //'A' row7
        mem[10'h218] = 8'h31;  //'A' row8
        mem[10'h219] = 8'h21;  //'A' row9
        mem[10'h21A] = 8'h7F;  //'A' row10
        mem[10'h21B] = 8'h7F;  //'A' row11
        mem[10'h21C] = 8'h40;  //'A' row12
        mem[10'h21D] = 8'hC0;  //'A' row13
        mem[10'h21E] = 8'h00;  //'A' row14
        mem[10'h21F] = 8'h00;  //'A' row15
        mem[10'h220] = 8'h00;  //'C' row0
        mem[10'h221] = 8'h00;  //'C' row1
        mem[10'h222] = 8'h00;  //'C' row2
        mem[10'h223] = 8'h1F;  //'C' row3
        mem[10'h224] = 8'h31;  //'C' row4
        mem[10'h225] = 8'h60;  //'C' row5
        mem[10'h226] = 8'h60;  //'C' row6
        mem[10'h227] = 8'h60;  //'C' row7
        mem[10'h228] = 8'h60;  //'C' row8
        mem[10'h229] = 8'h60;  //'C' row9
        mem[10'h22A] = 8'h60;  //'C' row10
        mem[10'h22B] = 8'h60;  //'C' row11
        mem[10'h22C] = 8'h3B;  //'C' row12
        mem[10'h22D] = 8'h1F;  //'C' row13
        mem[10'h22E] = 8'h00;  //'C' row14
        mem[10'h22F] = 8'h00;  //'C' row15
        mem[10'h230] = 8'h00;  //'K' row0
        mem[10'h231] = 8'h00;  //'K' row1
        mem[10'h232] = 8'h00;  //'K' row2
        mem[10'h233] = 8'h61;  //'K' row3
        mem[10'h234] = 8'h63;  //'K' row4
        mem[10'h235] = 8'h66;  //'K' row5
        mem[10'h236] = 8'h6C;  //'K' row6
        mem[10'h237] = 8'h78;  //'K' row7
        mem[10'h238] = 8'h70;  //'K' row8
        mem[10'h239] = 8'h78;  //'K' row9
        mem[10'h23A] = 8'h6C;  //'K' row10
        mem[10'h23B] = 8'h66;  //'K' row11
        mem[10'h23C] = 8'h63;  //'K' row12
        mem[10'h23D] = 8'h61;  //'K' row13
        mem[10'h23E] = 8'h00;  //'K' row14
        mem[10'h23F] = 8'h00;  //'K' row15
        mem[10'h240] = 8'h00;  //'E' row0
        mem[10'h241] = 8'h00;  //'E' row1
        mem[10'h242] = 8'h00;  //'E' row2
        mem[10'h243] = 8'h7F;  //'E' row3
        mem[10'h244] = 8'h60;  //'E' row4
        mem[10'h245] = 8'h60;  //'E' row5
        mem[10'h246] = 8'h60;  //'E' row6
        mem[10'h247] = 8'h60;  //'E' row7
        mem[10'h248] = 8'h7F;  //'E' row8
        mem[10'h249] = 8'h60;  //'E' row9
        mem[10'h24A] = 8'h60;  //'E' row10
        mem[10'h24B] = 8'h60;  //'E' row11
        mem[10'h24C] = 8'h60;  //'E' row12
        mem[10'h24D] = 8'h7F;  //'E' row13
        mem[10'h24E] = 8'h00;  //'E' row14
        mem[10'h24F] = 8'h00;  //'E' row15
        mem[10'h250] = 8'h00;  //'R' row0
        mem[10'h251] = 8'h00;  //'R' row1
        mem[10'h252] = 8'h00;  //'R' row2
        mem[10'h253] = 8'h7F;  //'R' row3
        mem[10'h254] = 8'h61;  //'R' row4
        mem[10'h255] = 8'h60;  //'R' row5
        mem[10'h256] = 8'h60;  //'R' row6
        mem[10'h257] = 8'h61;  //'R' row7
        mem[10'h258] = 8'h7F;  //'R' row8
        mem[10'h259] = 8'h7F;  //'R' row9
        mem[10'h25A] = 8'h63;  //'R' row10
        mem[10'h25B] = 8'h61;  //'R' row11
        mem[10'h25C] = 8'h61;  //'R' row12
        mem[10'h25D] = 8'h60;  //'R' row13
        mem[10'h25E] = 8'h00;  //'R' row14
        mem[10'h25F] = 8'h00;  //'R' row15
        mem[10'h260] = 8'h00;  //' ' row0
        mem[10'h261] = 8'h00;  //' ' row1
        mem[10'h262] = 8'h00;  //' ' row2
        mem[10'h263] = 8'h00;  //' ' row3
        mem[10'h264] = 8'h00;  //' ' row4
        mem[10'h265] = 8'h00;  //' ' row5
        mem[10'h266] = 8'h00;  //' ' row6
        mem[10'h267] = 8'h00;  //' ' row7
        mem[10'h268] = 8'h00;  //' ' row8
        mem[10'h269] = 8'h00;  //' ' row9
        mem[10'h26A] = 8'h00;  //' ' row10
        mem[10'h26B] = 8'h00;  //' ' row11
        mem[10'h26C] = 8'h00;  //' ' row12
        mem[10'h26D] = 8'h00;  //' ' row13
        mem[10'h26E] = 8'h00;  //' ' row14
        mem[10'h26F] = 8'h00;  //' ' row15
        mem[10'h270] = 8'h00;  //'2' row0
        mem[10'h271] = 8'h00;  //'2' row1
        mem[10'h272] = 8'h00;  //'2' row2
        mem[10'h273] = 8'h3F;  //'2' row3
        mem[10'h274] = 8'h33;  //'2' row4
        mem[10'h275] = 8'h61;  //'2' row5
        mem[10'h276] = 8'h01;  //'2' row6
        mem[10'h277] = 8'h03;  //'2' row7
        mem[10'h278] = 8'h07;  //'2' row8
        mem[10'h279] = 8'h0E;  //'2' row9
        mem[10'h27A] = 8'h1C;  //'2' row10
        mem[10'h27B] = 8'h38;  //'2' row11
        mem[10'h27C] = 8'h70;  //'2' row12
        mem[10'h27D] = 8'h7F;  //'2' row13
        mem[10'h27E] = 8'h00;  //'2' row14
        mem[10'h27F] = 8'h00;  //'2' row15
        mem[10'h280] = 8'h00;  //'0' row0
        mem[10'h281] = 8'h00;  //'0' row1
        mem[10'h282] = 8'h00;  //'0' row2
        mem[10'h283] = 8'h3F;  //'0' row3
        mem[10'h284] = 8'h73;  //'0' row4
        mem[10'h285] = 8'h63;  //'0' row5
        mem[10'h286] = 8'h65;  //'0' row6
        mem[10'h287] = 8'h65;  //'0' row7
        mem[10'h288] = 8'h69;  //'0' row8
        mem[10'h289] = 8'h69;  //'0' row9
        mem[10'h28A] = 8'h79;  //'0' row10
        mem[10'h28B] = 8'h71;  //'0' row11
        mem[10'h28C] = 8'h37;  //'0' row12
        mem[10'h28D] = 8'h1E;  //'0' row13
        mem[10'h28E] = 8'h00;  //'0' row14
        mem[10'h28F] = 8'h00;  //'0' row15
        mem[10'h290] = 8'h00;  //'2' row0
        mem[10'h291] = 8'h00;  //'2' row1
        mem[10'h292] = 8'h00;  //'2' row2
        mem[10'h293] = 8'h3F;  //'2' row3
        mem[10'h294] = 8'h33;  //'2' row4
        mem[10'h295] = 8'h61;  //'2' row5
        mem[10'h296] = 8'h01;  //'2' row6
        mem[10'h297] = 8'h03;  //'2' row7
        mem[10'h298] = 8'h07;  //'2' row8
        mem[10'h299] = 8'h0E;  //'2' row9
        mem[10'h29A] = 8'h1C;  //'2' row10
        mem[10'h29B] = 8'h38;  //'2' row11
        mem[10'h29C] = 8'h70;  //'2' row12
        mem[10'h29D] = 8'h7F;  //'2' row13
        mem[10'h29E] = 8'h00;  //'2' row14
        mem[10'h29F] = 8'h00;  //'2' row15
        mem[10'h2A0] = 8'h00;  //'6' row0
        mem[10'h2A1] = 8'h00;  //'6' row1
        mem[10'h2A2] = 8'h00;  //'6' row2
        mem[10'h2A3] = 8'h06;  //'6' row3
        mem[10'h2A4] = 8'h0C;  //'6' row4
        mem[10'h2A5] = 8'h18;  //'6' row5
        mem[10'h2A6] = 8'h1C;  //'6' row6
        mem[10'h2A7] = 8'h3F;  //'6' row7
        mem[10'h2A8] = 8'h61;  //'6' row8
        mem[10'h2A9] = 8'h61;  //'6' row9
        mem[10'h2AA] = 8'h61;  //'6' row10
        mem[10'h2AB] = 8'h61;  //'6' row11
        mem[10'h2AC] = 8'h33;  //'6' row12
        mem[10'h2AD] = 8'h1E;  //'6' row13
        mem[10'h2AE] = 8'h00;  //'6' row14
        mem[10'h2AF] = 8'h00;  //'6' row15
        mem[10'h2B0] = 8'h00;  //' ' row0
        mem[10'h2B1] = 8'h00;  //' ' row1
        mem[10'h2B2] = 8'h00;  //' ' row2
        mem[10'h2B3] = 8'h00;  //' ' row3
        mem[10'h2B4] = 8'h00;  //' ' row4
        mem[10'h2B5] = 8'h00;  //' ' row5
        mem[10'h2B6] = 8'h00;  //' ' row6
        mem[10'h2B7] = 8'h00;  //' ' row7
        mem[10'h2B8] = 8'h00;  //' ' row8
        mem[10'h2B9] = 8'h00;  //' ' row9
        mem[10'h2BA] = 8'h00;  //' ' row10
        mem[10'h2BB] = 8'h00;  //' ' row11
        mem[10'h2BC] = 8'h00;  //' ' row12
        mem[10'h2BD] = 8'h00;  //' ' row13
        mem[10'h2BE] = 8'h00;  //' ' row14
        mem[10'h2BF] = 8'h00;  //' ' row15
        mem[10'h2C0] = 8'h00;  //' ' row0
        mem[10'h2C1] = 8'h00;  //' ' row1
        mem[10'h2C2] = 8'h00;  //' ' row2
        mem[10'h2C3] = 8'h00;  //' ' row3
        mem[10'h2C4] = 8'h00;  //' ' row4
        mem[10'h2C5] = 8'h00;  //' ' row5
        mem[10'h2C6] = 8'h00;  //' ' row6
        mem[10'h2C7] = 8'h00;  //' ' row7
        mem[10'h2C8] = 8'h00;  //' ' row8
        mem[10'h2C9] = 8'h00;  //' ' row9
        mem[10'h2CA] = 8'h00;  //' ' row10
        mem[10'h2CB] = 8'h00;  //' ' row11
        mem[10'h2CC] = 8'h00;  //' ' row12
        mem[10'h2CD] = 8'h00;  //' ' row13
        mem[10'h2CE] = 8'h00;  //' ' row14
        mem[10'h2CF] = 8'h00;  //' ' row15
        mem[10'h2D0] = 8'h00;  //' ' row0
        mem[10'h2D1] = 8'h00;  //' ' row1
        mem[10'h2D2] = 8'h00;  //' ' row2
        mem[10'h2D3] = 8'h00;  //' ' row3
        mem[10'h2D4] = 8'h00;  //' ' row4
        mem[10'h2D5] = 8'h00;  //' ' row5
        mem[10'h2D6] = 8'h00;  //' ' row6
        mem[10'h2D7] = 8'h00;  //' ' row7
        mem[10'h2D8] = 8'h00;  //' ' row8
        mem[10'h2D9] = 8'h00;  //' ' row9
        mem[10'h2DA] = 8'h00;  //' ' row10
        mem[10'h2DB] = 8'h00;  //' ' row11
        mem[10'h2DC] = 8'h00;  //' ' row12
        mem[10'h2DD] = 8'h00;  //' ' row13
        mem[10'h2DE] = 8'h00;  //' ' row14
        mem[10'h2DF] = 8'h00;  //' ' row15
        mem[10'h2E0] = 8'h00;  //' ' row0
        mem[10'h2E1] = 8'h00;  //' ' row1
        mem[10'h2E2] = 8'h00;  //' ' row2
        mem[10'h2E3] = 8'h00;  //' ' row3
        mem[10'h2E4] = 8'h00;  //' ' row4
        mem[10'h2E5] = 8'h00;  //' ' row5
        mem[10'h2E6] = 8'h00;  //' ' row6
        mem[10'h2E7] = 8'h00;  //' ' row7
        mem[10'h2E8] = 8'h00;  //' ' row8
        mem[10'h2E9] = 8'h00;  //' ' row9
        mem[10'h2EA] = 8'h00;  //' ' row10
        mem[10'h2EB] = 8'h00;  //' ' row11
        mem[10'h2EC] = 8'h00;  //' ' row12
        mem[10'h2ED] = 8'h00;  //' ' row13
        mem[10'h2EE] = 8'h00;  //' ' row14
        mem[10'h2EF] = 8'h00;  //' ' row15
        mem[10'h2F0] = 8'h00;  //' ' row0
        mem[10'h2F1] = 8'h00;  //' ' row1
        mem[10'h2F2] = 8'h00;  //' ' row2
        mem[10'h2F3] = 8'h00;  //' ' row3
        mem[10'h2F4] = 8'h00;  //' ' row4
        mem[10'h2F5] = 8'h00;  //' ' row5
        mem[10'h2F6] = 8'h00;  //' ' row6
        mem[10'h2F7] = 8'h00;  //' ' row7
        mem[10'h2F8] = 8'h00;  //' ' row8
        mem[10'h2F9] = 8'h00;  //' ' row9
        mem[10'h2FA] = 8'h00;  //' ' row10
        mem[10'h2FB] = 8'h00;  //' ' row11
        mem[10'h2FC] = 8'h00;  //' ' row12
        mem[10'h2FD] = 8'h00;  //' ' row13
        mem[10'h2FE] = 8'h00;  //' ' row14
        mem[10'h2FF] = 8'h00;  //' ' row15
        mem[10'h300] = 8'h00;  //' ' row0
        mem[10'h301] = 8'h00;  //' ' row1
        mem[10'h302] = 8'h00;  //' ' row2
        mem[10'h303] = 8'h00;  //' ' row3
        mem[10'h304] = 8'h00;  //' ' row4
        mem[10'h305] = 8'h00;  //' ' row5
        mem[10'h306] = 8'h00;  //' ' row6
        mem[10'h307] = 8'h00;  //' ' row7
        mem[10'h308] = 8'h00;  //' ' row8
        mem[10'h309] = 8'h00;  //' ' row9
        mem[10'h30A] = 8'h00;  //' ' row10
        mem[10'h30B] = 8'h00;  //' ' row11
        mem[10'h30C] = 8'h00;  //' ' row12
        mem[10'h30D] = 8'h00;  //' ' row13
        mem[10'h30E] = 8'h00;  //' ' row14
        mem[10'h30F] = 8'h00;  //' ' row15
        mem[10'h310] = 8'h00;  //' ' row0
        mem[10'h311] = 8'h00;  //' ' row1
        mem[10'h312] = 8'h00;  //' ' row2
        mem[10'h313] = 8'h00;  //' ' row3
        mem[10'h314] = 8'h00;  //' ' row4
        mem[10'h315] = 8'h00;  //' ' row5
        mem[10'h316] = 8'h00;  //' ' row6
        mem[10'h317] = 8'h00;  //' ' row7
        mem[10'h318] = 8'h00;  //' ' row8
        mem[10'h319] = 8'h00;  //' ' row9
        mem[10'h31A] = 8'h00;  //' ' row10
        mem[10'h31B] = 8'h00;  //' ' row11
        mem[10'h31C] = 8'h00;  //' ' row12
        mem[10'h31D] = 8'h00;  //' ' row13
        mem[10'h31E] = 8'h00;  //' ' row14
        mem[10'h31F] = 8'h00;  //' ' row15
        mem[10'h320] = 8'h00;  //' ' row0
        mem[10'h321] = 8'h00;  //' ' row1
        mem[10'h322] = 8'h00;  //' ' row2
        mem[10'h323] = 8'h00;  //' ' row3
        mem[10'h324] = 8'h00;  //' ' row4
        mem[10'h325] = 8'h00;  //' ' row5
        mem[10'h326] = 8'h00;  //' ' row6
        mem[10'h327] = 8'h00;  //' ' row7
        mem[10'h328] = 8'h00;  //' ' row8
        mem[10'h329] = 8'h00;  //' ' row9
        mem[10'h32A] = 8'h00;  //' ' row10
        mem[10'h32B] = 8'h00;  //' ' row11
        mem[10'h32C] = 8'h00;  //' ' row12
        mem[10'h32D] = 8'h00;  //' ' row13
        mem[10'h32E] = 8'h00;  //' ' row14
        mem[10'h32F] = 8'h00;  //' ' row15
        mem[10'h330] = 8'h00;  //' ' row0
        mem[10'h331] = 8'h00;  //' ' row1
        mem[10'h332] = 8'h00;  //' ' row2
        mem[10'h333] = 8'h00;  //' ' row3
        mem[10'h334] = 8'h00;  //' ' row4
        mem[10'h335] = 8'h00;  //' ' row5
        mem[10'h336] = 8'h00;  //' ' row6
        mem[10'h337] = 8'h00;  //' ' row7
        mem[10'h338] = 8'h00;  //' ' row8
        mem[10'h339] = 8'h00;  //' ' row9
        mem[10'h33A] = 8'h00;  //' ' row10
        mem[10'h33B] = 8'h00;  //' ' row11
        mem[10'h33C] = 8'h00;  //' ' row12
        mem[10'h33D] = 8'h00;  //' ' row13
        mem[10'h33E] = 8'h00;  //' ' row14
        mem[10'h33F] = 8'h00;  //' ' row15
        mem[10'h340] = 8'h00;  //' ' row0
        mem[10'h341] = 8'h00;  //' ' row1
        mem[10'h342] = 8'h00;  //' ' row2
        mem[10'h343] = 8'h00;  //' ' row3
        mem[10'h344] = 8'h00;  //' ' row4
        mem[10'h345] = 8'h00;  //' ' row5
        mem[10'h346] = 8'h00;  //' ' row6
        mem[10'h347] = 8'h00;  //' ' row7
        mem[10'h348] = 8'h00;  //' ' row8
        mem[10'h349] = 8'h00;  //' ' row9
        mem[10'h34A] = 8'h00;  //' ' row10
        mem[10'h34B] = 8'h00;  //' ' row11
        mem[10'h34C] = 8'h00;  //' ' row12
        mem[10'h34D] = 8'h00;  //' ' row13
        mem[10'h34E] = 8'h00;  //' ' row14
        mem[10'h34F] = 8'h00;  //' ' row15
        mem[10'h350] = 8'h00;  //' ' row0
        mem[10'h351] = 8'h00;  //' ' row1
        mem[10'h352] = 8'h00;  //' ' row2
        mem[10'h353] = 8'h00;  //' ' row3
        mem[10'h354] = 8'h00;  //' ' row4
        mem[10'h355] = 8'h00;  //' ' row5
        mem[10'h356] = 8'h00;  //' ' row6
        mem[10'h357] = 8'h00;  //' ' row7
        mem[10'h358] = 8'h00;  //' ' row8
        mem[10'h359] = 8'h00;  //' ' row9
        mem[10'h35A] = 8'h00;  //' ' row10
        mem[10'h35B] = 8'h00;  //' ' row11
        mem[10'h35C] = 8'h00;  //' ' row12
        mem[10'h35D] = 8'h00;  //' ' row13
        mem[10'h35E] = 8'h00;  //' ' row14
        mem[10'h35F] = 8'h00;  //' ' row15
        mem[10'h360] = 8'h00;  //' ' row0
        mem[10'h361] = 8'h00;  //' ' row1
        mem[10'h362] = 8'h00;  //' ' row2
        mem[10'h363] = 8'h00;  //' ' row3
        mem[10'h364] = 8'h00;  //' ' row4
        mem[10'h365] = 8'h00;  //' ' row5
        mem[10'h366] = 8'h00;  //' ' row6
        mem[10'h367] = 8'h00;  //' ' row7
        mem[10'h368] = 8'h00;  //' ' row8
        mem[10'h369] = 8'h00;  //' ' row9
        mem[10'h36A] = 8'h00;  //' ' row10
        mem[10'h36B] = 8'h00;  //' ' row11
        mem[10'h36C] = 8'h00;  //' ' row12
        mem[10'h36D] = 8'h00;  //' ' row13
        mem[10'h36E] = 8'h00;  //' ' row14
        mem[10'h36F] = 8'h00;  //' ' row15
        mem[10'h370] = 8'h00;  //' ' row0
        mem[10'h371] = 8'h00;  //' ' row1
        mem[10'h372] = 8'h00;  //' ' row2
        mem[10'h373] = 8'h00;  //' ' row3
        mem[10'h374] = 8'h00;  //' ' row4
        mem[10'h375] = 8'h00;  //' ' row5
        mem[10'h376] = 8'h00;  //' ' row6
        mem[10'h377] = 8'h00;  //' ' row7
        mem[10'h378] = 8'h00;  //' ' row8
        mem[10'h379] = 8'h00;  //' ' row9
        mem[10'h37A] = 8'h00;  //' ' row10
        mem[10'h37B] = 8'h00;  //' ' row11
        mem[10'h37C] = 8'h00;  //' ' row12
        mem[10'h37D] = 8'h00;  //' ' row13
        mem[10'h37E] = 8'h00;  //' ' row14
        mem[10'h37F] = 8'h00;  //' ' row15
        mem[10'h380] = 8'h00;  //' ' row0
        mem[10'h381] = 8'h00;  //' ' row1
        mem[10'h382] = 8'h00;  //' ' row2
        mem[10'h383] = 8'h00;  //' ' row3
        mem[10'h384] = 8'h00;  //' ' row4
        mem[10'h385] = 8'h00;  //' ' row5
        mem[10'h386] = 8'h00;  //' ' row6
        mem[10'h387] = 8'h00;  //' ' row7
        mem[10'h388] = 8'h00;  //' ' row8
        mem[10'h389] = 8'h00;  //' ' row9
        mem[10'h38A] = 8'h00;  //' ' row10
        mem[10'h38B] = 8'h00;  //' ' row11
        mem[10'h38C] = 8'h00;  //' ' row12
        mem[10'h38D] = 8'h00;  //' ' row13
        mem[10'h38E] = 8'h00;  //' ' row14
        mem[10'h38F] = 8'h00;  //' ' row15
        mem[10'h390] = 8'h00;  //' ' row0
        mem[10'h391] = 8'h00;  //' ' row1
        mem[10'h392] = 8'h00;  //' ' row2
        mem[10'h393] = 8'h00;  //' ' row3
        mem[10'h394] = 8'h00;  //' ' row4
        mem[10'h395] = 8'h00;  //' ' row5
        mem[10'h396] = 8'h00;  //' ' row6
        mem[10'h397] = 8'h00;  //' ' row7
        mem[10'h398] = 8'h00;  //' ' row8
        mem[10'h399] = 8'h00;  //' ' row9
        mem[10'h39A] = 8'h00;  //' ' row10
        mem[10'h39B] = 8'h00;  //' ' row11
        mem[10'h39C] = 8'h00;  //' ' row12
        mem[10'h39D] = 8'h00;  //' ' row13
        mem[10'h39E] = 8'h00;  //' ' row14
        mem[10'h39F] = 8'h00;  //' ' row15
        mem[10'h3A0] = 8'h00;  //' ' row0
        mem[10'h3A1] = 8'h00;  //' ' row1
        mem[10'h3A2] = 8'h00;  //' ' row2
        mem[10'h3A3] = 8'h00;  //' ' row3
        mem[10'h3A4] = 8'h00;  //' ' row4
        mem[10'h3A5] = 8'h00;  //' ' row5
        mem[10'h3A6] = 8'h00;  //' ' row6
        mem[10'h3A7] = 8'h00;  //' ' row7
        mem[10'h3A8] = 8'h00;  //' ' row8
        mem[10'h3A9] = 8'h00;  //' ' row9
        mem[10'h3AA] = 8'h00;  //' ' row10
        mem[10'h3AB] = 8'h00;  //' ' row11
        mem[10'h3AC] = 8'h00;  //' ' row12
        mem[10'h3AD] = 8'h00;  //' ' row13
        mem[10'h3AE] = 8'h00;  //' ' row14
        mem[10'h3AF] = 8'h00;  //' ' row15
        mem[10'h3B0] = 8'h00;  //' ' row0
        mem[10'h3B1] = 8'h00;  //' ' row1
        mem[10'h3B2] = 8'h00;  //' ' row2
        mem[10'h3B3] = 8'h00;  //' ' row3
        mem[10'h3B4] = 8'h00;  //' ' row4
        mem[10'h3B5] = 8'h00;  //' ' row5
        mem[10'h3B6] = 8'h00;  //' ' row6
        mem[10'h3B7] = 8'h00;  //' ' row7
        mem[10'h3B8] = 8'h00;  //' ' row8
        mem[10'h3B9] = 8'h00;  //' ' row9
        mem[10'h3BA] = 8'h00;  //' ' row10
        mem[10'h3BB] = 8'h00;  //' ' row11
        mem[10'h3BC] = 8'h00;  //' ' row12
        mem[10'h3BD] = 8'h00;  //' ' row13
        mem[10'h3BE] = 8'h00;  //' ' row14
        mem[10'h3BF] = 8'h00;  //' ' row15
        mem[10'h3C0] = 8'h00;  //' ' row0
        mem[10'h3C1] = 8'h00;  //' ' row1
        mem[10'h3C2] = 8'h00;  //' ' row2
        mem[10'h3C3] = 8'h00;  //' ' row3
        mem[10'h3C4] = 8'h00;  //' ' row4
        mem[10'h3C5] = 8'h00;  //' ' row5
        mem[10'h3C6] = 8'h00;  //' ' row6
        mem[10'h3C7] = 8'h00;  //' ' row7
        mem[10'h3C8] = 8'h00;  //' ' row8
        mem[10'h3C9] = 8'h00;  //' ' row9
        mem[10'h3CA] = 8'h00;  //' ' row10
        mem[10'h3CB] = 8'h00;  //' ' row11
        mem[10'h3CC] = 8'h00;  //' ' row12
        mem[10'h3CD] = 8'h00;  //' ' row13
        mem[10'h3CE] = 8'h00;  //' ' row14
        mem[10'h3CF] = 8'h00;  //' ' row15
        mem[10'h3D0] = 8'h00;  //' ' row0
        mem[10'h3D1] = 8'h00;  //' ' row1
        mem[10'h3D2] = 8'h00;  //' ' row2
        mem[10'h3D3] = 8'h00;  //' ' row3
        mem[10'h3D4] = 8'h00;  //' ' row4
        mem[10'h3D5] = 8'h00;  //' ' row5
        mem[10'h3D6] = 8'h00;  //' ' row6
        mem[10'h3D7] = 8'h00;  //' ' row7
        mem[10'h3D8] = 8'h00;  //' ' row8
        mem[10'h3D9] = 8'h00;  //' ' row9
        mem[10'h3DA] = 8'h00;  //' ' row10
        mem[10'h3DB] = 8'h00;  //' ' row11
        mem[10'h3DC] = 8'h00;  //' ' row12
        mem[10'h3DD] = 8'h00;  //' ' row13
        mem[10'h3DE] = 8'h00;  //' ' row14
        mem[10'h3DF] = 8'h00;  //' ' row15
        mem[10'h3E0] = 8'h00;  //' ' row0
        mem[10'h3E1] = 8'h00;  //' ' row1
        mem[10'h3E2] = 8'h00;  //' ' row2
        mem[10'h3E3] = 8'h00;  //' ' row3
        mem[10'h3E4] = 8'h00;  //' ' row4
        mem[10'h3E5] = 8'h00;  //' ' row5
        mem[10'h3E6] = 8'h00;  //' ' row6
        mem[10'h3E7] = 8'h00;  //' ' row7
        mem[10'h3E8] = 8'h00;  //' ' row8
        mem[10'h3E9] = 8'h00;  //' ' row9
        mem[10'h3EA] = 8'h00;  //' ' row10
        mem[10'h3EB] = 8'h00;  //' ' row11
        mem[10'h3EC] = 8'h00;  //' ' row12
        mem[10'h3ED] = 8'h00;  //' ' row13
        mem[10'h3EE] = 8'h00;  //' ' row14
        mem[10'h3EF] = 8'h00;  //' ' row15
        // 未列出的地址保持 0（当前仅用 63 字符 x 16 行）
    end

    assign O_bits = mem[I_addr];

endmodule

// ===== [移植] motion_detect.v —— 逐字复制，来源 03_vision/step5_expansion/03_project/rtl/motion_detect.v，SHA256 6e71de92a0d9ca48 =====
// =============================================================================
// motion_detect.v —— 帧差运动检测（进阶④，v3 流水版 2026-10-03）
// 输入：平滑后的二值掩码流（与 centroid 同源同拍）。
// 结构：整帧 1bit 前帧缓存（W*H bit，TD 映射 ERAM），同步读一级流水：
//       第 1 拍发地址/写新值，第 2 拍取读出旧值与延迟一拍的掩码比对。
//       —— v2 用组合读 prev_mem[addr]，行为仿真可行但 TD ERAM(Block RAM)
//          不支持组合读，上板综合会失败；v3 改为同步读 + 信号对齐流水。
// 输出（语义定稿，2026-10-03 评审措辞澄清）：
//   O_mot_cnt/O_mot_bbox 每帧末锁存（含亚门限帧，cnt==0 时 bbox 全 0）；
//   O_mot_valid **本身就是阈值标志**=(cnt >= MOT_TH)：仅该帧判为运动时
//   拉高 1 拍（帧末结果与阈值判决合为一个输出，无独立逐帧选通信号）；
//   OSD 运动框以它为门控（mv），亚门限帧不画框。
//
// 版本要点：
//   v2 [1] sof 拍写地址强制 0（不再用上一帧遗留 row_base 算地址）；
//      [2] 首帧门控用 prev_ready（首帧不比对、不输出）；
//   v3 [3] 同步读流水（TD 可实现）；[4] addr 越界保护；
//   v3.1 写地址延迟一拍（与 ERAM 写模式解耦，防 WRITE_FIRST 下 diff 恒 0）；
//      [5] cnt==0 时 bbox 锁存 0（与金标准 frame_diff_motion 语义一致）。
// 已知约定：(0,0) 像素每帧只写缓存、不参与比对（sof 拍结构，1/921600）。
// =============================================================================
module motion_detect #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720,
    parameter MOT_TH     = 64
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_valid,
    input  wire        I_sof,
    input  wire        I_eol,
    input  wire        I_mask,
    output reg         O_mot_valid,
    output reg  [13:0] O_mot_cnt,
    output reg  [10:0] O_mot_minx,
    output reg  [10:0] O_mot_maxx,
    output reg  [9:0]  O_mot_miny,
    output reg  [9:0]  O_mot_maxy
);
    localparam TOTAL = IMG_WIDTH * IMG_HEIGHT;

    (* ram_style = "block" *) reg prev_mem [0:TOTAL-1];

    // ---------------- 坐标计数（输入拍） ----------------
    reg [10:0] x;
    reg [9:0]  y;
    reg [20:0] row_base;
    reg        prev_ready;   // 首帧缓存填满后置位；首帧不比对、不输出

    // sof 拍像素是 (0,0)：写地址强制 0（见 v2[1]）
    wire [20:0] addr = I_sof ? 21'd0 : (row_base + {10'd0, x});
    wire [20:0] addr_safe = (addr < TOTAL) ? addr : 21'd0;   // v3[4] 越界保护

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            x <= 11'd0; y <= 10'd0; row_base <= 21'd0; prev_ready <= 1'b0;
        end else if (I_valid) begin
            if (I_sof) begin
                x <= 11'd1; y <= 10'd0; row_base <= 21'd0;
            end else if (I_eol) begin
                x <= 11'd0;
                y <= (y == IMG_HEIGHT - 1) ? 10'd0 : y + 10'd1;
                row_base <= row_base + IMG_WIDTH;
                if (y == IMG_HEIGHT - 1) prev_ready <= 1'b1;  // 首帧末行：缓存已填满
            end else begin
                x <= x + 11'd1;
            end
        end
    end

    // ---------------- 一级流水：ERAM 同步读 + 信号对齐（v3[3]） ----------------
    // v3.1 外脑评审：写地址**延迟一拍**——杜绝同拍同址读写。
    // 若 ERAM 被综合为 WRITE_FIRST 模式，同址读写会让 old_r 直接读到新掩码，
    // diff 恒 0（运动检测静默失效）；地址错开一拍后与写模式无关（结构性读旧）。
    reg        old_r;                          // 前帧掩码（同步读输出）
    reg [20:0] addr_d;                         // 写地址（延迟一拍）
    reg        mask_wr;                        // 写数据（延迟一拍）
    reg        wr_en_d;                        // 写使能（延迟一拍）
    reg        v_d, sof_d, eol_d, mask_d, ready_d;
    reg [10:0] x_d;
    reg [9:0]  y_d;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            old_r <= 1'b0;
            addr_d <= 21'd0; mask_wr <= 1'b0; wr_en_d <= 1'b0;
            v_d <= 1'b0; sof_d <= 1'b0; eol_d <= 1'b0;
            mask_d <= 1'b0; ready_d <= 1'b0;
            x_d <= 11'd0; y_d <= 10'd0;
        end else begin
            old_r <= prev_mem[addr_safe];              // 读：本拍地址（读旧）
            // 写：上一拍的地址/数据 → 与读地址恒不同址（流内地址逐一递增）
            if (wr_en_d && (addr_d < TOTAL))
                prev_mem[addr_d] <= mask_wr;
            addr_d  <= addr_safe;
            mask_wr <= I_mask;
            wr_en_d <= I_valid;
            v_d   <= I_valid; sof_d <= I_sof; eol_d <= I_eol;
            mask_d <= I_mask; ready_d <= prev_ready;
            x_d   <= x; y_d <= y;
        end
    end

    wire diff = mask_d ^ old_r;    // 与 x_d/y_d/v_d 同拍对齐

    // ---------------- 帧内累加（延迟域） ----------------
    reg [13:0] cnt;
    reg        seen;
    reg [10:0] bmin_x, bmax_x;
    reg [9:0]  bmin_y, bmax_y;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            cnt <= 14'd0; seen <= 1'b0;
            bmin_x <= 11'd0; bmax_x <= 11'd0; bmin_y <= 10'd0; bmax_y <= 10'd0;
        end else if (v_d && sof_d) begin
            cnt <= 14'd0; seen <= 1'b0;            // 帧首清零（sof 像素不比对）
        end else if (v_d && ready_d && diff) begin
            cnt <= (cnt == 14'h3FFF) ? cnt : cnt + 14'd1;   // 饱和（14bit 接口）
            if (!seen) begin
                seen   <= 1'b1;
                bmin_x <= x_d; bmax_x <= x_d; bmin_y <= y_d; bmax_y <= y_d;
            end else begin
                if (x_d < bmin_x) bmin_x <= x_d;
                if (x_d > bmax_x) bmax_x <= x_d;
                if (y_d < bmin_y) bmin_y <= y_d;
                if (y_d > bmax_y) bmax_y <= y_d;
            end
        end
    end

    // ---------------- 帧末锁存（延迟域；首帧 prev_ready=0 不输出） ----------------
    // 外脑评审修复：锁存再延迟一拍——末像素的 diff 在 last_eol_d 同拍累加，
    // 同拍锁存读到的是旧 cnt/bbox（每帧漏掉 (W-1,H-1) 一个像素的计数）。
    wire last_eol_d = v_d && eol_d && (y_d == IMG_HEIGHT - 1);
    reg  last_eol_dd;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) last_eol_dd <= 1'b0;
        else          last_eol_dd <= last_eol_d;
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_mot_valid <= 1'b0;
            O_mot_cnt <= 14'd0;
            O_mot_minx <= 11'd0; O_mot_maxx <= 11'd0;
            O_mot_miny <= 10'd0; O_mot_maxy <= 10'd0;
        end else begin
            O_mot_valid <= 1'b0;
            if (last_eol_dd && ready_d) begin
                O_mot_valid <= (cnt >= MOT_TH);
                O_mot_cnt   <= cnt;
                // v3[5] cnt==0 时 bbox 全 0（与金标准一致）
                O_mot_minx  <= (cnt == 14'd0) ? 11'd0 : bmin_x;
                O_mot_maxx  <= (cnt == 14'd0) ? 11'd0 : bmax_x;
                O_mot_miny  <= (cnt == 14'd0) ? 10'd0 : bmin_y;
                O_mot_maxy  <= (cnt == 14'd0) ? 10'd0 : bmax_y;
            end
        end
    end

endmodule

// ===== [新增] led_indicator.v —— 跟踪状态指示灯（F4 语义，2026-10-11 本工程新写） =====
// 板载 LED1~4 = 引脚 D10/E10/C6/D6，低有效（原理图 P04_DIG_LED：LEDVCC->470R->LED->FPGA 引脚，灌电流；
// 另注意板上 LED/数码管切换开关须在 LED 档）。
//   LED1 心跳：PLL 锁定后约 1Hz 闪烁（HEART_HALF 半周期）      LED2 DET ：本帧目标有效
//   LED3 LOCK：连续 >=LOCK_N 帧有效且质心在中心死区 +-DEADZONE  LED4 ERR ：lost_cnt >= LOST_TH 或坏帧
// 运行域：相机/ISP 域（LED 为慢速人眼指示，无需跨域 CDC）。
module led_indicator #(
    parameter [10:0] DEADZONE  = 11'd25,
    parameter [3:0]  LOCK_N    = 4'd8,
    parameter [25:0] HEART_HALF = 26'd51_750_000,   // 0.5s @103.5MHz（26 位：24 位装不下）
    parameter [10:0] CX0 = 11'd640,
    parameter [10:0] CY0 = 11'd360,
    parameter [15:0] LOST_TH   = 16'd180,           // 约 3s @60fps（规格"饱和"=65535 帧约 18min，不实用 -> 阈值化）
    parameter        LED_ACTIVE_LOW = 1'b1         // 1=低有效（输出 0 点亮）；本板实测为高有效 → 顶层例化传 1'b0
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_pll_lock,
    input  wire        I_pack_load,      // 目标包装载脉冲（帧级）
    input  wire        I_target_valid,
    input  wire [10:0] I_cx,
    input  wire [10:0] I_cy,
    input  wire [15:0] I_lost_cnt,
    input  wire        I_frame_bad,      // 链路坏帧（MIPI 错误按帧锁存）
    output reg  [3:0]  O_led,            // 物理驱动：极性由 LED_ACTIVE_LOW 决定
    output reg  [3:0]  O_led_state       // 逻辑态（1=应亮），供 OSD 图例使用，与物理极性无关
);
    reg [25:0] hb_cnt;  reg hb;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin hb_cnt <= 26'd0; hb <= 1'b0; end
        else if (hb_cnt == HEART_HALF - 26'd1) begin hb_cnt <= 26'd0; hb <= ~hb; end
        else hb_cnt <= hb_cnt + 26'd1;
    end

    wire in_deadzone = (I_cx >= (CX0 - DEADZONE)) && (I_cx <= (CX0 + DEADZONE)) &&
                       (I_cy >= (CY0 - DEADZONE)) && (I_cy <= (CY0 + DEADZONE));

    reg [3:0] lock_cnt;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) lock_cnt <= 4'd0;
        else if (I_pack_load) begin
            if (I_target_valid && in_deadzone)
                lock_cnt <= (lock_cnt >= LOCK_N) ? lock_cnt : lock_cnt + 4'd1;
            else lock_cnt <= 4'd0;
        end
    end
    wire locked = (lock_cnt >= LOCK_N);
    wire err    = (I_lost_cnt >= LOST_TH) | I_frame_bad;
    wire alive  = I_pll_lock;

    // 【本工程改动 2026-10-14】极性参数化 + 逻辑态输出。
    // 背景：上板实测发现物理 LED 与"低有效"假设完全相反 → 本板实为高有效（LED_ACTIVE_LOW=0）。
    // 同时把"逻辑态"单独引出给 OSD 图例，使屏幕圆点始终表示"应亮"，与物理极性解耦——
    // 以后若再怀疑极性，对照屏幕圆点与实际灯即可一眼判定。
    wire [3:0] led_on = {alive & err, alive & locked, alive & I_target_valid, alive & hb};  // {ERR,LOCK,DET,RUN}，1=应亮

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_led       <= LED_ACTIVE_LOW ? 4'b1111 : 4'b0000;
            O_led_state <= 4'b0000;
        end else begin
            O_led_state <= led_on;
            O_led[0] <= LED_ACTIVE_LOW ? ~led_on[0] : led_on[0];
            O_led[1] <= LED_ACTIVE_LOW ? ~led_on[1] : led_on[1];
            O_led[2] <= LED_ACTIVE_LOW ? ~led_on[2] : led_on[2];
            O_led[3] <= LED_ACTIVE_LOW ? ~led_on[3] : led_on[3];
        end
    end
endmodule

// ===== [新增] vpix_de_vsync.v —— 显示域 (de/vsync) -> 视觉 vpix 约定 (valid/sof/eol) =====
// 计数语义与 ui_logo_page 一致（x 在 de 有效期递增、行尾回零；y 在 vsync 回零、行尾递增）。
module vpix_de_vsync #(
    parameter IMG_WIDTH = 1280
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_de,
    input  wire        I_vsync,
    output wire        O_valid,
    output wire        O_sof,
    output wire        O_eol,
    output wire [10:0] O_x
);
    reg [10:0] x_act;
    reg [9:0]  y_act;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin x_act <= 11'd0; y_act <= 10'd0; end
        else begin
            if (!I_de)                               x_act <= 11'd0;
            else                                     x_act <= x_act + 11'd1;
            if (I_vsync)                             y_act <= 10'd0;
            else if (I_de && (x_act == IMG_WIDTH-1)) y_act <= y_act + 10'd1;
        end
    end
    assign O_valid = I_de;
    assign O_sof   = I_de && (x_act == 11'd0) && (y_act == 10'd0);
    assign O_eol   = I_de && (x_act == IMG_WIDTH-1);
    assign O_x     = x_act;
endmodule

// 【SC520 本工程改动 v16】Display-only frame result stabilizer; no pixel/frame RAM.
// Input packets stay available at osd_track.raw_pack_dst for diagnosis.
module track_pack_stabilizer #(
    parameter IMG_WIDTH=1280, IMG_HEIGHT=720,
    parameter DEAD_BAND=2, JUMP_LIMIT=64, CONFIRM_BAND=24
)(
    input wire I_clk,I_rst_n,I_load,
    input wire [134:0] I_pack,
    output reg O_load,
    output reg [134:0] O_pack
);
    reg have, pending;
    reg [3:0] profile;
    reg [7:0] fid;
    reg [10:0] cx,cy,x0,x1,y0,y1;
    reg [10:0] pcx,pcy,px0,px1,py0,py1;
    wire [10:0] icx=I_pack[129:119],icy=I_pack[118:108];
    wire [10:0] ix0=I_pack[107:97],ix1=I_pack[96:86];
    wire [10:0] iy0={1'b0,I_pack[85:76]},iy1={1'b0,I_pack[75:66]};
    wire [7:0] delta_fid=I_pack[65:58]-fid;
    wire shape_ok=(ix0<=ix1)&&(iy0<=iy1)&&(ix1<IMG_WIDTH)&&(iy1<IMG_HEIGHT)&&
                  (icx>=ix0)&&(icx<=ix1)&&(icy>=iy0)&&(icy<=iy1);
    function [10:0] distance;
      input [10:0] a,b;
      begin distance=(a>=b)?a-b:b-a;end
    endfunction
    function [10:0] follow;
      input [10:0] a,b;
      reg [11:0] step;
      begin
        step=({1'b0,distance(a,b)}+12'd1)>>1;
        if(distance(a,b)<=DEAD_BAND)follow=a;
        else if(b>a)follow=a+step;else follow=a-step;
      end
    endfunction
    wire jump=(distance(icx,cx)>JUMP_LIMIT)||(distance(icy,cy)>JUMP_LIMIT)||
              (distance(ix0,x0)>JUMP_LIMIT)||(distance(ix1,x1)>JUMP_LIMIT)||
              (distance(iy0,y0)>JUMP_LIMIT)||(distance(iy1,y1)>JUMP_LIMIT);
    wire confirms=pending&&(distance(icx,pcx)<=CONFIRM_BAND)&&(distance(icy,pcy)<=CONFIRM_BAND)&&
              (distance(ix0,px0)<=CONFIRM_BAND)&&(distance(ix1,px1)<=CONFIRM_BAND)&&
              (distance(iy0,py0)<=CONFIRM_BAND)&&(distance(iy1,py1)<=CONFIRM_BAND);
    wire fresh=!have||(profile!=I_pack[133:130])||(delta_fid>8'd4);
    wire snap=fresh||(jump&&confirms);
    wire hold_position=(delta_fid==0)||(jump&&!confirms&&!fresh);
    wire [10:0] nx0=snap?ix0:hold_position?x0:follow(x0,ix0);
    wire [10:0] nx1=snap?ix1:hold_position?x1:follow(x1,ix1);
    wire [10:0] ny0=snap?iy0:hold_position?y0:follow(y0,iy0);
    wire [10:0] ny1=snap?iy1:hold_position?y1:follow(y1,iy1);
    wire [10:0] cx_next=snap?icx:hold_position?cx:follow(cx,icx);
    wire [10:0] cy_next=snap?icy:hold_position?cy:follow(cy,icy);
    wire [10:0] ncx=(cx_next<nx0)?nx0:(cx_next>nx1)?nx1:cx_next;
    wire [10:0] ncy=(cy_next<ny0)?ny0:(cy_next>ny1)?ny1:cy_next;
    always @(posedge I_clk or negedge I_rst_n)begin
      if(!I_rst_n)begin
        O_load<=0;O_pack<=0;have<=0;pending<=0;profile<=0;fid<=0;
        cx<=0;cy<=0;x0<=0;x1<=0;y0<=0;y1<=0;
        pcx<=0;pcy<=0;px0<=0;px1<=0;py0<=0;py1<=0;
      end else begin
        O_load<=I_load;
        if(I_load)begin
          O_pack<=I_pack;profile<=I_pack[133:130];fid<=I_pack[65:58];
          if(!I_pack[134]||!shape_ok)begin
            O_pack[134]<=0;O_pack[129:66]<=0;have<=0;pending<=0;
          end else begin
            O_pack[129:66]<={ncx,ncy,nx0,nx1,ny0[9:0],ny1[9:0]};
            cx<=ncx;cy<=ncy;x0<=nx0;x1<=nx1;y0<=ny0;y1<=ny1;have<=1;
            if(jump&&!fresh&&!confirms&&(delta_fid!=0))begin
              pending<=1;pcx<=icx;pcy<=icy;px0<=ix0;px1<=ix1;py0<=iy0;py1<=iy1;
            end else if(delta_fid!=0||fresh)pending<=0;
          end
        end
      end
    end
endmodule

// v17: 32x16 tile connected regions, exact moments/extents inside accepted tiles.
// 4-neighbour TILE connectivity, >=8 pixels/tile; largest pixel-count component wins.
// Two frame banks: no video backpressure, analysis runs concurrently with next frame.
module track_region_accum #(
 parameter IMG_WIDTH=1280, IMG_HEIGHT=720, MIN_PIXELS=30, TILE_MIN=8,
 parameter RED_STABLE=0, BLUE_STABLE=0, MIN_SEED_PIXELS=16, ASSOC_MARGIN=48, REACQUIRE_FRAMES=4, BRIDGE_ONE_TILE=1
)(
 input wire I_clk,I_rst_n,I_valid,I_sof,I_eol,I_mask,I_seed,
 input wire [7:0] I_fid,input wire [2:0] I_preset,
 output reg O_target_valid,output reg [10:0] O_cx,O_cy,
 output reg [20:0] O_count,output reg [10:0] O_min_x,O_max_x,
 output reg [9:0] O_min_y,O_max_y,output reg [15:0] O_lost_cnt,
 output reg O_results_upd,O_frame_tick,output reg [7:0] O_fid,
 output reg [2:0] O_preset,output reg O_error
);
 localparam NX=IMG_WIDTH/32, NY=IMG_HEIGHT/16, N=NX*NY;
 localparam IDLE=0,CLEAR=1,SCAN=2,WAIT_RD=3,CHECK=4,POP=5,
            POP_WAIT=6,POP_LOAD=7,NEIGH=8,NEXT_N=9,COMPARE=10,
            DIV_X=11,DIV_Y=12,LATCH=13;
 reg [3:0] state;
 reg [10:0] x;reg [9:0] y;reg [10:0] rowbase;
 reg cap_bank,seen,bad,have_frame;
 reg [7:0] cap_fid;reg [2:0] cap_preset;
 wire [10:0] px=I_sof?11'd0:x;
 wire [9:0] py=I_sof?10'd0:y;
 wire [10:0] cb=I_sof?11'd0:rowbase;
 wire bank_now=I_sof?(have_frame?~cap_bank:1'b0):cap_bank;
 wire [10:0] cell_addr=cb+{5'd0,px[10:5]};
 wire eof=seen&&I_valid&&I_eol&&(py==IMG_HEIGHT-1);
 reg [4:0] run_seed;
 reg [5:0] run_cnt;reg [9:0] run_sx;
 reg [4:0] run_min,run_max;
 wire [5:0] rc=(px[4:0]==0?6'd0:run_cnt)+I_mask;
 wire [9:0] rs=(px[4:0]==0?10'd0:run_sx)+(I_mask?{5'd0,px[4:0]}:10'd0);
 wire [4:0] rmin=(px[4:0]==0||run_cnt==0)?px[4:0]:run_min;
 wire [4:0] rmax=I_mask?px[4:0]:run_max;
 wire seed_pixel=(RED_STABLE || BLUE_STABLE) ? I_seed : I_mask;
 wire [5:0] next_run_seed=(px[4:0]==0?6'd0:{1'b0,run_seed})+seed_pixel;
 wire [5:0] next_tile_seed={1'b0,prior[59:55]}+next_run_seed;
 wire [4:0] merged_seed=next_tile_seed>31?5'd31:next_tile_seed[4:0];
 reg wr_en,wr_bank;reg [10:0] wr_addr;reg [59:0] wr_data;
 reg ana_bank;reg [10:0] candidate;
 wire [10:0] ra0=(state!=IDLE&&ana_bank==0)?candidate:cell_addr;
 wire [10:0] ra1=(state!=IDLE&&ana_bank==1)?candidate:cell_addr;
 wire [59:0] q0,q1;
 track_region_ram #(.W(60),.AW(11)) tiles0(I_clk,wr_en&&!wr_bank,wr_addr,wr_data,ra0,q0);
 track_region_ram #(.W(60),.AW(11)) tiles1(I_clk,wr_en&&wr_bank,wr_addr,wr_data,ra1,q1);
 wire [59:0] old_tile=bank_now?q1:q0;
 wire [59:0] prior=py[3:0]==0?60'd0:old_tile;
 wire [9:0] pc=prior[54:45];
 wire [9:0] merged_cnt=pc+rc;
 wire [13:0] merged_sx=prior[44:31]+rs;
 wire [12:0] merged_sy=prior[30:18]+(rc*py[3:0]);
 wire [4:0] merged_minx=pc==0?rmin:rc==0?prior[17:13]:rmin<prior[17:13]?rmin:prior[17:13];
 wire [4:0] merged_maxx=pc==0?rmax:rc==0?prior[12:8]:rmax>prior[12:8]?rmax:prior[12:8];
 wire [3:0] merged_miny=pc==0?py[3:0]:prior[7:4];
 wire [3:0] merged_maxy=rc==0?prior[3:0]:py[3:0];
 reg start_pending;reg start_bank;reg [7:0] start_fid;reg [2:0] start_preset;
 // Capture writes one completed horizontal run per 32 pixels, a single write port/bank.
 always @(posedge I_clk or negedge I_rst_n) begin
  if(!I_rst_n)begin
   x<=0;y<=0;rowbase<=0;cap_bank<=0;seen<=0;bad<=0;
   cap_fid<=0;cap_preset<=0;run_cnt<=0;run_seed<=0;run_sx<=0;run_min<=0;run_max<=0;
   wr_en<=0;wr_bank<=0;wr_addr<=0;wr_data<=0;start_pending<=0;
   start_bank<=0;start_fid<=0;start_preset<=0;O_frame_tick<=0;
  end else begin
   wr_en<=0;start_pending<=0;O_frame_tick<=eof;
   if(I_valid&&(seen||I_sof))begin
    if(I_sof)begin seen<=1;cap_bank<=bank_now;cap_fid<=I_fid;cap_preset<=I_preset;bad<=0;end
    run_cnt<=rc;run_seed<=next_run_seed>31?5'd31:next_run_seed[4:0];run_sx<=rs;
    if(I_mask)begin run_min<=rmin;run_max<=px[4:0];end
    if(px[4:0]==31)begin
     wr_en<=1;wr_bank<=bank_now;wr_addr<=cell_addr;
     wr_data<={merged_seed,merged_cnt,merged_sx,merged_sy,merged_minx,merged_maxx,merged_miny,merged_maxy};
    end
    if(I_eol)begin
     x<=0;y<=py+1'b1;
     rowbase<=cb+(py[3:0]==15?NX:0);
     if(px!=IMG_WIDTH-1)bad<=1;
    end else begin x<=px+1'b1;y<=py;rowbase<=cb;
     if(px==IMG_WIDTH-1)bad<=1;
    end
    if(eof)begin
     start_pending<=!bad&&(px==IMG_WIDTH-1);
     start_bank<=cap_bank;start_fid<=cap_fid;start_preset<=cap_preset;
     seen<=0;
    end
   end
  end
 end
 // cap_bank toggles per completed/new frame, even though seen clears at EOF.
 // A distinct epoch flag is needed because no pixels may occur during blanking.

 always @(posedge I_clk or negedge I_rst_n)
  if(!I_rst_n)have_frame<=0;else if(I_valid&&I_sof)have_frame<=1;

 (* ram_style="distributed" *) reg visited[0:2047];
 reg [10:0] clear_i,scan_i;
 reg [5:0] scan_x,scan_y,cand_x,cand_y,node_x,node_y;
 reg [10:0] node_addr;
 reg seed;
 reg [3:0] neighbour;
 reg [11:0] head,tail;
 reg queue_wr;reg [10:0] queue_wa;reg [22:0] queue_wd;
 wire [22:0] queue_q;
 track_region_ram #(.W(23),.AW(11)) queue(I_clk,queue_wr,queue_wa,queue_wd,head[10:0],queue_q);
 wire [59:0] tile=ana_bank?q1:q0;
 wire [9:0] tc=tile[54:45];
 wire [10:0] tminx={cand_x,5'b0}+tile[17:13], tmaxx={cand_x,5'b0}+tile[12:8];
 wire [9:0] tminy={cand_y,4'b0}+tile[7:4], tmaxy={cand_y,4'b0}+tile[3:0];
 wire [25:0] tsx=(tc*cand_x)*32+tile[44:31];
 wire [25:0] tsy=(tc*cand_y)*16+tile[30:18];
 reg [4:0] seed_count,best_seed_count;
 wire [5:0] seed_total={1'b0,seed_count}+{1'b0,tile[59:55]};
 wire [5:0] selected_seed_total={1'b0,best_seed_count}+{1'b0,seed_count};
 reg [20:0] count,best_count;
 reg [31:0] sumx,sumy,best_sumx,best_sumy;
 reg [10:0] minx,maxx,best_minx,best_maxx;
 reg [9:0] miny,maxy,best_miny,best_maxy;
 reg [7:0] ana_fid;reg [2:0] ana_preset;
 // Red identity survives short segmentation failures. An unrelated component
 // cannot replace the current object merely by gaining more red pixels.
 reg previous_valid,best_associated;
 reg [10:0] previous_minx,previous_maxx;
 reg [9:0] previous_miny,previous_maxy;
 reg [2:0] previous_preset;
 reg [7:0] miss_frames;
 wire stable_mode=(RED_STABLE && ana_preset==0) || (BLUE_STABLE && ana_preset==2);
 wire [3:0] last_neighbour=stable_mode ? (BRIDGE_ONE_TILE?4'd11:4'd7) : 4'd3;
 wire [11:0] component_sumx={1'b0,minx}+{1'b0,maxx};
 wire [10:0] component_sumy={1'b0,miny}+{1'b0,maxy};
 wire [10:0] component_cx=component_sumx[11:1];
 wire [9:0] component_cy=component_sumy[10:1];
 wire associated=previous_valid && previous_preset==ana_preset &&
    component_cx+ASSOC_MARGIN>=previous_minx && component_cx<=previous_maxx+ASSOC_MARGIN &&
    component_cy+ASSOC_MARGIN>=previous_miny && component_cy<=previous_maxy+ASSOC_MARGIN;
 wire accept_region=best_count>=MIN_PIXELS && (!stable_mode || best_seed_count>=MIN_SEED_PIXELS) && (!stable_mode || !previous_valid ||
    best_associated || miss_frames>=REACQUIRE_FRAMES-1);
 wire [11:0] selected_sumx={1'b0,best_minx}+{1'b0,best_maxx};
 wire [10:0] selected_sumy={1'b0,best_miny}+{1'b0,best_maxy};
 reg [31:0] dividend,quotient;reg [21:0] remainder;
 reg [5:0] bit_cnt;reg [10:0] cx,cy;
 wire [21:0] shifted={remainder[20:0],dividend[31]};
 wire ge=shifted>={1'b0,best_count};
 wire [31:0] next_q={quotient[30:0],ge};
 // Abort analysis before capture reuses its bank; malformed input never reads torn frames.
 wire bank_collision=I_valid&&I_sof&&(state!=IDLE)&&(bank_now==ana_bank);
 always @(posedge I_clk or negedge I_rst_n)begin
  if(!I_rst_n)begin
   state<=IDLE;O_target_valid<=0;O_cx<=0;O_cy<=0;O_count<=0;
   O_min_x<=0;O_max_x<=0;O_min_y<=0;O_max_y<=0;O_lost_cnt<=0;
   O_results_upd<=0;O_fid<=0;O_preset<=0;O_error<=0;
   ana_bank<=0;ana_fid<=0;ana_preset<=0;clear_i<=0;scan_i<=0;
   scan_x<=0;scan_y<=0;candidate<=0;cand_x<=0;cand_y<=0;
   node_addr<=0;node_x<=0;node_y<=0;seed<=0;neighbour<=0;
   head<=0;tail<=0;queue_wr<=0;queue_wa<=0;queue_wd<=0;
   seed_count<=0;best_seed_count<=0;previous_valid<=0;best_associated<=0;
   previous_minx<=0;previous_maxx<=0;previous_miny<=0;previous_maxy<=0;previous_preset<=0;miss_frames<=0;
   count<=0;sumx<=0;sumy<=0;minx<=0;maxx<=0;miny<=0;maxy<=0;
   best_count<=0;best_sumx<=0;best_sumy<=0;best_minx<=0;best_maxx<=0;best_miny<=0;best_maxy<=0;
   dividend<=0;quotient<=0;remainder<=0;bit_cnt<=0;cx<=0;cy<=0;
  end else begin
   queue_wr<=0;O_results_upd<=0;
   if(bank_collision)begin state<=IDLE;O_error<=1;O_target_valid<=0;O_results_upd<=1;end
   else case(state)
    IDLE:if(start_pending)begin
     ana_bank<=start_bank;ana_fid<=start_fid;ana_preset<=start_preset;
     clear_i<=0;best_count<=0;best_seed_count<=0;best_associated<=0;state<=CLEAR;
    end
    CLEAR:begin visited[clear_i]<=0;
     if(clear_i==N-1)begin scan_i<=0;scan_x<=0;scan_y<=0;state<=SCAN;end
     else clear_i<=clear_i+1'b1;
    end
    SCAN:begin
     if(scan_i==N)begin
      if(best_count<MIN_PIXELS || stable_mode)state<=LATCH;
      else begin dividend<=best_sumx;quotient<=0;remainder<=0;bit_cnt<=32;state<=DIV_X;end
     end else if(visited[scan_i])begin
      scan_i<=scan_i+1'b1;
      if(scan_x==NX-1)begin scan_x<=0;scan_y<=scan_y+1'b1;end else scan_x<=scan_x+1'b1;
     end else begin
      candidate<=scan_i;cand_x<=scan_x;cand_y<=scan_y;seed<=1;
      count<=0;seed_count<=0;sumx<=0;sumy<=0;head<=0;tail<=0;state<=WAIT_RD;
     end
    end
    WAIT_RD:state<=CHECK;
    CHECK:begin
     visited[candidate]<=1;
     if(!visited[candidate]&&tc>=TILE_MIN)begin
      queue_wr<=1;queue_wa<=tail[10:0];queue_wd<={candidate,cand_x,cand_y};tail<=tail+1'b1;
      seed_count<=seed_total>31?5'd31:seed_total[4:0];
      count<=count+tc;sumx<=sumx+tsx;sumy<=sumy+tsy;
      if(count==0)begin minx<=tminx;maxx<=tmaxx;miny<=tminy;maxy<=tmaxy;end
      else begin
       if(tminx<minx)minx<=tminx;if(tmaxx>maxx)maxx<=tmaxx;
       if(tminy<miny)miny<=tminy;if(tmaxy>maxy)maxy<=tmaxy;
      end
     end
     state<=seed?POP:NEXT_N;
    end
    POP:if(head==tail)state<=COMPARE;else state<=POP_WAIT;
    POP_WAIT:state<=POP_LOAD;
    POP_LOAD:begin
     node_addr<=queue_q[22:12];node_x<=queue_q[11:6];node_y<=queue_q[5:0];
     head<=head+1'b1;neighbour<=0;state<=NEIGH;
    end
    NEIGH:begin seed<=0;state<=WAIT_RD;
     case(neighbour)
      0:if(node_x==0)state<=NEXT_N;else begin candidate<=node_addr-1'b1;cand_x<=node_x-1'b1;cand_y<=node_y;end
      1:if(node_x==NX-1)state<=NEXT_N;else begin candidate<=node_addr+1'b1;cand_x<=node_x+1'b1;cand_y<=node_y;end
      2:if(node_y==0)state<=NEXT_N;else begin candidate<=node_addr-NX;cand_x<=node_x;cand_y<=node_y-1'b1;end
      3:if(node_y==NY-1)state<=NEXT_N;else begin candidate<=node_addr+NX;cand_x<=node_x;cand_y<=node_y+1'b1;end
      4:if(node_x==0||node_y==0)state<=NEXT_N;else begin candidate<=node_addr-NX-1;cand_x<=node_x-1'b1;cand_y<=node_y-1'b1;end
      5:if(node_x==NX-1||node_y==0)state<=NEXT_N;else begin candidate<=node_addr-NX+1;cand_x<=node_x+1'b1;cand_y<=node_y-1'b1;end
      6:if(node_x==0||node_y==NY-1)state<=NEXT_N;else begin candidate<=node_addr+NX-1;cand_x<=node_x-1'b1;cand_y<=node_y+1'b1;end
      7:if(node_x==NX-1||node_y==NY-1)state<=NEXT_N;else begin candidate<=node_addr+NX+1;cand_x<=node_x+1'b1;cand_y<=node_y+1'b1;end
      8:if(node_x<2)state<=NEXT_N;else begin candidate<=node_addr-2;cand_x<=node_x-2;cand_y<=node_y;end
      9:if(node_x>=NX-2)state<=NEXT_N;else begin candidate<=node_addr+2;cand_x<=node_x+2;cand_y<=node_y;end
      10:if(node_y<2)state<=NEXT_N;else begin candidate<=node_addr-2*NX;cand_x<=node_x;cand_y<=node_y-2;end
      11:if(node_y>=NY-2)state<=NEXT_N;else begin candidate<=node_addr+2*NX;cand_x<=node_x;cand_y<=node_y+2;end
     endcase
    end
    NEXT_N:if(neighbour==last_neighbour)state<=POP;else begin neighbour<=neighbour+1'b1;state<=NEIGH;end
    COMPARE:begin
     // Once an object is known, weak fragments inside its neighbourhood belong
     // to the same observation, even if a wide dark band separates them.
     // The combined observation still needs a confident red seed to be valid.
     if(stable_mode && associated && count>=MIN_PIXELS)begin
      best_associated<=1;
      if(best_associated)begin
       best_count<=best_count+count;
       best_seed_count<=selected_seed_total>31?5'd31:selected_seed_total[4:0];
       if(minx<best_minx)best_minx<=minx;if(maxx>best_maxx)best_maxx<=maxx;
       if(miny<best_miny)best_miny<=miny;if(maxy>best_maxy)best_maxy<=maxy;
      end else begin
       best_count<=count;best_seed_count<=seed_count;
       best_minx<=minx;best_maxx<=maxx;best_miny<=miny;best_maxy<=maxy;
      end
     end else if((!stable_mode && count>best_count) ||
       (stable_mode && !best_associated && !associated && count>=MIN_PIXELS && seed_count>=MIN_SEED_PIXELS && count>best_count))begin
      best_associated<=0;best_seed_count<=seed_count;
      best_count<=count;best_sumx<=sumx;best_sumy<=sumy;
      best_minx<=minx;best_maxx<=maxx;best_miny<=miny;best_maxy<=maxy;
     end
     scan_i<=scan_i+1'b1;
     if(scan_x==NX-1)begin scan_x<=0;scan_y<=scan_y+1'b1;end else scan_x<=scan_x+1'b1;
     state<=SCAN;
    end
    DIV_X,DIV_Y:begin
     remainder<=ge?shifted-best_count:shifted;quotient<=next_q;dividend<={dividend[30:0],1'b0};bit_cnt<=bit_cnt-1'b1;
     if(bit_cnt==1)begin
      if(state==DIV_X)begin cx<=next_q[10:0];dividend<=best_sumy;quotient<=0;remainder<=0;bit_cnt<=32;state<=DIV_Y;end
      else begin cy<=next_q[10:0];state<=LATCH;end
     end
    end
    LATCH:begin
     O_fid<=ana_fid;O_preset<=ana_preset;O_count<=stable_mode&&!accept_region?0:best_count;
     O_target_valid<=accept_region;O_results_upd<=1;
     if(stable_mode)begin
      if(accept_region)begin
       previous_valid<=1;previous_preset<=ana_preset;miss_frames<=0;
       previous_minx<=best_minx;previous_maxx<=best_maxx;previous_miny<=best_miny;previous_maxy<=best_maxy;
      end else if(previous_valid)begin
       if(miss_frames>=REACQUIRE_FRAMES-1)previous_valid<=0;
       if(miss_frames<REACQUIRE_FRAMES)miss_frames<=miss_frames+1'b1;
      end
     end else begin previous_valid<=0;miss_frames<=0;end
     if(accept_region)begin
      O_cx<=stable_mode?selected_sumx[11:1]:cx;O_cy<=stable_mode?selected_sumy[10:1]:cy;O_min_x<=best_minx;O_max_x<=best_maxx;
      O_min_y<=best_miny;O_max_y<=best_maxy;O_lost_cnt<=0;
     end else begin
      O_cx<=0;O_cy<=0;O_min_x<=0;O_max_x<=0;O_min_y<=0;O_max_y<=0;
      if(O_lost_cnt!=16'hffff)O_lost_cnt<=O_lost_cnt+1'b1;
     end
     state<=IDLE;
    end
    default:state<=IDLE;
   endcase
   if(I_valid&&I_sof&&I_preset!=previous_preset)begin previous_valid<=0;miss_frames<=0;end
   if(start_pending&&state!=IDLE)O_error<=1;
   if(I_valid&&seen&&!I_sof&&(I_eol!=(px==IMG_WIDTH-1)))O_error<=1;
   if(I_valid&&I_sof&&seen)O_error<=1;
   if(eof&&(bad||px!=IMG_WIDTH-1)&&state==IDLE)begin
    O_error<=1;O_target_valid<=0;O_count<=0;O_cx<=0;O_cy<=0;
    O_min_x<=0;O_max_x<=0;O_min_y<=0;O_max_y<=0;O_results_upd<=1;
    O_fid<=cap_fid;O_preset<=cap_preset;
   end
  end
 end
 // synthesis translate_off
 initial begin
  if(IMG_WIDTH%32||IMG_HEIGHT%16||N>2048||((RED_STABLE||BLUE_STABLE)&&(MIN_SEED_PIXELS<1||MIN_SEED_PIXELS>31)))$fatal(1,"REGION_GEOMETRY_UNSUPPORTED");
 end
 always @(posedge I_clk)if(I_rst_n&&queue_wr&&tail>2048)$fatal(1,"REGION_QUEUE_OVERFLOW");
 // synthesis translate_on
endmodule

// Explicit 20K RAM hardware; test model has exactly the same one-clock read.
module track_region_ram #(parameter W=55,AW=11)(
 input wire clk,we,input wire[AW-1:0] wa,input wire[W-1:0] wd,
 input wire[AW-1:0] ra,output wire[W-1:0] q);
`ifdef TRACK_RAM_SIM
 reg [W-1:0] mem[0:(1<<AW)-1];reg [W-1:0] qr;
 always @(posedge clk)begin if(we)mem[wa]<=wd;qr<=mem[ra];end
 assign q=qr;
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
 .INIT_FILE("NONE"),.FILL_ALL("0")) native_ram(
 .dia(wd),.dib({W{1'b0}}),.addra(wa),.addrb(ra),
 .clka(clk),.clkb(clk),.cea(we),.ceb(1'b1),.ocea(1'b1),.oceb(1'b1),
 .wea(we),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),
 .doa(),.dob(q),.ecc_sbiterr(),.ecc_dbiterr(),
 .ecc_sbiterrinj(1'b0),.ecc_dbiterrinj(1'b0));
`endif
endmodule

