// 答辩演示文稿生成脚本（pptxgenjs）
const pptxgen = require("pptxgenjs");

const p = new pptxgen();
p.layout = "LAYOUT_WIDE";           // 13.33 × 7.5
p.author = "fpga-ptz-tracker";
p.title = "基于 PH1P35 的实时数字图像处理与云台跟踪系统";

// 调色板：深空蓝底 + 深青主色 + 橙色强调（视觉跟踪/工程主题）
const BG_DARK = "0E1626", BG_LIGHT = "F7F9FB";
const PRIMARY = "1B6E8C", PRIMARY_LT = "D8E8EE";
const ACCENT = "E76F51";
const TEXT = "1E293B", MUTED = "64748B", LIGHT_TEXT = "E8EEF2";
const F = "微软雅黑";
const W = 13.33, H = 7.5, M = 0.6;

// ---------- S1 封面（深色） ----------
let s = p.addSlide();
s.background = { color: BG_DARK };
s.addText("基于 PH1P35 的实时数字图像处理\n与云台跟踪系统", {
  x: M, y: 1.9, w: W - 2 * M, h: 2.2, fontSize: 40, bold: true,
  color: LIGHT_TEXT, fontFace: F, align: "left", lineSpacingMultiple: 1.2,
});
s.addText("2026 全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道（安路）赛题二", {
  x: M, y: 4.25, w: W - 2 * M, h: 0.5, fontSize: 16, color: "9FB3C8", fontFace: F,
});
s.addText([
  { text: "视觉方向软件包", options: { color: ACCENT, bold: true } },
  { text: "   ·   仿真全量回归 16/16 通过   ·   位精确验证 2,764,800 像素零失配", options: { color: "9FB3C8" } },
], { x: M, y: 5.0, w: W - 2 * M, h: 0.5, fontSize: 15, fontFace: F });
s.addShape(p.shapes.LINE, { x: M, y: 4.15, w: 3.2, h: 0, line: { color: ACCENT, width: 2.5 } });

// ---------- S2 系统架构（框图） ----------
s = p.addSlide();
s.background = { color: BG_LIGHT };
s.addText("系统架构：一条从像素到舵机的全流水线", {
  x: M, y: 0.35, w: W - 2 * M, h: 0.6, fontSize: 26, bold: true, color: TEXT, fontFace: F,
});
const boxes = [
  ["摄像头\nRAW10", "8ECAE6"],
  ["官方 ISP\n去马赛克/3A", "8ECAE6"],
  ["RGB→HSV\n倒数表查映射", PRIMARY_LT],
  ["阈值分割\n8 组预置", PRIMARY_LT],
  ["3×3 平滑\n多数表决", PRIMARY_LT],
  ["质心+包围框\nQ8.8 控制律", "F4C7AB"],
  ["PWM 舵机\n云台跟随", "F4C7AB"],
];
const bw = 1.55, bh = 1.05, gap = 0.24, x0 = M, y0 = 1.5;
boxes.forEach((b, i) => {
  const bx = x0 + i * (bw + gap);
  s.addShape(p.shapes.ROUNDED_RECTANGLE, {
    x: bx, y: y0, w: bw, h: bh, fill: { color: b[1] }, rectRadius: 0.06,
    line: { color: PRIMARY, width: 0.75 },
  });
  s.addText(b[0], { x: bx, y: y0, w: bw, h: bh, fontSize: 11.5, bold: true,
    color: TEXT, fontFace: F, align: "center", valign: "middle", margin: 0 });
  if (i < boxes.length - 1)
    s.addText("▶", { x: bx + bw - 0.02, y: y0 + 0.3, w: gap + 0.06, h: 0.4,
      fontSize: 10, color: MUTED, align: "center", fontFace: F, margin: 0 });
});
// OSD 支路
s.addShape(p.shapes.ROUNDED_RECTANGLE, {
  x: x0 + 3 * (bw + gap), y: y0 + 1.55, w: bw * 2 + gap, h: 0.75,
  fill: { color: "FFFFFF" }, line: { color: ACCENT, width: 1 },
});
s.addText("OSD 叠加：状态行 + 遥测行 + 跑马灯 + 双框（影子寄存器消撕裂）", {
  x: x0 + 3 * (bw + gap), y: y0 + 1.55, w: bw * 2 + gap, h: 0.75, fontSize: 10.5,
  color: TEXT, fontFace: F, align: "center", valign: "middle", margin: 0.03 });
