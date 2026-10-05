# -*- coding: utf-8 -*-
"""
make_review_pdf.py —— 生成《代码与设计说明（外部评审版）》PDF

把全部自研代码（RTL/TB/Python/仿真脚本）+ 架构说明 + 验证状态 + 开放问题
汇编为单一 PDF，供外部 AI/同行评审。

用法： python tools/make_review_pdf.py
产物： docs/评审包_代码与设计说明.tex / .pdf
"""
import io
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_TEX = os.path.join(ROOT, 'docs', '评审包_代码与设计说明.tex')


def read_text(path):
    raw = open(path, 'rb').read()
    for enc in ('utf-8', 'gbk', 'latin-1'):
        try:
            return raw.decode(enc).replace('\r\n', '\n').replace('\r', '\n')
        except UnicodeDecodeError:
            continue
    return raw.decode('utf-8', errors='replace')


# PDF 排版符号映射：等宽字体缺字形，代码中的数学符号以 ASCII 等价显示
SYMBOL_MAP = {
    '∈': ' in ', '≥': '>=', '≤': '<=', '∧': '&&', '∨': '||',
    '↔': '<->', '→': '->', '←': '<-', 'Σ': 'sum', '×': 'x', '±': '+/-',
    '≈': '~=',
}


def pdf_sanitize(text):
    for k, v in SYMBOL_MAP.items():
        text = text.replace(k, v)
    return text


def esc_title(s):
    return s.replace('\\', '/').replace('_', r'\_').replace('&', r'\&').replace('#', r'\#')


