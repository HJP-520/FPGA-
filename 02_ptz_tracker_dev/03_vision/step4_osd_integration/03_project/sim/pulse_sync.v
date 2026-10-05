// =============================================================================
// pulse_sync.v —— 单 bit 脉冲跨时钟域（toggle 同步器）
// -----------------------------------------------------------------------------
// 源域脉冲 -> 目标域等宽脉冲。用于 frame_tick（检测域 -> 云台/PWM 域）。
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
