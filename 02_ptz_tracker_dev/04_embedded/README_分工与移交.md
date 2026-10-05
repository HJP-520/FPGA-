# 04_embedded —— 嵌入式方向交接说明（视觉 → 嵌入式）

> 视觉方向（本仓库 `03_vision/`）已交付的全部 RTL 为**纯 Verilog-2001、可综合、
> 不依赖任何 Xilinx/TD 专有 IP**。上板挂载需要的嵌入式配合如下。

## 一、需要嵌入式做的事（按优先级）

1. **挂载检测分支**（约 10 行接线）：
   在 `design_top_wrapper.v` 中把 `isp_top` 输出级（AWB 后 96bit AXI-S：
   tdata[95:0]/tvalid/tuser/tlast）同时接给 `detect_top`（纯旁路，O_tready 恒 1，
   不反压主线，直通输出可忽略）。文件：`03_vision/step2_color_centroid/03_project/rtl/detect_top.v`
2. **挂载 OSD 叠加**：显示侧把 `hdmi_mixer` 输出（或读出流）按 vpix 约定
   （DE→valid，帧/行首尾→sof/eol）接 `osd_track`，叠加规则见 `IF-OSD.md`；
   68bit 目标包从 `vision_top` 的 pack 端口引（IF-VISION.md）
3. **挂载云台控制**：`vision_top` 整体例化（内含 gimbal_ctrl + pwm_servo + 全部 CDC），
   只需：pix 时钟（CSI/AXI 域）、50MHz 时钟、复位，以及 2 个 PWM 输出脚约束
4. **pin.adc**：40Pin DC3 挑 2 个空闲脚给 O_pwm_x/O_pwm_y（+拨码 1 个给阈值组切换、
   1 个给 track_en，可选）
5. **摄像头维持 720p60**（`uics500reg_720p60.v`）；改分辨率须走 IF-DDR 变更流程

## 二、视觉方向对嵌入式的承诺

- 检测分支**零反压、零主线改动、零 DDR 带宽占用**（直通逐拍一致已断言）
- 视觉模块不依赖任何嵌入式 IP；仅消费 96bit 流与时钟
- 例程原有显示链路行为完全不变（视觉摘除后例程照跑）

## 三、联合验收清单（上板时）

- [ ] 例程原样跑通（Lab1 出图）
- [ ] 挂 detect_top：HDMI 画面无变化（旁路不扰主线）
- [ ] ChipWatcher 抓 t_valid=1、cx/cy 合理（红块场景）
- [ ] 挂 osd_track：屏幕出现十字/框/TRK0 LOCK 文字
- [ ] 接舵机独立 5V：duty 随目标移动方向变化（无画面闪=供电合格）
- [ ] 固化 QSPI：上电即跟踪（冷启动不需要 PC）

## 四、嵌入式已知风险提示（来自视觉仿真）

- **舵机独立供电是硬要求**（仿真无法暴露，上电第一次接舵机就会炸出来）
- AE 会拉动颜色 → 检测阈值漂移；演示前锁曝光或用 8 组阈值切换（视觉已备）
- 例程时序未收敛到正裕量属官方已知现象，视觉分支加深逻辑后请重跑时序报告
  （视觉逻辑 <3% LUT、关键路径浅，预期无碍）
