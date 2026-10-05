# fpga-ptz-tracker —— 视觉方向软件包

2026 FPGA 创新设计赛道（安路）赛题二：基于 PH1P35 的实时数字图像处理系统。
本仓库 = **视觉方向**全部软件资产：检测链 RTL、OSD 叠加、云台闭环控制、
金标准模型、测试向量、仿真套件与全套文档。

## 当前状态（2026-10-03）

- **整体回归 18/18 全绿**（ModelSim，`python tools/run_all.py`；含 CDC 复位偏斜、算法切换帧专项）
- 闭环在环仿真：12 帧锁定（相机-舵机模型，T1 控制节拍修正后），无振荡
- OSD 整帧 921600 像素与金标准逐位一致
- 硬件已到位（SC520CS + HX1P35A）：板级整链仿真 PASS + 出图确认，见 `08_board_bringup/`；
  TD 综合/上板清单在 `04_embedded/`
- **✅ 上板前 High 项已修复并复验（2026-10-03 修复轮，迭代记录 #N+7）**：
  实测官方 ISP AWB 输出为行级突发（320 beat=1280px/行）→ ser96to24 重写为 **v4 弹性缓冲**
  （2048px、寄存器读、+1 拍流水）；视觉抽头改 **AWB 96bit 直抽**（弃用 128bit 重排——其 tuser
  结构性错位）；`system_top` 握手修复。验收：行突发全链 TB **`pixels=2764800/sof=3/eol=2160/drop=0`
  PASS**（修复前 188 像素/0 SOF），18 项回归全绿；TD 像素域 **WNS −0.113 → +0.541ns（0 违规端点）**，
  OSD 跑马灯数组 ROM 化根治。证据与复现见 `08_board_bringup/02_td_synth_gate/`。
  遗留：ERAM 预算（视觉链 61/108，整合后≈93%，边缘支路可降 512px 或共享串化器）、P&R 后复核、
  真机上板以 `O_drop_cnt`+帧计数双重确认。

## 目录结构（对应项目地图六大分区）

```
01_official/          官方资料索引（原文件在 D 盘原位）
02_meetings/          决策纪要
03_vision/            ★ 视觉方向四步（每步四件套：方案对比/技术文档/工程文件/迭代文件）
  step1_video_link/       基座：串化器/TPG/仿真源/CDC
  step2_color_centroid/   检测链：HSV→阈值→平滑→质心
  step3_closed_loop/      云台控制律 + PWM
  step4_osd_integration/  OSD 叠加 + 整机顶层 + 闭环在环
04_embedded/          嵌入式方向交接说明（挂载/引脚/验收清单）
05_gimbal/            云台机械/电气/标定
06_interfaces/current/  接口统一文档（唯一生效版）
tools/                金标准模型 + 向量生成 + 测试调度（Python）
使用文档_视觉方向软件包.md
```

## 教程（给新队员）

**视觉方向（五册）**：

| 文档 | 内容 | 页数 |
|------|------|------|
| [docs/step1_tutorial.pdf](docs/step1_tutorial.pdf) | 《Step1 视频链路基座——从零手搓教程》 | 25 页 |
| [docs/step2_tutorial.pdf](docs/step2_tutorial.pdf) | 《Step2 颜色识别与质心——从零手搓教程》 | 26 页 |
| [docs/step3_tutorial.pdf](docs/step3_tutorial.pdf) | 《Step3 云台闭环控制——从零手搓教程》 | 17 页 |
| [docs/step4_tutorial.pdf](docs/step4_tutorial.pdf) | 《Step4 OSD 与系统联调——从零手搓教程》 | 16 页 |
| [docs/step5_tutorial.pdf](docs/step5_tutorial.pdf) | 《Step5 拓展功能集——从零手搓教程》 | 14 页 |

**嵌入式方向（两册，按工程实际结构编排）**：

| 文档 | 内容 | 页数 |
|------|------|------|
| [docs/emb1_tutorial.pdf](docs/emb1_tutorial.pdf) | 《全链集成与仿真设施——嵌入式对接教程（一）》 | 15 页 |
| [docs/emb2_tutorial.pdf](docs/emb2_tutorial.pdf) | 《外设驱动、摄像头配置与固化——嵌入式对接教程（二）》 | 15 页 |

内容分两部分（每册均同此结构）：
- **Part I 学习教程**：零基础入门路径，每阶段带练习与学习清单
- **Part II 工程实现详解**：实际 RTL 的逐模块分析——设计决策、逐段代码、
  边界情况、踩过的真 bug 与修复、测试平台设计、上板挂载说明

各册主题（Part II 独有内容）：
- **Step1**：串化器/TPG/CDC 逐模块、5 个真 bug、测试平台四层验证
- **Step2**：检测链逐模块、bin_smooth3x3 的 v3→v7 重构、
  质心"除法快照"竞争、向量文件格式三坑
- **Step3**：控制律/pwm_servo、增益公式与 2 帧延迟稳定判据、
  Kp 整定三轮记录（90 发散→40 慢发散→20 锁定，T1 节拍修正后 12 帧收敛）
- **Step4**：字库 ROM、osd_track v3 影子寄存器消撕裂、135bit 包位图、
  "永远 LOST"事故复盘、逐像素金标准比对方法
- **Step5**：官方核复用纪律、帧边界无缝切换、Q6 画质调节、
  帧差运动检测 v2（两处仿真/综合不一致修复）、7 轮迭代复盘
