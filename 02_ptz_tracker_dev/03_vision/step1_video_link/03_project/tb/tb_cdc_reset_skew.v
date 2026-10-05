`timescale 1ns/1ps
// =============================================================================
// tb_cdc_reset_skew.v —— cdc_4phase 复位偏斜验证（三版外部评审共识的硬 Gate）
// -----------------------------------------------------------------------------
// 架构约束：CDC 两侧复位**同源**（同一板级复位网络），仅释放时刻存在域间偏斜。
// 本 TB 验证该约束下的行为：
//   每轮：两域复位同时拉低 → 错开 K 拍释放（K = 0/3/7/10）
//   1) 释放后静默 60 拍：断言无任何 O_dst_valid（无伪事务）
//   2) 连续两笔事务：断言恰好两次 valid、数据与顺序正确（无重复/无丢失）
// 说明：运行时"单侧复位"不在支持范围（需 epoch/re-arm 协议），已在
// cdc_4phase.v 头部契约注明。
// =============================================================================
module tb_cdc_reset_skew;
    reg src_clk = 0, dst_clk = 0;
    always #7  src_clk = ~src_clk;    // ~71.4MHz（源域）
    always #10 dst_clk = ~dst_clk;    // 50MHz（目标域）

    reg        src_rst_n = 0, dst_rst_n = 0;
    reg [22:0] src_data = 23'd0;
    reg        src_load = 0;
    wire [22:0] dst_data;
    wire        dst_valid, src_busy;

    cdc_4phase #(.WIDTH(23)) u_dut (
        .I_clk_src(src_clk), .I_rst_src_n(src_rst_n),
        .I_src_data(src_data), .I_src_load(src_load), .O_src_busy(src_busy),
        .I_clk_dst(dst_clk), .I_rst_dst_n(dst_rst_n),
        .O_dst_data(dst_data), .O_dst_valid(dst_valid)
    );

    integer    valid_cnt = 0, mism = 0, rounds = 0;
    reg [22:0] cap;

    always @(posedge dst_clk) begin
        if (dst_valid) begin
            valid_cnt = valid_cnt + 1;
            cap = dst_data;
        end
    end

    // 一轮：错开 skew 拍释放 → 静默窗 → 两笔事务
    task run_round;
        input integer skew;
        input [22:0] d0;
        input [22:0] d1;
        begin
            // 两域复位同时拉低
            src_rst_n = 1'b0; dst_rst_n = 1'b0;
            repeat (5) @(posedge src_clk);
            repeat (2) @(posedge dst_clk);
            valid_cnt = 0;

            // 错开释放：源域先、目标域晚 skew 个目标周期
            src_rst_n = 1'b1;
            repeat (skew) @(posedge dst_clk);
            dst_rst_n = 1'b1;

            // 静默窗：不得出现任何 valid
            repeat (60) @(posedge dst_clk);
            if (valid_cnt != 0) begin
                $display("MISM skew=%0d 静默期伪 valid x%0d", skew, valid_cnt);
                mism = mism + 1;
            end

            // 第一笔
            @(posedge src_clk); src_data = d0; src_load = 1'b1;
            @(posedge src_clk); src_load = 1'b0;
            repeat (150) @(posedge dst_clk);
            if (valid_cnt != 1) begin
                $display("MISM skew=%0d 第一笔 valid 次数=%0d（期望 1）", skew, valid_cnt);
                mism = mism + 1;
            end else if (cap !== d0) begin
                $display("MISM skew=%0d 第一笔数据 %h != %h", skew, cap, d0);
                mism = mism + 1;
            end

            // 第二笔
            @(posedge src_clk); src_data = d1; src_load = 1'b1;
            @(posedge src_clk); src_load = 1'b0;
            repeat (150) @(posedge dst_clk);
            if (valid_cnt != 2) begin
                $display("MISM skew=%0d 第二笔后累计 valid=%0d（期望 2）", skew, valid_cnt);
                mism = mism + 1;
            end else if (cap !== d1) begin
                $display("MISM skew=%0d 第二笔数据 %h != %h", skew, cap, d1);
                mism = mism + 1;
            end

            rounds = rounds + 1;
            $display("ROUND skew=%0d OK (valid_cnt=%0d)", skew, valid_cnt);
        end
    endtask

    initial begin
        run_round(0,  23'h012345, 23'h0ABCDE);
        run_round(3,  23'h100001, 23'h200002);
        run_round(7,  23'h3FFFFF, 23'h000001);
        run_round(10, 23'h155555, 23'h2AAAAA);
        if (mism == 0)
            $display("TB_RESULT: PASS rounds=%0d", rounds);
        else
            $display("TB_RESULT: FAIL mism=%0d", mism);
        $finish;
    end

    initial begin
        #2000000;
        $display("TB_RESULT: FAIL timeout mism=%0d rounds=%0d", mism, rounds);
        $finish;
    end
endmodule
