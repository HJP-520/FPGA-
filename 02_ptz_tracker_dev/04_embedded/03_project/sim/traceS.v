`timescale 1ns/1ps
module traceS;
reg clk=0,rst=0; always #7 clk=~clk;
reg [39:0] beats [0:921599]; reg [1:0] metas [0:921599];
reg [39:0] raw_data; reg raw_valid, raw_sof, raw_eol;
integer bi=0;
wire [127:0] isp_tdata; wire isp_tvalid,isp_tuser,isp_tlast,isp_up;
isp_top dut(.axi4s_video_aclk(clk),.I_rst_n(rst),
 .I_tlast(raw_eol),.I_tuser(raw_sof),.I_tdata(raw_data),.I_tvalid(raw_valid),
 .I_tdest(10'd0),.O_tready(isp_up),.O_tdata(isp_tdata),.O_tlast(isp_tlast),
 .O_tuser(isp_tuser),.O_tvalid(isp_tvalid),.I_tready());
always @(posedge clk or negedge rst) begin
  if (!rst) begin raw_valid<=0; raw_sof<=0; raw_eol<=0; end
  else if (bi < 921600) begin
    raw_valid<=1; raw_data<=beats[bi]; raw_sof<=metas[bi][1]; raw_eol<=metas[bi][0]; bi=bi+1;
  end else begin raw_valid<=0; raw_sof<=0; raw_eol<=0; end
end
initial begin $readmemh("raw10_beats.hex",beats); $readmemh("raw10_meta.txt",metas); end
integer n=0;
always @(posedge clk) begin
  n=n+1;
  if (n<10) $display("cyc%0d rawv=%b rawsof=%b raweol=%b ispv=%b ispuser=%b isplast=%b",
    n, raw_valid, raw_sof, raw_eol, isp_tvalid, isp_tuser, isp_tlast);
  if (isp_tvalid) begin
    if (isp_tlast) $display("ISP_LAST at n=%0d", n);
  end
  if (dut.m_aixs_tuser && dut.m_aixs_tvalid) $display("DEMO_USER at n=%0d", n);
  if (dut.awb_O_tuser && dut.awb_O_tvalid) $display("AWB_USER at n=%0d", n);
  if (dut.m_aixs_tlast && dut.m_aixs_tvalid) $display("DEMO_LAST at n=%0d", n);
end
initial begin repeat(5) @(posedge clk); rst=1; #20000000; $display("end n=%0d bi=%0d", n, bi); $finish; end
endmodule
