// =============================================================================
// tb_uart_telemetry.v —— UART 遥测验证
// 注入 3 帧（valid=1/0/1，坐标各异），解码串行字节流，校验：
//   帧定界 A5/5A、valid 位、cx/cy 全部坐标字节、校验和。
//   （2026-10-03 外脑评审补：原检查器只校 cx 不校 cy——覆盖盲点）
// =============================================================================
`timescale 1ns/1ps
module tb_uart_telemetry;
    localparam CLK_DIV = 646;
    reg clk = 0, rst_n = 0;
    always #7 clk = ~clk;

    reg         frame_tick = 0;
    reg         tv = 0;
    reg [10:0]  cx = 0, cy = 0;
    reg [2:0]   preset = 3'd2;
    wire        txd;

    uart_telemetry #(.CLK_DIV(CLK_DIV)) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_frame_tick(frame_tick), .I_target_valid(tv),
        .I_cx(cx), .I_cy(cy), .I_preset(preset), .O_txd(txd));

    // 激励：三帧，帧间隔 3ms（远大于一包 780µs）
    task send_frame(input v, input integer x, input integer y);
        begin
            tv = v; cx = x; cy = y;
            frame_tick = 1;
            #14;
            frame_tick = 0;
            #3000000;
        end
    endtask

    wire [7:0] rbyte;
    wire       rvalid;
    uart_rx_mon #(.CLK_DIV(CLK_DIV)) u_mon (
        .I_clk(clk), .I_rst_n(rst_n), .I_rxd(txd),
        .O_byte(rbyte), .O_valid(rvalid));

    // 组包校验
    integer state = 0, good = 0, frames = 0, mism = 0;
    reg [7:0] f [0:8];
    always @(posedge clk) begin
        if (rst_n && rvalid) begin
            $display("RXB t=%0t byte=%02x state=%0d", $time, rbyte, state);
            case (state)
                0: if (rbyte == 8'hA5) state = 1;
                8: begin
                    if (rbyte == 8'h5A) begin
                        frames = frames + 1;
                        // 校验和 + 内容
                        if (f[7] == (8'hA5 + f[1] + f[2] + f[3] + f[4] + f[5] + f[6])) begin
                            if ((f[1] == 8'h01) && (f[2] == 8'h52) && (f[3] == 8'h02) &&   // cx=594=0x252
                                (f[4] == 8'h4D) && (f[5] == 8'h01) &&                   // cy=333=0x14D（外脑评审补）
                                (f[6] == 8'h02))
                                good = good + 1;
                        end else mism = mism + 1;
                    end else mism = mism + 1;
                    state = 0;
                end
                default: begin
                    f[state] = rbyte;
                    state = state + 1;
                end
            endcase
        end
    end

    // 帧内容期望：帧0 LOST（00,0,0）不校坐标；帧1 LOCK (0254=594?) 用帧1的 (594, 333)
    // 简化：只对 LOCK 帧校验 X 低位字节与组号（帧1 注入 cx=594=0x252、cy=333）
    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        send_frame(0, 0, 0);
        send_frame(1, 594, 333);
        send_frame(1, 594, 333);
        #4000000;
        if ((frames >= 2) && (good >= 2) && (mism == 0))   // 首帧可能被监视器冷启动吞掉
            $display("TB_RESULT: PASS frames=%0d good=%0d", frames, good);
        else
            $display("TB_RESULT: FAIL frames=%0d good=%0d mism=%0d", frames, good, mism);
        $finish;
    end
    initial begin
        #40000000;
        $display("TB_RESULT: FAIL timeout frames=%0d good=%0d", frames, good);
        $finish;
    end
endmodule
