// =============================================================================
// tb_gimbal.v —— 云台控制律表驱动校验（死区/限速/限幅/丢失保持）
// 激励与期望由 golden_model.gimbal_ctrl_step 位精确生成。
// =============================================================================
`timescale 1ns/1ps
module tb_gimbal;
    localparam N = 10;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;   // 50MHz 域

    reg        tick = 0, track_en = 1, t_valid = 0;
    reg [10:0] cx = 0, cy = 0;
    wire [12:0] duty_x, duty_y;
    wire [15:0] lost;
    wire [7:0]  status;

    gimbal_ctrl dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_frame_tick(tick), .I_track_en(track_en),
        .I_target_valid(t_valid), .I_cx(cx), .I_cy(cy),
        .O_duty_x_us(duty_x), .O_duty_y_us(duty_y),
        .O_lost_cnt(lost), .O_status(status));

    integer fd_s, fd_e, i, scanned, scanned_e, mism = 0;
    reg stim_v; integer stim_cx, stim_cy;
    integer e_dx, e_dy, e_lost, e_dzx, e_dzy;

    initial begin
        fd_s = $fopen("gimbal_stim.txt", "r");
        fd_e = $fopen("gimbal_exp.txt", "r");
        repeat (3) @(posedge clk);
        rst_n <= 1;
        repeat (2) @(posedge clk);
        for (i = 0; i < N; i = i + 1) begin
            scanned = $fscanf(fd_s, "%1x%3x%3x", stim_v, stim_cx, stim_cy);
            scanned_e = $fscanf(fd_e, "%3x%3x%4x%1x%1x",
                                e_dx, e_dy, e_lost, e_dzx, e_dzy);
            t_valid <= stim_v;
            cx <= stim_cx[10:0];
            cy <= stim_cy[10:0];
            @(posedge clk);
            tick <= 1'b1;
            @(posedge clk);
            tick <= 1'b0;
            repeat (2) @(posedge clk);   // 等 O_duty 锁存
            if ((duty_x !== e_dx[12:0]) || (duty_y !== e_dy[12:0]) ||
                (lost !== e_lost[15:0]) ||
                (status[0] !== e_dzx[0]) || (status[1] !== e_dzy[0])) begin
                $display("MISM i=%0d got x=%0d y=%0d lost=%0d st=%b | exp x=%0d y=%0d lost=%0d dz=%b%b",
                         i, duty_x, duty_y, lost, status, e_dx, e_dy, e_lost, e_dzy, e_dzx);
                mism = mism + 1;
            end else begin
                $display("STEP%0d OK x=%0d y=%0d lost=%0d", i, duty_x, duty_y, lost);
            end
        end
        if (mism == 0)
            $display("TB_RESULT: PASS (steps=%0d)", N);
        else
            $display("TB_RESULT: FAIL mism=%0d", mism);
        $finish;
    end
endmodule
