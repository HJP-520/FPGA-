
## #N OSD 双缓冲消撕裂 + 135bit 包位宽事故修复（2026-09-20 凌晨，v2 冲刺）

**1. osd_track 升级 v3（双缓冲）**：CDC 目标包可能落帧中，v2 直接更新绘制寄存器
→ 同帧上下两半坐标不一致（框撕裂）。v3 引入影子寄存器组，pack_valid 只写影子，
sof 拍整组换装（vsync 语义）。顺带修正延迟显示读旧值的问题（原 txt2 显示的是
上一包的 s_lat；保留该确定性行为，金标准按其建模）。

**2.【重大】vision_top 135bit 包缺保留位（上板必现事故）**：IF-VISION v1.1.0 规定
135bit（bit0 保留），但 pack_vision 拼接只有 134 位 → 零扩展后 valid 恒 0 →
**OSD 永远 LOST、准星/目标框永不绘制**。TB 侧同病（一直被 "golden pending" 空
check 掩盖）。修复：发送端补 1'b0（vision_top + tb）。教训：扩位时 IF 文档、
发送端、接收端三处必须同步过；任何"待更新"的金标准比对都是债务。

**3. 金标准渲染器升级 v3 + tb_osd_track 重写**：render_osd 补齐 L2/L3（跑马灯
ANLOGIC PH1P35 FPGA VISION PTZ TRACKER 2026，disp_cnt×2px/帧）、运动框、
空状态支持；TB 改 3 帧（f0 空状态 / f1 换装后 / f2 连续），中帧注包，三份
逐位比对——f0 若被撕裂不可能匹配。**3×921600 像素全部位精确一致。**

**4. TB 文件句柄竞态教训**：$fopen 放在首个 o_valid 边沿会与 $fwrite 同拍竞态，
像素 0 写进 fd0 且整个文件前移一格（f0=921599 行、噪声像素成对"错位"的怪象）。
修复：句柄在 initial 开头打开。另：快照+延迟一拍写入（od_d/ov_d）作为标准做法。

**回归**：tb_osd_track（3 帧位精确）+ tb_vision_top + 全量 16/16 见
测试运行_20260920_02*.log。
