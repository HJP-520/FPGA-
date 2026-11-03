
module logo_display #(
    parameter LOGO_W = 256,
    parameter LOGO_H = 80,
    parameter X_OFF  = 384,
    parameter Y_OFF  = 190,
    parameter HTOTAL  = 1650,
    parameter VTOTAL  = 750,
    parameter HACTIVE = 1280,
    parameter VACTIVE = 720
) (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire [10:0] i_col,
    input  wire [9:0]  i_line,
    input  wire        i_user,
    input  wire        i_valid,
    input  wire        i_last,
    output wire [23:0] o_data,
    output reg         o_user,
    output reg         o_valid,
    output reg         o_last
);



    localparam [23:0] PAL_BLACK = 24'h000000;
    localparam [23:0] PAL_WHITE = 24'hFFFFFF;
    localparam [23:0] PAL_BLUE  = 24'h011459;
    localparam [23:0] PAL_RED   = 24'hEE0600;









    localparam HBLANK = HTOTAL - HACTIVE;
    localparam VBLANK = VTOTAL - VACTIVE;
    wire [10:0] x_act = i_col - HBLANK;
    wire [9:0]  y_act = i_line - VBLANK;

    wire        in_win = (x_act >= X_OFF) && (x_act < X_OFF + LOGO_W) &&
                         (y_act >= Y_OFF) && (y_act < Y_OFF + LOGO_H);

    wire [17:0] pix_idx = (y_act - Y_OFF) * LOGO_W + (x_act - X_OFF);

    reg  [17:0] addr_r;
    reg         win_r;
    reg         user_r1, valid_r1, last_r1;

    initial begin
        addr_r  = 18'd0;
        win_r   = 1'b0;
        user_r1 = 1'b0;  valid_r1 = 1'b0;  last_r1 = 1'b0;
    end

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            addr_r   <= 18'd0;
            win_r    <= 1'b0;
            user_r1  <= 1'b0;  valid_r1 <= 1'b0;  last_r1 <= 1'b0;
        end else begin
            addr_r   <= in_win ? pix_idx : 18'd0;
            win_r    <= in_win;
            user_r1  <= i_user;
            valid_r1 <= i_valid;
            last_r1  <= i_last;
        end
    end


    wire [3:0] rom_index;

    logo_rom u_logo_rom (
        .i_clk   (i_clk),
        .i_addr  (addr_r),
        .o_index (rom_index)
    );

    reg         win_r1, win_r2;
    reg         user_r2, valid_r2, last_r2;

    initial begin
        win_r1 = 1'b0;  win_r2 = 1'b0;
        user_r2 = 1'b0; valid_r2 = 1'b0; last_r2 = 1'b0;
    end

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            win_r1 <= 1'b0;  win_r2 <= 1'b0;
            user_r2 <= 1'b0; valid_r2 <= 1'b0; last_r2 <= 1'b0;
        end else begin
            win_r1  <= win_r;
            win_r2  <= win_r1;
            user_r2 <= user_r1;
            valid_r2 <= valid_r1;
            last_r2 <= last_r1;
        end
    end



    function [23:0] palette_rgb;
        input [3:0] index;
        begin
            case(index)
                4'd0: palette_rgb=24'h000000;
                4'd1: palette_rgb=24'hffffff;
                4'd2: palette_rgb=24'h0d1c39;
                4'd3: palette_rgb=24'h303c55;
                4'd4: palette_rgb=24'h525d72;
                4'd5: palette_rgb=24'h757d8e;
                4'd6: palette_rgb=24'h979eaa;
                4'd7: palette_rgb=24'hbabec6;
                4'd8: palette_rgb=24'hdcdfe3;
                4'd9: palette_rgb=24'he01d28;
                4'd10: palette_rgb=24'he43d47;
                4'd11: palette_rgb=24'he95e65;
                4'd12: palette_rgb=24'hed7e84;
                4'd13: palette_rgb=24'hf29ea3;
                4'd14: palette_rgb=24'hf6bec2;
                4'd15: palette_rgb=24'hfbdfe0;
                default: palette_rgb=24'hFFFFFF;
            endcase
        end
    endfunction
    assign o_data = win_r2 ? palette_rgb(rom_index) : 24'h000000;

    initial begin
        o_user = 1'b0;  o_valid = 1'b0;  o_last = 1'b0;
    end

    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            o_user  <= 1'b0;  o_valid <= 1'b0;  o_last <= 1'b0;
        end else begin
            o_user  <= user_r2;
            o_valid <= valid_r2;
            o_last  <= last_r2;
        end
    end

endmodule