s.addText("▲ 目标包 135bit（每帧一次）", { x: x0 + 3 * (bw + gap) + 0.1, y: y0 + 1.12,
  w: 2.6, h: 0.4, fontSize: 9.5, color: MUTED, fontFace: F, margin: 0 });
s.addText([
  { text: "50 MHz 单时钟域 · ", options: {} },
  { text: "1 像素/拍全流水 · ", options: {} },
  { text: "视觉逻辑 <3% LUT", options: { bold: true, color: PRIMARY } },
], { x: M, y: y0 + 2.6, w: 8, h: 0.45, fontSize: 15, color: TEXT, fontFace: F });
s.addText("所有跨时钟交互均经 4 相握手 CDC；检测分支与显示域解耦，目标包整帧快照。", {
  x: M, y: y0 + 3.1, w: W - 2 * M, h: 0.45, fontSize: 12.5, color: MUTED, fontFace: F });

// ---------- S3 位精确金标准（大数字） ----------
s = p.addSlide();
s.background = { color: BG_LIGHT };
s.addText("方法学：先把“真值”写死，再让 RTL 逐位追认", {
  x: M, y: 0.35, w: W - 2 * M, h: 0.6, fontSize: 26, bold: true, color: TEXT, fontFace: F,
});
s.addText("2,764,800", { x: M, y: 1.35, w: 6.4, h: 1.5, fontSize: 72, bold: true,
  color: ACCENT, fontFace: F, margin: 0 });
s.addText("像素位精确比对零失配（720p × 3 帧 OSD 整帧）", {
  x: M, y: 2.95, w: 6.4, h: 0.5, fontSize: 16, color: TEXT, fontFace: F });
s.addText("16/16", { x: 7.6, y: 1.35, w: 5.2, h: 1.5, fontSize: 72, bold: true,
  color: PRIMARY, fontFace: F, margin: 0 });
s.addText("全量回归测试通过（单元级 → 检测链 → 整机在环）", {
  x: 7.6, y: 2.95, w: 5.2, h: 0.8, fontSize: 16, color: TEXT, fontFace: F });
const rows = [
  ["算术真值先行", "Python 金标准模型与 RTL 逐位约定：定点移位、边界策略、取整方向，先改真值再改 RTL"],
  ["三层验证网", "模块级 TB ×14 → 检测链 TB → 相机-舵机在环 + OSD 整帧 dump 逐位比对"],
  ["回归即门禁", "任何改动必跑全量 16 项，汇总全绿才算改完；日志按时间戳沉淀到迭代档案"],
];
rows.forEach((r, i) => {
  const ry = 4.05 + i * 0.95;
  s.addShape(p.shapes.ROUNDED_RECTANGLE, { x: M, y: ry, w: W - 2 * M, h: 0.8,
    fill: { color: i === 0 ? PRIMARY_LT : "FFFFFF" }, rectRadius: 0.05,
    line: { color: "D5DEE5", width: 0.75 } });
  s.addText(r[0], { x: M + 0.25, y: ry, w: 2.3, h: 0.8, fontSize: 15, bold: true,
    color: PRIMARY, fontFace: F, valign: "middle", margin: 0 });
  s.addText(r[1], { x: M + 2.7, y: ry, w: W - 2 * M - 3, h: 0.8, fontSize: 12.5,
    color: TEXT, fontFace: F, valign: "middle", margin: 0 });
});

