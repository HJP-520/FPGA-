// ANLOGIC reference logo, native 256x80, 16-colour edge palette.
// Pixel stream and sync retain the existing four-register pipeline.
module ui_logo_page #(
    parameter SCALE = 1,        
    parameter X_OFF = 16,       
    parameter Y_OFF = 16,       
    parameter LOGO_W = 256,     
    parameter LOGO_H = 80      
)(
    input  wire        I_clk,          
    input  wire        I_rst_n,        
    input  wire        I_de,           
    input  wire        I_vsync,        
    input  wire [23:0] I_cam_data,     
    output reg  [23:0] O_data,         
    output reg         O_vsync,
    output reg         O_de
);
    localparam OV_W = LOGO_W / SCALE;      
    localparam OV_H = LOGO_H / SCALE;      

    
    localparam [23:0] PAL_WHITE = 24'hFFFFFF;
    localparam [23:0] PAL_BLUE  = 24'h011459;
    localparam [23:0] PAL_RED   = 24'hEE0600;

    
    reg [10:0] x_act;      
    reg [9:0]  y_act;      
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin x_act <= 11'd0; y_act <= 10'd0; end
        else begin
            if (!I_de)                            x_act <= 11'd0;
            else                                  x_act <= x_act + 11'd1;
            if (I_vsync)                          y_act <= 10'd0;
            else if (I_de && (x_act == 11'd1279)) y_act <= y_act + 10'd1;
        end
    end

    
    wire [11:0] dx = (x_act >= X_OFF) ? (x_act - X_OFF) : 12'd0;
    wire [11:0] dy = (y_act >= Y_OFF) ? (y_act - Y_OFF) : 12'd0;
    wire in_win = I_de && (x_act >= X_OFF) && (x_act < X_OFF + OV_W) &&
                         (y_act >= Y_OFF) && (y_act < Y_OFF + OV_H);

    reg         win_r;
    reg  [17:0] addr_r;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin win_r <= 1'b0; addr_r <= 18'd0; end
        else begin
            win_r  <= in_win;
            addr_r <= in_win ? (SCALE * dy) * LOGO_W + (SCALE * dx) : 18'd0;   
        end
    end

    
    wire [3:0] rom_index;
    logo_rom #(
        .IMG_W (LOGO_W), .IMG_H (LOGO_H),
        .ADDR_W(18), .DEPTH((LOGO_W*LOGO_H+1)/2)
    ) u_logo_rom (
        .i_clk   (I_clk),
        .i_addr  (addr_r),
        .o_index (rom_index)
    );

    reg win_r1, win_r2;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin win_r1 <= 1'b0; win_r2 <= 1'b0; end
        else begin win_r1 <= win_r; win_r2 <= win_r1; end
    end

    
    reg [23:0] ov_rgb;
    always @* begin
        case (rom_index)
            4'd0: ov_rgb=24'h000000;
            4'd1: ov_rgb=24'hffffff;
            4'd2: ov_rgb=24'h0d1c39;
            4'd3: ov_rgb=24'h303c55;
            4'd4: ov_rgb=24'h525d72;
            4'd5: ov_rgb=24'h757d8e;
            4'd6: ov_rgb=24'h979eaa;
            4'd7: ov_rgb=24'hbabec6;
            4'd8: ov_rgb=24'hdcdfe3;
            4'd9: ov_rgb=24'he01d28;
            4'd10: ov_rgb=24'he43d47;
            4'd11: ov_rgb=24'he95e65;
            4'd12: ov_rgb=24'hed7e84;
            4'd13: ov_rgb=24'hf29ea3;
            4'd14: ov_rgb=24'hf6bec2;
            4'd15: ov_rgb=24'hfbdfe0;
            default: ov_rgb=24'hFFFFFF;
        endcase
    end
    // 2026-10-26：白底(index1 FFFFFF) 与近白抗锯齿(7 BABEC6 / 8 DCDFE3 / 15 FBDFE0) 一并键控为透明，
    // 去掉字母周围那圈白色描边；更深的过渡级(2~6/9~14)保留，边缘仍有柔和过渡。
    wire ov_hit=win_r2 && (rom_index!=4'd0) && (rom_index!=4'd1) &&
                       (rom_index!=4'd7) && (rom_index!=4'd8) && (rom_index!=4'd15);

    
    reg [23:0] d1, d2, d3;
    reg        v1, v2, v3, e1, e2, e3;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            d1 <= 24'd0; d2 <= 24'd0; d3 <= 24'd0;
            v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0;
            e1 <= 1'b0; e2 <= 1'b0; e3 <= 1'b0;
        end else begin
            d1 <= I_cam_data; d2 <= d1; d3 <= d2;
            v1 <= I_vsync;    v2 <= v1; v3 <= v2;
            e1 <= I_de;       e2 <= e1; e3 <= e2;
        end
    end

    
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin O_data <= 24'd0; O_vsync <= 1'b0; O_de <= 1'b0; end
        else begin
            O_data  <= ov_hit ? ov_rgb : d3;
            O_vsync <= v3;
            O_de    <= e3;
        end
    end
endmodule
