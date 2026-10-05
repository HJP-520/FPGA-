
// =============================================================================
// divider_gate_sim.v —— divider_gate 门级网表的行为级替身（仅供仿真）
// TD 综合时排除本文件，使用官方 divider_gate.v（AL_* 库单元）。
// 行为：start 上升沿锁存，16 拍后 done 一拍脉冲，quotient = num/den（floor）。
// =============================================================================
`timescale 1ns/1ps
module divider (
    input  wire        clk,
    input  wire [31:0] denominator,
    input  wire [47:0] numerator,
    input  wire        rst,
    input  wire        start,
    output reg         done,
    output reg  [47:0] quotient,
    output reg  [31:0] remainder
);
    reg [47:0] num_q;
    reg [31:0] den_q;
    reg [5:0]  wait_cnt;
    reg busy;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            done <= 1'b0; busy <= 1'b0;
            quotient <= 0; remainder <= 0;
            num_q <= 0; den_q <= 0; wait_cnt <= 0;
        end else begin
            done <= 1'b0;
            if (!busy && start && !done) begin
                num_q <= numerator;
                den_q <= denominator;
                busy  <= 1'b1;
                wait_cnt <= 0;
            end else if (busy) begin
                if (wait_cnt == 6'd15) begin
                    if (den_q != 0) begin
                        quotient  <= num_q / den_q;
                        remainder <= num_q % den_q;
                    end else begin
                        quotient <= {48{1'b1}};
                        remainder <= num_q;
                    end
                    done <= 1'b1;
                    busy <= 1'b0;
                end else begin
                    wait_cnt <= wait_cnt + 6'd1;
                end
            end
        end
    end
endmodule
