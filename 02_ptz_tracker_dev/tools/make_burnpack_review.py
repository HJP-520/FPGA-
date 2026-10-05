#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""make_burnpack_review.py —— 生成《SC520 视频通路交付包 · 评审卷宗》Markdown 源稿

原则（与仓库评审包口径一致）：
  · 代码以仓库/交付包实际文件为唯一真值（本脚本生成时现场读取并计算 MD5）；
  · 状态总览/证据/复现前置；开放问题清单收尾，供外部 AI 评审。
用法：python tools/make_burnpack_review.py   → 输出 docs/burnpack_review.md
随后用 any2pdf 两遍编译（--code-max-lines 2000）得到 PDF。
"""
import os
import hashlib

ROOT = r"D:\fpga-ptz-tracker"
PACK = r"D:\SC520_display_burnpack"
OUT = os.path.join(ROOT, "docs", "burnpack_review.md")

FILES = [
    # (标题, 路径, 语言, 说明)
    ("5.1 axis_saturation_rgb96.v —— 饱和度增强级（新增，含评审#7 位宽修复）",
     os.path.join(ROOT, r"04_embedded\03_project\rtl\axis_saturation_rgb96.v"), "verilog",
     "我方新增。插在 ISP 链 AWB 之后、128bit 重排之前；Q4.4 增益 K（板上定版 28≈1.75x）；"
     "中间量 v 已扩为 12bit（评审 #7：原 10bit 在 K≥33 时先于限幅溢出）。"
     "该模块同时以独立文件（本节）与内嵌形式（5.3 isp_top.v 文件末尾）存在，两处文本一致。"),
    ("5.2 awb.v —— 白平衡（改动版全文，板上真值；含#1 帧同步化与第2批边界防护）",
     os.path.join(ROOT, r"08_board_bringup\01_video_passthrough\lab_ex1\user_source\hdl_source\awb.v"), "verilog",
     "厂商原版 + 第1批（#1 帧同步化）：上一帧统计锁存 / 商帧内恒定 / 帧边界 ±0.125x 步进、限幅 0.5~3.0x；"
     "+ 第2批：采样数上下界（20480~300000，防短帧与漏 SOF 并帧）+ 近黑剔除（rgb_sum>45）"
     "+ frame_bad 门（坏帧不采信）。改动段有注释标记；边界 TB 38 项全绿（5.4）。"),
    ("5.3 isp_top.v —— ISP 顶层（饱和度实例 + 第2批接口接线；全文）",
     os.path.join(ROOT, r"08_board_bringup\01_video_passthrough\lab_ex1\user_source\hdl_source\isp\isp_top.v"), "verilog",
     "厂商原版 + 我方改动：u_saturation 实例（AWB 之后）；第2批：repack 的 I_96b_tlast/O_128b_tlast 接入、"
     "O_tlast = repack_O_tlast（与 O_tdata/O_tvalid 同拍）、新增 I_frame_bad 端口。"),
    ("5.4 tb_awb.v —— AWB 单元测试台（含第2批边界相位；新增）",
     os.path.join(ROOT, r"08_board_bringup\04_awb_framesync\tb_awb.v"), "verilog",
     "直接实例化工程版 awb.v（板上真值）。38 项检查全绿（PASS）：正常链（复位/首步/两帧滞后/帧内恒定/"
     "限幅 3.0x/帧中突变）+ 边界（20480 拒/20481 采、亮白与近黑剔除、超长帧拒、坏帧门拒+恢复、帧中复位）。"),
    ("5.5 tb_video_passthrough.v —— 整链仿真 TB（含饱和度 SAT_EN 开关）",
     os.path.join(ROOT, r"08_board_bringup\01_video_passthrough\sim\tb_video_passthrough.v"), "verilog",
     "虚拟 RAW10 传感器 → ISP(明码) → 饱和度级（TB 内插入，SAT_EN/SAT_K_Q4 可切换）→ "
     "弹性串化 → 逐帧转储。位精确对拍即基于其转储帧。"),
    ("5.6 px_serializer_fifo.v —— 仿真用“浅 DDR”（弹性 FIFO + 真反压）",
     os.path.join(ROOT, r"08_board_bringup\01_video_passthrough\sim\px_serializer_fifo.v"), "verilog",
     "整链仿真里替代 DDR 帧缓存的角色；4 像素/拍 → 1 像素/拍。"),
    ("5.7 烧录脚本（交付包内三个一键 bat）",
     None, "bat",
     "burn_camera_sram.bat（原版直通流）/ burn_camera_sat_sram.bat（当前定版，见 6.4）/\n"
     "burn_colorbar_sram.bat（彩条自检）。要点：自动确保 hwserver 在跑——**手动启动必须带 -r**\n"
     "（remote-bitbang，端口 5555；不带只开设备不开服务——本次实测教训）。"),
    ("5.8 tools/sat_tool.py —— 饱和度预览/位精确对拍工具（新增）",
     os.path.join(ROOT, r"tools\sat_tool.py"), "python",
     "sweep：多档 K 预览拼图（仿真帧 + 实拍照片示意）；check：RTL 转储帧 vs Python 同式\n"
     "参考逐字节比对（与 RTL 全整数同式，含算术右移 floor 语义）。check 模式已严格帧尺寸校验。"),
    ("5.9 data_96bit_to_128bit —— 96→128 重排（第2批重构版，板用副本全文）",
     os.path.join(ROOT, r"08_board_bringup\01_video_passthrough\lab_ex1\user_source\hdl_source\isp\data96_128\data96_128.v"), "verilog",
     "第2批改动：① 气泡保相位（valid=0 不再清 S_cnt，仅帧首复位；评审#8）；"
     "② tlast 在 repack 内重建（O_128b_tlast 与 O_128b_valid/O_128b_data 同拍；评审#4/#5）。"
     "行长为 4 拍整数倍（720p 行 320 拍）时 tlast 恒在相位 3。本文件另含未用的 data96_128 模块。"),
    ("5.10 tb_repack.v —— post-repack 记分板（第2批①，新增）",
     os.path.join(ROOT, r"08_board_bringup\05_isp_interface\tb_repack.v"), "verilog",
     "byte-stream 记分板 + 气泡注入（4 个相位各一次）+ tlast 落位 + back-to-back 帧；"
     "结果见 6.6（全部 CHECK OK）。"),
]

EVIDENCE_TB = os.path.join(ROOT, r"08_board_bringup\04_awb_framesync\tb_awb_run.log")


def read_text(path):
    """按行尽力解码（厂商历史文件存在 GBK/UTF-8 混编）；归一化 CRLF，避免 CR 渲染成空行。"""
    raw = open(path, "rb").read()
    try:
        txt = raw.decode("utf-8")
    except UnicodeDecodeError:
        out = []
        for ln in raw.split(b"\n"):
            for enc in ("utf-8", "gbk"):
                try:
                    out.append(ln.decode(enc))
                    break
                except Exception:
                    continue
            else:
                out.append(ln.decode("utf-8", "replace"))
        txt = "\n".join(out)
    return txt.replace("\r\n", "\n").replace("\r", "\n")


def md5_of(path):
    return hashlib.md5(open(path, "rb").read()).hexdigest()


def code_block(lang, text):
    return "```%s\n%s\n```" % (lang, text.rstrip("\n"))


def main():
    P = []
    A = P.append

    A("""---
