# -*- coding: utf-8 -*-
"""
make_tree_pdf.py —— 生成《文件树.tex》（分区彩盒版）并调用 latexmk 编译 PDF。
树内容以数据块维护；注释行自动着色：普通注释灰色，含 [核心] 的橙色加粗。
用法：python tools/make_tree_pdf.py
"""
import os
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SECTIONS = [
    # (标题, 颜色名, 树行)
    ("根目录", "rootcol", r"""
D:\fpga-ptz-tracker\
├── README.md                       # 项目总览：状态 / 结构 / 快速开始 / 赛题覆盖
├── 使用文档_视觉方向软件包.md       # 使用文档：环境 / 日常操作 / 上板移植 / 整定 / FAQ
├── regression_*.log                # 历史回归留档（v4.1 整定轮等）
└── docs.zip                        # 文档打包（交接/外发用）
"""),

    ("01\_official · 02\_meetings —— 资料与决策", "auxcol", r"""
├── 01_official\                    # 官方资料索引（原文件留在 D 盘原位，不复制）
│   └── README_资料索引.md          #   看什么、在哪、已核实的关键事实
│
├── 02_meetings\
│   ├── 2026-09-19_视觉方向启动与架构决策.md   # 决策纪要 + 移交嵌入式事项
│   ├── 第一次组会_议程与讲稿.md     # 组会材料
│   └── 第一次组会_小白版.md         # 组会材料（科普版）
│
└── _review_tmp\                    # 外部 AI 评审提示词临时目录（可清）
"""),

    ("03\_vision · step1 —— 视频链路基座", "visioncol", r"""
├── 03_vision\                      # 视觉方向：五步 × 每步四件套
│   ├── step1_video_link\
│   │   ├── 01_方案对比\方案对比_视频链路基座.md
│   │   ├── 02_技术文档\技术文档_视频链路基座.md
│   │   ├── 03_project\
│   │   │   ├── rtl\  ser96to24.v       # [核心] 96bit→1ppc 串化器 v4.1（弹性缓冲+看门狗）
│   │   │   │         tpg_720p.v       # 测试图案源（可上板）
│   │   │   │         sim_video_src.v  # 文件回放源（仅仿真）
│   │   │   │         frame_dump24.v   # 帧转储（仅仿真）
│   │   │   │         pulse_sync.v     # 脉冲跨域（toggle 同步）
│   │   │   │         cdc_4phase.v     # 4 相握手数据跨域
│   │   │   ├── tb\  tb_ser96to24(故障注入) / tb_tpg / tb_pulse_sync / tb_cdc4phase / tb_cdc_reset_skew
│   │   │   ├── sim\、scripts\、sim_out\    # 向量 / 日志 / 产物
│   │   └── 04_迭代文件\迭代记录_视频链路基座.md
"""),

    ("03\_vision · step2 —— 颜色识别与质心（检测链）", "visioncol", r"""
│   ├── step2_color_centroid\
│   │   ├── 01_方案对比\  02_技术文档\
│   │   ├── 03_project\
│   │   │   ├── rtl\  rgb2hsv.v        # [核心] RGB→HSV 定点（2 级流水，查表+移位）
│   │   │   │         hsv_inv_lut.v    # 倒数表 ROM（生成物，勿手改）
│   │   │   │         hsv_threshold.v  # 8 组预置阈值（红色窗口环绕）
│   │   │   │         bin_smooth3x3.v  # [核心] 3x3 多数表决平滑
│   │   │   │         centroid_accum.v # 帧累加 + 快照除法 + 包围框
│   │   │   │         detect_top.v     # 检测分支顶层（窃流旁路 + sync_err 引出）
│   │   │   ├── tb\  tb_rgb2hsv / tb_hsv_threshold / tb_bin_smooth / tb_centroid / tb_detect_chain
│   │   └── 04_迭代文件\迭代记录_v1到v7.md   # [核心] 全项目最厚的迭代记录
"""),

    ("03\_vision · step3 —— 闭环控制", "visioncol", r"""
│   ├── step3_closed_loop\
│   │   ├── 01_方案对比\  02_技术文档\
│   │   ├── 03_project\
│   │   │   ├── rtl\  gimbal_ctrl.v    # 死区 + P + 限速 + 限幅控制律
│   │   │   │         pwm_servo.v      # 双路 50Hz 共周期 PWM
│   │   │   ├── tb\  tb_gimbal / tb_pwm / tb_algo_switch（算法切换严格 scoreboard）
│   │   └── 04_迭代文件\迭代记录_闭环控制.md
"""),

    ("03\_vision · step4 —— OSD 与系统联调", "visioncol", r"""
│   ├── step4_osd_integration\
│   │   ├── 01_方案对比\  02_技术文档\
│   │   ├── 03_project\
│   │   │   ├── rtl\  osd_track.v      # [核心] 十字/框/状态/跑马灯（前瞻 4 像素流水）
│   │   │   │         vision_top.v     # [核心] 视觉整机顶层（检测+OSD+云台+CDC）
│   │   │   │         font_rom_8x16.v  # 字库 ROM（生成物，勿手改）
│   │   │   ├── tb\  tb_osd_track / tb_vision_top / tb_closed_loop
│   │   │   ├── sim\  closed_loop_trace.txt   # 闭环收敛轨迹（答辩素材）
│   │   │   └── sim_out\ *.png        # OSD 渲染对比图（调试证据）
│   │   └── 04_迭代文件\              # 迭代记录 + 全部历史回归日志（约 130 轮）
"""),

    ("03\_vision · step5 —— 拓展功能集（加分项）", "visioncol", r"""
│   └── step5_expansion\
│       ├── 01_方案对比\  02_技术文档\
│       ├── 03_project\
│       │   ├── rtl\  edge_detect_96.v   # 边缘检测（Sobel 类）
│       │   │         video_adj.v        # 亮度/对比度调节（显示路径）
│       │   │         motion_detect.v    # 运动检测（帧差 + ERAM 行缓存）
│       │   │         marquee_rom_64.v   # 跑马灯字模 ROM（生成物）
│       │   ├── tb\  tb_motion_detect
│       └── 04_迭代文件\迭代记录_拓展功能集.md
"""),

    ("04\_embedded —— 嵌入式方向（对接）", "embcol", r"""
├── 04_embedded\
│   ├── README_嵌入式方向报告.md     # [核心] 对接总报告（分层证明 + 发现 + 遗留）
│   ├── README_分工与移交.md        # 给嵌入式队友的挂载 / 验收清单
│   ├── 03_project\
│   │   ├── rtl\  system_top.v      # [核心] 官方 ISP 全链 + vision_top 零改动对接顶层
│   │   │         axis_saturation_rgb96.v  # [核心] 饱和度增强级（2026-10-04，K_Q4 六位，
│   │   │                                  #   定版 28≈1.75x；重建见 08_board_bringup/03_）
│   │   │         uart_telemetry.v  # UART 状态遥测（新增）
│   │   │         led_buzzer.v      # LED/蜂鸣器指示
│   │   │         i2c_bfm_sc500.v   # SC500CS I2C 从机 BFM（仿真）
│   │   │         divider_gate_sim.v     # 门级除法器行为替身（仅仿真）
│   │   │         ph1p_logic_eram_stub.v # TD ERAM 原语行为替身（仅仿真）
│   │   ├── scripts\ filelist.f          # TD 工程文件清单（含排除项）
│   │   │           td_build_and_flash.md # TD TCL 骨架 + QSPI 固化 runbook
│   │   ├── tb\  tb_system_integration / tb_i2c_config / tb_uart_telemetry / uart_rx_mon
│   │   └── sim\  官方 ISP 明码 RTL 副本（25 项）+ RAW10 虚拟传感器向量
│   └── 04_迭代文件\迭代记录_嵌入式对接.md   # 已累积至 #N+11（饱和度两轮）
"""),

    ("05\_gimbal · 06\_interfaces —— 云台与接口", "ifcol", r"""
├── 05_gimbal\                      # 二维舵机云台
│   ├── README_云台规格.md          # 选型 / 电气 / 控制接口 / 现场标定
│   └── mechanical\ servo\ power\   # 预留子目录
│
├── 06_interfaces\                  # 接口统一文档（唯一生效版）
│   └── current\
│       ├── IF-00_总览.md           # 分工边界 / 全局参数 / 时钟域
│       ├── IF-MIPI.md              # 视频输入契约（96bit AXI-S 窃流）
│       ├── IF-DDR.md               # 旁路挂载 / 资源预算 / 分辨率变更流程
│       ├── IF-VISION.md            # [核心] 135bit 目标包 v1.1.0（两方向强耦合点）
│       ├── IF-SERVO-PWM.md         # 云台电气 / 时序 / 控制律 / 校准
│       ├── IF-OSD.md               # 显示侧挂载与 vpix 转换
│       └── 接口变更记录.md         # v1.0.0 定稿决策与教训
"""),

    ("07\_答辩素材 —— 演示材料", "ifcol", r"""
├── 07_答辩素材\
│   ├── 答辩演示文稿.pptx           # 演示文稿（成品）
│   ├── build_ppt.js                # pptxgenjs 生成脚本（改稿用）
│   ├── 答辩讲稿.md                 # 讲稿（配合 PPT 页序）
│   ├── 闭环收敛曲线.png            # 由 closed_loop_trace.txt 绘制
│   └── node_modules\               # pptxgenjs 依赖（本地）
"""),

    ("docs —— 教程与文档 PDF", "auxcol", r"""
├── docs\
│   ├── step{1..5}_tutorial.tex/.pdf   # [核心] 五步教程 25/26/17/16/14 页
│   ├── step{1..5}_impl.tex            #   Part II 工程实现详解（复盘）
│   ├── emb1_tutorial / emb2_tutorial  # [核心] 嵌入式教程（一）（二）各 15 页
│   ├── board1_guide.tex/.pdf          # 视频通路使用指导 9 页（导入/仿真/烧录）
│   ├── td_burn_tutorial.md/.pdf       # [核心] 烧录实战教程 14 页（试错+逐步点击+固化）
│   ├── assets_td_burn\               #   烧录教程图素材（厂商文档截图，已裁白边）
│   ├── 评审包_代码与设计说明.tex/.pdf  # [核心] 外部评审版 105 页（v8）
│   ├── 文件树.tex/.pdf                # 本文件（彩盒版，由 make_tree_pdf.py 生成）
│   └── backup_20261003\              # 评审包快照（含生成器）
"""),

    ("08\_board\_bringup —— 上板阶段（真机）", "visioncol", r"""
├── 08_board_bringup\
│   ├── 01_video_passthrough\        # SC520CS 直通（官方 Lab1 适配版，720p60）
│   │   ├── lab_ex1\                 # TD 工程（.al 已修 XML；user_source 96 RTL + 约束）
│   │   ├── sim\                     # 整链仿真：run_sim.bat / tb_video_passthrough
│   │   │                             #   + 饱和度级 SAT_EN 开关 + sat_tool 对拍产物
│   │   └── README.md                 # 三步上手 + 参数速查
│   ├── 02_td_synth_gate\            # 视觉链 TD gate 级证据（LUTRAM / STA 两闸门）
│   │   ├── reports\                 # 修复后（像素域 WNS +2.441ns）
│   │   ├── reports_prefix\          # 修复前（-0.113ns）对照
│   │   └── README.md                 # 复现步骤与结论
│   ├── 03_td_rebuild_sat\           # [核心] 饱和度增强重建（2026-10-04）
│   │   ├── README.md                 #   根因/改动/验证链/复现/收官
│   │   ├── camera_to_dsi_display_sat_k28.bit          # 定版比特流（已上板）
│   │   ├── camera_to_dsi_display_sat_k28_qspi_16M.bin # QSPI 固化镜像
│   │   ├── camera_to_dsi_display_sat_k21.*            # 过渡版留档
│   │   └── lab_ex1_build\           # 构建副本（lab_ex1+补丁；syn/phy 两段无头流程）
│   └── _sc520_src\                  # 厂商原始交付（zip + 解包 + PDF，证据保留）
"""),

    ("tools —— Python 支撑体系", "toolcol", r"""
└── tools\
    ├── golden_model.py             # [核心] 算术金标准（HSV/阈值/平滑/质心/云台）
    ├── gen_vectors.py              # 测试向量 + 自动生成 RTL 表（倒数表/字库/跑马灯）
    ├── gen_raw10_sensor.py         # 虚拟 RAW10 传感器（嵌入式集成仿真）
    ├── gen_marquee_rom.py          # 跑马灯字模生成
    ├── rtl_model_check.py          # RTL 周期精确转录模型（调试用）
    ├── run_all.py                  # [核心] 一键回归（18 项，逐位比对与汇总）
    ├── sat_tool.py                 # [核心] 饱和度工具（sweep 预览 / check 位精确对拍）
    ├── dump2png.py                 # 帧 hex → PNG（整链仿真出图）
    ├── plot_convergence.py         # 闭环收敛曲线绘图
    ├── make_tree_pdf.py            # 本文件树生成器
    ├── check_tex.py                # 教程 tex 静态检查（转义/缺字）
    ├── make_review_pdf.py          # 外部评审包 PDF 生成器
    ├── render_pdf.py               # PDF 逐页渲染 PNG（视觉验收用）
    └── patch_round2.py             # 历史补丁存档
"""),
]

