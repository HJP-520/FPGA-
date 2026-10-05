// =============================================================================
// tb_rgb2hsv.v —— RGB->HSV 位精确校验：10010 个向量（含角点）逐个比对
// 期望值：tools/gen_vectors.py 由 golden_model 位精确生成（rgb2hsv_exp.hex）
// =============================================================================
`timescale 1ns/1ps
module tb_rgb2hsv;
    localparam N = 10010;
    reg clk = 0, rst_n = 0;
    always #7 clk = ~clk;

    reg        in_valid;
    reg  [23:0] in_data;
    wire       o_valid, o_sof, o_eol;
    wire [8:0] o_h;
    wire [7:0] o_s, o_v;

    rgb2hsv dut (.I_clk(clk), .I_rst_n(rst_n),
        .I_valid(in_valid), .I_sof(1'b0), .I_eol(1'b0), .I_data(in_data),
        .O_valid(o_valid), .O_sof(o_sof), .O_eol(o_eol),
        .O_h(o_h), .O_s(o_s), .O_v(o_v));

    reg [23:0] vin  [0:N-1];
    reg [27:0] vexp [0:N-1];   // {H[11:0], S[7:0], V[7:0]} 28bit
    integer i, idx = 0, mism = 0;

    initial begin
        $readmemh("rgb2hsv_in.hex", vin);
        $readmemh("rgb2hsv_exp.hex", vexp);
    end

    // 1:1 有序流：第 oc 个输出即第 oc 个输入的期望
    integer oc = 0;
    always @(posedge clk) begin
        if (rst_n && o_valid) begin
            if ({3'b000, o_h, o_s, o_v} !== vexp[oc]) begin
                if (mism < 6)
                    $display("MISM idx=%0d got h=%0d s=%0d v=%0d exp=%h",
                             oc, o_h, o_s, o_v, vexp[oc]);
                mism = mism + 1;
            end
            oc = oc + 1;
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        rst_n <= 1;
        @(posedge clk);
        for (i = 0; i < N; i = i + 1) begin
            in_valid <= 1'b1;
            in_data  <= vin[i];
            idx = idx + 1;
            @(posedge clk);
        end
        in_valid <= 1'b0;
        repeat (8) @(posedge clk);
        if ((mism == 0) && (oc == N))
            $display("TB_RESULT: PASS (vectors=%0d)", N);
        else
            $display("TB_RESULT: FAIL mism=%0d/%0d oc=%0d", mism, N, oc);
        $finish;
    end
endmodule
