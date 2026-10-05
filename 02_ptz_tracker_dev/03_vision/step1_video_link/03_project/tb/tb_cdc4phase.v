// =============================================================================
// tb_cdc4phase.v —— 4 相握手数据跨域 TB：200 个随机数据完整性校验
// =============================================================================
`timescale 1ns/1ps
module tb_cdc4phase;
    localparam WIDTH = 23;
    reg clk_s = 0, clk_d = 0, rst_s = 0, rst_d = 0;
    always #7  clk_s = ~clk_s;
    always #10 clk_d = ~clk_d;

    reg  [WIDTH-1:0] s_data = 0;
    reg              s_load = 0;
    wire             s_busy;
    wire [WIDTH-1:0] d_data;
    wire             d_valid;

    cdc_4phase #(.WIDTH(WIDTH)) dut (
        .I_clk_src(clk_s), .I_rst_src_n(rst_s),
        .I_src_data(s_data), .I_src_load(s_load), .O_src_busy(s_busy),
        .I_clk_dst(clk_d), .I_rst_dst_n(rst_d),
        .O_dst_data(d_data), .O_dst_valid(d_valid));

    integer sent = 0, got = 0, mism = 0;
    reg [WIDTH-1:0] exp_q [0:255];
    reg [7:0] wp = 0, rp = 0;

    always @(posedge clk_d) begin
        if (rst_d && d_valid) begin
            if (d_data !== exp_q[rp]) begin
                if (mism < 5)
                    $display("MISM got=%h exp=%h", d_data, exp_q[rp]);
                mism = mism + 1;
            end
            rp = rp + 8'd1;
            got = got + 1;
        end
    end

    integer i;
    reg [WIDTH-1:0] data_v;
    initial begin
        repeat (3) @(posedge clk_s); rst_s <= 1;
        repeat (3) @(posedge clk_d); rst_d <= 1;
        for (i = 0; i < 200; i = i + 1) begin
            wait (!s_busy);
            repeat ($urandom_range(0, 6)) @(posedge clk_s);
            data_v = WIDTH'($urandom());
            s_data <= data_v;
            exp_q[wp] <= data_v;
            wp = wp + 8'd1;
            s_load <= 1'b1;
            @(posedge clk_s);
            s_load <= 1'b0;
            // 等 DUT 受理（busy 拉高）并完成握手（busy 拉低），避免同沿竞态
            @(posedge clk_s);
            wait (s_busy === 1'b1);
            wait (s_busy === 1'b0);
            sent = sent + 1;
        end
        #5000;
        if ((mism == 0) && (got == sent))
            $display("TB_RESULT: PASS (sent=%0d got=%0d)", sent, got);
        else
            $display("TB_RESULT: FAIL sent=%0d got=%0d mism=%0d", sent, got, mism);
        $finish;
    end
endmodule
