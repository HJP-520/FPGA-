create_clock -name {pix_clk} -period 13.468 -waveform {0.000 6.734} [get_ports {I_pix_clk}]
create_clock -name {pwm_clk} -period 20.000 -waveform {0.000 10.000} [get_ports {I_pwm_clk}]
set_clock_groups -asynchronous -group [get_clocks {pix_clk}] -group [get_clocks {pwm_clk}]
