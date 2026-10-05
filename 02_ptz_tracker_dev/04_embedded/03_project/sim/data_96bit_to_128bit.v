

module data_96bit_to_128bit (
    input wire        I_clk,
    input wire        I_rst_n,
   
    input wire        I_96b_frame_start,
    input wire        I_96b_valid,
    input wire        I_96b_tlast,          // 评审#4/#8（第2批）：行尾，与 I_96b_valid 同拍
    input wire[95:0]  I_96b_data,
  
    output reg        O_128b_frame_start,
    output reg        O_128b_tlast,         // 与 O_128b_valid/O_128b_data 同拍重建
    output reg        O_128b_valid,
    output reg[127:0] O_128b_data
);



    reg[95:0]  S_96b_data_1d;
    reg        S_96b_valid_1d;
    reg[1:0]   S_cnt;


    always @(posedge I_clk) begin
        S_96b_valid_1d <= I_96b_valid;
        S_96b_data_1d  <= I_96b_data;

		O_128b_frame_start <= I_96b_frame_start;
    end


    // 相位：仅在有效拍前进、气泡保持（评审#8）；帧首强制相位 0
    // 注意：行长为 4 拍整数倍（720p 行 320 拍）时 tlast 落在相位 3；行长非 4 倍时
    // 相位 0 拍的 tlast 会被抑制（无对应输出字）。
    wire[1:0]  cnt_eff = I_96b_frame_start ? 2'd0 : S_cnt;

    always @(posedge I_clk) begin
        if(I_96b_frame_start && I_96b_valid)
            S_cnt <= 2'd1;                     // 帧首拍按相位 0 处理
        else if(I_96b_frame_start)
            S_cnt <= 2'd0;
        else if(I_96b_valid)
            S_cnt <= S_cnt + 2'd1;
        // 气泡（valid=0）：保持相位
    end


    always @(posedge I_clk) begin
        if(I_96b_valid)
            begin
                case(cnt_eff)
                    'd0 : 
                        begin
                            O_128b_valid <= 1'b0;
                            O_128b_tlast <= 1'b0;
                            O_128b_data  <= 'd0;
                        end
                    'd1 :
                        begin
                            O_128b_valid <= 1'b1;
                            O_128b_tlast <= I_96b_tlast;
                            O_128b_data  <= {S_96b_data_1d,I_96b_data[95:64]};
                        end
                    'd2 :
                        begin
                            O_128b_valid <= 1'b1;
                            O_128b_tlast <= I_96b_tlast;
                            O_128b_data  <= {S_96b_data_1d[63:0],I_96b_data[95:32]};
                        end
                    'd3 :
                        begin
                            O_128b_valid <= 1'b1;
                            O_128b_tlast <= I_96b_tlast;
                            O_128b_data  <= {S_96b_data_1d[31:0],I_96b_data};
                        end
                    default:
                        begin
                            O_128b_valid <= 1'b0;
                            O_128b_tlast <= 1'b0;
                            O_128b_data  <= 'd0;
                        end
                endcase
            end
        else
            begin
                O_128b_valid <= 1'b0;
                O_128b_tlast <= 1'b0;
                O_128b_data  <= 'd0;
            end
    end

    

endmodule