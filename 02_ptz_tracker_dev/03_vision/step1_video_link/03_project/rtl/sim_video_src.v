`timescale 1ns/1ps
// =============================================================================
// sim_video_src.v —— 仿真专用视频源（仅供仿真，禁止综合）
// -----------------------------------------------------------------------------
// 回放 gen_vectors.py 生成的 96bit 拍数据（chain_beats.hex）与
// tuser/tlast 标志（chain_flags.hex），按帧重复 FRAMES 次。
// 替代 MIPI 摄像头，用于 detect 链与整链仿真的确定性激励。
// =============================================================================
module sim_video_src #(
    parameter BEAT_FILE   = "chain_beats.hex",
    parameter FLAG_FILE   = "chain_flags.hex",
    parameter BEATS_TOTAL = 3 * 720 * 320,   // 帧 x 行 x 每行拍数
    parameter FRAMES      = 3,
    parameter FRAME_BEATS = 720 * 320
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    output reg         O_tvalid,
    output reg  [95:0] O_tdata,
    output reg         O_tuser,
    output reg         O_tlast,
    input  wire        I_tready
);

    reg [95:0] beats [0:BEATS_TOTAL-1];
    reg [1:0]  flags [0:BEATS_TOTAL-1];
    integer    idx;
    integer    frame_cnt;
    reg [1:0]  pres;      // 1/4 占空节拍（与真实像素率占用一致）

    initial begin
        $readmemh(BEAT_FILE, beats);
        $readmemh(FLAG_FILE, flags);
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            idx       <= 0;
            frame_cnt <= 0;
            pres      <= 2'd0;
            O_tvalid  <= 1'b0;
            O_tdata   <= 96'd0;
            O_tuser   <= 1'b0;
            O_tlast   <= 1'b0;
        end else if (pres == 2'd3) begin      // 每 4 拍发 1 个 beat
            pres   <= 2'd0;
            O_tvalid <= 1'b1;
            O_tdata  <= beats[idx];
            O_tuser  <= flags[idx][1];
            O_tlast  <= flags[idx][0];
            if (idx == BEATS_TOTAL - 1) begin
                idx <= 0;
                frame_cnt <= frame_cnt + 1;
            end else begin
                idx <= idx + 1;
            end
        end else begin
            pres     <= pres + 2'd1;
            O_tvalid <= 1'b0;
        end
    end

    // synthesis translate_off
    initial begin
        wait (frame_cnt == FRAMES);
        #5000;   // 留足末帧除法与锁存时间
        $display("SIM_SRC_INFO: %0d frames played, stopping at t=%0t", FRAMES, $time);
        $finish;
    end
    // synthesis translate_on

endmodule