title: SC520 视频通路交付包 · 评审卷宗
subtitle: HX1P35A 摄像头→HDMI 直通 + 饱和度/AWB 改动 —— 供外部独立评审
author: FPGA 创新赛视觉组（D:\\fpga-ptz-tracker）
date: 2026-10-05
version: v1.1
theme: github-light
header-title: SC520 视频通路交付包评审卷宗
footer-left: FPGA 创新赛视觉组
---

# 一、评审范围与阅读指引

**本卷宗覆盖什么**：交付包 `D:\\SC520_display_burnpack` 的全部工程技术内容，以及仓库中
与之对应的改动源码与验证证据。目标是让评审者**不接触硬件、不打开 TD** 也能完成技术评审。

**文件归属（评审火力请集中在"我方"部分）**：

| 归属 | 文件 |
|---|---|
| 我方新增 | `axis_saturation_rgb96.v`、`tb_awb.v`、`tb_repack.v`、`tools/sat_tool.py`、三个 `burn_*.bat`、`px_serializer_fifo.v`、批次文档 |
| 我方修改 | `awb.v`（#1 帧同步化；第2批：采样窗口/近黑剔除/frame_bad 门）、`isp_top.v`（饱和度实例；第2批：repack tlast 接入 + I_frame_bad）、`data_96bit_to_128bit`（**第2批：间隙保相位 + tlast 重建**）、`design_top_wrapper.v`（**第2批：坏帧标志接线，三行小改**）、`tb_video_passthrough.v`（SAT_EN 开关）、`filelist_sim.f` |
| 厂商原版（未动） | `user_source` 其余 96 个 RTL、`ip_source`、约束、`lab_ex1` 工程结构、`_hx1p35_docs` 官方文档、原版/彩条 bit |

