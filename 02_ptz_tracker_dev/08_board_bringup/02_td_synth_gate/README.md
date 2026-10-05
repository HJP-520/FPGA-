# 02_td_synth_gate —— 视觉链 TD 综合（gate 级）证据与复现（2026-10-03）

来源：外部架构级复审提出的三项上板前 Gate（ser96to24 突发 / LUTRAM 映射 / gimbal STA）。
本目录保存**可复现的综合证据**；LUTRAM 与 gimbal STA 两项 Gate 由本目录的
`reports_prefix/`（修复前）与 `reports/`（修复后）两次运行共同闭合。

## 复现步骤

1. 把 `vision_gate_top.v` 放进工程 `src/`，连同视觉链 19 个 RTL：
   `03_vision/step{1..5}/*/03_project/rtl/` 下的
   ser96to24、pulse_sync、cdc_4phase、rgb2hsv、hsv_inv_lut、hsv_threshold、
   bin_smooth3x3、centroid_accum、detect_top、gimbal_ctrl、pwm_servo、osd_track、
   vision_top、font_rom_8x16、edge_detect_96、video_adj、motion_detect、marquee_rom_64
   + `04_embedded/03_project/rtl/led_buzzer.v`（共 19 文件）。
   （排除仿真专用：sim_video_src / frame_dump24 / *_stub / divider_gate_sim）
2. run 目录放 `vision_gate.prj`（源列表 + 顶层 `vision_gate_top`）、`settings.cfg`、`vision_gate.sdc`
   （约束：pix 74.25MHz / pwm 50MHz，双域 async 分组）。
3. 运行（TD 6.2.1 无头）：
   ```
   cd <run 目录>
   <TD>/bin/td_commands_prompt.exe <TD>/doc/scripts/DefaultFlow.tcl
   ```
   首跑若报 `SYN-8228 MapIO IO 超限`：说明顶层直接用 wide-bus 端口版（329 IO > 160），
   必须用本目录的激励包装顶层 `vision_gate_top`（40 IO）。
4. 产物：`reports*/` 下 gate.area / gate.timing / gate.ts / gate.qor / flow.status。

## 修复前（reports_prefix/，2026-10-03 首轮）

- LUTRAM 映射成立：ser96to24 = **56 dram lut**（0 eram）；bin_smooth3x3 = **256 dram lut**（0 eram）。
- motion_detect：prev_mem → ERAM 57 块；设计总 eram 57/108。
- 50MHz 域 WNS **+8.747ns**（gimbal 13×16 乘加无虞）。
- 74.25MHz 域 WNS **−0.113ns / TNS −0.904ns**：8 个违规端点全部同源 = OSD 跑马灯
  （px_reg[4] → osd_track.v(248) 加法器 → marquee_rom_64 地址译码 mux 树，14 级逻辑）。
- 资源：3153 lut / 1879 reg / 2471 slice（11.65%）/ dram 312 / eram 57 / dsp 8。

## 修复后（reports/，\#N+7 修复轮）

- **像素域 WNS +0.541ns、TNS 0.000ns、0 违规端点**（跑马灯数组 ROM 化后彻底退出关键路径；
  新最差路径 = OSD 文本影子装载 `u_cdc.O_dst_data_reg[56] → txt2_s_reg`，12.863ns，
  且每帧仅装载一次）。hold WNS +0.502ns。
- `ser96to24` v4（2048px）被 TD 判给 **ERAM 4 块**（ram_style 未强扭）——注册读设计对
  LUTRAM/ERAM 双映射皆正确，这是 v4 的鲁棒性收益；bin_smooth3x3 仍为 256 dram lut。
- 资源：3150 lut / 1892 reg / 2422 slice（11.42%）/ dram 256 / **eram 61/108（56.5%）** / dsp 8。
- 注：gate 级 Confidence=Synthesized，净延迟 68% 为估算；P&R 后需复核。

## 修复后·终态（#N+9，本目录 reports/ 已更新为该轮报告）

- 手改记录：`ser96to24.v`（v4.1 看门狗/观测量）、`osd_track.v`（跑马灯前瞻 4 像素流水）、
  `detect_top.v`/`vision_top.v`（sync_err 引出）、`marquee_rom_64.v`（数组版）。
- **像素域 WNS +2.441ns、TNS 0、0 违规端点**；pwm 域 +8.747ns。
- 资源：3179 lut / 1963 reg / dram 256 / **eram 62/108（57.4%）** / dsp 8。
- marquee_rom_64 被 TD 判给 **1 块 ERAM**（22 逻辑 LUT）；ser96to24 4 块/实例。

## 一场值得记录的过程（诚实更正）

仅在 #N+7 把 marquee 从 case 改成数组 ROM 后，一次综合曾报 +0.541ns——但 #N+9 复综合
（加了 v4.1 逻辑后）**回退到 −1.025ns**，关键路径仍是 px→marquee ROM→O_data（15 级）：
TD 又把数组映射成 ~10 级 `ramread` LUT3 链，`ram_style`/`syn_ramstyle` 属性均未生效。
**结论：换写法 ≠ 映射变浅；必须看 gate 报告的逻辑级数。** 最终以前瞻 4 像素 + 4 级移位
的结构性流水解决（+2.441ns）。中间态证据保留在 `reports_prefix/`（最初 case 版）。
- 注：边缘支路在本轮合成激励下被判死逻辑未保留（algo 恒 0）；正式 P&R 需确保其被综合。
