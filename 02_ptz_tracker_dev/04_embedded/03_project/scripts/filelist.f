# filelist.f —— TD 工程 RTL 清单（视觉+嵌入式新增部分）
# 官方例程源码按 TD 工程原有列表保留（design_top_wrapper/isp/ddr/hdmi/csi/i2c 等）
# 本清单只列"新增"文件；仿真专用文件勿加入 TD 工程
#
# ---- 视觉方向（03_vision）----
03_vision/step1_video_link/03_project/rtl/ser96to24.v
03_vision/step1_video_link/03_project/rtl/pulse_sync.v
03_vision/step1_video_link/03_project/rtl/cdc_4phase.v
03_vision/step2_color_centroid/03_project/rtl/hsv_inv_lut.v
03_vision/step2_color_centroid/03_project/rtl/rgb2hsv.v
03_vision/step2_color_centroid/03_project/rtl/hsv_threshold.v
03_vision/step2_color_centroid/03_project/rtl/bin_smooth3x3.v
03_vision/step2_color_centroid/03_project/rtl/centroid_accum.v
03_vision/step2_color_centroid/03_project/rtl/detect_top.v
03_vision/step3_closed_loop/03_project/rtl/gimbal_ctrl.v
03_vision/step3_closed_loop/03_project/rtl/pwm_servo.v
03_vision/step4_osd_integration/03_project/rtl/osd_track.v
03_vision/step4_osd_integration/03_project/rtl/vision_top.v
03_vision/step4_osd_integration/03_project/rtl/font_rom_8x16.v
#
# ---- 嵌入式方向（04_embedded）----
04_embedded/03_project/rtl/uart_telemetry.v
04_embedded/03_project/rtl/system_top.v
#
# ---- 仿真专用（禁止加入 TD 工程）----
# tools/ 生成物中的 sim_video_src.v / frame_dump24.v
# 04_embedded/03_project/rtl/ph1p_logic_eram_stub.v
# 04_embedded/03_project/rtl/divider_gate_sim.v
# 04_embedded/03_project/tb/*
