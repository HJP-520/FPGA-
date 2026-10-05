`timescale 1ns/1ps
// Control-level FIFO substitute: explicitly inject full/empty conditions.
// It verifies recovery policy and CDC sequencing, not DDR PHY behavior.
module w128_d512_fifo(input rst,clkw,we,input[127:0] di,output afull,full_flag,
    output[8:0] wrusedw,input clkr,re,output[127:0] dout,output[8:0] rdusedw,
    output valid,empty_flag,aempty);
    reg inject_full=0,inject_empty=0;
    assign full_flag=inject_full;assign empty_flag=inject_empty;
    assign afull=inject_full;assign aempty=inject_empty;
    assign wrusedw=0;assign rdusedw=0;assign valid=re;
    assign dout={16{8'h55}};
endmodule
module tb_fifo_recovery;
    reg cam=0,ddr=0,px=0,rst=0,sof=0,v=0,bad=0,vs=1,rd=0;
    always #5 cam=~cam;always #4 ddr=~ddr;always #7 px=~px;
    wire[1:0] rp;wire[23:0] pixel;
    video_in vi(.I_rst_n(rst),.I_camera_clk(cam),.I_camera_frame_start(sof),.I_camera_valid(v),.I_camera_data(128'd0),
        .I_mipi_rx_error(bad),.I_ddr_clk(ddr),.I_display_pause(1'b0),.I_video_out_rd_busy(1'b0),
        .O_video_in_wr_busy(),.O_video_out_rp(rp),.O_ddr_user_wr_en(),.O_ddr_user_addr(),.O_ddr_user_wr_data(),.I_ddr_user_ready(1'b1));
    video_out vo(.I_rst_n(rst),.I_ddr_clk(ddr),.I_video_in_wr_busy(1'b0),.I_video_out_rp(2'd0),
        .O_video_out_rd_busy(),.O_ddr_user_rd_en(),.O_ddr_user_addr(),.I_ddr_user_ready(1'b1),
        .I_ddr_user_rd_valid(1'b0),.I_ddr_user_rd_data(128'd0),.I_dsi_clk(px),.I_video_vsync(vs),.I_video_rd_en(rd),.O_vdieo_data(pixel));
    task new_frame;
        @(negedge cam);sof=1;
        @(negedge cam);sof=0;
        repeat(30) @(negedge cam);
    endtask
    reg[1:0] saved_rp;reg[1:0] saved_wp;integer checks=0;
    task check(input bit ok,input string tag);if(!ok)$fatal(1,"FIFO %s",tag);checks=checks+1;endtask
    initial begin
        repeat(4) @(negedge cam);rst=1;new_frame();
        saved_rp=rp;saved_wp=vi.S_video_in_wp;
        v=1;vi.U_w128_d512_fifo.inject_full=1;
        repeat(3) @(negedge cam);
        check(vi.S_frame_overflow && vi.S_overflow_count==1,"overflow sticky once/frame");
        vi.U_w128_d512_fifo.inject_full=0;
        check(!vi.U_w128_d512_fifo.we,"drop rest of corrupt frame");v=0;
        new_frame();
        check(rp==saved_rp && vi.S_video_in_wp==saved_wp,"overflow does not publish/advance");
        check(!vi.S_frame_overflow,"recover at next SOF");
        new_frame();check(vi.S_video_in_wp==saved_wp+2'd1,"good frame advances");
        saved_rp=rp;saved_wp=vi.S_video_in_wp;bad=1;
        new_frame();check(rp==saved_rp && vi.S_video_in_wp==saved_wp,"MIPI bad synchronized and vetoed");
        @(negedge px);rd=1;vo.U_w128_d512_fifo.inject_empty=1;
        repeat(5) @(negedge px);
        check(vo.S_read_corrupt && vo.S_underflow_count==1 && pixel==0,"underrun blanks remainder");
        check(!vo.U_w128_d512_fifo.re,"empty reads suppressed");
        vo.U_w128_d512_fifo.inject_empty=0;repeat(5) @(negedge px);
        check(vo.S_read_corrupt && pixel==0,"holds blank even if data returns");
        rd=0;vs=0;repeat(3) @(negedge px);vs=1;repeat(3) @(negedge px);
        check(!vo.S_read_corrupt,"recover at vsync");
        $display("TB_RESULT: PASS fifo checks=%0d",checks);$finish;
    end
endmodule