- **嵌入式（一）**：官方 ISP 链路接入、两个行为替身的三条纪律、
  system_top 集成两坑、虚拟 RAW10 传感器与整链四判据、分层证明写法
- **嵌入式（二）**：UART 遥测协议与 bit_idx 状态机、
  I2C 开漏建模与 ACK 位相遗留（诚实记录）、配置链对录方法、
  TD 工程/filelist/QSPI 固化 runbook、五步联调检查点

源码：`docs/stepN_tutorial.tex` + `docs/stepN_impl.tex`（N=1..5）、
`docs/emb1_*.tex` + `docs/emb2_*.tex`，
编译：`cd docs && latexmk -xelatex stepN_tutorial.tex`；
静态检查：`python tools/check_tex.py docs/*.tex`；
逐页渲染（视觉验收）：`python tools/render_pdf.py docs/*.pdf <输出目录>`

## 上板阶段（08_board_bringup）

硬件已到位（SC520CS 摄像头 + HX1P35A 开发板）。

| 内容 | 位置 |
|------|------|
| 视频传输路线工程（SC520CS 适配版官方 Lab1，720p60） | [08_board_bringup/01_video_passthrough/](08_board_bringup/01_video_passthrough/) |
| 使用指导 PDF（导入/仿真/烧录/排查） | [docs/board1_guide.pdf](docs/board1_guide.pdf) |
| **烧录实战教程（试错全记录 + GUI 逐步点击 + 命令行 + 固化，2026-10-04 实测，14 页）** | [docs/td_burn_tutorial.pdf](docs/td_burn_tutorial.pdf)（源稿 `docs/td_burn_tutorial.md` + `docs/assets_td_burn/`；any2pdf 生成，改稿后连跑两遍脚本即带目录页码） |
| **接口修复与异常帧防护（第2批：repack tlast/保相位、坏帧标志接入、AWB 窗口/暗剔除/坏帧门，2026-10-05）** | [08_board_bringup/05_isp_interface/](08_board_bringup/05_isp_interface/)（README + tb_repack + 定版 bit `..._awbfs_b2.bit`） |
| **饱和度增强重建（画面发灰修复：+axis_saturation_rgb96，无头两段重建，2026-10-04）** | [08_board_bringup/03_td_rebuild_sat/](08_board_bringup/03_td_rebuild_sat/)（README + 定版 bit `camera_to_dsi_display_sat_k28.bit`（K≈1.75x，已上板）+ QSPI 镜像 + 复现命令） |
| **独立投放包（成品 bit + TD 工程 + 烧录说明，2026-10-04）** | **`D:\SC520_display_burnpack`**（交接/外发用；先读其 `00_START_HERE_burn_guide.md`） |
| 整链仿真（虚拟 RAW10 传感器 → ISP → 帧转储出图） | 01_video_passthrough/sim/（run_sim.bat 一键） |

仿真实测（2026-10-03 复跑）：`TB_RESULT: PASS frames_dumped=2 tuser_total=3 tlast_total=2008 ser_ovf=0`，
PNG 出图确认为灰底 + 噪声 + 红色条纹方块（虚拟传感器目标物）。
已知坑与修复复盘见嵌入式迭代记录第 9、10 轮。

## 外部评审包（给其它 AI / 同行）

| 文档 | 内容 |
|------|------|
| [docs/burnpack_review.pdf](docs/burnpack_review.pdf) | **SC520 视频通路交付包评审卷宗：41 页**（交付包技术内容+我方源码全文+验证证据+Q1~Q8；源稿 `docs/burnpack_review.md`，生成器 `tools/make_burnpack_review.py`） |
| [docs/评审包_代码与设计说明.pdf](docs/评审包_代码与设计说明.pdf) | **全部自研代码（RTL/TB/仿真设施/Python，约 7600 行）+ 架构说明 + 验证状态 + 开放问题清单，105 页**，供外部独立评审 |

生成脚本：`python tools/make_review_pdf.py`（可复现；代码以仓库实际文件为唯一真值）。

## 快速开始

```bash
cd D:\fpga-ptz-tracker\tools
python gen_vectors.py     # 生成全部测试向量与两张自动 RTL 表
python run_all.py         # 全量 18 项回归（含 CDC 复位偏斜、算法切换帧），约 4 分钟
python run_all.py tb_vision_top tb_closed_loop   # 只跑指定项
```

环境：Python 3.10（numpy/cv2）+ ModelSim（`D:\ModelSim\win64`，路径写死在 run_all.py）。

## 与嵌入式方向的接口

`06_interfaces/current/`：IF-MIPI（视频输入）、IF-DDR（旁路挂载）、
IF-VISION（目标包，强耦合点）、IF-SERVO-PWM（云台）、IF-OSD（显示侧）。

## 覆盖的赛题要求

| 要求 | 本包对应 |
|------|----------|
| 扩展① 图层叠加与文字 | OSD 文字层（TRK0 LOCK X..Y..） |
| 扩展④ 实时参数调节与 OSD | 阈值 8 组按键切换 + OSD 显示组号/状态 |
| 进阶② 目标跟踪与坐标标注 | 检测链 + 十字/框/坐标 OSD + 云台闭环 |
| 进阶③ 延迟可视化（可选） | OSD 帧计数扩展位（架构已留） |