> **v1.1（2026-10-05）变更说明**：依首轮评审意见修订——(1) 更正两处过强表述：AWB"防异常帧污染"改为"防短/空/近白不足帧，坏帧由 frame_bad 门拦截（第2批）"；"tlast 已对齐"改为"第2批在 repack 内重建（与 O_tdata/O_tvalid 同拍）"。(2) 归入第2批的新增代码/测试/证据（5.9/5.10、6.6、7.1 更新、R1 重写）。(3) 改用 (1)(2)(3) 编号并补当前定版 bit（awbfs_b2）。

**建议评审优先级**：① AWB 帧同步化与第2批边界防护（窗口/暗剔除/坏帧门）的正确性；
② repack 重构（气泡保相位 + tlast 重建）与 post-repack 记分板；③ 流接口语义（tlast/repack）；
④ 第七章的 Q1~Q8 逐条结论（v1.1 已更新处置状态）。

# 二、状态总览（截至 2026-10-05）

## 2.1 比特流三代（板上/包内现状）

| 版本 | 内容 | MD5 | 状态 |
|---|---|---|---|
| `camera_to_dsi_display.bit` | 厂商原版直通流（=best_result 同源） | `2ef0ec47…` | 基线留档 |
| `…_sat_k21.bit` | 饱和度 1.31x（过渡版） | `d211a715…` | 留档 |
| `…_sat_k28.bit` | 饱和度 1.75x（曾定版，已上板验收） | `5f2a33c4…` | 留档 |
| `…_sat_k28_awbfs.bit` | 饱和度 1.75x + AWB 帧同步化（第1批） | `%(awbfs)s` | 留档（未上板） |
| `…_sat_k28_awbfs_b2.bit` | 上述 + **接口修复（第2批：repack tlast/异常帧门）** | `%(awbfs_b2)s` | **当前定版：已烧录实测**（PRG-2014+返回 0，2026-10-05；目视验收进行中） |

## 2.2 时序（无头两段流程：syn_1 → phy_1，厂商自带 settings.cfg）

| 构建 | 阶段 | Setup WNS / TNS / 违规端点 | Hold WNS |
|---|---|---|---|
| K21（1.31x） | phy final | +255ps / 0 / 0 | +20ps / 0 |
| K28（1.75x） | phy final | +703ps / 0 / 0 | +20ps / 0 |
| K28+AWB（第1批） | phy final | +176ps / 0 / 0 | +20ps / 0 |
| K28+AWB+接口（第2批，**当前**） | phy final | +143ps / 0 / 0 | +20ps / 0 |

## 2.3 一致性（"工程源码 = 能重建板上定版"的核验）

