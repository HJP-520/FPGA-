// =============================================================================
// vision_gate_top.v —— TD 综合研究用顶层（非交付 RTL，仅进 scratch 工程）
// 目的：把 vision_top 的宽视频总线收进内部（避免顶层 IO 超过器件 160 上限），
//       用伪随机激励驱动 + 观测汇总输出，保证整链逻辑不被综合器裁剪，
//       从而读到真实的 RAM 映射（dram lut vs ERAM）与 50MHz 时序结论。
// 注：本文件不修改 vision_top 任何逻辑；仅做"激励/观测"包装。
// =============================================================================
`timescale 1ns/1ps
module vision_gate_top (
    input  wire        I_pix_clk,
    input  wire        I_pix_rst_n,
    input  wire        I_pwm_clk,
    input  wire        I_pwm_rst_n,
    output wire [31:0] O_obs,      // pix 域观测汇总（防裁剪）
    output wire [31:0] O_obs2      // pwm 域观测汇总（防裁剪）
);
    // ---- pix 域激励 ----
    reg  [95:0] lfsr;
    reg  [15:0] cnt;
    always @(posedge I_pix_clk or negedge I_pix_rst_n) begin
        if (!I_pix_rst_n) begin
            lfsr <= 96'h0000_0000_0000_0001;
            cnt  <= 16'd0;
        end else begin
            lfsr <= {lfsr[94:0], lfsr[95] ^ lfsr[92]};   // 周期长伪随机像素流
            cnt  <= cnt + 16'd1;
        end
    end

    wire        tvalid = (cnt[2:0] != 3'd0);      // 8 拍 7 有效（近似行级占空）
    wire        tuser  = (cnt[9:0] == 10'd1);     // 必须落在 valid 拍上（cnt[2:0]!=0）
    wire        tlast  = (cnt[9:0] == 10'd1001);

    // ---- 被测：完整视觉链 ----
    wire [95:0] pt_data;
    wire        pt_valid, pt_user, pt_last;
    wire        osd_valid, osd_sof, osd_eol;
    wire [23:0] osd_data;
    wire        pwm_x, pwm_y, led_g, led_r, buzz;
    wire [12:0] duty_x, duty_y;
    wire [15:0] lost;
    wire [7:0]  status;
    wire        ftick, tvalid_o;
    wire [10:0] tcx, tcy;

    (* syn_dont_touch = 1 *)
    vision_top #(.IMG_WIDTH(1280), .IMG_HEIGHT(720)) u_vision (
        .I_pix_clk    (I_pix_clk),
        .I_pix_rst_n  (I_pix_rst_n),
        .I_pwm_clk    (I_pwm_clk),
        .I_pwm_rst_n  (I_pwm_rst_n),
        .I_tdata      (lfsr),
        .I_tvalid     (tvalid),
        .I_tuser      (tuser),
        .I_tlast      (tlast),
        .O_tready     (),
        .O_tdata      (pt_data),
        .O_tvalid     (pt_valid),
        .O_tuser      (pt_user),
        .O_tlast      (pt_last),
        .O_osd_valid  (osd_valid),
        .O_osd_sof    (osd_sof),
        .O_osd_eol    (osd_eol),
        .O_osd_data   (osd_data),
        .I_preset_idx (cnt[2:0]),
        .I_track_en   (cnt[10]),
        .I_algo_edge  (cnt[7]),
        .I_bright     (cnt[6:0]),
        .I_contrast   ({1'b0, cnt[6:0]}),
        .O_pwm_x      (pwm_x),
        .O_pwm_y      (pwm_y),
        .O_duty_x_us  (duty_x),
        .O_duty_y_us  (duty_y),
        .O_lost_cnt   (lost),
        .O_status     (status),
        .O_led_g      (led_g),
        .O_led_r      (led_r),
        .O_buzzer     (buzz),
        .O_frame_tick (ftick),
        .O_target_valid(tvalid_o),
        .O_tgt_cx     (tcx),
        .O_tgt_cy     (tcy)
    );

    // ---- pix 域观测汇总（接入输出端口，防裁剪）----
    reg [31:0] obs;
    always @(posedge I_pix_clk or negedge I_pix_rst_n) begin
        if (!I_pix_rst_n) obs <= 32'd0;
        else
            obs <= obs
                 ^ osd_data
                 ^ {24'h0, osd_valid, osd_sof, osd_eol, 5'h0}
                 ^ pt_data[31:0]
                 ^ pt_data[63:32]
                 ^ pt_data[95:64]
                 ^ {28'h0, pt_valid, pt_user, pt_last, 1'b0}
                 ^ {21'h0, tcx}
                 ^ {21'h0, tcy}
                 ^ {30'h0, ftick, tvalid_o};
    end
    assign O_obs = obs;

    // ---- pwm 域观测汇总 ----
    reg [31:0] obs2;
    always @(posedge I_pwm_clk or negedge I_pwm_rst_n) begin
        if (!I_pwm_rst_n) obs2 <= 32'd0;
        else
            obs2 <= obs2
                  ^ {19'h0, duty_x}
                  ^ {19'h0, duty_y}
                  ^ {16'h0, lost}
                  ^ {24'h0, status}
                  ^ {26'h0, pwm_x, pwm_y, led_g, led_r, buzz, 1'b0};
    end
    assign O_obs2 = obs2;
endmodule