# ============================================================
# 各文件简介（评审读者视角：这个文件干什么、关键设计点、已知取舍）
# ============================================================
INTRO = {
'03_vision/step1_video_link/03_project/rtl/ser96to24.v':
 '检测链入口适配层 v4.1（2026-10-03 弹性缓冲重写 + 异常恢复加固）：96bit(4px/拍) AXI-S 拆成'
 '1 像素/拍 vpix。官方 ISP AWB 输出实测为行级突发（320 beat=1280px/行），v3 的 128px 缓冲远不够'
 '（实链 188/2764800 像素）；v4 容量 2048 像素（512 beat）+ 寄存器读（输出 +1 拍，兼容 LUTRAM/ERAM）。'
 '无反压；溢出丢弃 + 帧级重同步；v4.1 增加帧同步看门狗（SYNC_TIMEOUT 后置 O_sync_err）与'
 'tlast 门控受控恢复（tuser 永久缺失不再死锁；故障注入 TB 验证）+ O_occ_max 占用水位观测。'
 '验收：tb_isp_burst 行突发模式像素/帧计数/drop 全对；18 项回归全绿。',
'03_vision/step1_video_link/03_project/rtl/pulse_sync.v':
 '单 bit 脉冲跨域（toggle 翻转 + 目标域 3 级同步 + 边沿还原），输出固定 1 拍脉冲。'
 '要求源脉冲间隔 > 目标域 2 拍（帧级脉冲天然满足）。当前设计中 T1 修正后已无实例化，保留备用。',
'03_vision/step1_video_link/03_project/rtl/cdc_4phase.v':
 'N bit 数据跨域（4 相电平握手）：装载拍寄存数据、握手中恒定，目标域 2FF 同步 req、'
 '应答后输出 1 拍 valid。用于 135bit 目标包与 23bit 控制包跨 74.25M↔50M。'
 '复位契约：两侧复位必须同源（允许释放偏斜，已由 tb_cdc_reset_skew 固化验证）。',
'03_vision/step1_video_link/03_project/tb/tb_cdc_reset_skew.v':
 'CDC 复位偏斜验证（三版评审共识 Gate）：两域复位同拉低、错开 0/3/7/10 拍释放，'
 '静默期断言无伪 valid，随后两笔事务计数与数据逐一比对。',
'03_vision/step4_osd_integration/03_project/tb/tb_algo_switch.v':
 '算法切换帧专项 TB（第 18 项，GPT-3 复审后新增）：TPG->vision_top，第 3/5 帧输入'
 'algo_edge 翻转，输出 921600 像素分窗断言"切换后每窗 SOF=1、EOL=720、分支内容'
 '符合切换后算法"——首跑即钉死"提交沿扇出窗口 SOF 丢失"（MISM win=5 sof=0），'
 '修复后 PASS。判据含 sof<=2/eol>=719 容忍切换窗固有跨窗语义。'
 '2026-10-03 复审响应再升级为 \textbf{SOF→SOF 严格 scoreboard}：SB1 每条 EOL 行恰 1280 像素；'
 'SB2 非切换跨度恰 720 行/921600 像素；SB3 切换跨度允许旧帧截断（≤719 行+残行）；'
 'SB4 截断事件 <= 命令切换数。复跑 PASS：SB frames=9 partial=2 sb_fail=0。',
'03_vision/step2_color_centroid/03_project/rtl/rgb2hsv.v':
 'RGB888→HSV 2 级流水。定点方案：V=max、S=delta（未归一化代理）、H 三扇区'
 '（R>G>B 优先级）+ 倒数表 inv[d] = floor(3840/d)、有符号乘、算术右移。'
 '已知简化：H 只落三段区间（0..60 / 120..180 / 240..300），品红归红扇区（方案对比已记录）。'
 '与 Python 金标准位精确（10010 向量回归）。',
'03_vision/step2_color_centroid/03_project/rtl/hsv_threshold.v':
 'HSV 阈值分割（1 拍）：8 组预置 ROM（H 窗口支持环绕：红色 335..25 用"或"判断判），'
 'mask = H∈窗 ∧ S≥s_lo ∧ v_lo≤V≤v_hi。预置组在 detect_top 帧首锁存。',
'03_vision/step2_color_centroid/03_project/rtl/bin_smooth3x3.v':
 '二值掩码 3x3 多数表决去噪（v7 索引行缓存自对齐结构）。读写同指针行缓存 + 2 拍水平抽头；'
 '边界复制与行尾窗口用抽头寄存器补出，输出流连续（每行恰 W 像素）。'
 '行缓存需 LUTRAM（组合读），TD 综合后须核对映射（已在上板检查单）。'
 'v3→v7 四轮相位缺陷的重构复盘见迭代记录。',
'03_vision/step2_color_centroid/03_project/rtl/centroid_accum.v':
 '帧内累加质心/包围框 + 帧末恢复法除法（32 位商，X/Y 两轴串行）。'
 '关键设计：帧末 tick 拍全量快照（snap_*），除法与结果锁存只读快照——'
 '避免下一帧 sof 清零竞争（迭代 8 抓出的真缺陷）。商末位与最后一次移位同拍预测锁存。',
'03_vision/step2_color_centroid/03_project/rtl/detect_top.v':
 '检测分支顶层：96bit 窃流纯旁路（O_*=I_* 逐拍一致，不反压）+ 检测链串联。'
 '含进阶项：fid 帧号计数器、motion_detect 分支挂载、串化后 1ppc 流引出（OSD 底图用）。',
'03_vision/step3_closed_loop/03_project/rtl/gimbal_ctrl.v':
 '云台控制律（50MHz 域）：误差→Q8.8 比例→死区→限速→限幅，双轴 task 复用。'
 'T3 修正：was_lost 标志使恢复首帧 D 项=0（KD 默认关）；track_en=0 当拍回中。'
 '控制节拍由 vision_top 提供（=新包到达拍，T1 修正）。整定：Kp=20/18、SLEW=100。',
'03_vision/step3_closed_loop/03_project/rtl/pwm_servo.v':
 '双路 50Hz 舵机 PWM：单一 1,000,000 拍共周期计数器 + 双比较器（严格共周期）。'
 'T4 修正：占空比改为周期起点边界换装（防帧拍落周期中途截断脉宽）；'
 '双道限幅（500~2500 硬件保险）；上电中位 1500µs。',
'03_vision/step4_osd_integration/03_project/rtl/osd_track.v':
 'OSD 叠加层 v3：影子寄存器组 + sof 换装（消撕裂）；三行文本（状态/遥测/跑马灯）+ 十字准星 +'
 '双框（目标红/运动橙）。135bit 目标包经 cdc_4phase 接收。跑马灯索引 (pos>>3) mod 63'
 '（连减法，含参数变更保险分支）。文本构建用常量除法（帧率更新，非关键路径）。'
 '2026-10-03（#N+9）：跑马灯路径结构性流水——地址+ROM 读前瞻 4 像素、4 级移位对齐，'
 'ROM 读获整拍预算，混合级仅 3~4 级（像素域 WNS +0.541→+2.441ns；此前"数组 ROM 化"'
 '并未真正消除 mux 树，属综合器估算运气，已诚实记录）；位精确由 tb_osd_track 复验。',
'03_vision/step4_osd_integration/03_project/rtl/vision_top.v':
 '整机顶层 v2+：直通零扰动；检测/边缘双分支 + 帧首锁存 algo mux；video_adj 画质调节'
 '（显示路径）；OSD 叠加；声光反馈；控制路径（T1 修正：tick=新包到达拍，控制滞后 1 帧）'
 '+ 云台 + PWM。目标状态（O_frame_tick/O_target_valid/O_tgt_cx/cy）端口化直出替代层次引用。',
'03_vision/step5_expansion/03_project/rtl/video_adj.v':
 '亮度/对比度（1 拍流水）：out = clamp(((c-128)×C>>6)+128+B)。'
 "C 为 Q6（64=1.0×）；B 为 7bit 有符号——修复记：原 {1'b0,bright} 零扩展把负亮度当正数，" +
 '已改 $signed(bright) 并手工验证（-16→-16）。',
'03_vision/step5_expansion/03_project/rtl/motion_detect.v':
 '帧差运动检测 v3.1：整帧 1bit 前帧缓存（115KB ERAM）。同步读一级流水（TD 可实现），'
 '写地址延迟一拍与读结构性错开（与 ERAM 写模式解耦——防 WRITE_FIRST 下 diff 恒 0）；'
 '首帧 prev_ready 门控；addr 越界保护；cnt==0 时 bbox 全 0（与金标准一致）。'
 '每帧末锁存 cnt/bbox + 1 拍选通，亚门限帧照常更新（valid=cnt≥MOT_TH）。',
'04_embedded/03_project/rtl/led_buzzer.v':
 '声光反馈：锁定绿灯、丢失红灯 1Hz 闪、锁定沿蜂鸣 200ms（BEEP_CYCLES 参数化）。',
'03_vision/step2_color_centroid/03_project/rtl/hsv_inv_lut.v':
 '倒数表 ROM（生成文件，禁止手改）：inv[d]=floor(3840/d)，256×12bit，'
 '由 gen_vectors.py 生成 case 表（综合为 Block ROM）。',
'03_vision/step4_osd_integration/03_project/rtl/font_rom_8x16.v':
 '8x16 点阵字库（生成文件，禁止手改）：40 字符 ASCII 子集，由 gen_vectors.py '
 '从 cv2 Hershey 字体渲染生成；地址 {char[7:0], row[3:0]}，MSB=最左像素。',
'03_vision/step5_expansion/03_project/rtl/marquee_rom_64.v':
 '跑马灯字库（生成文件，禁止手改）：63 字符消息 x 16 行 case 表，由 gen_vectors.py 生成。',
'04_embedded/03_project/rtl/system_top.v':
 '嵌入式集成顶层（仿真/TD 双用）：官方 ISP 全链 + vision_top 挂载 + 按键消抖 glue + UART 遥测。'
 '2026-10-03 修复（#N+7）：视觉抽头改 AWB 96bit 直抽（isp_top 新增 tap_* 端口；弃用 128bit 重排——'
 '其 tuser 与 valid 结构性错位）；I_tvalid 直用 RAW 有效、O_tready 显式 1\'b1（原悬空网）。',
'04_embedded/03_project/rtl/uart_telemetry.v':
 '目标状态 UART 遥测（115200-8N1，每帧一包 9 字节）：A5|valid|cx(2)|cy(2)|preset|sum|5A。'
 '帧拍起包（发送中跳过）；单 always 状态机（外脑评审修复：原两块同驱寄存器）。',
'04_embedded/03_project/rtl/i2c_bfm_sc500.v':
 'SC500CS I2C 从机 BFM（仿真）：开漏建模（inout + 上拉）、7bit 地址 0x36、'
 'ACK 位相、每 4 字节一个寄存器写事务。已知遗留：ACK 位相未收敛（列 TD 阶段项，'
 '需真机逻辑分析仪对照）——寄存器序列本身已由 ROM 侧逐条确认。',
'04_embedded/03_project/rtl/divider_gate_sim.v':
 '门级除法器（AL_* 库 7355 行网表）的行为级替身（仅仿真）：16 拍延迟、除零给全 1。'
 'TD 综合时用真网表，本文件排除。',
'04_embedded/03_project/rtl/ph1p_logic_eram_stub.v':
 'TD ERAM 原语行为替身 v3（仅仿真）：参数名与官方 wrapper 对齐（ADDR_WIDTH_A/B，'
 '曾因名字不匹配致端口宽度失效、整帧 X）；地址 Z/X 位清洗归 0 + 未知位单次告警；'
 '使能语义：cea/ceb 未接=通、wea/web 仅显式 1 才写；mem 上电清零。',
'04_embedded/03_project/tb/tb_uart_telemetry.v':
 '遥测验证：注入 3 帧（valid=1/0/1、坐标各异），uart_rx_mon 逐字节解码，'
 '校验定界/校验和/坐标；PASS 判据：全帧正确且含 ≥2 帧 LOCK。',
'04_embedded/03_project/tb/uart_rx_mon.v':
 'UART 接收监视器（仿真）：2FF 同步 + 半位对齐采样（位中心）、假起始重同步；'
 '自由运转状态机（无 @ 事件同步）。',
'04_embedded/03_project/tb/tb_system_integration.v':
 '整链对接仿真（TD 阶段项）：虚拟 RAW10 传感器 -> 官方 ISP -> 重排 -> vision_top -> '
 'OSD 转储 + 四判据（几何/检测/云台方向/UART）。最后一次全链运行受厂商 ISP 仿真环境限制，'
 '列 TD 阶段验证。',
'04_embedded/03_project/tb/tb_i2c_config.v':
 '摄像头配置链对录：官方 uicfgcs520+uii2c 对 I2C BFM，逐条比对 116 条寄存器写事务。'
 '已知遗留：BFM ACK 位相（TD 阶段项）。',
'08_board_bringup/01_video_passthrough/sim/tb_video_passthrough.v':
 '板级整链仿真 TB：虚拟 RAW10（1/8 占空馈送，AXI 正确握手每拍一消费）-> 官方 ISP '
 '-> 弹性串化 -> 逐帧转储。实测 PASS：frames_dumped=2（每帧 921600 像素）、'
 'tuser=3、ser_ovf=0。踩坑记：向量 int32 溢出致 readmemh 终止、替身参数名、AXI 重复消费。',
'08_board_bringup/01_video_passthrough/sim/px_serializer_fifo.v':
 '仿真专用弹性串化器：8192 beat FIFO + 真反压（替代无反压的 ser96to24 做整链转储）；'
 '充当"浅 DDR"吸收 ISP 行级突发。',
'08_board_bringup/01_video_passthrough/sim/tb_isp_burst.v':
 'ISP 实流突发测量 TB（2026-10-03 架构级复审新增）：虚拟 RAW10 满速 / 1:9 / 1:6 三档馈送 -> '
 '官方 ISP -> data_96bit_to_128bit(4:3) -> data128_96 -> ser96to24（与 system_top 同接法）。'
 '实测：AWB 行级突发 maxrun=320（1:6 达 1925）；128 重排 maxrun=3 且 tuser∧valid=0；'
 'ser96to24 输出 188 像素/零 SOF/丢弃饱和——坐实"128 像素缓冲吸不住行级突发 + 帧同步不可建立"。',
'08_board_bringup/01_video_passthrough/sim/filelist_sim.f':
 '板级仿真编译清单（全部仿真专用文件，禁止加入 TD 工程）。',
'08_board_bringup/01_video_passthrough/sim/run_sim.bat':
 '板级仿真一键脚本（重建 work 库防 vopt 缓存旧设计）。',
'08_board_bringup/01_video_passthrough/sim/msim_passthrough.do':
 'ModelSim do 脚本等价版本。',
'tools/golden_model.py':
 '算术金标准（唯一真值来源）：HSV/阈值/平滑/质心/云台/帧差/整链，'
 '所有 RTL 按其逐位复刻；含 MIN_PIXELS/勘探参数表。',
'tools/gen_vectors.py':
 '向量生成器：16 TB 的激励/期望 + 3 个生成 RTL（倒数表/字库/跑马灯表）+ OSD 金标准渲染器'
 '（位精确复刻 osd_track 绘制规则）。',
'tools/gen_raw10_sensor.py':
 '虚拟 RAW10 传感器（BGGR 灰底+红块+0.2% 确定性噪声，4 帧）：'
 '打包先转 Python int 再移位（int32 溢出坑）；R 位点相位为厂商 demosaic 实测定稿。',
'tools/run_all.py':
 '一键回归执行器：18 个 TB 的编译/运行/逐位比对/汇总。',
'tools/rtl_model_check.py':
 'RTL 周期精确转录模型（调试辅助）：失配时先在 Python 里定位再改 RTL。',
'tools/dump2png.py':
 '转储帧（hex）-> PNG（含 X 像素统计），板级仿真"画面"肉眼验证用。',
}