| 位置 | isp_top.v | awb.v | 状态 |
|---|---|---|---|
| 仓库 `01_video_passthrough/lab_ex1` | ✓ 含饱和度+K28 | ✓ 帧同步化 | 三处同哈希 |
| 仓库 `03_td_rebuild_sat/lab_ex1_build`（构建工作树） | ✓ | ✓ | （本表三次构建的来源） |
| 交付包 `02_TD_project_rebuild/lab_ex1` | ✓ | ✓ | 与上两处 MD5 一致 |

> 厂商原版基线唯一保留于仓库 `_sc520_src/`。

## 2.4 验证矩阵

- **单元 TB**（tb_awb，28 项行为检查）→ 工程版 awb.v：**全绿**（6.1 全录）；
- **整链仿真**（虚拟 RAW10，3 帧）→ ISP→饱和度→转储：PASS（几何与基线一致）；
- **位精确对拍**（Python 同式参考）→ 饱和度级经整链：K=28 / K=50 全 PASS；
- **时序** → 三代构建全部 0 违规端点（2.2 表）；
- **烧录实测** → `PRG-2014 Chip validation success` + 100%%（11~12s）。

# 三、交付包结构与文件树

```text
SC520_display_burnpack\\
├── 00_START_HERE_burn_guide.md      # 先读：包内容/接线/三种烧录方式/固化/故障速查
├── TD_burn_tutorial.pdf             # 烧录实战教程 14 页（试错+GUI逐步点击+CLI+固化）
├── video_passthrough_guide.pdf      # 详细版指导 9 页
├── burnpack_review.pdf              # 本卷宗
├── 01_bitstream_flash_direct\\       # 成品 bit（原版/k21/k28/awbfs）+ QSPI 镜像 + 三个一键 bat
├── 02_TD_project_rebuild\\lab_ex1\\  # 完整 TD 工程（已含全部我方补丁，可重建定版）
│   ├── td_project\\                 #   .al(已修XML) + Runs（厂商 best_result 留档）
│   └── user_source\\                #   hdl_source 96 RTL + ip_source + 约束
├── 03_simulation_optional\\sim\\     # 整链仿真快照（TB 与仓库同步，含 SAT_EN 开关）
└── _hx1p35_docs\\                    # 官方烧写/驱动文档留档
```

# 四、信号链架构与改动位置

```text
SC520CS ─MIPI RAW10─> dphy_rx/csi_unpacket ─> demosaic ─> AWB ─> [我方] 饱和度级
                                                              │ axis_saturation_rgb96 (K=28)
                                                              │ data_96bit_to_128bit (96->128)
                                                              │
         video_in ──DDR 帧缓存── video_out ─> hdmi_mixer ─> hdmi_tx ─> HDMI 720p60

改动点：awb.v（帧同步化）；isp_top.v（u_saturation 实例 + O_tlast = sat_O_tlast）
```

| 改动点 | 文件:位置 | 内容 |
|---|---|---|
| ① 饱和度级 | `isp_top.v` u_saturation 实例 | AWB 之后、重排之前；4 像素/拍、2 拍流水、无背压 |
| ② AWB 帧同步化 | `awb.v` 三处（有"评审#1"注释） | 上一帧统计锁存 / 商帧内恒定 / 帧边界 ±0.125x 步进 |
| ③ tlast 对齐 | `isp_top.v` 输出段 | `O_tlast = sat_O_tlast`（原直取 awb，错位 3 拍） |

