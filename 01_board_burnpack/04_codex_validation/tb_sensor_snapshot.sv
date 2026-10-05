`timescale 1ns/1ps
module uii2c #(parameter WMEN_LEN=4,RMEN_LEN=1,CLK_DIV=1)
    (input I_clk,I_rstn,output O_iic_scl,inout IO_iic_sda,input[31:0] I_wr_data,input[7:0] I_wr_cnt,
     output reg[7:0] O_rd_data,input[7:0] I_rd_cnt,input I_iic_req,I_iic_mode,
     output reg O_iic_busy,output O_iic_bus_error,inout IO_iic_sda_dg);
    assign O_iic_scl=1;assign O_iic_bus_error=0;
    reg[3:0] cnt;reg[15:0] address;
    reg[7:0] last_3e00,last_3e01,last_3e02,last_3e09,last_3e07;
    always @(posedge I_clk or negedge I_rstn) begin
        if(!I_rstn) begin O_iic_busy<=0;cnt<=0;O_rd_data<=0;end
        else if(!O_iic_busy && I_iic_req) begin
            O_iic_busy<=1;cnt<=0;
            address={I_wr_data[15:8],I_wr_data[23:16]};
            if(I_iic_mode) O_rd_data <= (address==16'h3107) ? 8'hee : 8'h4b;
            else case(address)
                16'h3e00:last_3e00<=I_wr_data[31:24];
                16'h3e01:last_3e01<=I_wr_data[31:24];
                16'h3e02:last_3e02<=I_wr_data[31:24];
                16'h3e09:last_3e09<=I_wr_data[31:24];
                16'h3e07:last_3e07<=I_wr_data[31:24];
            endcase
        end else if(O_iic_busy) begin
            cnt<=cnt+1;if(cnt==7)O_iic_busy<=0;
        end
    end
endmodule
module tb_sensor_snapshot;
    reg clk=0,rst=0,req=0;reg[15:0] ae=500,ag=16;
    always #5 clk=~clk;
    wire cfg,done;
    uicfgcs520 #(.CLK_DIV(1)) dut(.I_clk(clk),.I_rst_n(rst),.I_ae_req(req),.I_ae(ae),.I_ag(ag),
        .O_cam_scl(),.IO_cam_sda(),.O_cfg_done(cfg),.O_ae_cfg_done(done),.O_sensor_id(),.O_sensor_id_ok(),.O_iic_error());
    initial begin
        repeat(4)@(negedge clk);rst=1;wait(cfg && done);
        @(negedge clk);req=1;@(negedge clk);req=0;
        wait(!done);ae=1991;ag=144; // inputs change while grouped write is active
        wait(done);@(negedge clk);
        if(dut.u_i2c.last_3e00!==0 || dut.u_i2c.last_3e01!==8'h1f || dut.u_i2c.last_3e02!==8'h40 ||
           dut.u_i2c.last_3e09!==0 || dut.u_i2c.last_3e07!==8'h80)
            $fatal(1,"grouped AE/AG transaction was not coherent");
        // Reproduce the brightness candidate: AE=1991, AG=80 (4x table entry).
        ae=1991;ag=80;
        @(negedge clk);req=1;@(negedge clk);req=0;
        wait(!done);ae=2;ag=16;
        wait(done);@(negedge clk);
        if(dut.u_i2c.last_3e00!==0 || dut.u_i2c.last_3e01!==8'h7c || dut.u_i2c.last_3e02!==8'h70 ||
           dut.u_i2c.last_3e09!==8'h09 || dut.u_i2c.last_3e07!==8'h80)
            $fatal(1,"4x brightness candidate AE/AG register payload mismatch");
        $display("TB_RESULT: PASS sensor grouped transaction snapshot and AE1991 AG80 payload");$finish;
    end
    initial begin #5000000;$fatal(1,"sensor watchdog");end
endmodule
