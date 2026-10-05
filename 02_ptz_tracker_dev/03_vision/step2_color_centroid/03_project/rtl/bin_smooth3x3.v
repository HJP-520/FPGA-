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
    reg        started;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            x <= 11'd0; y <= 10'd0; started <= 1'b0;
        end else if (I_valid) begin
            if (I_sof) begin
                x <= 11'd1; y <= 10'd0; started <= 1'b1;
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
    wire d0 = line0_arr[x];          // row y-1 列 x
    wire d1 = line1_arr[x];          // row y-2 列 x

    // 写新值：当前行进 line0，被挤出的 d0 进 line1（行滚动）
    always @(posedge I_clk) begin
        if (I_valid) begin
            line1_arr[x] <= d0;
            line0_arr[x] <= I_mask;
        end
    end

    // ---------------- 行选择（垂直复制规则） ----------------
    // t* 管道载运 row y-2、m* 载运 row y-1、b* 载运 row y（当前行）
    wire t_sel_r = (y == 10'd0) ? I_mask :
                   (y == 10'd1) ? d0    : d1;
    wire m_sel_r = (y == 10'd0) ? I_mask : d0;
    wire b_sel_r = I_mask;

    // ---------------- 水平 FF 抽头 ----------------
    reg t0, t1, m0, m1, b0, b1;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            {t0,t1} <= 2'b00; {m0,m1} <= 2'b00; {b0,b1} <= 2'b00;
        end else if (I_valid) begin
            t0 <= t_sel_r; m0 <= m_sel_r; b0 <= b_sel_r;
            t1 <= t0;      m1 <= m0;      b1 <= b0;
            if (x == 11'd0) begin
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

    wire main_en = (x >= 11'd1);
    wire last_en = (x == 11'd0) && started;

    // ---------------- 输出 ----------------
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_valid <= 1'b0; O_sof <= 1'b0; O_eol <= 1'b0; O_mask <= 1'b0;
        end else begin
            O_valid <= I_valid && (main_en || last_en);
            O_sof   <= I_valid && main_en && (y == 10'd0) && (x == 11'd1);
            O_eol   <= I_valid && last_en;      // 行尾窗口即每行最后一个输出
            O_mask  <= I_valid && (main_en ? (win_main >= 4'd5) :
                                   (last_en ? (win_last >= 4'd5) : 1'b0));
        end
    end

endmodule
