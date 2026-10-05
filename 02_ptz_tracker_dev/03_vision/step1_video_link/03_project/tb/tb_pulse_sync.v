// =============================================================================
// tb_pulse_sync.v —— 脉冲跨域 TB：异步双时钟，100 个随机脉冲 1:1 传递
// =============================================================================
`timescale 1ns/1ps
module tb_pulse_sync;
    reg clk_s = 0, clk_d = 0, rst_s = 0, rst_d = 0;
    always #7  clk_s = ~clk_s;    // ~71.4MHz 源
    always #10 clk_d = ~clk_d;    // 50MHz 目标

    reg  pulse_s = 0;
    wire pulse_d;

    pulse_sync dut (
        .I_clk_src(clk_s), .I_rst_src_n(rst_s), .I_pulse_src(pulse_s),
        .I_clk_dst(clk_d), .I_rst_dst_n(rst_d), .O_pulse_dst(pulse_d));

    integer sent = 0, got = 0, i;
    reg [15:0] lfsr = 16'h1234;

    always @(posedge clk_d) begin
        if (rst_d && pulse_d)
            got = got + 1;
    end

    initial begin
        repeat (3) @(posedge clk_s);
        rst_s <= 1;
        repeat (3) @(posedge clk_d);
        rst_d <= 1;
        for (i = 0; i < 100; i = i + 1) begin
            repeat ($urandom_range(4, 20)) @(posedge clk_s);
            pulse_s <= 1'b1;
            @(posedge clk_s);
            pulse_s <= 1'b0;
            sent = sent + 1;
        end
        #5000;
        if (got == sent)
            $display("TB_RESULT: PASS (sent=%0d got=%0d)", sent, got);
        else
            $display("TB_RESULT: FAIL sent=%0d got=%0d", sent, got);
        $finish;
    end
endmodule