def latex_intro(text):
    """简介文本 -> LaTeX（先符号映射，再转义 & _ # % $）"""
    t = pdf_sanitize(text)
    t = t.replace('&', r'\&').replace('_', r'\_').replace('#', r'\#').replace('%', r'\%').replace('$', r'\$')
    return t


# ============================================================
# 章节结构：(标题, [ (相对路径, 模式) ... ])，模式 full / ('sample', 行数)
# ============================================================
PARTS = [
 ('视觉链路 RTL（数据流顺序）', [
   '03_vision/step1_video_link/03_project/rtl/ser96to24.v',
   '03_vision/step1_video_link/03_project/rtl/pulse_sync.v',
   '03_vision/step1_video_link/03_project/rtl/cdc_4phase.v',
   '03_vision/step2_color_centroid/03_project/rtl/rgb2hsv.v',
   '03_vision/step2_color_centroid/03_project/rtl/hsv_threshold.v',
   '03_vision/step2_color_centroid/03_project/rtl/bin_smooth3x3.v',
   '03_vision/step2_color_centroid/03_project/rtl/centroid_accum.v',
   '03_vision/step2_color_centroid/03_project/rtl/detect_top.v',
   '03_vision/step3_closed_loop/03_project/rtl/gimbal_ctrl.v',
   '03_vision/step3_closed_loop/03_project/rtl/pwm_servo.v',
   '03_vision/step4_osd_integration/03_project/rtl/osd_track.v',
   '03_vision/step4_osd_integration/03_project/rtl/vision_top.v',
   '03_vision/step5_expansion/03_project/rtl/video_adj.v',
   '03_vision/step5_expansion/03_project/rtl/motion_detect.v',
   '04_embedded/03_project/rtl/led_buzzer.v',
 ]),
 ('视觉链路验证 TB（18 项回归全集）', [
   '03_vision/step1_video_link/03_project/tb/tb_ser96to24.v',
   '03_vision/step1_video_link/03_project/tb/tb_tpg.v',
   '03_vision/step1_video_link/03_project/tb/tb_pulse_sync.v',
   '03_vision/step1_video_link/03_project/tb/tb_cdc4phase.v',
   '03_vision/step1_video_link/03_project/tb/tb_cdc_reset_skew.v',
   '03_vision/step2_color_centroid/03_project/tb/tb_rgb2hsv.v',
   '03_vision/step2_color_centroid/03_project/tb/tb_hsv_threshold.v',
   '03_vision/step2_color_centroid/03_project/tb/tb_bin_smooth.v',
   '03_vision/step2_color_centroid/03_project/tb/tb_centroid.v',
   '03_vision/step2_color_centroid/03_project/tb/tb_detect_chain.v',
   '03_vision/step3_closed_loop/03_project/tb/tb_gimbal.v',
   '03_vision/step3_closed_loop/03_project/tb/tb_pwm.v',
   '03_vision/step4_osd_integration/03_project/tb/tb_osd_track.v',
   '03_vision/step4_osd_integration/03_project/tb/tb_vision_top.v',
   '03_vision/step4_osd_integration/03_project/tb/tb_closed_loop.v',
   '03_vision/step4_osd_integration/03_project/tb/tb_algo_switch.v',
   '03_vision/step5_expansion/03_project/tb/tb_motion_detect.v',
 ]),
 ('嵌入式对接 RTL 与 TB', [
   '04_embedded/03_project/rtl/system_top.v',
   '04_embedded/03_project/rtl/uart_telemetry.v',
   '04_embedded/03_project/rtl/i2c_bfm_sc500.v',
   '04_embedded/03_project/rtl/divider_gate_sim.v',
   '04_embedded/03_project/rtl/ph1p_logic_eram_stub.v',
   '04_embedded/03_project/tb/tb_uart_telemetry.v',
   '04_embedded/03_project/tb/uart_rx_mon.v',
   '04_embedded/03_project/tb/tb_system_integration.v',
   '04_embedded/03_project/tb/tb_i2c_config.v',
 ]),
 ('板级点亮仿真设施（08，SC520CS 通路）', [
   '08_board_bringup/01_video_passthrough/sim/tb_video_passthrough.v',
   '08_board_bringup/01_video_passthrough/sim/tb_isp_burst.v',
   '08_board_bringup/01_video_passthrough/sim/px_serializer_fifo.v',
   '08_board_bringup/01_video_passthrough/sim/filelist_sim.f',
   '08_board_bringup/01_video_passthrough/sim/run_sim.bat',
   '08_board_bringup/01_video_passthrough/sim/msim_passthrough.do',
 ]),
 ('Python 金标准与工具链', [
   'tools/golden_model.py',
   'tools/gen_vectors.py',
   'tools/gen_raw10_sensor.py',
   'tools/run_all.py',
   'tools/rtl_model_check.py',
   'tools/dump2png.py',
 ]),
]

SAMPLED = [  # 生成文件：节选
 ('视觉链路 RTL（数据流顺序）', '03_vision/step2_color_centroid/03_project/rtl/hsv_inv_lut.v', 24),
 ('视觉链路 RTL（数据流顺序）', '03_vision/step4_osd_integration/03_project/rtl/font_rom_8x16.v', 18),
 ('视觉链路 RTL（数据流顺序）', '03_vision/step5_expansion/03_project/rtl/marquee_rom_64.v', 18),
]