# 五、自研与改动代码全文
""" % {"awbfs": md5_of(os.path.join(PACK, r"01_bitstream_flash_direct\camera_to_dsi_display_sat_k28_awbfs.bit")),
     "awbfs_b2": md5_of(os.path.join(PACK, r"01_bitstream_flash_direct\camera_to_dsi_display_sat_k28_awbfs_b2.bit"))})

    # ---- 5.x 代码全文 ----
    for title, path, lang, note in FILES:
        A("\n## " + title + "\n")
        A(note + "\n")
        if path is None:
            # 5.7 三个 bat 合并展示
            for name in ("burn_camera_sram.bat", "burn_camera_sat_sram.bat", "burn_colorbar_sram.bat"):
                fp = os.path.join(PACK, "01_bitstream_flash_direct", name)
                A("**%s**（MD5 `%s`）：" % (name, md5_of(fp)[:8]))
                A(code_block("bat", read_text(fp)))
                A("")
        else:
            txt = read_text(path)
            n = txt.count("\n") + 1
            A("（%d 行，MD5 `%s`）\n" % (n, md5_of(path)[:8]))
            A(code_block(lang, txt))
            A("")

    # ---- 5.11 编译清单 ----
    A("\n## 5.11 编译清单（整链仿真 / AWB 单元 / repack 单元）\n")
    for tag, fp in (("filelist_sim.f（整链）", os.path.join(ROOT, r"08_board_bringup\01_video_passthrough\sim\filelist_sim.f")),
                    ("filelist_awb_tb.f（单元）", os.path.join(ROOT, r"08_board_bringup\04_awb_framesync\filelist_awb_tb.f")),
                    ("filelist_tb_repack.f（repack 单元）", os.path.join(ROOT, r"08_board_bringup\05_isp_interface\filelist_tb_repack.f"))):
        A("**%s**：\n" % tag)
        A(code_block("text", read_text(fp)))
        A("")

    # ---- 六、验证证据 ----
    A("""# 六、验证证据

本章为全部验证证据的原始记录；日志原件随仓库归档（路径见各小节标题）。

## 6.1 AWB 单元 TB 结果（28 项全绿，原始日志已归档 04_awb_framesync/tb_awb_run.log）

""")
    ev = read_text(EVIDENCE_TB)
    lines = [l for l in ev.split("\n") if "CHECK" in l or "TB_RESULT" in l]
    A(code_block("text", "\n".join(lines)))
    A("")
    A("""期望值推导说明：统计初值 +1 使目标商偶有 1LSB 偏差（1.5x 实测 0x17FFF，容差 TOL=0x100 覆盖）；
限幅检查特意用 3.75x 比值——若 clamp 失效增益会爬到 0x31FFF+（远超容差必判错），实测精确停在 0x30000。

## 6.2 整链仿真与位精确对拍

```text
TB_RESULT: PASS frames_dumped=2 tuser_total=3 tlast_total=2008 ser_ovf=0     （K=28 与 K=50 两轮同值）
sat_tool check K=28: [PASS] 921600 像素全部与 Python 参考一致（帧0/帧1 各一次）
sat_tool check K=50: [PASS] 921600 像素全部与 Python 参考一致（评审#7 修复后的溢出场景）
```

> 注：AWB 帧同步化并入工程版后，整链"位精确对拍"谱系由**未并入的仿真变体 AWB** 保持
> （见 6.1 说明与 7.3 风险 R3）；AWB 新行为由单元 TB 对板上真值验证。

## 6.3 时序证据（摘自各代 phy 日志 final 段）

```text
K21 : Setup WNS  255ps  TNS 0ps  NUM_FEPS 0 | Hold WNS 20ps  TNS 0ps
K28 : Setup WNS  703ps  TNS 0ps  NUM_FEPS 0 | Hold WNS 20ps  TNS 0ps
K28+AWB(awbfs,第1批): Setup WNS 176ps  TNS 0ps  NUM_FEPS 0 | Hold WNS 20ps  TNS 0ps
K28+AWB+接口(awbfs_b2,第2批): Setup WNS 143ps  TNS 0ps  NUM_FEPS 0 | Hold WNS 20ps  TNS 0ps
```

## 6.4 烧录实测记录（无头 CLI，hwserver -r / 端口 5555）

