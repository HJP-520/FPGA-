// =============================================================================
// uart_telemetry.v —— 目标状态 UART 遥测（115200-8N1，每帧一包）
// -----------------------------------------------------------------------------
// 帧格式（9 字节）：A5 | valid | cx_lo cx_hi | cy_lo cy_hi | preset | checksum | 5A
// checksum = 低 8 位累加(A5..preset)。上位机按 0xA5 ... 0x5A 定界。
// 波特率 = I_clk / CLK_DIV（74.25MHz/646 ≈ 114938，标准容差内）。
// 发送期间新帧到达则跳过（下一帧再发），绝不打断当前包。
// =============================================================================
module uart_telemetry #(
    parameter integer CLK_DIV = 646
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_frame_tick,     // 每帧一拍（检测域）
    input  wire        I_target_valid,
    input  wire [10:0] I_cx,
    input  wire [10:0] I_cy,
    input  wire [2:0]  I_preset,
    output reg         O_txd
);
    localparam NBYTES = 9;
    reg [7:0] payload [0:NBYTES-1];
    reg [3:0] byte_idx;
    reg [3:0] bit_idx;                    // 0=起始 1..8=数据 9=停止
    reg [9:0] div_cnt;
    reg       sending;
    reg [7:0] shifter;
    reg       tick_d;

    // 快照 + 发送状态机（单一 always —— 外脑评审: 原两块同驱
    // byte_idx/bit_idx/div_cnt/sending 属多驱动寄存器，TD 综合会报错；
    // 合并后时序行为与原设计逐拍一致）
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_txd   <= 1'b1;
            tick_d <= 1'b0;
            sending <= 1'b0;
            div_cnt <= 10'd0;
            bit_idx <= 4'd0;
            byte_idx <= 4'd0;
            shifter <= 8'hFF;
        end else begin
            tick_d <= I_frame_tick;
            if (sending) begin
            if (div_cnt == CLK_DIV - 1) begin
                div_cnt <= 10'd0;
                case (bit_idx)
                    4'd0: begin
                        O_txd   <= 1'b0;                 // 起始位
                        shifter <= payload[byte_idx];    // 装载
                    end
                    4'd9: begin
                        O_txd <= 1'b1;                   // 停止位
                        if (byte_idx == NBYTES - 1)
                            sending <= 1'b0;
                        else
                            byte_idx <= byte_idx + 4'd1;
                    end
                    default: begin                       // 数据位 LSB 先行
                        O_txd   <= shifter[0];
                        shifter <= {1'b0, shifter[7:1]};
                    end
                endcase
                bit_idx <= (bit_idx == 4'd9) ? 4'd0 : bit_idx + 4'd1;
            end else begin
                div_cnt <= div_cnt + 10'd1;
            end
        end else begin
            O_txd <= 1'b1;
            // 帧拍上升沿: 快照目标状态并启动一包发送
            if (I_frame_tick && !tick_d) begin
                payload[0] <= 8'hA5;
                payload[1] <= {7'd0, I_target_valid};
                payload[2] <= I_cx[7:0];
                payload[3] <= {5'd0, I_cx[10:8]};
                payload[4] <= I_cy[7:0];
                payload[5] <= {5'd0, I_cy[10:8]};
                payload[6] <= {5'd0, I_preset};
                payload[7] <= 8'hA5 + {7'd0, I_target_valid} + I_cx[7:0]
                            + {5'd0, I_cx[10:8]} + I_cy[7:0] + {5'd0, I_cy[10:8]}
                            + {5'd0, I_preset};
                payload[8] <= 8'h5A;
                byte_idx <= 4'd0;
                bit_idx  <= 4'd0;
                div_cnt  <= 10'd0;
                sending  <= 1'b1;
            end
        end
    end
end

endmodule