// ---------- S4 闭环收敛（曲线图） ----------
s = p.addSlide();
s.background = { color: BG_LIGHT };
s.addText("闭环跟踪：36 帧锁定，无振荡", {
  x: M, y: 0.35, w: W - 2 * M, h: 0.6, fontSize: 26, bold: true, color: TEXT, fontFace: F,
});
s.addImage({ path: "闭环收敛曲线.png", x: M, y: 1.15, w: 8.6, h: 5.6, sizing: { type: "contain", w: 8.6, h: 5.6 } });
const kpis = [["36 帧", "锁定用时（|err|≤20px 连续 5 帧）"], ["12 px", "末帧残差（<0.94% 视场宽）"], ["1.5°/帧", "舵机限速下平滑收敛，无摆头"]];
kpis.forEach((k, i) => {
  const ky = 1.3 + i * 1.75;
  s.addText(k[0], { x: 9.6, y: ky, w: 3.2, h: 0.85, fontSize: 40, bold: true,
    color: i === 0 ? ACCENT : PRIMARY, fontFace: F, margin: 0 });
  s.addText(k[1], { x: 9.6, y: ky + 0.85, w: 3.2, h: 0.7, fontSize: 12.5,
    color: TEXT, fontFace: F, margin: 0 });
});
s.addText("数据来源：tb_closed_loop 相机-舵机在环仿真 closed_loop_trace.txt（tools/plot_convergence.py 绘制）", {
  x: M, y: 6.95, w: W - 2 * M, h: 0.35, fontSize: 10.5, color: MUTED, fontFace: F });

// ---------- S5 工程严谨性：三个被消灭的 bug ----------
s = p.addSlide();
s.background = { color: BG_LIGHT };
s.addText("仿真层就能抓住的“上板事故”", {
  x: M, y: 0.35, w: W - 2 * M, h: 0.6, fontSize: 26, bold: true, color: TEXT, fontFace: F,
});
const bugs = [
  ["135bit 目标包缺保留位", "发送端拼接 134 位 → 整包上移 → OSD 永远 LOST。\n对照接口规格逐位排查，补齐保留位。上板前消灭。"],
  ["帧差首帧门控失效", "靠未初始化 RAM 的 X 值“碰巧”不计数，综合后 RAM 初值 0 会误报全帧运动。\n改显式 prev_ready 状态位，仿真/上板行为强制一致。"],
  ["OSD 坐标帧中更新撕裂", "CDC 包落帧中 → 同帧上下两半两种坐标。\n影子寄存器 + sof 整帧换装，3×921600 像素位精确验证消撕裂。"],
];
bugs.forEach((b, i) => {
  const by = 1.25 + i * 1.85;
  s.addShape(p.shapes.ROUNDED_RECTANGLE, { x: M, y: by, w: W - 2 * M, h: 1.6,
    fill: { color: "FFFFFF" }, rectRadius: 0.06,
    shadow: { type: "outer", color: "93A6B5", blur: 7, offset: 2, angle: 90, opacity: 0.28 } });
  s.addText(b[0], { x: M + 0.3, y: by + 0.12, w: 5.4, h: 1.35, fontSize: 16, bold: true,
    color: ACCENT, fontFace: F, valign: "top", margin: 0 });
  s.addText(b[1], { x: M + 5.9, y: by + 0.14, w: W - 2 * M - 6.2, h: 1.35, fontSize: 12.5,
    color: TEXT, fontFace: F, valign: "top", margin: 0 });
});
s.addText("验证不止“功能对”，而是“仿真行为 = 上板行为”——每一位都一致。", {
  x: M, y: 6.95, w: W - 2 * M, h: 0.4, fontSize: 13, bold: true, color: PRIMARY, fontFace: F });

