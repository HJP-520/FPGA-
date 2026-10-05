# FPGA 创新设计赛道（安路）· 视觉方向主仓库

> 2026 全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道 · 赛题二
> **基于 PH1P35 的实时数字图像处理与云台跟踪系统**
> 平台：安路 HX1P35A 开发板（PH1P35MDG324）+ SC520CS 摄像头 + HDMI 显示

本仓库是三个本地工作目录的整合版本，把「已确认能上板的视频通路」「算法与仿真研发资产」
「官方资料」合并到一处，方便队友查阅、复现和交接。

---

## 一、先看这里：三份资产的分工

整合前它们分散在三个盘符目录，现在按**成熟度**分成三个顶层目录：

| 仓库目录 | 来源 | 定位 | 能否上板 |
|---|---|---|---|
| [`01_board_burnpack/`](01_board_burnpack/) | `D:\SC520_display_burnpack` | **视频通路交付包**（成品 bit + TD 工程 + 烧录脚本 + 验证卷宗） | ✅ **已实测出图** |
| [`02_ptz_tracker_dev/`](02_ptz_tracker_dev/) | `D:\fpga-ptz-tracker` | **算法与仿真研发资产**（检测链 RTL / 金标准模型 / 五册教程 / 上板各批次） | ⚠️ **整体未上板验收**，仅链路部分与 burnpack 同源 |
| [`03_official_refs/`](03_official_refs/) | `D:\FPGA创新赛` | **官方资料**（选题指南 / 赛题解析 / 安路技术文档 / 设计参考） | — |

> **重要区分**：`02_ptz_tracker_dev/` 里「仿真全绿」不等于「能上板」。
> 该目录的算法模块（HSV 阈值、质心、OSD、云台控制）目前**只有 ModelSim 验证证据，
> 没有真机运行证据**；真正烧进板子跑通的是 `01_board_burnpack/` 的视频通路。
> 详细状态见 [`docs/02_上板状态与验证结论.md`](docs/02_上板状态与验证结论.md)。

---

## 二、五分钟看到画面

**只想先在显示器上看到摄像头画面**，用 `01_board_burnpack`，双击脚本即可：

```bat
cd 01_board_burnpack\01_bitstream_flash_direct
burn_camera_sram.bat          :: 烧摄像头画面（实测 100% / 11.9 秒）
burn_colorbar_sram.bat        :: 显示器无信号时先用彩条自检，隔离问题
burn_camera_sat_sram.bat      :: 饱和度增强版（画面不发灰，K≈1.75x）
```

前置条件与完整步骤见
[`01_board_burnpack/00_START_HERE_burn_guide.md`](01_board_burnpack/00_START_HERE_burn_guide.md)，
图文版见 [`TD_burn_tutorial.pdf`](01_board_burnpack/TD_burn_tutorial.pdf)（14 页，含每步点哪里）。

---

## 三、当前推荐版本（2026-10-05）

画面过暗的修正版是 **balanced（4× 增益档）**，源工程默认启动增益 AG80：

| 用途 | 位流 | 烧录脚本 | 参数 |
|---|---|---|---|
| **推荐（亮度修正）** | `camera_to_dsi_display_codex_balanced.bit` | `burn_codex_balanced_sram.bat` | AG=80（4×）、AE=1991、AWB 开、K=24 |
| 上一版主版 | `camera_to_dsi_display_codex_main.bit` | `burn_codex_main_sram.bat` | AG=16、AE=1991、AWB 开、K=24 |
| 颜色诊断版 | `camera_to_dsi_display_codex_unity.bit` | `burn_codex_unity_sram.bat` | AWB 固定 1×、K=16（关闭两级颜色增强） |

三个候选**仿真/综合/布局布线均通过，但尚未上板验收**；旧定版 bit 与 QSPI 镜像全部保留可回退。
详见 [`01_board_burnpack/04_codex_validation/README.md`](01_board_burnpack/04_codex_validation/README.md)。

**未结问题**：画面「中心泛绿」尚未定位到根因，unity 版仍有泛绿 → 说明不只是这两级颜色增强所致。
排查思路见 [`GREEN_CENTER_RESEARCH.md`](01_board_burnpack/04_codex_validation/GREEN_CENTER_RESEARCH.md)。

---

## 四、仓库地图

