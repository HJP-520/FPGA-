`timescale 1ns/1ps
// =============================================================================
// px_serializer_fifo.v —— 仿真专用弹性串化器（96bit 4像素/拍 -> 1像素/拍）
// -----------------------------------------------------------------------------
// 与 ser96to24（无反压窃流设计）不同：本模块带 8192 beat 弹性 FIFO，
// 并把"空位不足"如实反压回上游（O_ready -> isp 上游流控）。
// 官方链路里 ISP 输出去往 DDR 帧缓存（深缓冲吸收行级突发）；
// 仿真里没有 DDR，用本模块充当"浅 DDR"，保证零丢拍。
// 每个存储字 = {eol, sof, data[95:0]}；sof 标在首像素、eol 标在第 4 像素。
// 仅供仿真，禁止综合。
// =============================================================================
module px_serializer_fifo #(
    parameter DEPTH = 8192                    // beat 数（2 的幂）
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_valid,
    input  wire        I_sof,
    input  wire        I_eol,
    input  wire [95:0] I_data,
    output wire        O_ready,               // 对上游的反压（空位充足才为 1）
    output reg         O_valid,
    output reg         O_sof,
    output reg         O_eol,
    output reg  [23:0] O_data,
    output reg  [15:0] O_dbg_overflows        // 调试：因满被拒的 beat 计数
);
    reg [97:0] mem [0:DEPTH-1];
    reg [12:0] waddr, raddr;
    reg [13:0] count;                         // FIFO 内 beat 数
    reg [1:0]  px_sel;                        // 当前 beat 内像素指针

    assign O_ready = (count < DEPTH - 4);

    wire wr        = I_valid && O_ready;
    wire rd        = (count != 14'd0);
    wire beat_done = rd && (px_sel == 2'd3);  // 本拍第 4 像素已输出 = beat 消费完

    wire [97:0] rword = mem[raddr];
    wire [23:0] rpx   = (px_sel == 2'd0) ? rword[23:0]   :
                        (px_sel == 2'd1) ? rword[47:24]  :
                        (px_sel == 2'd2) ? rword[71:48]  :
                                           rword[95:72];

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            waddr <= 13'd0; raddr <= 13'd0; count <= 14'd0; px_sel <= 2'd0;
            O_valid <= 1'b0; O_sof <= 1'b0; O_eol <= 1'b0; O_data <= 24'd0;
            O_dbg_overflows <= 16'd0;
        end else begin
            O_valid <= 1'b0;

            if (wr) begin
                mem[waddr] <= {I_eol, I_sof, I_data};
                waddr <= waddr + 13'd1;
            end
            if (beat_done)
                raddr <= raddr + 13'd1;

            // count: 写 +1，beat 消费完 -1（同拍两者相抵）
            if (wr && !beat_done)        count <= count + 14'd1;
            else if (!wr && beat_done)   count <= count - 14'd1;

            if (rd) begin
                O_valid <= 1'b1;
                O_data  <= rpx;
                O_sof   <= rword[96] && (px_sel == 2'd0);   // 首像素携带 sof
                O_eol   <= rword[97] && (px_sel == 2'd3);   // 末像素携带 eol
                px_sel <= (px_sel == 2'd3) ? 2'd0 : px_sel + 2'd1;
            end else begin
                O_sof <= 1'b0;
                O_eol <= 1'b0;
            end

            if (I_valid && !O_ready)
                O_dbg_overflows <= O_dbg_overflows + 16'd1;
        end
    end

endmodule