TEX_HEAD = r"""\documentclass[10pt]{ctexart}
\usepackage[a4paper,top=1.1cm,bottom=1.2cm,left=1.35cm,right=1.35cm]{geometry}
\usepackage{fancyvrb}
\usepackage{xcolor}
\usepackage{fontspec}
\usepackage[most]{tcolorbox}
\setmonofont{Consolas}
\setCJKmonofont{SimHei}
\setlength{\parindent}{0pt}

\definecolor{deep}{RGB}{22,50,92}
\definecolor{rootcol}{RGB}{95,105,118}
\definecolor{auxcol}{RGB}{130,110,70}
\definecolor{visioncol}{RGB}{26,116,88}
\definecolor{embcol}{RGB}{192,86,24}
\definecolor{ifcol}{RGB}{104,64,138}
\definecolor{toolcol}{RGB}{0,108,120}
\definecolor{cmt}{RGB}{124,134,150}
\definecolor{core}{RGB}{192,86,24}
\definecolor{boxbg}{RGB}{250,251,253}
\definecolor{linegray}{RGB}{200,206,214}

\newtcolorbox{sectbox}[2]{enhanced, breakable,
  colback=boxbg, colframe=#2, boxrule=0.7pt, arc=1.6mm,
  left=2.2mm, right=2.2mm, top=1.2mm, bottom=1.2mm,
  title={{\bfseries #1}}, fonttitle=\bfseries\small,
  coltitle=white, colbacktitle=#2,
  attach boxed title to top left={yshift=-2.2mm, xshift=3mm},
  boxed title style={arc=1.2mm, boxrule=0pt, left=2mm, right=2mm,
                     top=0.7mm, bottom=0.7mm}}

\begin{document}

% ================= 横幅 =================
\begin{tcolorbox}[enhanced, colback=deep, colframe=deep, arc=2.5mm,
  left=5mm, right=5mm, top=3.2mm, bottom=3.2mm, boxrule=0pt]
  {\color{white}\LARGE\bfseries fpga-ptz-tracker \;{\large 项目文件树}}\par
  \vspace{1mm}
  {\color{white!85!deep}2026 FPGA 创新设计赛道（安路）赛题二 \;·\; 视觉 + 嵌入式方向软件包}\par
  \vspace{2mm}
  {\color{white!70!deep}\small 生成日期 2026-10-04 \quad|\quad 路径 \texttt{D:\string\fpga-ptz-tracker}
   \quad|\quad 回归 \textbf{18/18 全绿} \quad|\quad 上板：SC520 直通出图 · 饱和度增强 \textbf{1.75x} 定版}
\end{tcolorbox}

\vspace{3.5mm}

% ================= 统计卡片 =================
\begin{tcbraster}[raster columns=4, raster column skip=2.4mm, raster equal height]
\begin{tcolorbox}[enhanced, colback=boxbg, colframe=linegray, boxrule=0.5pt, arc=1.6mm,
  left=1mm, right=1mm, top=2mm, bottom=2mm, halign=center]
  {\Large\bfseries\color{visioncol} 23}\par\vspace{1mm}
  {\scriptsize\color{black!70} 可综合 RTL（视觉19+嵌入4）}\par\vspace{0.6mm}
  {\tiny\color{black!50} 纯 Verilog-2001，TD 可综合}
\end{tcolorbox}
\begin{tcolorbox}[enhanced, colback=boxbg, colframe=linegray, boxrule=0.5pt, arc=1.6mm,
  left=1mm, right=1mm, top=2mm, bottom=2mm, halign=center]
  {\Large\bfseries\color{embcol} 18}\par\vspace{1mm}
  {\scriptsize\color{black!70} 一键回归项（18/18 PASS）}\par\vspace{0.6mm}
  {\tiny\color{black!50} ModelSim · 20 个 TB 文件}
\end{tcolorbox}
\begin{tcolorbox}[enhanced, colback=boxbg, colframe=linegray, boxrule=0.5pt, arc=1.6mm,
  left=1mm, right=1mm, top=2mm, bottom=2mm, halign=center]
  {\Large\bfseries\color{ifcol} 65}\par\vspace{1mm}
  {\scriptsize\color{black!70} 文档（md/pdf/tex）}\par\vspace{0.6mm}
  {\tiny\color{black!50} 四件套 + 接口 + 报告}
\end{tcolorbox}
\begin{tcolorbox}[enhanced, colback=boxbg, colframe=linegray, boxrule=0.5pt, arc=1.6mm,
  left=1mm, right=1mm, top=2mm, bottom=2mm, halign=center]
  {\Large\bfseries\color{toolcol} 13}\par\vspace{1mm}
  {\scriptsize\color{black!70} Python 工具}\par\vspace{0.6mm}
  {\tiny\color{black!50} 金标准 / 回归 / 对拍 / 生成器}
\end{tcolorbox}
\end{tcbraster}

\vspace{3.5mm}

% ================= 图例 =================
{\small
\textcolor{core}{\rule[2pt]{2.6mm}{2.6mm}}\;{\color{core}\bfseries [核心]}\ = 标志性交付 \quad
{\color{cmt}\ttfamily\# 注释}\ = 用途说明 \quad
{\ttfamily (仅仿真)}\ = 不进 TD 工程 \quad
{\ttfamily (生成物)}\ = 由工具生成，勿手改
}

\vspace{2.5mm}
"""

