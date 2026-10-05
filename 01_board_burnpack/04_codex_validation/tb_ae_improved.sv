`timescale 1ns/1ps
module tb_ae_improved;
    reg clk=0,rst=1,cfg=0,done=1;reg[3:0] btn=15;
    always #5 clk=~clk;
    wire req;wire[15:0] ae,ag;
    ae_set #(.CLK_HZ(1000),.DEBOUNCE_MS(2),.AE_DEFAULT(5),.AE_MAX(8),.AG_MAX(18)) dut
        (.I_clk(clk),.I_rst(rst),.I_btn(btn),.I_cam_cfg_done(cfg),.I_ae_cfg_done(done),.O_ae_req(req),.O_ae(ae),.O_ag(ag));
    integer checks=0,requests=0;
    always @(posedge clk) if(!rst && req) requests=requests+1;
    task wait_cycles(input integer n);repeat(n) @(negedge clk);endtask
    task check(input bit ok,input string tag);
        if(!ok)$fatal(1,"AE check failed %s",tag);checks=checks+1;
    endtask
    initial begin
        wait_cycles(3);rst=0;wait_cycles(10);check(requests==0,"wait init");
        cfg=1;wait_cycles(5);check(requests==1 && ag==16 && ae==5,"one startup request, unity gain");
        btn=14;wait_cycles(1);btn=15;wait_cycles(10);check(ae==5,"bounce ignored");
        btn=14;wait_cycles(30);btn=15;wait_cycles(8);check(ae==2,"exposure floor");
        btn=13;wait_cycles(36);btn=15;wait_cycles(8);check(ae==8,"exposure ceiling");
        btn=11;wait_cycles(300);btn=15;wait_cycles(8);check(ag==16,"gain floor");
        btn=7;wait_cycles(300);btn=15;wait_cycles(8);check(ag==18,"gain ceiling");
        done=0;btn=14;wait_cycles(25);check(ae==8,"payload held while busy");
        btn=15;done=1;wait_cycles(8);check(ae==2,"pending change after done");
        $display("TB_RESULT: PASS ae checks=%0d requests=%0d",checks,requests);$finish;
    end
endmodule