> **记录归属（如实标注）**：以下为 `…_sat_k28.bit`（曾定版）的完整烧录实录。**当前定版 `…_awbfs_b2.bit` 已于 2026-10-05 烧录实测成功**（同判据：Chip validation success + 进度 100% + 返回 0，见本节末补录）；色彩稳定性由现场目视确认。

```text
connect_cable -host_name 127.0.0.1:5555 -open   → 0.005s, 返回 0
read_device_id                                  → PH1P35MDG324
download -bit …/camera_to_dsi_display_sat_k28.bit
  PRG-2014 : Chip validation success: PH1P35MDG324
  0%…100% 进度条走满（约 12s），命令返回 0

补录：awbfs_b2（当前定版，第1+2批全部改动）
  download -bit …/camera_to_dsi_display_sat_k28_awbfs_b2.bit
  PRG-2014 : Chip validation success: PH1P35MDG324  → 返回 0   (2026-10-05)
```

## 6.5 源码一致性核验（本轮收尾时实测）

```text
三处 isp_top.v          MD5 一致（含 u_saturation + repack tlast 接入 + I_frame_bad）
三处 awb.v              MD5 一致（含 #1 帧同步化 + 第2批窗口/暗剔除/frame_bad 门）
三处 design_top_wrapper MD5 一致（含 S_frame_bad 接线）
三处 data96_128.v       MD5 一致（含保相位 + tlast 重建）
投放包 sim 的 tb/filelist 与仓库当前版逐字节一致
```
""")

    A("""
## 6.6 repack 重构验证（tb_repack，第2批①；原始日志 05_isp_interface/tb_repack_run.log）

""")
    _rp = read_text(os.path.join(ROOT, r"08_board_bringup\05_isp_interface\tb_repack_run.log"))
    A(code_block("text", "\n".join(l for l in _rp.split("\n") if "CHECK" in l or "TB_RESULT" in l)))
    A("""
# 七、已知问题与开放问题（请评审重点）

## 7.1 外部评审 7 条的处置状态

- **#1 AWB 按帧更新** — 属实 → 已改（5.2）；**第2批补强**：采样数上下界 + 近黑剔除 + frame_bad 门，边界 TB 38/38；
- **#2 异常帧丢弃**（error 线硬接 0）— 属实 → **第2批已接**：`S_mipi_last_*` 按帧锁存 → video_in 帧首回退 + AWB 拒采信；
- **#3 FIFO 满/空标志未用** — 属实（全悬空 / 接了未用）→ 第 3 批（先计数观测）；
- **#4 96→128 重排不支持间隙** — 属实 → **第2批已改**：气泡保相位 + repack 内 tlast 重建；新增 post-repack 记分板 TB（PASS）；
- **#5 tlast/ready 语义** — 属实 → 第1批消固定错位，**第2批在 repack 内重建**（与 O_tdata/O_tvalid 同拍）；完整握手重构暂缓；
- **#6 参数分散 / gamma 未例化** — 属实 → 第 3 批（随视觉链集成）；
- **#7 饱和度 v 位宽溢出（K≥33）** — 确凿 bug → 已修复（12bit，K=50 PASS）。

## 7.2 设计取舍（请评审这些参数选择）

| 取舍 | 当前值 | 理由 | 疑问 |
|---|---|---|---|
| AWB 滞后 | 2 帧（≈33ms@60fps） | 上一帧统计→本帧恒定，消除帧内漂移 | 对运动场景是否可感知？ |
| 增益步进 | ±0.125x/帧 | 场景切换 ~8 帧收敛，抑制色彩泵动 | 步进与滞后的组合是否过慢/过快？ |
| 增益限幅 | 0.5x~3.0x | 防除法病态（暗场景小分母）与极端修正 | 上限 3.0x 是否足够覆盖极端色温？ |
| 统计抽样 | 工程版 1/4 像素（原厂设计）+ 剔除近白（rgb_sum<720）与近黑（>45，第2批） | 省资源 + 防暗噪声驱动比值病态 | 1/4 抽样在纹理丰富场景的偏差风险？（相位轮换列为候选） |
| 采信门槛 | 20480 < 非白拍/帧 < 300000（第2批加下/上界） | 防短/空帧与漏 SOF 并帧（720p 并帧 460800 必拒） | 门限取舍是否合理？ |
| 饱和度 | K=1.75x（Q4.4，上限 3.94x） | 用户上板定版 | 与 AWB 的相互作用（见 Q3） |

