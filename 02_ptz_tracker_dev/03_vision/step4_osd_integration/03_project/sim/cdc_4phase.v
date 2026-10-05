// =============================================================================
// cdc_4phase.v —— N bit 数据跨时钟域（4 相握手，电平比较式）
// -----------------------------------------------------------------------------
// 用途：检测域 -> OSD/控制域 的目标坐标/状态传递（每帧一次，低速）。
// 协议：req/ack 为电平（翻转式）握手。源域 load 时锁存数据并翻转 req；
// 目标域发现 req != ack（2FF 同步后）即锁存数据、翻转 ack、给出 1 拍
// O_dst_valid；源域发现 ack_2ff == req（对端已应答）即解除 busy。
// 数据在 req 翻转前即稳定，且整个握手期间保持不变——跨域采样安全。
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
