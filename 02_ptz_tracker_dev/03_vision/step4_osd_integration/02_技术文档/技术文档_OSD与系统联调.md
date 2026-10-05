# 技术文档 —— Step4 OSD 与系统联调

对应 RTL：`rtl/{font_rom_8x16.v(生成), osd_track.v, vision_top.v}`；
验证：`tb_osd_track`（逐像素）、`tb_vision_top`（整机）、`tb_closed_loop`（闭环在环）。

## 1. osd_track（跟踪叠加层，显示域）

### 结构
```
vpix 输入 ─> x/y 计数器 ─┐
68bit 目标包 ─> CDC ─> 目标寄存器 ─> 叠加判决 ─> O_data
（4 相握手）           （txt 缓冲 20×8bit + 字库 ROM）
```

- **CDC**：`cdc_4phase #(.WIDTH(68))`，源域 load = 检测域 `results_upd`；
  目标寄存器（tv/cx/cy/bbox/preset + 20 字符 txt 缓冲）在 pack_valid 拍一次成套更新
- **x/y 计数**：valid 门控，sof 复位行/列 —— 输入含消隐气泡时自然停走，无需 DE 变换电路
- **叠加判决**（组合，输出寄存一拍）：
  - 文字：y∈[16,32) ∧ x∈[16,176)：`addr = {txt[(x-16)>>3], y-16}`，位 MSB=左
  - 十字：`|dx|∈[3,12] ∧ dy==0` 或对称（dx/dy 为对 cx/cy 的带符号差）
  - 框：x∈{minx,minx+1,maxx-1,maxx} ∧ y∈[miny..maxy]，或对称
  - 优先级：文字 > 十字 > 框 > 底图；颜色 白/绿/红
- **文字构建**：pack_valid 拍一次性写 20 字符：
  `TRK`+组号+ (`LOCK`|`LOST`) + `X`+4 位十进制 + `Y`+4 位十进制；
  二进制转 ASCII 用常量除法（val/1000、%100、%10——帧率更新，时序充裕）
- **68bit 包位偏移**（唯一权威定义在 IF-VISION.md；本模块与 vision_top 两端一致）：
  `tv=[67] preset=[66:64] cx=[63:53] cy=[52:42] minx=[41:31] maxx=[30:20] miny=[19:10] maxy=[9:0]`

### 已知限制（v2 项）
坐标包到达与显示消隐不同步 → 单帧内新旧坐标并存的撕裂窗口（概率极低）。
v2：双缓冲 + 显示 vsync 交换。

## 2. vision_top（整机顶层）

```
96bit AXI-S 入 ─┬─ 直通出（逐拍一致）
                └─ detect_top ─┬─ 68bit 包 ─cdc─> osd_track ─> OSD'd vpix 出
                               └─ 23bit 坐标 ─cdc─┐
                  frame_tick ─pulse_sync──────────┤
                                                  v
                              gimbal_ctrl ─> pwm_servo ─> O_pwm_x/y（50M 域）
```

- 三个时钟域：pix（检测/OSD）、pwm（50M 整数域）；跨域全部经 pulse_sync/cdc_4phase
- 控制节拍 = 新包到达拍（`ctrl_valid_dst` 打一拍，2026-10-03 外脑评审 T1）：tick 与数据同源，控制滞后 1 帧（原 t_tick 脉冲早于 cdc 数据 ~0.9µs，实际 2 帧）；
  `ctrl_vld_hold` 缓存 + 新包优先（同拍竞争修复）
- 参数全部 RTL parameter（Kp/DZ/SLEW/限幅/极性/阈值组数），随 bit 固化

## 3. tb_vision_top 断言清单（全部通过）

| # | 断言 | 意义 |
|---|------|------|
| 1 | 直通输出 ≡ 输入（逐拍） | 主线零扰动 |
| 2 | frame_4.hex ≡ Python 金标准渲染（921600 像素） | OSD 整帧逐像素 |
| 3 | duty_x ∈ [700,1500) | 云台 X 朝目标方向动（box 在左半屏） |
| 4 | duty_y == 1500 | Y 死区正确（cy=340，err=−20 ≤ DZ_Y=20） |
| 5 | lost_cnt == 0 | 无误丢帧 |

## 4. tb_closed_loop（闭环在环）

TPG 方块位置由 TB 相机模型驱动：`box_x = 640 + (40°−θ)×20px/° − 40`；
θ 由脉宽换算（0.18°/µs）经 1.5°/帧速率限幅逼近 θ_cmd（位置舵机语义，
1500µs=保持）。60 帧判据：|err|≤25px 连续 10 帧。

结果：**settle_frame=36，最终 err 在死区内，无振荡**（轨迹文件
`sim/closed_loop_trace.txt` 每帧一行，答辩可直接展示收敛曲线）。

> 教训：模型首版 `(duty_x − 13'd1500)` 无符号减法回绕 → θ 正向跑飞；
> 闭环仿真两次抓出真实缺陷（该无符号 bug + Kp 增益超标），是本项目
> 验证体系价值的最佳证据。
