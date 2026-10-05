`timescale 1ns/1ps
module tb_awb_improved;
    reg clk=0,rst=0,v=0,sof=0,last=0,bad=0; reg[95:0] d=0;
    always #5 clk=~clk;
    awb #(.IMG_WIDTH(16),.IMG_HEIGHT(4),.STAT_MIN_BEATS(4),.FRAME_MAX_BEATS(16)) dut
        (.I_clk(clk),.I_rst_n(rst),.I_tlast(last),.I_tuser(sof),.I_frame_bad(bad),.I_tdata(d),.I_tvalid(v),
         .I_tready(),.O_tlast(),.O_tuser(),.O_tdata(),.O_tvalid(),.O_tready(1'b1));
    integer checks=0;
    task tick(input bit vv,input bit ss,input bit bb,input reg[95:0] dd);
        @(negedge clk);v=vv;sof=ss;bad=bb;d=dd;
    endtask
    task check_sum(input integer r,input integer g,input integer b);
        repeat(3) @(negedge clk);
        if(dut.sum_r_p!==r || dut.sum_g_p!==g || dut.sum_b_p!==b)
            $fatal(1,"stats mismatch got %0d %0d %0d expected %0d %0d %0d",dut.sum_r_p,dut.sum_g_p,dut.sum_b_p,r,g,b);
        checks=checks+1;
    endtask
    task flush(input bit error);
        tick(0,1,error,0); tick(0,0,0,0);
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=1;
        // Exactly four accepted samples reject, five accept. First SOF sample counts.
        tick(1,1,0,{4{24'h6496c8}});
        repeat(3) tick(1,0,0,{4{24'h6496c8}});
        flush(0); check_sum(1,1,1);
        repeat(5) tick(1,0,0,{4{24'h6496c8}});
        flush(0); check_sum(501,751,1001);
        // Total frame > MAX rejects even with only five accepted samples.
        repeat(5) tick(1,0,0,{4{24'h6496c8}});
        repeat(12) tick(1,0,0,0);
        flush(0);check_sum(501,751,1001);
        // Exactly MAX accepts; black samples do not influence ratio.
        repeat(5) tick(1,0,0,{4{24'h325064}});
        repeat(11) tick(1,0,0,0);
        flush(0);check_sum(251,401,501);
        repeat(6) tick(1,0,0,{4{24'h6496c8}});
        flush(1);check_sum(251,401,501);
        repeat(6) tick(1,0,0,{4{24'hffffff}});
        flush(0);check_sum(251,401,501);
        // Consecutive frames, no gap: final previous sample is retained.
        repeat(5) tick(1,0,0,{4{24'h0a141e}});
        tick(1,1,0,{4{24'h28323c}});
        repeat(4) tick(1,0,0,{4{24'h28323c}});
        if(dut.sum_r_p!==51 || dut.sum_g_p!==101 || dut.sum_b_p!==151)
            $fatal(1,"back-to-back dropped final sample");
        flush(0);check_sum(201,251,301);
        // Four-pixel sampling rotates each frame, rather than fixed pixel0.
        @(negedge clk);rst=0;v=0;sof=0;
        @(negedge clk);rst=1;
        for(integer phase=0;phase<4;phase=phase+1) begin
            @(negedge clk);rst=0;v=0;sof=0;
            @(negedge clk);rst=1;
            for(integer n=0;n<phase;n=n+1) begin flush(0); end
            tick(1,1,0,{24'h46505a,24'h323c46,24'h1e2832,24'h0a141e});
            repeat(4) tick(1,0,0,{24'h46505a,24'h323c46,24'h1e2832,24'h0a141e});
            tick(0,0,0,0); // allow final delayed sample to reach accumulator
            tick(0,1,0,0);tick(0,0,0,0);
            check_sum(1+5*(10+20*phase),1+5*(20+20*phase),1+5*(30+20*phase));
        end
        $display("TB_RESULT: PASS awb checks=%0d",checks);$finish;
    end
endmodule
