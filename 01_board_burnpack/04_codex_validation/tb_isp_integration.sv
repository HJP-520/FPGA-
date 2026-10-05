`timescale 1ns/1ps
module tb_isp_integration;
    reg clk=0,rst=0,v=0,sof=0,eol=0;
    reg[39:0] raw=0;
    always #5 clk=~clk;
    wire[127:0] out_data;wire out_valid,out_last,out_reset;
    isp_top #(.SAT_K_Q4(24)) dut(.axi4s_video_aclk(clk),.I_rst_n(rst),.I_tlast(eol),.I_tuser(sof),
        .I_tdata(raw),.I_tvalid(v),.I_tdest(10'd0),.I_frame_bad(1'b0),.O_tready(1'b1),
        .O_tdata(out_data),.O_tlast(out_last),.O_tuser(out_reset),.O_tvalid(out_valid),.I_tready());
    byte unsigned byte_q[$];
    reg[127:0] expected;
    integer input_beats=0,output_words=0,line_words=0,lines=0,resets=0,sat_beats=0;
    reg sampled_valid;
    always @(posedge clk) begin
        if(rst) begin
            sampled_valid=dut.sat_O_tvalid;
            if(dut.sat_O_tuser && byte_q.size()!=0)
                $fatal(1,"input reset with residual bytes=%0d sat=%0d words=%0d linewords=%0d",byte_q.size(),sat_beats,output_words,line_words);
            if(dut.sat_O_tvalid) begin
                for(integer n=11;n>=0;n=n-1)byte_q.push_back(dut.sat_O_tdata[8*n+:8]);
                sat_beats=sat_beats+1;
            end
            #1;
            if(out_reset) begin
                if(byte_q.size()!=(sampled_valid ? 12 : 0))$fatal(1,"reset arrived with unconsumed bytes");
                line_words=0;resets=resets+1;
            end
            if(out_valid) begin
                if(byte_q.size()<16)$fatal(1,"unexpected output");
                for(integer n=15;n>=0;n=n-1)expected[8*n+:8]=byte_q.pop_front();
                if(out_data!==expected)$fatal(1,"post-repack payload mismatch at word %0d",output_words);
                output_words=output_words+1;line_words=line_words+1;
                if(out_last) begin
                    if(line_words!=240)$fatal(1,"line has %0d words",line_words);
                    line_words=0;lines=lines+1;
                end
            end else if(out_last)$fatal(1,"EOL on invalid output");
        end
    end
    initial begin
        repeat(5)@(negedge clk);rst=1;
        for(integer f=0;f<3;f=f+1) begin
            for(integer y=0;y<720;y=y+1) begin
                for(integer x=0;x<320;x=x+1) begin
                    @(negedge clk);
                    raw={10'd300,10'd500,10'd400,10'd600};
                    v=1;sof=(x==0 && y==0);eol=(x==319);
                    input_beats=input_beats+1;
                end
                @(negedge clk);v=0;sof=0;eol=0;
                // Real CSI lines arrive as bursts followed by horizontal blank.
                repeat(2000)@(negedge clk);
            end
            @(negedge clk);sof=0;eol=0;
            repeat(200)@(negedge clk);
        end
        repeat(3000)@(negedge clk);
        if(output_words<2*172800 || lines<2*720 || resets!=3 || byte_q.size()!=0 || line_words!=0)
            $fatal(1,"geometry input=%0d sat=%0d words=%0d lines=%0d resets=%0d pending=%0d",input_beats,sat_beats,output_words,lines,resets,byte_q.size());
        $display("TB_RESULT: PASS isp post-repack words=%0d lines=%0d resets=%0d raw_beats=%0d",output_words,lines,resets,input_beats);
        $finish;
    end
endmodule
