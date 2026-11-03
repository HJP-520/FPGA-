// 256x80 4bpp; low nibble first; two-cycle synchronous ROM.
module logo_rom #(
    parameter IMG_W   = 256,   
    parameter IMG_H   = 80,   
    parameter ADDR_W  = 18,           
    parameter DEPTH   = 10240       
) (
    input  wire                i_clk,   
    input  wire [ADDR_W-1:0]   i_addr,  
    output reg  [3:0]          o_index  
);

    
    reg [7:0] mem [0:DEPTH-1];
    initial begin
        $readmemh("logo_mem.hex", mem);
    end

    
    
    
    reg [7:0] byte_r;
    reg sel_r;
    initial begin
        byte_r = 8'd0;
        sel_r  = 1'b0;
        o_index = 4'd0;
    end

    always @(posedge i_clk) begin
        byte_r <= mem[i_addr[ADDR_W-1:1]];   
    end

    always @(posedge i_clk) begin
        sel_r <= i_addr[0];                
    end

    always @(posedge i_clk) begin
        o_index <= (byte_r >> (4 * sel_r)) & 4'hF;  
    end

endmodule
