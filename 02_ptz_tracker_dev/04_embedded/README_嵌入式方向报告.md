# 嵌入式方向报告 —— 与视觉方向对接（v1.0）

日期：2026-09-19 ｜ 方法论：与视觉方向相同（金标准先行 → RTL → 仿真回归 → 迭代记录）
环境：无硬件、无 TD —— 官方例程明码 RTL 在 ModelSim 仿真；加密核（MIPI D-PHY 字节对齐层、
HDMI 发送核）与 DDR2 物理时序只能上 TD/真机验证，已在文中标注。

## 四步交付总览

| 步骤 | 交付物 | 验证状态 |
|------|--------|----------|
| ① 环境搭建 | TD TCL 自动化脚本 + 固化 runbook（`scripts/`） | 文档级（待 TD 实测） |
| ② 驱动开发 | 按键消抖→阈值组/跟踪使能 glue、UART 遥测（新增 RTL）+ TB | tb_uart_telemetry PASS |
| ③ 摄像头配置 | SC500CS 寄存器表 ROM 化确认 + I2C BFM + 配置链 TB | 部分通过（位相遗留，见下） |
| ④ 联调交付 | `system_top.v`（官方 ISP 全链 + vision_top 零改动挂载）+ 对接仿真 | **elaboration 零错误**；全链仿真列 TD 阶段项 |

## 对接证明（分层）

1. **契约层（已证）**：视觉方向消费的 96bit AXI-S 契约 = 官方 `isp_top` 输出经
   `data128_96` 重排（纯组合，官方模块原样复用）。tb_vision_top 14 项回归证明视觉侧
   完全兼容该契约。
2. **挂载层（已证）**：`system_top.v` 把官方 ISP（demosaic/AWB/BLC/blk_mem 全套明码
   RTL）+ data128_96 + vision_top + 按键 + UART 装进一个顶层，ModelSim elaboration
   **零错误**（含官方 blk_mem 仿真 RTL 与两个 ERAM 行为替身）。
3. **行为层（部分）**：tb_system_integration 以虚拟 RAW10 传感器驱动官方 ISP——
   发现官方 demosaic 的 tuser 链在本仿真环境不激活（详见"发现"节）→ 全链行为仿真
   列为 TD 阶段验证项。
4. **外设层（已证）**：UART 遥测逐字节验证（A5 定界、校验和、坐标、LOCK/LOST）。

## 重要发现（上板联调检查点）

1. **官方 `demosaic.v` 的 tuser 链在纯 RTL 仿真不激活**（bilinear 5 拍延迟线输入
   无脉冲；tlast 正常 2424 次）——很依赖真实 CSI 时序或 TD 仿真库。上板若"有数据
   无帧同步"，先查 tuser 链。已记录进 tb_system_integration（保留为 TD 阶段项）。
2. **AWB 是色彩目标跟踪的天然威胁**（环境清单 5.4 风险项的实证路径）：AWB 自适应
   会拉近目标色与背景色。对策已内置：阈值 8 组现场切换 + 必要时锁 AWB 增益
   （isp_top 内 awb 分支留有旁路改造点，改造方案在联调预案中）。
3. **`divider_gate.v` 是门级网表**（AL_* 库单元 7355 行）：仿真需行为级替身
   （`rtl/divider_gate_sim.v`，TD 综合时排除替身、用真网表）。
4. **ERAM 原语**：官方 blk_mem 仿真 RTL 例化 `PH1P_LOGIC_ERAM/PH1_LOGIC_ERAM`，
   仿真需行为替身（`rtl/ph1p_logic_eram_stub.v`，双口 RAM 行为，TD 用真原语）。

## 遗留（TD 阶段）

- tb_i2c_config：BFM 的 ACK 位相与 uii2c 主控存在未收敛的时序细节（464 次地址识别
  正确但 ACK 后状态被自身 START 误判清零）——上板用逻辑分析仪抓真机波形后半天可收敛；
  寄存器序列本身（116 条）已由 ROM 逐条确认。
- tb_system_integration 全链行为仿真（依赖 demosaic tuser 链在 TD 仿真器下复现）。
- DDR2 控制器与 HDMI 加密核：官方黑盒，仅上板验证。
