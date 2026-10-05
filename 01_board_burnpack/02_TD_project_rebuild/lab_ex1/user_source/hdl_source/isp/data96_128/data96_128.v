// Four RGB888 pixels per input beat; three 128-bit words per four beats.
// This fixed video interface has no backpressure. Lines must contain a
// multiple of 16 pixels. O_128b_frame_start is an EARLY FIFO-reset pulse,
// deliberately independent of valid; it is not AXI4-Stream SOF metadata.
module data_96bit_to_128bit (
    input wire I_clk, I_rst_n,
    input wire I_96b_frame_start, I_96b_valid, I_96b_tlast,
    input wire [95:0] I_96b_data,
    output reg O_128b_frame_start, O_128b_tlast, O_128b_valid,
    output reg [127:0] O_128b_data
);
    reg [95:0] S_96b_data_1d;
    reg [1:0] S_cnt;
    wire [1:0] cnt_eff = I_96b_frame_start ? 2'd0 : S_cnt;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_cnt <= 0;
            S_96b_data_1d <= 0;
            O_128b_frame_start <= 0;
            O_128b_tlast <= 0;
            O_128b_valid <= 0;
            O_128b_data <= 0;
        end else begin
            O_128b_frame_start <= I_96b_frame_start;
            O_128b_valid <= 0;
            O_128b_tlast <= 0;
            if (I_96b_frame_start) begin
                S_cnt <= 0;
                S_96b_data_1d <= 0;
            end
            if (I_96b_valid) begin
                // Both the phase AND the pending bytes must hold on bubbles.
                S_96b_data_1d <= I_96b_data;
                S_cnt <= cnt_eff + 2'd1;
                case (cnt_eff)
                    2'd0: begin end
                    2'd1: begin
                        O_128b_valid <= 1;
                        O_128b_data <= {S_96b_data_1d,I_96b_data[95:64]};
                    end
                    2'd2: begin
                        O_128b_valid <= 1;
                        O_128b_data <= {S_96b_data_1d[63:0],I_96b_data[95:32]};
                    end
                    2'd3: begin
                        O_128b_valid <= 1;
                        O_128b_tlast <= I_96b_tlast;
                        O_128b_data <= {S_96b_data_1d[31:0],I_96b_data};
                    end
                endcase
            end
        end
    end
endmodule
