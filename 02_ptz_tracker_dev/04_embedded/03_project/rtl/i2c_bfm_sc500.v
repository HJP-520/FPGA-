// =============================================================================
// i2c_bfm_sc500.v —— SC500CS I2C 从机 BFM（仅供仿真）
// -----------------------------------------------------------------------------
// 行为级开漏 I2C 从机：7bit 地址 0x36（8bit 写 0x6C），记录主控写入字节序列。
// 每 4 字节为一次寄存器写事务：{0x6C, reg_hi, reg_lo, data}。
// 时序：数据位在 SCL 高电平期稳定，下降沿采样；ACK 在第 9 个 SCL 上升沿拉低、
// 第 9 个下降沿释放；START/STOP 在 SCL 高电平期按 SDA 边沿识别。
// =============================================================================
module i2c_bfm_sc500 #(
    parameter integer MAX_BYTES = 2048
)(
    input  wire I_clk,
    input  wire I_rst_n,
    input  wire I_scl,
    inout  wire I_sda,
    output reg  [15:0] O_byte_cnt,
    output reg         O_addr_seen,
    output reg         O_addr_naked     // 地址不匹配 NAK 事件
);
    // 记录数组放在模块内（V2001 端口不允许数组），TB 层次化读取
    reg [7:0] O_bytes [0:MAX_BYTES-1];
    reg       pull;                    // BFM 拉低使能
    reg [3:0] bit_cnt;                 // 0..7 数据位，8=ACK 位
    reg [7:0] shift;
    reg       addr_match;
    reg       scl_d, sda_d;            // 上一拍值
    wire      scl_rise = I_scl && !scl_d;
    wire      scl_fall = !I_scl && scl_d;
    wire      start_c  = I_scl &&  sda_d && !I_sda;
    wire      stop_c   = I_scl && !sda_d &&  I_sda;
    wire      shift_next_match = {shift[6:0], I_sda} == 8'h6C;

    assign I_sda = pull ? 1'bz : 1'b0; // 开漏
    wire sda_now = I_sda;              // 采样（z 由 TB 上拉为 1）

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            pull <= 1'b1; bit_cnt <= 0; shift <= 0; addr_match <= 0;
            scl_d <= 1'b1; sda_d <= 1'b1;
            O_byte_cnt <= 16'd0; O_addr_seen <= 1'b0; O_addr_naked <= 1'b0;
        end else begin
            scl_d <= I_scl;
            sda_d <= sda_now;

            if (start_c) begin
                bit_cnt <= 4'd0;
                addr_match <= 1'b0;
                pull <= 1'b1;
            end else if (stop_c) begin
                addr_match <= 1'b0;
                pull <= 1'b1;
            end else if (scl_rise) begin
                if (bit_cnt == 4'd8) begin
                    // 第 9 个时钟上升沿：地址匹配或数据字节 -> ACK
                    if (!addr_match) begin
                        // synthesis translate_off
                        $display("BFM_ADDR shift=%h bits=%0d t=%0t", shift, bit_cnt, $time);
                        // synthesis translate_on
                        if (shift[7:1] == 7'h36) begin
                            addr_match  <= 1'b1;
                            O_addr_seen <= 1'b1;
                            pull        <= 1'b0;       // ACK
                        end else begin
                            O_addr_naked <= 1'b1;
                            pull         <= 1'b1;      // NAK
                        end
                    end else begin
                        pull <= 1'b0;                  // 数据 ACK
                    end
                end
            end else if (scl_fall) begin
                if (bit_cnt <= 4'd7) begin
                    shift  <= {shift[6:0], sda_now};   // 采样数据位
                    bit_cnt <= bit_cnt + 4'd1;
                end else begin
                    // 第 9 个下降沿：释放；地址后的字节写入记录
                    pull <= 1'b1;
                    if (addr_match && O_byte_cnt < MAX_BYTES) begin
                        O_bytes[O_byte_cnt[15:0]] <= shift;
                        O_byte_cnt <= O_byte_cnt + 16'd1;
                    end
                    bit_cnt <= 4'd0;
                end
            end
        end
    end

endmodule