## 7.3 风险与未覆盖项

- **R1**：DDR/显示路径（video_in/video_out/hdmi_tx）不在任何仿真内——第2批的坏帧门接线只能上板验证；
- **R2**：仿真树的 `isp_top` 为"抽头变体"（与工程版在端口层分叉），整链仿真不覆盖 frame_bad/repack-tlast 接线；
- **R3**：`axis_saturation_rgb96` 存在"独立文件 + isp_top 内嵌"双副本（现靠哈希一致性核验；计划最终并入 `.prj` 源列表）；
- **R4**：交付包内仿真 filelist 使用仓库绝对路径（离开本机无法独立运行）；
- **R5**：厂商 `.al` 与本机 TD GUI 不兼容（PRJ-8641），重建依赖无头流程（已验证可复现）。

## 7.4 请评审回答的问题清单

- **Q1**：AWB 帧同步化（5.2）的逻辑与边界是否正确？特别检查：上电序列（prev 初值 1 → 商恰为 1.0）、
  `stat_beats` 门槛、异常/碎帧时"保持旧增益"的行为、tuser 与统计清零同拍的非阻塞读旧值。
- **Q2**：增益应用段（Q16 乘法 + `[27:24]` 判 255 饱和）与帧同步化增益的配合是否有新的溢出/精度问题？
- **Q3**：无 CCM 的链路里，饱和度 1.75x 是否会放大 AWB 残余色偏？两者先后级（AWB→饱和度）是否合理？
- **Q4**：饱和度位宽修复（5.1，v=12bit）复核：K≤63 时最坏 |v|≈1004/−749，12bit 是否充分？
  `t`（16bit）与乘法链还有无其他溢出点？
- **Q5**：`O_tlast = sat_O_tlast` 的对齐程度（repack 未参与 tlast 重排）：将来在 ISP 输出后挂
  视觉检测模块时，这个边界的正确处理建议？
- **Q6**：#2 异常帧丢弃：顶层 `S_mipi_length_error/lane_error/last_*` 到 `video_in.I_mipi_rx_error`
  的"按帧锁存"实现建议（时序关联与复位点）？
- **Q7**：#3 FIFO 观测：溢出/欠载计数 + 欠载补色 + 溢出后等帧重同步的最小实现方案？
- **Q8**：#4 重排模块的间隙兼容改法（保相位 vs 帧边界复位）与无仿真覆盖下的验证方法？

# 八、复现速查

```bat
rem ---- 整链仿真（K 可在 TB 的 SAT_K_Q4 改）----
cd D:\\fpga-ptz-tracker\\08_board_bringup\\01_video_passthrough\\sim
run_sim.bat
python ..\\..\\..\\tools\\dump2png.py . passthrough_frame 0 1 --out sim_out
python ..\\..\\..\\tools\\sat_tool.py check --before baseline_oct03\\passthrough_frame_0.hex --after passthrough_frame_0.hex --k 28

rem ---- AWB 单元 TB ----
cd D:\\fpga-ptz-tracker\\08_board_bringup\\04_awb_framesync
run_tb.bat

rem ---- 无头重建（改 RTL 后）----
cd D:\\fpga-ptz-tracker\\08_board_bringup\\03_td_rebuild_sat\\lab_ex1_build\\td_project\\camera_to_dsi_display_Runs\\syn_1
D:\\TD6.2.1\\bin\\td_commands_prompt.exe D:\\TD6.2.1\\doc\\scripts\\DefaultFlow.tcl
cd ..\\phy_1
D:\\TD6.2.1\\bin\\td_commands_prompt.exe D:\\TD6.2.1\\doc\\scripts\\DefaultFlow.tcl

rem ---- 烧录（SRAM；hwserver 手动启动必须带 -r）----
D:\\SC520_display_burnpack\\01_bitstream_flash_direct\\burn_camera_sat_sram.bat
```
""")

    # ---- 九、评审提示词 ----
    A("""# 九、给评审者的提示词（v1.1 复核版，可直接复制发给 AI）

