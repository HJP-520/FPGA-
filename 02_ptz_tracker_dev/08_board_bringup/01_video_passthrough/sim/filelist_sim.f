# filelist_sim.f —— 视频通路整链仿真编译清单（ModelSim 用）
# 约定：D:/fpga-ptz-tracker 为仓库根；本清单供 msim_passthrough.do 使用
# 注意：全部为仿真专用文件，禁止加入 TD 工程

# ---- 视觉方向（串化器 + 帧转储） ----
D:/fpga-ptz-tracker/03_vision/step1_video_link/03_project/rtl/ser96to24.v
D:/fpga-ptz-tracker/03_vision/step1_video_link/03_project/rtl/frame_dump24.v

# ---- 饱和度增强级（本次新增；ISP 链内插在 AWB 之后） ----
D:/fpga-ptz-tracker/04_embedded/03_project/rtl/axis_saturation_rgb96.v

# ---- 官方 ISP 明码副本（04_embedded/sim）----
D:/fpga-ptz-tracker/04_embedded/03_project/sim/isp_top.v
D:/fpga-ptz-tracker/04_embedded/03_project/sim/data128_96.v
D:/fpga-ptz-tracker/04_embedded/03_project/sim/data_96bit_to_128bit.v
D:/fpga-ptz-tracker/04_embedded/03_project/sim/demosaic_4x_2_0/demosaic.v
D:/fpga-ptz-tracker/04_embedded/03_project/sim/demosaic_4x_2_0/zhenghe.v
D:/fpga-ptz-tracker/04_embedded/03_project/sim/demosaic_4x_2_0/bilinear_interpolation.v
D:/fpga-ptz-tracker/04_embedded/03_project/sim/demosaic_4x_2_0/line_buffer_demosaic.v
D:/fpga-ptz-tracker/04_embedded/03_project/sim/demosaic_4x_2_0/mipi_to_raw_converter.v
D:/fpga-ptz-tracker/04_embedded/03_project/sim/demosaic_4x_2_0/raw_matrix_3x3_buffer.v
D:/fpga-ptz-tracker/04_embedded/03_project/sim/demosaic_4x_2_0/blk_mem_gen_demosaic/blk_mem_gen_demosaic.v
D:/fpga-ptz-tracker/04_embedded/03_project/sim/demosaic_4x_2_0/blk_mem_gen_demosaic/RTL/ram_c36c2ca3b3a7.v
D:/fpga-ptz-tracker/04_embedded/03_project/sim/demosaic_4x_2_0/blk_mem_gen_zhenghe/blk_mem_gen_zhenghe.v
D:/fpga-ptz-tracker/04_embedded/03_project/sim/demosaic_4x_2_0/blk_mem_gen_zhenghe/RTL/ram_d32970204f32.v
D:/fpga-ptz-tracker/04_embedded/03_project/sim/awb.v
D:/fpga-ptz-tracker/04_embedded/03_project/sim/awb/signal_delay.v
D:/fpga-ptz-tracker/04_embedded/03_project/sim/awb/ram/blk_mem_gen_awb_delay_signal.v

# ---- 行为级替身（TD 工程禁止加入）----
D:/fpga-ptz-tracker/04_embedded/03_project/rtl/divider_gate_sim.v
D:/fpga-ptz-tracker/04_embedded/03_project/rtl/ph1p_logic_eram_stub.v

# ---- 本 TB ----
D:/fpga-ptz-tracker/08_board_bringup/01_video_passthrough/sim/px_serializer_fifo.v
D:/fpga-ptz-tracker/08_board_bringup/01_video_passthrough/sim/tb_video_passthrough.v
