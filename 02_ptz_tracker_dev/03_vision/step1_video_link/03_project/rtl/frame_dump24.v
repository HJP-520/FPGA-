`timescale 1ns/1ps
// =============================================================================
// frame_dump24.v —— vpix 1像素/拍 流 -> 逐帧 hex 文件（仅供仿真，禁止综合）
// -----------------------------------------------------------------------------
// 每帧写一个文件 <BASE>_<帧号>.hex，每行一个 24bit RGB888 像素（行主序），
// 帧长固定 W*H=1280*720。O_frame_done 在每帧最后一个像素写完后输出 1 拍。
// 供 Python 端与金标准渲染帧逐像素比对。
// =============================================================================
module frame_dump24 #(
    parameter BASE_NAME  = "frame",
    parameter MAX_FRAMES = 4,
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_valid,
    input  wire        I_eol,
    input  wire [23:0] I_data,
    output reg         O_frame_done
);

    localparam FRAME_PX = IMG_WIDTH * IMG_HEIGHT;

    integer      fd;
    integer      frame_idx;
    integer      px_cnt;
    reg [1023:0] fname;

    initial begin
        frame_idx = 0;
        px_cnt    = 0;
        $sformat(fname, "%s_%0d.hex", BASE_NAME, frame_idx);
        fd = $fopen(fname, "w");
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_frame_done <= 1'b0;
        end else begin
            O_frame_done <= 1'b0;
            if (I_valid && frame_idx < MAX_FRAMES) begin
                $fwrite(fd, "%02X%02X%02X\n", I_data[23:16], I_data[15:8], I_data[7:0]);
                if (px_cnt == FRAME_PX - 1) begin   // 本帧最后像素
                    $fflush(fd);
                    $fclose(fd);
                    O_frame_done <= 1'b1;
                    frame_idx = frame_idx + 1;
                    px_cnt    = 0;
                    if (frame_idx < MAX_FRAMES) begin
                        $sformat(fname, "%s_%0d.hex", BASE_NAME, frame_idx);
                        fd = $fopen(fname, "w");
                    end
                end else begin
                    px_cnt = px_cnt + 1;
                end
            end
        end
    end

endmodule