# ============================================================
# Part 0 总览与评审指南（正文 LaTeX，此处为受控文本）
# ============================================================
OVERVIEW = r"""
\section{项目总览与阅读指南}

\textbf{【本版状态总览（v8）】}本版把“当前状态 / 已闭环项 / 开放 Gate / 证据索引 / 复现方式”
前置到本节开头，便于评审快速锁定基线。\textbf{已闭环项请当作待复核命题而非免检项}——
能给出可复现失效路径的反驳最有价值（本项目历史上两轮真 bug 均由此类反驳钉出）。

\textbf{验证与综合现状}
\begin{center}
{\small
\begin{tabular}{p{4.6cm}p{5.6cm}p{6.6cm}}
\toprule
\rowcolor{rowtint}\textbf{指标} & \textbf{数值} & \textbf{证据} \\
\midrule
位精确回归 & \textbf{18/18 PASS} & \code{测试运行\_20261003\_202418.log} \\
行突发全链验收 & 2764800 px / sof=3 / eol=2160 / drop=0 & \code{tb\_isp\_burst}（行节奏馈送）\\
FIFO 最大占用 & 1601/2048 px（78\%）& \code{tb\_isp\_burst} 观测 \\
TD 综合（像素域 74.25MHz）& \textbf{WNS +2.441ns}，0 违规端点 & \code{02\_td\_synth\_gate/reports/} \\
TD 综合（控制域 50MHz）& WNS +8.747ns & 同上 \\
资源（视觉链）& 3179 lut / 1963 reg / dram 256 / \textbf{eram 62/108} / dsp 8 & 同上 \\
\bottomrule
\end{tabular}}
\end{center}

\textbf{已闭环项（处置 + 证据指针）}
\begin{center}
{\small
\begin{tabular}{p{4.2cm}p{5.4cm}p{7.2cm}}
\toprule
\rowcolor{rowtint}\textbf{问题} & \textbf{处置} & \textbf{证据} \\
\midrule
算法 mux 提交沿丢 SOF & 提交沿组合选择 + 超时回退 & \code{tb\_algo\_switch}（SOF$\to$SOF 严格 scoreboard）\\
128bit 重排 tuser 错位 & 抽头改 AWB 96bit 直抽 & \code{tb\_isp\_burst} + system\_top \\
system\_top 悬空网 & 握手修正（I\_tvalid 直用 RAW / O\_tready 显式）& 代码 + 迭代记录 \#N+6 \\
串化器容量不足（128px）& v4 弹性缓冲 2048px + 寄存器读 & \code{tb\_isp\_burst} 验收 \\
resync 抱死（tuser 缺失）& v4.1 看门狗 + tlast 门控恢复 & \code{tb\_ser96to24} 阶段 2 故障注入 \\
跑马灯 ROM mux 链超时 & 前瞻 4 像素 + 4 级移位流水 & TD +2.441ns + \code{tb\_osd\_track} 位精确 \\
LUTRAM 映射未证 & TD 实证（bin\_smooth 256 dram lut）& \code{02\_td\_synth\_gate/reports\_prefix/} \\
motion ERAM 同址依赖 & 写地址延迟一拍结构解耦 & TD（eram 57）+ \code{tb\_motion\_detect} \\
OSD 影子换装撕裂 & 结构成立（SOF 换装）& \code{tb\_osd\_track} / \code{tb\_vision\_top} \\
闭环控制滞后 & T1/T4 时序修正（12 帧锁定）& \code{tb\_closed\_loop} \\
\bottomrule
\end{tabular}}
\end{center}

\textbf{开放 Gate（评审请聚焦）}
\begin{center}
{\small
\begin{tabular}{p{1.1cm}p{7.4cm}p{8.2cm}}
\toprule
\rowcolor{rowtint}\textbf{Gate} & \textbf{内容} & \textbf{验证途径} \\
\midrule
A & 真机 ISP 最大连续 burst / 多行合并行数上限 & 上板：O\_drop\_cnt / O\_occ\_max / sync\_err + 帧计数 \\
B & P\&R 时序与最终资源（gate 级为估算，净延迟占 \~{}68\%）& \code{opt\_place/opt\_route} 后复核 \\
C & 算法切换短帧对真实视频消费者的兼容性 & 先测两分支延迟差是否固定，再决定是否对齐 \\
D & ERAM 最终布局（视觉 62 + 官方链 39 $\Rightarrow$ \~{}94\%）& P\&R 布局报告 \\
E & 边缘支路未在合成激励下保留；cdc busy 断言待补 & 正式 P\&R 激励覆盖 / 断言 TODO \\
\bottomrule
\end{tabular}}
\end{center}

\textbf{证据索引（可向维护者索取对应工件）}
\begin{itemize}
  \item 回归日志：\code{03\_vision/step4\_osd\_integration/04\_迭代文件/测试运行\_*.log}
  \item TD 综合证据：\code{08\_board\_bringup/02\_td\_synth\_gate/}（reports/ 终态；reports\_prefix/ 修复前）
  \item 板级突发测量/验收 TB：\code{08\_board\_bringup/01\_video\_passthrough/sim/tb\_isp\_burst.v}
  \item 全量迭代记录（\#N+6 \~{} \#N+9 为关键节点）：\code{04\_embedded/04\_迭代文件/迭代记录\_嵌入式对接.md}
\end{itemize}

\textbf{复现速查}
\begin{itemize}
  \item 全量回归：\code{cd tools \&\& python run\_all.py}（约 4 分钟，18 项）
  \item 行突发验收：\code{vsim -c -gFEED\_MODE=1 tb\_isp\_burst}（板级 sim 目录，用法见其文件头注释）
  \item TD gate 综合：\code{td\_commands\_prompt.exe <TD>/doc/scripts/DefaultFlow.tcl}
        （run 目录放 settings.cfg 与 vision\_gate.sdc；完整说明见 \code{02\_td\_synth\_gate/README.md}）
\end{itemize}

\textbf{卷宗版本历史}
\begin{center}
{\small
\begin{tabular}{p{1.8cm}p{3.0cm}p{11.6cm}}
\toprule
\rowcolor{rowtint}\textbf{版本} & \textbf{口径} & \textbf{关键变化} \\
\midrule
v1 & 旧排版 105 页 & 初版（全代码 + 架构说明）\\
v2\~{}v4 & --- & 第 1\~{}6 轮外部评审落地（18 项回归成型）\\
v5 & 旧排版 117 页 & 架构级复审实测：ISP 行突发/全灭证据 + TD 两 Gate 解除\\
v6 & 旧排版 119 页 & 严格帧 scoreboard（SOF$\to$SOF）+ FIFO 占用实测 \\
v7 & 旧排版 122 页 & v4.1 异常恢复 + 跑马灯结构性流水（WNS +2.441ns）\\
\textbf{v8（本版）} & \textbf{精排版 + 内容同步} & 页眉/页脚/彩色标题/架构图；状态总览、证据索引、复现速查前置 \\
\bottomrule
\end{tabular}}
\end{center}
{\small\color{black!55} 注：v8 起排版升级（每页更密），页数与旧版不可直接比较；内容以本版为准。}

\subsection{一句话与架构}

\textbf{2026 FPGA 创新设计赛道（安路）赛题二}：基于 PH1P35 的实时视觉跟踪系统。
摄像头 SC520CS（1280x720@60）经官方 ISP 链路输出 96bit AXI4-Stream（4 像素/拍），
自研检测链在纯旁路窃流点接入，完成 颜色识别 → 阈值分割 → 3x3 去噪 → 质心/包围框，
结果经跨时钟域送至云台控制（双路 50Hz 舵机 PWM）与 OSD 叠加/遥测。

\begin{center}
\begin{tikzpicture}[x=1cm,y=1cm,>={Stealth[length=2.4mm]},
  main/.style={draw=deep,fill=rowtint,rounded corners=2pt,align=center,font=\small,inner sep=3pt,minimum height=8mm},
  mod/.style={draw=accent,fill=codebg,rounded corners=2pt,align=center,font=\footnotesize\ttfamily,inner sep=2.5pt,minimum height=7mm},
  io/.style={draw=deep,fill=white,rounded corners=2pt,align=center,font=\footnotesize,inner sep=3pt,minimum height=7mm},
  chip/.style={draw=thinline,fill=codebg,rounded corners=6pt,align=center,font=\scriptsize,inner sep=3pt,text width=3.5cm,minimum height=9mm},
  lab/.style={font=\tiny\itshape,text=black!60,align=center},
  arr/.style={->,draw=accent!75!black,semithick},
  elbow/.style={arr,rounded corners=3pt}]
% ---- 主通路（显示链路，零扰动）----
\node[main] (sensor) at (1.1,0) {SC520CS\\[-2pt]{\scriptsize 1280x720@60}};
\node[main] (isp) at (4.7,0) {官方 ISP\\[-2pt]{\scriptsize AWB 后 96bit}};
\node[io] (thru) at (11.1,0) {直通出 · 显示链路（零扰动）};
\coordinate (tap) at (8.2,0);
\draw[arr] (sensor.east) -- (isp.west);
\draw[arr] (isp.east) -- (tap);
\draw[arr] (tap) -- (thru.west);
\fill[accent] (tap) circle (1.5mm);
\node[lab,above=2pt] at (tap) {旁路窃流点};
% ---- 检测分支（旁路窃流）----
\node[mod] (ser) at (1.6,-1.8) {ser96to24};
\node[mod] (rgb) at (4.1,-1.8) {rgb2hsv};
\node[mod] (hsv) at (7.0,-1.8) {hsv\_threshold};
\node[mod] (sm3) at (10.1,-1.8) {bin\_smooth3x3};
\node[mod] (cen) at (13.4,-1.8) {centroid\_accum};
\node[lab] at (3.9,-1.05) {检测分支（旁路窃流）};
\draw[elbow] (tap) -- (8.2,-0.55) -- (1.6,-0.55) -- (ser.north);
\draw[arr] (ser.east) -- (rgb.west);
\draw[arr] (rgb.east) -- (hsv.west);
\draw[arr] (hsv.east) -- (sm3.west);
\draw[arr] (sm3.east) -- (cen.west);
% ---- 输出：OSD 与云台 ----
\node[io] (osd) at (13.4,-3.5) {OSD 叠加};
\node[mod] (gim) at (10.0,-3.5) {gimbal\_ctrl};
\node[mod] (pwm) at (6.7,-3.5) {pwm\_servo};
\draw[elbow] (cen.south) -- (13.4,-2.7) -- (10.0,-2.7) -- (gim.north);
\draw[arr] (13.4,-2.7) -- (osd.north);
\node[lab,anchor=west] at (13.75,-2.95) {135bit 目标包 · cdc};
\node[lab] at (11.7,-2.45) {23bit 控制包 · cdc};
\draw[arr] (gim.west) -- (pwm.east);
\node[lab] at (8.35,-3.25) {50Hz};
\node[lab] at (6.7,-4.2) {双路 50Hz 舵机};
% ---- 边缘分支（常开）----
\node[mod] (edge) at (2.4,-5.1) {edge\_detect\_96};
\node[lab] at (2.4,-5.65) {边缘分支（常开，Lab2 复用）};
\node[io] (mux) at (6.4,-5.1) {帧首 mux 切换显示};
\draw[arr] (edge.east) -- (mux.west);
\draw[elbow,dashed] (mux.north) -- (6.4,-4.35) -- (16.7,-4.35) -- (16.7,-0.02) -- (thru.east);
% ---- 辅助模块 ----
\node[chip] at (2.1,-6.35) {video\_adj\\亮度/对比度（画质，显示路径）};
\node[chip] at (6.2,-6.35) {motion\_detect\\帧差（运动，115KB ERAM）};
\node[chip] at (10.3,-6.35) {led\_buzzer\\声光提示};
\node[chip] at (14.4,-6.35) {uart\_telemetry\\115200，每帧 9 字节（遥测）};
\node[lab] at (8.5,-7.15) {实线：数据流；虚线：显示切换；圆点：窃流接入点};
\end{tikzpicture}
\end{center}

\subsection{平台、工具链与关键约定}

\begin{itemize}
  \item 器件/工具：安路 PH1P35MDG324（-3）；TD 6.2.1（build 168116）；仿真 ModelSim SE 10.4；Verilog-2001。
  \item 时钟域：像素域 74.25MHz（1 像素/拍，96bit 流为 1 beat/4 clk）；PWM/控制域 50MHz；跨域仅经 pulse\_sync（单 bit）与 cdc\_4phase（多 bit）。
  \item 96bit 契约：4 像素 RGB888/拍；tuser=帧首、tlast=行尾、tready 恒 1（不反压）。
  \item 舵机：50Hz，0.5～2.5ms 对应 0～180 度；共周期计数器；上电中位 1500us；双道限幅。
  \item UART 遥测：115200-8N1；帧格式 A5|valid|cx(2B)|cy(2B)|preset|累加和|5A。
\end{itemize}

\subsection{目标包位图（IF-VISION v1.1.0，135bit，位偏移唯一权威定义）}

\begin{center}
\begin{tikzpicture}[x=1cm,y=1cm,
  seg/.style={rounded corners=1.2pt},
  nam/.style={font=\tiny\bfseries,text=white},
  rng/.style={font=\tiny,text=white!75!deep},
  nar/.style={font=\tiny\bfseries,text=black!70},
  rngn/.style={font=\tiny,text=black!55}]
% ---- 第一行：bit 134 .. 66 ----
\path[fill=deep,seg] (0,-0.375) rectangle (0.38,0.375);
\path[fill=deep,seg] (0.46,-0.375) rectangle (0.84,0.375);
\path[fill=deep,seg] (0.92,-0.375) rectangle (1.58,0.375);
\path[fill=accent,seg] (1.66,-0.375) rectangle (4.08,0.375);
\path[fill=accent,seg] (4.16,-0.375) rectangle (6.58,0.375);
\path[fill=accent,seg] (6.66,-0.375) rectangle (9.08,0.375);
\path[fill=accent,seg] (9.16,-0.375) rectangle (11.58,0.375);
\path[fill=accent,seg] (11.66,-0.375) rectangle (13.86,0.375);
\node[nar,rotate=90,anchor=west] at (0.19,-0.45) {valid};
\node[rngn,rotate=-90,anchor=west] at (0.19,0.45) {[134]};
\node[nar,rotate=90,anchor=west] at (0.65,-0.45) {algo};
\node[rngn,rotate=-90,anchor=west] at (0.65,0.45) {[133]};
\node[nar,rotate=90,anchor=west] at (1.25,-0.45) {preset};
\node[rngn,rotate=-90,anchor=west] at (1.25,0.45) {[132:130]};
\node[nam] at (2.87,0.10) {cx};
\node[rng] at (2.87,-0.17) {[129:119]};
\node[nam] at (5.37,0.10) {cy};
\node[rng] at (5.37,-0.17) {[118:108]};
\node[nam] at (7.87,0.10) {minx};
\node[rng] at (7.87,-0.17) {[107:97]};
\node[nam] at (10.37,0.10) {maxx};
\node[rng] at (10.37,-0.17) {[96:86]};
\node[nam] at (12.76,0.10) {miny};
\node[rng] at (12.76,-0.17) {[85:76]};
\node[rngn,anchor=east] at (-0.12,0) {bit 134};
\node[rngn,anchor=west] at (13.98,0) {bit 66};
% ---- 第二行：bit 65 .. 0 ----
\path[fill=accent,seg] (0,-2.675) rectangle (1.76,-1.925);
\path[fill=moteal,seg] (1.84,-2.675) rectangle (2.22,-1.925);
\path[fill=moteal,seg] (2.30,-2.675) rectangle (5.38,-1.925);
\path[fill=moteal,seg] (5.46,-2.675) rectangle (7.88,-1.925);
\path[fill=moteal,seg] (7.96,-2.675) rectangle (10.38,-1.925);
\path[fill=moteal,seg] (10.46,-2.675) rectangle (12.66,-1.925);
\path[fill=moteal,seg] (12.74,-2.675) rectangle (14.94,-1.925);
\path[fill=ggray,seg] (15.02,-2.675) rectangle (15.40,-1.925);
\node[nam] at (0.88,-2.20) {fid};
\node[rng] at (0.88,-2.47) {[65:58]};
\node[nar,rotate=90,anchor=west] at (2.03,-2.75) {mot\_valid};
\node[rngn,rotate=-90,anchor=west] at (2.03,-1.85) {[57]};
\node[nam] at (3.84,-2.20) {mot\_cnt};
\node[rng] at (3.84,-2.47) {[56:43]};
\node[nam] at (6.67,-2.20) {mot\_minx};
\node[rng] at (6.67,-2.47) {[42:32]};
\node[nam] at (9.17,-2.20) {mot\_maxx};
\node[rng] at (9.17,-2.47) {[31:21]};
\node[nam] at (11.56,-2.20) {mot\_miny};
\node[rng] at (11.56,-2.47) {[20:11]};
\node[nam] at (13.84,-2.20) {mot\_maxy};
\node[rng] at (13.84,-2.47) {[10:1]};
\node[nar,rotate=90,anchor=west] at (15.21,-2.75) {reserved（填 0）};
\node[rngn,rotate=-90,anchor=west] at (15.21,-1.85) {[0]};
\node[rngn,anchor=east] at (-0.12,-2.3) {bit 65};
\node[rngn,anchor=west] at (15.52,-2.3) {bit 0};
% ---- 图例 ----
\node[rngn,anchor=west] at (0.3,-3.35)
  {\textcolor{deep}{\rule[2.2pt]{7pt}{7pt}}\ 头部（valid/algo/preset）\quad
   \textcolor{accent}{\rule[2.2pt]{7pt}{7pt}}\ 目标/坐标\quad
   \textcolor{moteal}{\rule[2.2pt]{7pt}{7pt}}\ 运动统计\quad
   \textcolor{ggray}{\rule[2.2pt]{7pt}{7pt}}\ 保留};
\end{tikzpicture}

{\tiny\color{black!55} 段宽示意（非等比例）；位段范围以各段标注为准，为唯一权威定义。}
\end{center}

\subsection{验证体系（18 项回归，2026-10-03 全绿）}

方法：\textbf{金标准先行}。所有算术先在 Python 金标准 \code{golden\_model.py} 中实现，
RTL 逐位复刻；激励/期望由 \code{gen\_vectors.py} 生成；\code{run\_all.py} 一键回归。

\begin{center}
\renewcommand{\arraystretch}{1.35}
\arrayrulecolor{thinline}
\rowcolors{2}{white}{rowtint}
{\small
\begin{tabular}{@{}>{\ttfamily}p{5.2cm}p{4.9cm}p{4.6cm}@{}}
\toprule
\rowcolor{deep}
\textcolor{white}{\textbf{TB}} & \textcolor{white}{\textbf{验证对象}} & \textcolor{white}{\textbf{粒度}} \\
\midrule
tb\_ser96to24 / tb\_tpg & 串化器 / 测试图案源 & 逐位 \\
tb\_pulse\_sync / tb\_cdc4phase & 两种跨域桥 & 行为/时序 \\
tb\_rgb2hsv / tb\_hsv\_threshold & 颜色变换 / 阈值 & 逐位（10010/4000 向量）\\
tb\_bin\_smooth / tb\_centroid & 去噪 / 质心 & 逐位（12288 像素/3 帧）\\
tb\_detect\_chain & 检测链整链 & 3 帧真实场景逐字段 \\
tb\_gimbal / tb\_pwm & 控制律 / PWM 波形 & 10 步进表 / 逐拍 \\
tb\_osd\_track / tb\_vision\_top & OSD / 整机 & 逐像素 921600 / 5 断言 \\
tb\_closed\_loop & 相机-舵机在环 & 12 帧锁定 \\
tb\_motion\_detect & 帧差运动 & 6 帧逐字段（含末像素边界）\\
tb\_uart\_telemetry & 遥测（含 cx/cy 全坐标字节） & 逐字节 \\
tb\_cdc\_reset\_skew & CDC 复位偏斜（第 17 项） & 4 轮错开释放 \\
tb\_algo\_switch & 算法切换帧对齐（第 18 项） & SOF→SOF 严格 scoreboard \\
\bottomrule
\end{tabular}}
\end{center}

\subsection{已完成的独立评审（供本轮评审参考，不必重复）}

自研代码已经过\textbf{六轮外部 AI 评审}（三版独立模型、累计 100+ 条意见，逐条实证甄别），
已修复并回归的问题包括：

\begin{itemize}
  \item \textbf{TD 综合阻断类}：多驱动网络/寄存器、层次化引用取跨域信号；
  \item \textbf{综合模式依赖类}：motion\_detect 同址读写依赖 ERAM 写模式
        （已改"写地址延迟一拍"结构性解耦）；组合读行缓存/缓冲的 LUTRAM 映射
        （列入第 8 节硬 Gate）；
  \item \textbf{系统级接线类}：vision\_top 显示链曾断接（video\_adj 输出无下游，
        edge/亮度对比度为死分支）——已重接 mux->video\_adj->OSD；
  \item \textbf{边界/时序类}：motion 帧末漏最后像素（锁存再延一拍，并新增
        末像素专项向量）；PWM 占空采样与 gimbal 更新同沿致多一帧滞后（已修）；
        ser96to24 满缓冲拒收 SOF 后帧同步丢失窗口（已改"仅 SOF 真正入队才解除"）；
  \item \textbf{恢复/复位类}：CDC 两侧复位无同步释放（vision\_top 已加 pix/pwm
        双域两拍同步释放网络）；
  \item \textbf{功能类}：跑马灯索引截断、亮度负值符号、D 字段滞后一包、
        蜂鸣时长与文档不符；
  \item \textbf{控制性能}：控制节拍改为"新包到达即节拍"，配合上述修复，
        相机-舵机在环锁定帧数 36 -> 12。
\end{itemize}

已确认"不成立"的被驳意见（供参考）：组合读被静默强转 BRAM、OSD 影子寄存器
同沿撕裂、大 LUT-ROM 必然时序违例（均给出过实证反驳，详见仓库迭代记录）。

第四轮落地批次（三版独立模型评审后已完成，供本轮参考）：（1）算法 mux 改为
\textbf{输出侧 SOF 提交}（每个输出帧严格单算法，消除切换帧内新旧拼接）；
（2）CDC \textbf{复位同源契约}写入 cdc\_4phase 头部，并新增
\code{tb\_cdc\_reset\_skew}（第 17 项回归，4 轮错开释放全部 PASS）；
（3）system\_top 的 OSD 流补全 \code{O\_osd\_sof/O\_osd\_eol} 正式端口，
异步输入（algo/bright/contrast）加 2FF 同步；（4）运动框与 M-字段的
\textbf{像素级覆盖}测试上线后立刻抓出并修复"OSD M 字段读影子旧值"缺陷
（与 D 字段同类，此前只修了 D）。另：本轮评审中出现的若干"接线 bug"指控
（UART cy、运动框坐标、video\_adj 复位极性）经逐行实证均为引用幻觉，
代码本身正确——文档与代码冲突时以代码为准。

第五轮落地批次（ChatGPT 第三版复审）：外部评审指出算法 mux 的"输出侧提交"存在
NBA 同沿首拍丢失——mux 选择块与提交寄存器分处两个 always，提交沿扇出的首个
帧首脉冲落到旧选择分支，新算法帧的 SOF 被吃掉。此项指控成立：新增
\code{tb\_algo\_switch}（第 18 项回归）首跑即复现（MISM win=5 sof=0，切换后
首窗零 SOF）。修复为\textbf{提交沿组合选择}（\code{algo\_sel} 提交当拍即生效）
并加入\textbf{请求超时回退}（输入帧首仍未提交则强制提交，兑现上一轮评审的
"绝不卡死"建议）；修复后专项 PASS，18 项回归全绿。

第六轮（架构级复审，2026-10-03 深夜）：以"不依赖文档自证"为前提，改用\textbf{实测与工具}
替代论证——新增 \code{tb\_isp\_burst}（三档馈送节拍）坐实 ISP 行级突发与 ser96to24
实链功能性全灭，并连带抓出 128bit 重排 tuser 结构性错位、system\_top isp\_tready
悬空网两个独立致命；用\textbf{安路 TD 无头综合}（read\_design→opt\_rtl→opt\_gate）解除
两个 Gate：LUTRAM 映射实证（ser96to24 56 / bin\_smooth3x3 256 dram lut）、
50MHz 域 WNS +8.747ns（gimbal 乘加无虞），并指认真正的时序风险在 OSD 跑马灯路径
（74.25MHz 域 WNS −0.113ns）。详见迭代记录 \#N+6 与第 8 节。

\textbf{修复轮（\#N+7，用户授权后实施）}：三处致命全部修复并复验——ser96to24 v4
（2048px 寄存器读弹性缓冲）、抽头改 AWB 96bit 直抽（isp\_top 新增 tap\_* 端口）、
system\_top 握手修复、跑马灯数组 ROM 化。验收：tb\_isp\_burst 行突发模式
\code{pixels=2764800/sof=3/eol=2160/drop=0} PASS（修复前 188 像素/0 SOF）；
18 项回归全绿；TD 像素域 \textbf{WNS −0.113ns → +0.541ns（0 违规端点）}。

\textbf{加固轮（\#N+9，第七轮复审响应）}：采纳其两条核心意见——\textbf{ser96to24 v4.1}
（帧同步看门狗 + tlast 门控受控恢复，杜绝 tuser 缺失死锁；故障注入 TB 验证；O\_occ\_max/
sync\_err 观测量经 status[6] 引出）；\textbf{跑马灯结构性流水化}（并诚实更正：\#N+7 的
"数组 ROM 化"并未真正消除 mux 树，WNS 曾回退 −1.025ns；前瞻 4 像素+移位对齐后
像素域 \textbf{WNS +2.441ns、0 违规端点}）。多行合并突发与短帧兼容性维持"真机确认"Gate。

第二波待办与上板硬 Gate 见第 8 节；\textbf{如你不同意以上任何结论，请明确指出并给出依据}。

\subsection{请重点评审的问题（回答时请注明严重度与依据）}

已闭环项（详见 §1.5 与 §8，请勿重复报告，除非有新证据）：算法 mux 首拍 SOF、128bit 重排
tuser 错位、system\_top 悬空网、ser96to24 突发（v4 已修）、LUTRAM 映射（TD 已证）、
50MHz 时序（+8.747ns）、OSD 跑马灯与文本影子、motion ERAM 解耦。当前开放边界如下：

\begin{enumerate}
  \item \textbf{ser96to24 v4.1 的对抗性审计}：容量 2048px 依据=实测行突发 320 beat、
        最大占用 1601/2048（78\%）、drop=0；寄存器读（+1 拍）；溢出帧级重同步 +
        \textbf{帧同步看门狗（SYNC\_TIMEOUT=2 帧预算）+ tlast 门控恢复}（tuser 永久缺失
        不再死锁，故障注入 TB 已验）。请继续找：多行合并突发（3 行=2880px > 2048）
        的分布边界是否可在板级可靠界定；恢复后的帧相位偏移对下游有无隐性影响；
        以及 DEPTH 是否需要更大的量化判断（代价：4 块 ERAM/实例，整机预算 ≈94\%）。
  \item \textbf{抽头点选择}：视觉从 AWB 96bit 直抽（isp\_top 只增 4 个 tap\_* 端口，
        未改 ISP 逻辑），弃用官方 128bit 重排路径（其 tuser 与 valid 结构性错位已实测）。
        请评估该改动对"官方显示链零扰动"承诺是否有任何破坏，以及 tap 端口加法
        在 TD 综合/P\&R 上可能引入的负担或副作用。
  \item \textbf{无反压直抽 ISP 的完整性边界}：窃流语义下 O\_tready 恒 1。
        实测：行突发节奏下零丢行；但满速馈送（非真实节奏）下曾观察到 AWB 仅输出
        \~{}668/720 行。请评估"无背压"的残余风险，并给出上板必须确认的观测项清单
        （O\_drop\_cnt / O\_occ\_max / sync\_err 已可观测）。
  \item \textbf{P\&R 前的时序风险预判}：gate 级 0 违规（pwm +8.747ns / pix \textbf{+2.441ns}，
        跑马灯已结构性流水化）。但 68\% 为估算净延迟。请指出 P\&R 后最可能恶化的路径簇
        与兜底改法（成本排序），特别复核：OSD 文本影子装载、cdc 目的侧数据到文本数组、
        AWB tap fanout。
  \item \textbf{严格帧 scoreboard 的语义边界}：SOF→SOF 判据（行宽严格 1280 / 非切换跨度
        恰 720 行 / 切换跨度允许旧帧截断 ≤2 次）已 PASS；实测两次切换截断形态为
        \code{0 行+1px} 与 \code{719 行+1279px}（源于两分支流水延迟差）。请评估该语义
        对下游（显示/推流/录像）的可接受性，以及"对齐两分支延迟实现零截断"是否值得做。
  \item \textbf{ERAM 预算与资源分配}：视觉链 61/108（motion 57 + ser 8），
        叠加官方 DDR/HDMI 链 39 块 ⇒ 真机 ≈93\%。请给出资源分配建议
        （降 ser DEPTH / 共享串化器 / 裁剪 motion 分辨率，按性价比排序）。
  \item \textbf{竞赛层面}：以"基础+扩展+进阶"评分口径看，此实现还有哪些短板可补？
  \item \textbf{接线语义审计（继续）}：上一轮同类审计抓到真实缺陷（system\_top 的
        isp\_tready 悬空网）。请继续沿 vision\_top / system\_top 每条数据通路核对
        "文档声明意图"与"实际连线"的闭环性，重点：tap\_* 四端口、cdc\_4phase 两侧
        握手、OSD 的 sof/eol/valid 对齐链。
\end{enumerate}
"""


