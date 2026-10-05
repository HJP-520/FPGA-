// =============================================================================
// tb_hsv_threshold.v —— 阈值分割位精确校验：4000 向量 x 8 组预置随机覆盖
// =============================================================================
`timescale 1ns/1ps
module tb_hsv_threshold;
    localparam N = 4000;
    reg clk = 0, rst_n = 0;
    always #7 clk = ~clk;

    reg        in_valid;
    reg  [8:0] in_h;
    reg  [7:0] in_s, in_v;
    reg  [2:0] in_p;
    wire       o_valid, o_sof, o_eol, o_mask;

    hsv_threshold dut (.I_clk(clk), .I_rst_n(rst_n),
        .I_valid(in_valid), .I_sof(1'b0), .I_eol(1'b0),
        .I_h(in_h), .I_s(in_s), .I_v(in_v), .I_preset_idx(in_p),
        .O_valid(o_valid), .O_sof(o_sof), .O_eol(o_eol), .O_mask(o_mask));

    reg [31:0] vin  [0:N-1];   // {H[11:0], S[15:8], V[7:0], preset[3:0]}
    reg [2:0]  vpre [0:N-1];
    reg        vexp [0:N-1];
    integer i, idx = 0, mism = 0;

    initial begin
        $readmemh("threshold_in.hex", vin);
        $readmemh("threshold_exp.hex", vexp);
    end

    integer oc = 0;
    always @(posedge clk) begin
        if (rst_n && o_valid) begin
            if (o_mask !== vexp[oc]) begin
                if (mism < 6)
                    $display("MISM idx=%0d got=%b exp=%b", oc, o_mask, vexp[oc]);
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
            {in_h, in_s, in_v} <= vin[i][31:4];   // 28bit {H,S,V}
            in_p     <= vin[i][3:0];      // 文件自带预置组（=i%8）
            idx = idx + 1;
            @(posedge clk);
        end
        in_valid <= 1'b0;
        repeat (6) @(posedge clk);
        if (mism == 0)
            $display("TB_RESULT: PASS (vectors=%0d)", N);
        else
            $display("TB_RESULT: FAIL mism=%0d/%0d oc=%0d", mism, N, oc);
        $finish;
    end
endmodule
