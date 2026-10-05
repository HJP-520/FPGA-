// =============================================================================
// ser96to24.v —— 96bit(4像素/拍) AXI4-Stream 视频 -> 1像素/拍 vpix 流 串化器
// -----------------------------------------------------------------------------
// 视觉方向自研检测链路的入口适配层。官方 ISP 链路（awb 之后）为 96bit 总线
// （pix0=[95:72], pix1=[71:48], pix2=[47:24], pix3=[23:0]，AXI-S 约定
// tuser=帧起始、tlast=行尾、仅有效像素）。本模块将其拆为单像素流：
//   O_sof：帧首像素；O_eol：行尾像素；O_valid：数据有效。
// 无反压设计（O_tready 恒 1，旁路窃流语义）：输出每拍最多消耗 1 像素，
// 输入每拍最多写入 4 像素；只要时钟 >= 有源像素率(55.3MHz@720p60)，
// 内部 8 深缓冲不会溢出（峰值 7）。上板时挂在 detect 分支入口。
// =============================================================================
module ser96to24 (
    input  wire        I_clk,
    input  wire        I_rst_n,
    // 96bit AXI4-Stream 视频输入（仅有效像素拍）
    input  wire [95:0] I_tdata,
    input  wire        I_tvalid,
    input  wire        I_tuser,
    input  wire        I_tlast,
    output wire        O_tready,
    // 1 像素/拍 vpix 输出
    output reg         O_valid,
    output reg         O_sof,
    output reg         O_eol,
    output reg  [23:0] O_data
);

    assign O_tready = 1'b1;   // 窃流分支，绝不反压上游

    // 8 深像素缓冲（数据+标志同址）
    reg [23:0] mem [0:7];
    reg        sof_q [0:7];
    reg        eol_q [0:7];
    reg [2:0]  wp;            // 写指针
    reg [2:0]  rp;            // 读指针
    reg [3:0]  cnt;           // 缓冲像素数（0..7）

    wire        do_wr = I_tvalid & O_tready;
    wire        do_rd = (cnt != 4'd0);          // 每拍最多读 1 像素
    wire [2:0]  wp_n = wp + 4'd1;
    wire [2:0]  wp_n2 = wp + 4'd2;
    wire [2:0]  wp_n3 = wp + 4'd3;
    wire [2:0]  rp_n = rp + 4'd1;

    wire [23:0] p0 = I_tdata[95:72];
    wire [23:0] p1 = I_tdata[71:48];
    wire [23:0] p2 = I_tdata[47:24];
    wire [23:0] p3 = I_tdata[23:0];

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            wp  <= 3'd0;
            rp  <= 3'd0;
            cnt <= 4'd0;
        end else begin
            if (do_wr) begin
                mem[wp]   <= p0;
                mem[wp_n] <= p1;
                // 4像素入队（赛题分辨率宽为4的倍数，末拍必满4像素）
                mem[wp_n2] <= p2;
                mem[wp_n3] <= p3;
                sof_q[wp]   <= I_tuser;
                sof_q[wp_n] <= 1'b0;
                sof_q[wp_n2]<= 1'b0;
                sof_q[wp_n3]<= 1'b0;
                eol_q[wp]   <= 1'b0;
                eol_q[wp_n] <= 1'b0;
                eol_q[wp_n2]<= 1'b0;
                eol_q[wp_n3]<= I_tlast;
                wp <= wp + 4'd4;
            end
            if (do_rd)
                rp <= rp_n;
            case ({do_wr, do_rd})
                2'b10:   cnt <= cnt + 4'd4;
                2'b01:   cnt <= cnt - 4'd1;
                2'b11:   cnt <= cnt + 4'd3;
                default: cnt <= cnt;
            endcase
        end
    end

    // 组合读出（分布式 RAM 读，速度充裕）
    always @(*) begin
        O_valid = do_rd;
        O_data  = mem[rp];
        O_sof   = sof_q[rp];
        O_eol   = eol_q[rp];
    end

    // 综合提示：mem 用分布式 RAM/寄存器实现，勿推断为 Block RAM（读口组合）
    // synthesis translate_off
    always @(posedge I_clk) begin
        if (I_rst_n && (cnt > 4'd7))
            $display("SER96TO24_FATAL: overflow cnt=%0d t=%0t", cnt, $time);
    end
    // synthesis translate_on

endmodule