// ---------- S6 v2 拓展（演示亮点） ----------
s = p.addSlide();
s.background = { color: BG_LIGHT };
s.addText("拓展功能：超出基线的部分", {
  x: M, y: 0.35, w: W - 2 * M, h: 0.6, fontSize: 26, bold: true, color: TEXT, fontFace: F,
});
const exts = [
  ["帧差运动检测", "整帧 1bit 前帧缓存，运动计数+包围框；\n亚门限拒报、首帧门控均已位精确验证", "已回归"],
  ["OSD 双缓冲", "影子寄存器 + vsync 换装，坐标更新\n永不撕裂画面；3 帧整帧位精确比对", "已回归"],
  ["UART 遥测", "115200-8N1 帧格式 A5|valid|cx|cy|…\n上位机串口即可读目标状态", "已回归"],
  ["扩展显示集", "边缘检测 / 画质调节 / 跑马灯 ROM，\nOSD 三行文本 + 双框 + 运动框叠加", "已集成"],
];
exts.forEach((e, i) => {
  const ex = M + (i % 2) * (W - 2 * M) / 2, ey = 1.3 + Math.floor(i / 2) * 2.55;
  const ew = (W - 2 * M) / 2 - 0.25;
  s.addShape(p.shapes.ROUNDED_RECTANGLE, { x: ex, y: ey, w: ew, h: 2.25,
    fill: { color: "FFFFFF" }, rectRadius: 0.06,
    shadow: { type: "outer", color: "93A6B5", blur: 7, offset: 2, angle: 90, opacity: 0.28 } });
  s.addText(e[0], { x: ex + 0.3, y: ey + 0.15, w: ew - 1.6, h: 0.5, fontSize: 17,
    bold: true, color: PRIMARY, fontFace: F, margin: 0 });
  s.addShape(p.shapes.ROUNDED_RECTANGLE, { x: ex + ew - 1.25, y: ey + 0.22, w: 1.0, h: 0.38,
    fill: { color: PRIMARY_LT }, rectRadius: 0.19 });
  s.addText(e[2], { x: ex + ew - 1.25, y: ey + 0.22, w: 1.0, h: 0.38, fontSize: 10.5,
    bold: true, color: PRIMARY, fontFace: F, align: "center", valign: "middle", margin: 0 });
  s.addText(e[1], { x: ex + 0.3, y: ey + 0.75, w: ew - 0.6, h: 1.35, fontSize: 12.5,
    color: TEXT, fontFace: F, margin: 0, lineSpacingMultiple: 1.15 });
});

// ---------- S7 上板计划（TD 流程） ----------
s = p.addSlide();
s.background = { color: BG_LIGHT };
s.addText("上板路径：每一步都有官方脚本背书", {
  x: M, y: 0.35, w: W - 2 * M, h: 0.6, fontSize: 26, bold: true, color: TEXT, fontFace: F,
});
const steps = ["新建工程\nHX1P35A", "导入 RTL\n排除仿真源", "管脚/时钟\n约束", "综合\nopt_gate", "布线\n时序审查", "固化\nQSPI Flash"];
steps.forEach((st, i) => {
  const sx = M + i * ((W - 2 * M - 0.5) / 6 + 0.1), sw = (W - 2 * M - 0.5) / 6;
  s.addShape(p.shapes.CHEVRON, { x: sx, y: 1.35, w: sw + 0.12, h: 0.95,
    fill: { color: i < 2 ? ACCENT : PRIMARY } });
  s.addText(st, { x: sx, y: 1.35, w: sw + 0.12, h: 0.95, fontSize: 11, bold: true,
    color: "FFFFFF", fontFace: F, align: "center", valign: "middle", margin: 0 });
});
s.addText([
  { text: "流程命令已经官方脚本核验：", options: { bold: true, color: TEXT, breakLine: true } },
  { text: "elaborate → optimize_rtl → optimize_gate → place → route → bitgen（DefaultFlow.tcl 六步）", options: { breakLine: true } },
  { text: "阶段完成标志 .step.end.f / 失败标志 .step.error.f，每步产物可独立检查（*_gate.db、*_pr.db、*.bit）", options: {} },
], { x: M, y: 2.7, w: W - 2 * M, h: 1.4, fontSize: 13.5, color: TEXT, fontFace: F,
  paraSpaceAfter: 6, margin: 0 });
