// =============================================================================
// tb_bin_smooth.v —— 3x3 多数表决平滑位精确校验（64x48 迷你几何 x 4 帧）
// 输入带 sof/eol 帧行定界；逐像素比对 smooth_exp.hex。
// =============================================================================
`timescale 1ns/1ps
module tb_bin_smooth;
    localparam W = 64, H = 48, FRAMES = 4, TOTAL = W*H*FRAMES;
    reg clk = 0, rst_n = 0;
    always #7 clk = ~clk;

    reg        in_valid, in_sof, in_eol, in_mask;
    wire       o_valid, o_sof, o_eol, o_mask;

    bin_smooth3x3 #(.IMG_WIDTH(W), .IMG_HEIGHT(H)) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_valid(in_valid), .I_sof(in_sof), .I_eol(in_eol), .I_mask(in_mask),
        .O_valid(o_valid), .O_sof(o_sof), .O_eol(o_eol), .O_mask(o_mask));

    reg        vin  [0:TOTAL-1];
    reg        vexp [0:TOTAL-1];
    integer    i = 0, o = 0, mism = 0, x = 0, y = 0;
    reg        x_sof, x_eol;

    initial begin
        $readmemh("smooth_in.hex", vin);
        $readmemh("smooth_exp.hex", vexp);
    end

    // 驱动：1 像素/拍，sof/eol 按几何
    always @(posedge clk) begin
        if (rst_n && (i < TOTAL+1)) begin           // 多喂 1 个冲刷令牌
            in_valid <= 1'b1;
            in_mask  <= (i == TOTAL) ? 1'b0 : vin[i];
            x_sof    = (i % (W*H) == 0);
            x_eol    = (x == W-1);
            in_sof   <= x_sof;
            in_eol   <= x_eol;
            if (x == W-1) begin
                x <= 0;
                y <= y + 1;
            end else begin
                x <= x + 1;
            end
            i = i + 1;
        end else begin
            in_valid <= 1'b0; in_sof <= 1'b0; in_eol <= 1'b0;
        end
    end

    // 比对
    always @(posedge clk) begin
        if (rst_n && o_valid) begin
            if (o_mask !== vexp[o]) begin
                if (mism < 8)
                    $display("MISM px=%0d got=%b exp=%b", o, o_mask, vexp[o]);
                mism = mism + 1;
            end
            o = o + 1;
            if (o == TOTAL) begin
                if (mism == 0)
                    $display("TB_RESULT: PASS (pixels=%0d)", o);
                else
                    $display("TB_RESULT: FAIL mism=%0d/%0d", mism, o);
                $finish;
            end
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        rst_n <= 1;
        #20000000;
        $display("TB_RESULT: FAIL timeout o=%0d/%0d", o, TOTAL);
        $finish;
    end
endmodule