TEX_TAIL = r"""
\vspace{2.5mm}
\begin{tcolorbox}[colback=boxbg, colframe=linegray, boxrule=0.5pt, arc=1.6mm,
  left=3mm, right=3mm, top=1.8mm, bottom=1.8mm]
{\small\textbf{\color{deep} 与项目地图的对应}\quad
项目地图的“工程文件”四件套在本仓库体现为 \texttt{03\_project}（ASCII 命名——ModelSim
的 sqlite 引擎不支持中文路径）；其余三件（方案对比 / 技术文档 / 迭代文件）保留中文目录名，
与地图一一对应。\texttt{06\_interfaces/current/} 为接口唯一生效版：视觉与嵌入式两个方向的
全部跨模块约定（135bit 目标包 v1.1.0、96bit 契约、PWM 规格）以该目录为权威，
任何改动走《接口变更记录.md》。\texttt{sim/} 下另有各 TB 的 \texttt{.hex} 向量与
ModelSim \texttt{transcript}；\texttt{sim\_out/} 为帧转储与比对图，未列入树中。}
\end{tcolorbox}

\vspace{1.5mm}
{\color{black!45}\scriptsize\hfill fpga-ptz-tracker 文件树 · 由 tools/make\_tree\_pdf.py 生成 · latexmk/xelatex 编译\hfill}

\end{document}
"""


