// =============================================================================
// hsv_threshold.v —— HSV 阈值分割（8 组预置阈值，1 拍延迟）
// -----------------------------------------------------------------------------
// mask = H∈[h_lo..h_hi]（支持环绕窗口，用于红色 335..25）且 S>=s_lo
//        且 v_lo<=V<=v_hi
// 阈值组与 golden_model.py::HSV_PRESETS 一致；I_preset_idx 由按键/拨码
// 切换（上板时接嵌入式方向的键控模块）。
// =============================================================================
module hsv_threshold (
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
            3'd0: begin h_lo = 9'd335; h_hi = 9'd25;  s_lo = 8'd80; v_lo = 8'd60;  v_hi = 8'd255; end // 红
            3'd1: begin h_lo = 9'd110; h_hi = 9'd145; s_lo = 8'd60; v_lo = 8'd40;  v_hi = 8'd255; end // 绿
            3'd2: begin h_lo = 9'd200; h_hi = 9'd250; s_lo = 8'd60; v_lo = 8'd40;  v_hi = 8'd255; end // 蓝
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
