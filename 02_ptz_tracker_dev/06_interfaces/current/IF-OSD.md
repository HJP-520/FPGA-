# IF-OSD 显示侧对接（v1.0.0）

## 视觉 OSD 与官方 hdmi_mixer 的关系

官方例程 3 的 `hdmi_mixer.v` 在显示读出路径（DDR → FIFO → mixer → HDMI）上叠加 Logo/文字。
视觉方向的 `osd_track.v` 是同构的叠加层，提供**跟踪专用**元素：

| 元素 | 规格 |
|------|------|
| 跟踪框 | 红色 FF0000，包围框边缘内缩 2px |
| 十字准星 | 绿色 00FF00，臂长 12px、中空半径 3px，中心 = 质心 |
| 状态文字 | 白色 FFFFFF，8×16 点阵，左上角 (16,16)，20 字符 |
| 文案 | `TRK<n> LOCK X<cx>Y<cy>` / `TRK<n> LOST X----Y----`，n=阈值组号 |

绘制优先级：文字 > 十字 > 框 > 底图。

## 两种挂载方式（上板二选一）

**A. 替换/扩展 hdmi_mixer（推荐，嵌入式配合）**
`hdmi_mixer` 已有 x/y 计数与 FIFO 读出；把 osd_track 的叠加判决函数并入其像素 mux：
```
最终像素 = mixer原有叠加 ? : osd_track覆盖 ? : 视频像素
```
osd_track 需要：显示域时钟、DE/行场（转成 vpix 的 valid/sof/eol 约定）、以及 68bit 目标包（IF-VISION）。

**B. 独立叠加层串在 mixer 之后**
读出流 → osd_track → HDMI 编码。要求 osd_track 的 vpix 输入接 mixer 输出（含消隐期气泡时
内部计数器以 valid 门控，天然兼容）。

## vpix 流约定（视觉内部通用，上板转换规则）

| vpix | 显示侧对应 |
|------|------------|
| `I_valid` | `DE`（数据有效） |
| `I_sof` | 帧起始（vsync 后首个 DE 拍） |
| `I_eol` | 行尾（每行最后一个 DE 拍） |
| `I_data[23:0]` | RGB888 `{R,G,B}` |

osd_track 内部 x/y 计数器以 valid 门控自增，`O_valid/O_sof/O_eol` 与输出像素严格对齐。

## 已知限制与 v2 计划

- 目标包经 4 相握手写入 OSD 寄存器，到达时刻与显示场消隐不同步 → 理论上存在单帧内
  新旧坐标并存的撕裂窗口（概率极低；v2 计划双缓冲 + 显示 vsync 交换，见迭代文件）
- 字库 ROM 当前仅 40 字符 ASCII 子集（数字/大写/少量符号），由 `tools/gen_vectors.py` 生成，
  改字库重跑生成器即可

## 仿真验证状态

tb_osd_track：整帧 921600 像素与 Python 金标准渲染**逐像素一致**（含文字/框/十字/底图合成）。