def make_tex():
    L = []
    a = L.append
    a(r'''\documentclass[10pt]{ctexart}
\usepackage[a4paper,top=2.3cm,bottom=2.3cm,left=1.8cm,right=1.8cm,headheight=15pt,headsep=0.45cm,footskip=1.0cm]{geometry}
\usepackage{fvextra}
\usepackage[table]{xcolor}
\usepackage{colortbl}
\usepackage{fontspec}
\usepackage[most]{tcolorbox}
\usepackage{booktabs}
\usepackage{enumitem}
\usepackage{titlesec}
\usepackage{array}
\usepackage{tikz}
\usetikzlibrary{arrows.meta,positioning,calc}
\usepackage{fancyhdr}
\usepackage{lastpage}
\usepackage{hyperref}
\setmonofont{Consolas}
\setCJKmonofont{SimHei}
\setlength{\parindent}{0pt}
\setlist{nosep,leftmargin=1.4em}
\linespread{1.06}
% ---------- 配色 ----------
\definecolor{deep}{RGB}{24,43,73}
\definecolor{accent}{RGB}{31,95,168}
\definecolor{rowtint}{RGB}{232,239,247}
\definecolor{codebg}{RGB}{247,249,252}
\definecolor{thinline}{RGB}{178,193,214}
\definecolor{codeframe}{RGB}{203,215,230}
\definecolor{codenum}{RGB}{140,155,175}
\definecolor{moteal}{RGB}{23,124,122}
\definecolor{ggray}{RGB}{118,126,138}
% ---------- 页眉页脚 ----------
\pagestyle{fancy}
\fancyhf{}
\fancyhead[L]{\small\color{deep}\bfseries fpga-ptz-tracker\ \ 代码与设计说明}
\fancyhead[R]{\small\color{accent}\nouppercase{\rightmark}}
\fancyfoot[C]{\small\color{black!60}\thepage\ / \pageref{LastPage}}
\renewcommand{\headrulewidth}{0.7pt}
\renewcommand{\headrule}{{\color{accent}\hrule width\headwidth height\headrulewidth}}
\renewcommand{\footrulewidth}{0pt}
\fancypagestyle{plain}{%
  \fancyhf{}%
  \fancyfoot[C]{\small\color{black!60}\thepage\ / \pageref{LastPage}}%
  \renewcommand{\headrulewidth}{0pt}}
% ---------- 标题样式 ----------
\titleformat{\section}{\large\bfseries\color{deep}}%
  {\colorbox{deep}{\textcolor{white}{\,\thesection\,}}}{0.55em}{}%
  [{\vspace{2pt}\color{accent}\titlerule[1pt]}]
\titlespacing{\section}{0pt}{16pt}{9pt}
\titleformat{\subsection}{\normalsize\bfseries\color{deep}}%
  {\textcolor{accent}{\thesubsection}}{0.5em}{}
\titlespacing{\subsection}{0pt}{12pt}{5pt}
% ---------- 代码块 ----------
\fvset{framerule=0.5pt,framesep=2.5mm,rulecolor=\color{codeframe}}
\renewcommand{\theFancyVerbLine}{\textcolor{codenum}{\scriptsize\arabic{FancyVerbLine}}}
\newcommand{\code}[1]{\texttt{#1}}
\newcommand{\fileintro}[1]{{\small\color{accent}\sloppy\emergencystretch=2.5em #1\par}\vspace{2pt}}
\newtcolorbox{notebox}[1]{enhanced, breakable, colback=codebg, colframe=thinline,
  boxrule=0.5pt, arc=1.5mm, left=3mm, right=3mm, top=2mm, bottom=2mm,
  title={\bfseries #1}, fonttitle=\small\bfseries, coltitle=white,
  colbacktitle=deep}
% ---------- 超链接 ----------
\hypersetup{colorlinks=true, linkcolor=deep, urlcolor=accent, citecolor=accent,
  linktocpage=true,
  pdftitle={fpga-ptz-tracker 代码与设计说明（外部评审版）},
  pdfauthor={fpga-ptz-tracker 项目组}}
\setcounter{tocdepth}{1}
\begin{document}
''')
    # 封面
    a(r'''\begin{titlepage}
\begin{tcolorbox}[enhanced, colback=deep, colframe=deep, sharp corners,
  boxrule=0pt, left=9mm, right=9mm, top=13mm, bottom=13mm,
  borderline west={1.4mm}{0pt}{accent}]
\raggedright
{\color{white}\Huge\bfseries fpga-ptz-tracker}\\[10pt]
{\color{rowtint}\Large\bfseries 代码与设计说明（外部评审版）}\\[12pt]
{\color{thinline}\large 2026 FPGA 创新设计赛道（安路）赛题二 · 视觉跟踪系统}
\end{tcolorbox}
\vspace{1.4cm}
\begin{center}
{\large PH1P35MDG324 / TD 6.2.1 / ModelSim SE}\\[10pt]
{\color{accent}\rule{0.32\textwidth}{0.9pt}}
\end{center}
\vspace{1.1cm}
\begin{notebox}{本文档用途}
\centering
{\small 汇总全部自研代码（RTL / 测试平台 / 仿真设施 / Python 工具，\textbf{约 7600 行}）\\
与架构说明、验证状态、开放问题清单，供外部 AI / 同行独立评审。\\
\textbf{版本 v8}（2026-10-03）：状态总览 / 已闭环项与证据指针 / 开放 Gate / 复现速查前置（见 \S1 首页）。\\
代码均通过 18 项位精确仿真回归，TD gate 综合 0 违规；开放项与上板核实清单见第 8 节。}
\end{notebox}
\vfill
{\small\color{black!55} 生成脚本：tools/make\_review\_pdf.py（可复现） · 2026-10}
\end{titlepage}
\tableofcontents
\newpage
''')
    a(OVERVIEW)

    # 各 Part
    for part_title, files in PARTS:
        a(r'\section{%s}' % latex_intro(part_title))
        # 生成文件节选穿插到对应 part 末尾之前——这里按 SAMPLED 列表判断归属
        part_samples = [(p, n) for (pt, p, n) in SAMPLED if pt == part_title]
        # 先放普通文件
        for rel in files:
            a(r'\subsection{%s}' % esc_title(os.path.basename(rel)))
            intro = INTRO.get(rel)
            if intro:
                a(r'\fileintro{%s}' % latex_intro(intro))
            txt = pdf_sanitize(read_text(os.path.join(ROOT, rel.replace('/', os.sep))))
            a(r'\begin{Verbatim}[numbers=left,numbersep=5pt,frame=single,fontsize=\footnotesize,breaklines=true,breakanywhere=true]')
            a(txt.rstrip('\n'))
            a(r'\end{Verbatim}')
        # 再放节选
        for rel, n in part_samples:
            a(r'\subsection{%s（生成文件 · 节选）}' % esc_title(os.path.basename(rel)))
            intro = INTRO.get(rel)
            if intro:
                a(r'\fileintro{%s}' % latex_intro(intro))
            lines = read_text(os.path.join(ROOT, rel.replace('/', os.sep))).split('\n')
            total = len(lines)
            sample = lines[:n]
            a(r'\begin{Verbatim}[numbers=left,numbersep=5pt,frame=single,fontsize=\footnotesize,breaklines=true,breakanywhere=true]')
            a('\n'.join(sample))
            a(r'\end{Verbatim}')
            a(r'\begin{notebox}{节选说明}')
            a(r'{\small 该文件共 %d 行（完整内容由 gencode 脚本可复现生成）。}' % total)
            a(r'\end{notebox}')

    # 尾部说明
    a(r'''
\section{官方复用与生成文件说明}

\begin{itemize}
  \item \textbf{官方复用（不改动）}：edge\_detect\_96.v（Lab2 Sobel 边缘核，149 行，整链仿真已验证接线）；
        官方 ISP 明码副本（isp\_top/data128\_96/awb/demosaic 树/raw10 解包等，位于 04\_embedded/03\_project/sim/，仅用于仿真）；
        SC520 适配版 Lab1 完整 TD 工程（08\_board\_bringup，含加密 MIPI/HDMI 核，不可改）。
  \item \textbf{生成文件（禁止手改）}：hsv\_inv\_lut.v、font\_rom\_8x16.v、marquee\_rom\_64.v，
        均由 tools/gen\_vectors.py 从算法/字库源生成（节选见上文）。
  \item \textbf{仿真专用（禁止进 TD 工程）}：\*\_stub.v / \*\_sim.v、全部 tb\_\*.v、px\_serializer\_fifo.v。
\end{itemize}

\section{开放项与上板检查单}

\begin{enumerate}
  \item \textbf{（已修复，2026-10-03 修复轮 \#N+7 / 加固 \#N+9）ISP 行级突发 vs 视觉抽头}：
        实测坐实"AWB 输出为行级突发（每行恰 320 beat，行间消隐；2160 段=3 帧×720 行）"后：
        ① ser96to24 v4/v4.1——容量 128→\textbf{2048 像素} + \textbf{寄存器读}（+1 拍，
        兼容 LUTRAM/ERAM）+ \textbf{帧同步看门狗与 tlast 门控恢复}（tuser 永久缺失不再死锁，
        故障注入 TB 验证）+ O\_occ\_max 观测（经 status[6] 引出 sync\_err）；
        ② 抽头改 AWB 96bit 直抽。验收：\code{pixels=2764800, sof=3, eol=2160, drop=0}
        （修复前 188 像素/0 SOF），\textbf{FIFO 最大占用实测 1601/2048（78\%）}。
        遗留：真机上板用 O\_drop\_cnt 与帧计数双重确认；多行合并突发的最大行数需真机确认
        （3 行=2880px 会超 2048；不盲目升 4096——双实例 16 块 ERAM 超出整机预算）。
  \item \textbf{（已修复，\#N+7）128bit 重排路径 tuser 结构性错位}：改 AWB 直抽后该路径不再
        参与视觉链（isp\_top 新增 tap\_* 只增端口）。
  \item \textbf{（已修复，\#N+7）system\_top 握手}：\code{I\_tvalid} 直用 RAW 有效（与官方
        design\_top\_wrapper 同款）；\code{O\_tready} 显式 1'b1。注：官方 wrapper 亦悬空该网
        （有效行为=无背压），本次显式化消除 Z 传播。
  \item \textbf{ERAM 写模式 + 预算}：motion\_detect v3.1 "写延迟一拍"结构解耦成立；
        TD gate 报告确认 prev\_mem → ERAM（57 块）。v4 串化器 4 块/实例；跑马灯 ROM 1 块。
        \textbf{预算}：视觉链 \textbf{62/108（57.4\%）} + 官方 DDR/HDMI 链 39 块 ⇒ 真机整合
        ≈94\%——若吃紧：边缘支路 ser 降 DEPTH 512（1 块）或走共享串化器重构；接近冻结期
        不建议大改；最终以 P\&R 布局报告为准。
  \item \textbf{LUTRAM 映射（已解除）}：bin\_smooth3x3 行缓存推断为 Distributed RAM
        （gate 报告 256 dram lut）；ser96to24 v4 因注册读设计对 LUTRAM/ERAM 双映射皆正确。
  \item \textbf{gimbal\_ctrl 帧拍组合路径（已解除）}：pwm\_clk(50MHz) WNS \textbf{+8.747ns}。
        像素域曾两度指认 OSD 跑马灯 ROM 路径：先 case→数组（\#N+7）——但 \#N+9 复综合发现
        该改动\textbf{并未真正消除 mux 树}（TD 仍映射为 ~10 级 LUT3 链，WNS 一度回退到
        −1.025ns，"+0.541"是综合器估算运气）；最终\textbf{结构性流水化}（地址+ROM 读前瞻
        4 像素 + 4 级移位对齐）后 \textbf{WNS +2.441ns、0 违规端点}。教训：换写法≠映射变浅，
        必须看 gate 报告的逻辑级数。gate 级净延迟 ~68\% 为估算，P\&R 后复核。
  \item \textbf{I2C BFM ACK 位相}（tb\_i2c\_config）：列 TD 阶段项，需真机逻辑分析仪对照；
        寄存器序列（116 条）本身已由 ROM 逐条确认。
  \item \textbf{厂商 ISP 仿真环境限制}：无背压满速馈送下 AWB 行数完整性在行突发模式下
        实测零丢行（早期 668/720 观察与馈送模型有关）；上板仍以 O\_drop\_cnt 实测为准。
  \item \textbf{CDC 复位同源（已固化）}：cdc\_4phase 头部契约 + \code{tb\_cdc\_reset\_skew}
        （4 轮错开释放 PASS）；上板确认两复位同源，禁止运行时单侧复位。
  \item \textbf{算法切换帧专项 TB（已完成）}：输出侧 SOF 提交 + 提交沿组合选择 + 超时回退，
        经 \code{tb\_algo\_switch}（第 18 项）覆盖，全绿。
\end{enumerate}

\vspace{6pt}
{\small\color{black!60} —— 文档由 tools/make\_review\_pdf.py 自动生成；
代码以仓库实际文件为唯一真值，本文档中的说明如与代码冲突，以代码为准。}
''')
    a(r'\end{document}')

    io.open(OUT_TEX, 'w', encoding='utf-8').write('\n'.join(L))
    return OUT_TEX


def main():
    tex = make_tex()
    print('tex 写入', tex)
    r = subprocess.run(['latexmk', '-xelatex', '-interaction=nonstopmode', '-halt-on-error',
                        os.path.basename(tex)], cwd=os.path.dirname(tex),
                       capture_output=True, text=True, errors='replace')
    print('latexmk exit:', r.returncode)
    if r.returncode != 0:
        tail = (r.stdout or '')[-3000:]
        print(tail)
        sys.exit(1)
    pdf = tex[:-4] + '.pdf'
    print('PDF:', pdf, os.path.getsize(pdf), 'bytes')


if __name__ == '__main__':
    main()
