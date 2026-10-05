// =============================================================================
// tb_i2c_config.v —— SC500CS 摄像头配置链验证
// uicfgcs500_720p + uii2c + 寄存器 ROM（官方全套）对着 I2C BFM 跑，
// 逐条比对 BFM 收到的写事务与 uics500reg_720p60 ROM：
//   通过判据：cfg_done 拉高 且 前 116 条写事务 (addr,reg_hi,reg_lo,data)
//   与 ROM 完全一致（AE 追加写只计数不校验）。
// =============================================================================
`timescale 1ns/1ps
module tb_i2c_config;
    reg clk_24 = 0;                       // 24MHz MCLK
    always #20.833 clk_24 = ~clk_24;
    reg rst_n = 0;

    wire cam_scl;
    wire cam_sda;
    reg  [15:0] ae = 16'd0, ag = 16'd0;
    wire ae_req = 1'b0;
    wire cfg_done, ae_cfg_done;

    // 上拉（1kΩ 行为模型）：开漏总线的 1 电平由上拉提供
    pullup(cam_sda);

    // 被测：官方配置链
    uicfgcs500_720p #(.CLK_DIV(239)) u_cfg (
        .I_clk(clk_24), .I_rst_n(rst_n),
        .I_ae_req(ae_req), .I_ae(ae), .I_ag(ag),
        .O_cam_scl(cam_scl), .IO_cam_sda(cam_sda),
        .O_cfg_done(cfg_done), .O_ae_cfg_done(ae_cfg_done));

    // BFM（记录数组在 BFM 内部，层次化读取 u_bfm.O_bytes）
    wire [15:0] byte_cnt;
    wire addr_seen, addr_naked;
    i2c_bfm_sc500 #(.MAX_BYTES(2048)) u_bfm (
        .I_clk(clk_24), .I_rst_n(rst_n), .I_scl(cam_scl), .I_sda(cam_sda),
        .O_byte_cnt(byte_cnt),
        .O_addr_seen(addr_seen), .O_addr_naked(addr_naked));

    // 期望 ROM（与被测同源）
    wire [31:0] reg_data;
    wire [8:0]  reg_size;
    reg [8:0]   idx;
    uics500reg_720p60 u_rom (.REG_INDEX(idx), .REG_DATA(reg_data), .REG_SIZE(reg_size));

    integer mism = 0, checked = 0;
    integer i;
    reg [7:0] e_hi, e_lo, e_da;

    // 周期性进度显示
    reg [15:0] last_bc = 0;
    always @(posedge clk_24) begin
        if (rst_n && (byte_cnt % 40 == 0) && byte_cnt != last_bc) begin
            last_bc <= byte_cnt;
            $display("PROG t=%0t tb_wire=%0d bfm_int=%0d match=%b seen=%b", $time, byte_cnt, u_bfm.O_byte_cnt, u_bfm.addr_match, addr_seen);
        end
    end

    // 等待配置完成
    initial begin
        repeat (5) @(posedge clk_24);
        rst_n = 1;
        wait (cfg_done === 1'b1);
        repeat (100) @(posedge clk_24);
        // 终态一次性扫描：前 116 条写事务与 ROM 逐条比对
        checked = 0;
        for (i = 0; i < 116; i = i + 1) begin
            idx = i[8:0];
            e_hi = reg_data[23:16]; e_lo = reg_data[15:8]; e_da = reg_data[7:0];
            if (u_bfm.O_bytes[i*4+0] !== 8'h6C ||
                u_bfm.O_bytes[i*4+1] !== e_hi ||
                u_bfm.O_bytes[i*4+2] !== e_lo ||
                u_bfm.O_bytes[i*4+3] !== e_da) begin
                if (mism < 4)
                    $display("MISM wr#%0d got %h %h %h %h | exp 6C %h %h %h",
                             i, u_bfm.O_bytes[i*4+0], u_bfm.O_bytes[i*4+1],
                             u_bfm.O_bytes[i*4+2], u_bfm.O_bytes[i*4+3], e_hi, e_lo, e_da);
                mism = mism + 1;
            end
            checked = checked + 1;
        end
        if ((mism == 0) && (checked == 116) && (addr_seen === 1'b1))
            $display("TB_RESULT: PASS (writes=%0d)", checked);
        else
            $display("TB_RESULT: FAIL mism=%0d checked=%0d addr_seen=%b naked=%b",
                     mism, checked, addr_seen, addr_naked);
        $finish;
    end

    initial begin
        #60000000;   // 60ms 上限（116 条 @ ~50kHz I2C 约 1.2ms，AE 追加后仍远小于此）
        $display("TB_RESULT: FAIL timeout checked=%0d mism=%0d cfg_done=%b", checked, mism, cfg_done);
        $finish;
    end
endmodule