const prep = [
  ["99 MB 官方文档已蒸馏", "TD 用户指南 / SWUG105 TCL 命令 / UG1310 PH1P 原语库 → 中文知识库，管脚约束语法、时序审查三件套、BitWriter 固化流程逐条核对"],
  ["风险项已预判", "官方 demosaic 的 tuser 链在纯 RTL 仿真不激活（上板第一检查点）；舵机独立 5V 供电；AE 拉色则锁曝光或切阈值组"],
];
prep.forEach((pr, i) => {
  const py = 4.3 + i * 1.15;
  s.addShape(p.shapes.ROUNDED_RECTANGLE, { x: M, y: py, w: W - 2 * M, h: 1.0,
    fill: { color: i === 0 ? PRIMARY_LT : "FFFFFF" }, rectRadius: 0.05,
    line: { color: "D5DEE5", width: 0.75 } });
  s.addText(pr[0], { x: M + 0.25, y: py, w: 3.1, h: 1.0, fontSize: 14, bold: true,
    color: PRIMARY, fontFace: F, valign: "middle", margin: 0 });
  s.addText(pr[1], { x: M + 3.5, y: py, w: W - 2 * M - 3.8, h: 1.0, fontSize: 12,
    color: TEXT, fontFace: F, valign: "middle", margin: 0 });
});

// ---------- S8 演示脚本 ----------
s = p.addSlide();
s.background = { color: BG_LIGHT };
s.addText("现场演示脚本（5 幕）", {
  x: M, y: 0.35, w: W - 2 * M, h: 0.6, fontSize: 26, bold: true, color: TEXT, fontFace: F,
});
const demo = [
  ["上电", "云台回中，OSD 显示 TRK0 LOST", "丢失策略=保持，状态可预期"],
  ["目标入画", "OSD 变 TRK0 LOCK，十字/框锁定，云台跟随", "约 0.6 秒锁定"],
  ["快速甩目标", "云台平滑跟随，不摆头", "Kp 按增益稳定域整定"],
  ["遮挡 2 秒", "云台保持不动，OSD 显示 LOST", "丢失策略生效"],
  ["按键切色", "阈值组 TRK0→TRK1，换色目标照样锁", "8 组 HSV 预置已内置"],
];
demo.forEach((d, i) => {
  const dy = 1.3 + i * 1.12;
  s.addShape(p.shapes.OVAL, { x: M, y: dy + 0.12, w: 0.62, h: 0.62, fill: { color: PRIMARY } });
  s.addText(String(i + 1), { x: M, y: dy + 0.12, w: 0.62, h: 0.62, fontSize: 20, bold: true,
    color: "FFFFFF", fontFace: F, align: "center", valign: "middle", margin: 0 });
  s.addText([
    { text: d[0] + "　", options: { bold: true, color: TEXT, fontSize: 16 } },
    { text: d[1], options: { color: TEXT, fontSize: 14 } },
  ], { x: M + 0.85, y: dy + 0.02, w: 8.0, h: 0.85, fontFace: F, valign: "middle", margin: 0 });
  s.addText(d[2], { x: 9.6, y: dy + 0.02, w: 3.1, h: 0.85, fontSize: 12, color: MUTED,
    fontFace: F, valign: "middle", margin: 0 });
  if (i < demo.length - 1)
    s.addShape(p.shapes.LINE, { x: M + 0.85, y: dy + 1.0, w: W - 2 * M - 0.85, h: 0,
      line: { color: "D5DEE5", width: 0.75 } });
});

// ---------- S9 结尾（深色） ----------
s = p.addSlide();
s.background = { color: BG_DARK };
s.addText("把每一步都做成可验证的", {
  x: M, y: 2.3, w: W - 2 * M, h: 1.0, fontSize: 38, bold: true, color: LIGHT_TEXT,
  fontFace: F, margin: 0 });
s.addText("位精确金标准 · 16/16 回归 · 2,764,800 像素零失配 · 上板路径全程背书", {
  x: M, y: 3.5, w: W - 2 * M, h: 0.6, fontSize: 17, color: "9FB3C8", fontFace: F, margin: 0 });
s.addShape(p.shapes.LINE, { x: M, y: 4.35, w: 3.2, h: 0, line: { color: ACCENT, width: 2.5 } });
s.addText("谢谢评委老师\n（现场演示 + 代码逐层可追溯，迭代档案见 04_迭代文件）", {
  x: M, y: 4.6, w: W - 2 * M, h: 1.0, fontSize: 15, color: LIGHT_TEXT, fontFace: F,
  lineSpacingMultiple: 1.3 });

p.writeFile({ fileName: "答辩演示文稿.pptx" }).then(() => console.log("PPTX 生成完成"));
