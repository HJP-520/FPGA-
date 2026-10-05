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
    wire last_line = (y == IMG_HEIGHT - 1);

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            x <= 11'd0; y <= 10'd0;
        end else if (I_valid) begin
            if (I_eol) begin
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
            sum_x <= 32'd0; sum_y <= 32'd0; cnt <= 21'd0; seen <= 1'b0; // 帧首清零
        end else if (hit) begin
            sum_x <= sum_x + {21'd0, x};
            sum_y <= sum_y + {22'd0, y};
            cnt   <= cnt + 21'd1;
            if (!seen) begin
                seen   <= 1'b1;
                bmin_x <= x; bmax_x <= x; bmin_y <= y; bmax_y <= y;
            end else begin
                if (x < bmin_x) bmin_x <= x;
                if (x > bmax_x) bmax_x <= x;
                if (y < bmin_y) bmin_y <= y;
                if (y > bmax_y) bmax_y <= y;
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
