`timescale 1ns/1ps
module tb_repack_improved;
    reg clk=0,rst=0,v=0,fs=0,last=0;
    reg [95:0] data=0;
    always #5 clk=~clk;
    wire ov,of,ol; wire [127:0] od;
    data_96bit_to_128bit dut(clk,rst,fs,v,last,data,of,ol,ov,od);
    byte unsigned bytes_q[$];
    integer marks_q[$];
    integer bytes_in=0,bytes_out=0,checks=0,words=0;
    reg [127:0] expected;
    integer j;
    always @(posedge clk) begin
        if (!rst) begin
            bytes_q.delete(); marks_q.delete(); bytes_in=0; bytes_out=0;
        end else begin
            if(fs) begin
                if(bytes_q.size()!=0) $fatal(1,"SOF with residual bytes");
                bytes_in=0; bytes_out=0;
            end
            if(v) begin
                for(integer n=11;n>=0;n=n-1) bytes_q.push_back(data[8*n+:8]);
                bytes_in=bytes_in+12;
                if(last) marks_q.push_back(bytes_in);
            end
            #1;
            if(of!==fs) $fatal(1,"early reset pulse mismatch");
            if(ol && !ov) $fatal(1,"invalid tlast");
            if(ov) begin
                if(bytes_q.size()<16) $fatal(1,"unexpected word");
                for(integer n=15;n>=0;n=n-1) expected[8*n+:8]=bytes_q.pop_front();
                if(od!==expected) $fatal(1,"word mismatch got %h expected %h",od,expected);
                bytes_out=bytes_out+16;
                if(marks_q.size()!=0 && marks_q[0]==bytes_out) begin
                    if(!ol) $fatal(1,"missing line end");
                    j=marks_q.pop_front();
                end else if(ol) $fatal(1,"extra line end");
                words=words+1;
            end
            checks=checks+1;
        end
    end
    task tick(input bit vv,input bit ff,input bit ll,input integer seed);
        @(negedge clk);
        v=vv; fs=ff; last=ll;
        for(integer n=0;n<12;n=n+1) data[8*n+:8]=(seed*13+n*17)&255;
    endtask
    initial begin
        repeat(3) @(negedge clk); rst=1;
        // No idle cycle at the frame boundary: SOF and first pixel coincide.
        for(integer f=0;f<3;f=f+1)
            for(integer b=0;b<32;b=b+1) tick(1,b==0,(b%8)==7,f*32+b);
        tick(0,0,0,99);
        // Early reset followed by bubbles whose DATA changes every cycle.
        tick(0,1,0,1);
        for(integer b=0;b<320;b=b+1) begin
            for(integer g=0;g<(b%5);g=g+1) tick(0,0,0,1000+b+g);
            tick(1,0,b==319,b+301);
        end
        tick(0,0,0,999);
        // Reset at each of the four packing phases; no SOF needed afterwards.
        for(integer p=0;p<4;p=p+1) begin
            tick(0,1,0,1);
            for(integer b=0;b<p;b=b+1) tick(1,0,0,b);
            @(negedge clk); rst=0; v=0; fs=0; last=0;
            @(negedge clk); rst=1;
            for(integer b=0;b<8;b=b+1) tick(1,0,b==7,b+701);
            tick(0,0,0,0);
        end
        repeat(3) @(negedge clk);
        if(bytes_q.size()!=0 || marks_q.size()!=0) $fatal(1,"unflushed bytes");
        $display("TB_RESULT: PASS repack checks=%0d words=%0d (changing-data bubbles, real back-to-back, reset all phases)",checks,words);
        $finish;
    end
endmodule
