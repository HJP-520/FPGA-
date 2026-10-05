`timescale 1ns/1ps
module tb_saturation_improved;
    localparam N=256;
    reg clk=0,rst=0,v=0,sof=0,eol=0;reg[95:0] data=0;
    always #5 clk=~clk;
    reg[95:0] inputs[0:N-1];
    reg[95:0] refs[0:6*N-1];
    wire[95:0] outputs[0:5];wire[5:0] ov,os,ol;
    genvar p;
    generate for(p=0;p<6;p=p+1) begin: profiles
        localparam K=(p==0)?0:(p==1)?16:(p==2)?24:(p==3)?28:(p==4)?50:63;
        axis_saturation_rgb96 #(.K_Q4(K)) dut(clk,rst,eol,sof,data,v,ol[p],os[p],outputs[p],ov[p]);
    end endgenerate
    integer idx=0,checks=0;
    always @(posedge clk) begin
        #1;
        if(rst && ov[0]) begin
            for(integer p=0;p<6;p=p+1) begin
                if(!ov[p] || outputs[p]!==refs[p*N+idx])$fatal(1,"saturation profile=%0d vector=%0d got=%h expected=%h",p,idx,outputs[p],refs[p*N+idx]);
                if(os[p]!==((idx%64)==0) || ol[p]!==((idx%17)==16))$fatal(1,"saturation metadata");
                checks=checks+1;
            end
            idx=idx+1;
        end
    end
    initial begin
        $readmemh("saturation_inputs.hex",inputs);$readmemh("saturation_expected.hex",refs);
        repeat(4)@(negedge clk);rst=1;
        for(integer i=0;i<N;i=i+1) begin
            @(negedge clk);data=inputs[i];v=1;sof=(i%64)==0;eol=(i%17)==16;
            if((i%4)==0)begin @(negedge clk);v=0;sof=0;eol=0;data=~inputs[i];end
        end
        @(negedge clk);v=0;sof=0;eol=0;
        repeat(6)@(negedge clk);
        if(idx!=N)$fatal(1,"saturation missing output");
        $display("TB_RESULT: PASS saturation checks=%0d K=0/16/24/28/50/63",checks);$finish;
    end
endmodule