```
FPGA-/
├── README.md                    ← 本文件（总入口）
├── docs/                        整合说明与状态文档
│   ├── 01_仓库结构与来源对照.md
│   ├── 02_上板状态与验证结论.md   ← 判断「哪个能用」先看这份
│   ├── 03_收录与排除清单.md       ← 为什么少了 3.8GB
│   └── 04_工具链与复现指南.md
├── 01_board_burnpack/           视频通路交付包（已上板）
│   ├── 00_START_HERE_burn_guide.md    ★ 从这里开始
│   ├── 01_bitstream_flash_direct/     成品 bit + 一键烧录脚本
│   ├── 02_TD_project_rebuild/         完整 TD 工程（可重建比特流）
│   ├── 03_simulation_optional/        ModelSim 整链仿真
│   ├── 04_codex_validation/           改进版验证（单测/证据/构建脚本）
│   └── _hx1p35_docs/                  厂商烧写与驱动文档
├── 02_ptz_tracker_dev/          算法与仿真研发资产（未整体上板）
│   ├── 03_vision/                    视觉方向五步（step1~step5）
│   ├── 04_embedded/                  嵌入式对接（system_top / UART / 固化 runbook）
│   ├── 06_interfaces/current/        接口唯一生效版
│   ├── 08_board_bringup/             上板各批次（01~06）
│   ├── docs/                         七册教程 PDF + LaTeX 源稿
│   ├── tools/                        金标准模型 + 向量生成 + 回归调度
│   └── 07_答辩素材/                  答辩 PPT / 讲稿 / 收敛曲线
├── 03_official_refs/            官方资料
│   ├── 官方资料文档/                选题指南、赛题解析、安路技术文档、设计参考
│   └── 阶段驱动版项目地图.html
└── legacy/                      早期快照归档（已被上表目录取代）
```

---

## 五、跑仿真回归（`02_ptz_tracker_dev`）

```bash
cd 02_ptz_tracker_dev/tools
python gen_vectors.py     # 先生成测试向量（*.hex 不入库，需本地生成）
python run_all.py         # 全量回归，期望 "汇总: N/N PASS"
python run_all.py tb_vision_top tb_closed_loop    # 只跑指定项
```

环境：Python 3.10（numpy/opencv）+ ModelSim SE（本机路径写死在 `run_all.py`，默认 `D:\ModelSim\win64`）。
**工程目录必须保持 ASCII** —— ModelSim 遇中文路径会报 sqlite 错误。

验证的是 RTL 与 Python 金标准**逐位一致**，不是"看起来对"。
金标准在 `tools/golden_model.py`，改算术必须先改它再同步 RTL。

---

## 六、工具链与硬件

| 项 | 版本 / 型号 |
|---|---|
| FPGA | 安路 PH1P35MDG324（HX1P35A），速度等级 -3 |
| 工具 | 安路 TD 6.2.1（本机 `D:\TD6.2.1`） |
| 仿真 | ModelSim SE 10.4（本机 `D:\ModelSim\win64`） |
| 下载器 | FT2232（USB-JTAG，A 通道需装 WinUSB 驱动） |
| 摄像头 | SC520CS，MIPI 2-lane RAW10，MCLK 24MHz，I2C 7bit `0x36` |
| 显示 | HDMI TMDS 1280×720@60 |
| 板载 Flash | 兆易 W25Q128（16MB），用于 QSPI 固化 |

TD 流程命令与各阶段产物标志见 [`docs/04_工具链与复现指南.md`](docs/04_工具链与复现指南.md)。

---

## 七、覆盖的赛题要求

| 要求 | 对应实现 | 状态 |
|---|---|---|
| 基础：实时图像采集与显示 | SC520 → ISP → HDMI 720p60 | ✅ 已上板 |
| 进阶② 目标跟踪与坐标标注 | 检测链 + 十字/框/坐标 OSD + 云台闭环 | ⚠️ 仅仿真 |
| 进阶③ 延迟可视化 | OSD 帧计数扩展位（架构已留） | ⚠️ 仅架构 |
| 扩展① 图层叠加与文字 | OSD 文字层（TRK0 LOCK X..Y..） | ⚠️ 仅仿真 |
| 扩展④ 实时参数调节与 OSD | 阈值 8 组按键切换 + OSD 显示组号/状态 | ⚠️ 仅仿真 |
| 赛场要求：无 PC 参与冷启动 | QSPI 固化（`camera_to_dsi_display_qspi_16M.bin`） | ⚠️ 镜像已生成，固化流程待现场验收 |

---

## 八、整合说明

本仓库由三个本地目录整合而成，**整合时没有删除任何本地文件**，只做了筛选收录。
哪些收了、哪些没收、为什么没收，见
[`docs/03_收录与排除清单.md`](docs/03_收录与排除清单.md)。
被排除的主要是厂商大体量压缩包和可重新生成的工具链产物（GitHub 单文件上限 100MB）。