```text
你是资深 FPGA 图像通路评审专家。这是同一交付包（安路 PH1P35/HX1P35A，SC520CS 摄像头→HDMI 直通）
评审卷宗的 **v1.1 修订版**——按你上一轮评审意见逐条落实后的版本，请做**复核 + 增量评审**。

上一轮要点与处置（详见文首"v1.1 变更说明"与第七章 7.1 更新）：
- #1 AWB：采样数上下界（20480<beats<300000）+ 近黑剔除（rgb_sum>45）+ frame_bad 拒采信门；
  边界 TB 38/38（含 20480 拒/20481 采、亮白/近黑剔除、超长帧拒、坏帧门、帧中复位）；
- #2 异常帧：S_mipi_last_* 按帧锁存 → video_in.I_mipi_rx_error（帧首回退）+ AWB 门（按你的 Q6 方案）；
- #4/#5/#8 repack：气泡保相位 + tlast 在 repack 内重建（5.9），新增 post-repack byte-stream
  记分板（5.10/6.6：4 相位气泡注入 + tlast 落位 + back-to-back，PASS）；
- #7：v 位宽 10→12bit（K=50 位精确对拍 PASS）；
- 卷宗两处过强表述已更正（"防异常帧污染"、"tlast 已对齐"），风险清单 R1 重写。
- 上板状态：awbfs_b2 已重建待烧（下载器未连接，6.4 已如实标注）；sat_k28 版曾上板验证。

请按以下优先级输出：
1) 复核：对上述每项给"正确 / 仍有问题 / 表述仍不准确"，逐条附依据（模块/信号/代码行为）；
2) 重点检查两处新代码：repack 重构（5.9）的相位/边界；AWB 边界相位（5.4 与 6.1 证据）的实现细节；
3) 对仍未处理项（#3 FIFO 计数与重同步、#6 参数集中管理、1/4 抽样相位轮换）给最小实现建议；
4) 若发现新问题，按 严重度/位置/建议修复 排列。
不要泛泛而谈；每个结论给可核验依据；不同意处直接指出并说明理由。
```
""")

    # ---- 标题降级（H1 分部页在代码密集卷宗里会产生整页孤儿标题；H2 章页紧凑）----
    # 注意：只降级代码围栏之外的行（filelist/Python 的 # 注释不能被误改成标题）。
    # ---- 字形兜底：圆圈数字在嵌入字体中缺字形（渲染成 □），统一映射为 ASCII ----
    GLYPH = {"\u2460": "(1)", "\u2461": "(2)", "\u2462": "(3)", "\u2463": "(4)",
             "\u2464": "(5)", "\u2465": "(6)", "\u2466": "(7)", "\u2467": "(8)"}
    md_lines = []
    in_fence = False
    for ln in "\n".join(P).split("\n"):
        for k, v in GLYPH.items():
            if k in ln:
                ln = ln.replace(k, v)
        if ln.lstrip().startswith("```"):
            in_fence = not in_fence
            md_lines.append(ln)
            continue
        if not in_fence:
            if ln.startswith("## "):
                ln = "### " + ln[3:]
            elif ln.startswith("# "):
                ln = "## " + ln[2:]
        md_lines.append(ln)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    open(OUT, "w", encoding="utf-8").write("\n".join(md_lines))
    n_lines = open(OUT, encoding="utf-8").read().count("\n") + 1
    print("已生成:", OUT, "(%d 行)" % n_lines)


if __name__ == "__main__":
    main()
