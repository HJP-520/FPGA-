# 08_board_bringup —— 上板点亮（真机阶段）

> 硬件已到位：SC520CS 摄像头模组 + HX1P35A（PH1P35MDG324）开发板。
> 本目录存放"真机第一战"的工程与指导；视觉五册 + 嵌入式两册教程见 `docs/`。

## 01_video_passthrough —— 视频传输路线（屏幕显示摄像头画面）

SC520CS 适配版官方例程 Lab1（厂商已统一 1280x720@60fps HD 模式），
即"摄像头 -> MIPI -> ISP -> HDMI 出图"的完整通路工程。

```
01_video_passthrough/
├── lab_ex1/                     # 完整工程（整体拷贝即可用；**含饱和度增强补丁 K28**，
│                                #   可直接重建板上定版 bit；厂商原版基线在 ../../_sc520_src/）
│   ├── td_project/              #   camera_to_dsi_display.al + Runs（含 best_result 厂商留档）
│   ├── user_source/hdl_source/  #   96 个 RTL（含 uics520_cfg SC520 配置）
│   └── user_source/constraints_source/{pin.adc, timing.sdc}
├── sim/                         # ModelSim 整链仿真（明码段 + 虚拟传感器）
│   ├── run_sim.bat              #   一键仿真（Windows 双击/命令行）
│   ├── filelist_sim.f           #   编译清单（含饱和度级 axis_saturation_rgb96.v）
│   ├── tb_video_passthrough.v   #   整链 TB：SAT_EN / SAT_K_Q4 开关（28≈1.75x 可复现定版）
│   ├── px_serializer_fifo.v     #   仿真用"浅 DDR"（8192 深弹性 FIFO + 真反压）
│   ├── tb_isp_burst.v           #   ISP 突发观测专项 TB（行级突发实测）
│   ├── raw10_beats.hex/.txt     #   虚拟 RAW10 传感器（BGGR 灰底+红块, 3 帧）
│   ├── baseline_oct03/          #   未加饱和度级的基线帧留档（供 sat_tool check 对拍）
│   └── sim_out/                 #   dump2png 产物 + sat_sweep_*.png（K 档位预览）
└── README.md                    # 本文件
```

## 三步上手

1. **仿真预演**（可选但强烈建议）：`cd sim && run_sim.bat`，看到
   `TB_RESULT: PASS frames_dumped=2 ... ser_ovf=0`（跑完约 5～8 分钟）
   后用 `python ../../tools/dump2png.py sim passthrough_frame 0 1`
   出图，确认"画面能到达"（灰底 + 噪声 + 红色条纹方块）；
2. **TD 编译**：TD 6.2.1 打开 `lab_ex1/td_project/camera_to_dsi_display.al`
   → 跑完 compile/map/pnr/bitgen → 产出 `.bit`；
3. **烧录验收**：BitWizard 写 QSPI（或先 JTAG 下载 SRAM 调试）→
   上电 15 秒内 HDMI 出图。

详细步骤、故障排查表、参数速查见 `docs/board1_guide.pdf`（《视频通路使用指导》，9 页）。

## 相关目录（08_board_bringup 其余部分）

- `../02_td_synth_gate/` —— 视觉链 TD gate 级证据（LUTRAM / STA 两闸门，含修复前后对照）；
- `../03_td_rebuild_sat/` —— **饱和度增强重建**（2026-10-04）：定版 bit `..._sat_k28.bit`
  （K≈1.75x，已上板）、K28 QSPI 镜像、无头两段重建复现命令；
- `../_sc520_src/` —— 厂商原始交付留档（zip / 解包 / PDF）。
- 独立交付包（外发/交接，不在本仓库内）：`D:\SC520_display_burnpack\`。

## 关键参数速查

| 项 | 值 |
|----|-----|
| 分辨率/帧率 | 1280x720 @ 60fps（SC520CS 原厂 HD 模式） |
| MIPI | 2-lane RAW10，MCLK 24MHz（O_cam_24m） |
| 摄像头 I2C 地址 | 7bit 0x36（8bit 写 0x6C） |
| 传感器 ID 校验 | 0xEE4B / 0x9E4B（uicfgcs520 读 CHIP_ID） |
| 备用寄存器表 | 2560x1920@30（`uics520reg_full_2560x1920_30.v`，未接入） |
| 显示输出 | HDMI（TMDS，720p60），另有屏幕背光 O_screen_pwm |

## 已知注意点（来自前期仿真，上板先查）

- **TD GUI 打开工程报 `XML tag Project is invalid`**：厂商原版 `camera_to_dsi_display.al/.prj` 里
  `UsedInP&R` 属性的 `&` 未转义（违反 XML 规范；TD 无头引擎容忍、Qt GUI 严格解析会拒）。
  **本仓库已修复**（57 处 → `UsedInP&amp;R`）；若从厂商原始压缩包重新取值需同样处理。
- 上电时序：FPGA 先给 O_cam_rst、再 24MHz、I2C 配置完成后才出流；
  若"有数据无帧同步"，先查 demosaic tuser 链（嵌入式教程（一）第 5 节）。
- AWB 会自适应拉动颜色，检测类演示前可锁曝光或切阈值组。
- 替身文件（*_stub.v / *_sim.v）只属于仿真，**禁止加入 TD 工程**。
- 仿真日志若出现 `ERAM_STUB_WARN: unknown (X/Z) ...`（每实例最多一次）：
  厂商 zhenghe 的 B 端口只读用法把 web/dib 悬空所致，属已知且已处置情形
  （替身按"未接即安全默认"处理），不是错误——但**若地址位也报未知**，
  说明 wrapper 与替身参数不匹配，需要处理。
- **TD 综合后核对两处**（外脑评审转检查单）：
  1）bin_smooth3x3 行缓存须映射为 **LUTRAM**（查综合报告；`ram_style`
     属性若被忽略、误映射 BRAM 会因读出延迟一拍导致整帧错行一行）；
  2）时序报告关注 **gimbal_ctrl 帧拍单周期组合路径**（err×KP+加法树），
     不收敛则拆 2 拍流水或加 multicycle 约束。