def esc_comment(cmt_text):
    if "[核心]" in cmt_text:
        body = cmt_text.replace("[核心]", "").replace("#", "", 1).strip()
        return "|textcolor{core}{|bfseries # " + body + "}"
    return "|textcolor{cmt}{" + cmt_text + "}"


def process_block(raw):
    out = []
    for ln in raw.strip("\n").split("\n"):
        s = ln.rstrip()
        if " # " in s:
            left, cmt = s.split(" # ", 1)
            s = left + "  " + esc_comment("# " + cmt)
        elif s.strip().startswith("#"):
            s = "  " + esc_comment(s.strip())
        out.append(s)
    return "\n".join(out)


def main():
    parts = [TEX_HEAD]
    for title, color, tree in SECTIONS:
        if title.startswith("tools"):
            parts.append("\\clearpage\n")
        parts.append("\\begin{sectbox}{" + title + "}{" + color + "}\n")
        parts.append("\\begin{Verbatim}[fontsize=\\scriptsize, commandchars=\\|\\{\\}]\n")
        parts.append(process_block(tree) + "\n")
        parts.append("\\end{Verbatim}\n\\end{sectbox}\n\\vspace{2.2mm}\n")
    parts.append(TEX_TAIL)
    tex = "".join(parts)
    tex_path = os.path.join(ROOT, "docs", "文件树.tex")
    with open(tex_path, "w", encoding="utf-8") as f:
        f.write(tex)
    print("tex 写入", tex_path, len(tex), "chars")
    r = subprocess.run(
        ["latexmk", "-xelatex", "-interaction=nonstopmode", "-halt-on-error", "文件树.tex"],
        cwd=os.path.join(ROOT, "docs"), capture_output=True, text=True, errors="replace")
    print("latexmk exit:", r.returncode)
    if r.returncode != 0:
        print((r.stdout or "")[-1200:])
    else:
        subprocess.run(["latexmk", "-c", "文件树.tex"], cwd=os.path.join(ROOT, "docs"), capture_output=True)
        pdf = os.path.join(ROOT, "docs", "文件树.pdf")
        print("PDF:", pdf, os.path.getsize(pdf), "bytes")


if __name__ == "__main__":
    main()
