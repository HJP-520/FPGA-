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
    (* ram_style = "distributed" *) reg [23:0] mem   [0:DEPTH-1];
    (* ram_style = "distributed" *) reg        sof_q [0:DEPTH-1];
    (* ram_style = "distributed" *) reg        eol_q [0:DEPTH-1];
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
                mem[wp]    <= p0;
                mem[wp_n]  <= p1;
                mem[wp_n2] <= p2;
                mem[wp_n3] <= p3;
                sof_q[wp]    <= wr_as_sof;          // 真实或（超时后）合成帧首
                sof_q[wp_n]  <= 1'b0;
                sof_q[wp_n2] <= 1'b0;
                sof_q[wp_n3] <= 1'b0;
                eol_q[wp]    <= 1'b0;
                eol_q[wp_n]  <= 1'b0;
                eol_q[wp_n2] <= 1'b0;
                eol_q[wp_n3] <= I_tlast;
                wp <= wp + 11'd4;
            end
            // 读口：寄存器读（rp 当拍指向的像素在下一拍出现在输出寄存器上）
            O_data  <= mem[rp];
            O_sof   <= sof_q[rp];
            O_eol   <= eol_q[rp];
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
