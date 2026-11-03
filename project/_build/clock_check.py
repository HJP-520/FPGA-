"""Reject positive timing reports with missing or substituted clock definitions."""
import re
EXPECTED={'MIPI_RX_BYTE_CLK':103.520,'HDMI_PIXEL_CLK':75.002,
 'u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk':66.667,'sys_clk_50m':50.000,
 'HDMI_SERIAL_CLK':375.094,'pll_clk_100m':100.000}
def check_clocks(report):
 clocks={name:float(freq) for freq,name in re.findall(r'^\s*clk\d+:\s*([\d.]+)\s+\d+\s+(\S+)',report,re.M)}
 m=re.search(r'Path Group\s*:\s*MIPI_RX_BYTE_CLK -> MIPI_RX_BYTE_CLK.*?Clock Uncertainty\s*:.*?sdc uncertainty:\s*([\d.]+)ns',report,re.S)
 return len(clocks)>=14 and 'DeriveClock' not in report and m is not None and float(m[1])==0.0 and all(name in clocks and abs(clocks[name]-freq)<0.002 for name,freq in EXPECTED.items())
