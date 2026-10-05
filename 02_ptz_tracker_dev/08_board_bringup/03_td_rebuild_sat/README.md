# 03_td_rebuild_sat —— 饱和度增强版比特流重建（2026-10-04）

## 目的（问题与根因）

上板画面正常但**饱和度低、发灰**。源码级根因（逐模块查证）：

- SC520CS 输出 **RAW10**，颜色完全由 FPGA 侧决定；
- `isp_top` 链路 = `demosaic → AWB（灰世界全帧平均）→ 128bit 重排 → DDR/HDMI`，
  **没有 CCM（色彩校正矩阵）、没有饱和度处理**；
- 文件里附带的 `axis_gamma_rgb96`（^0.7 曲线）与 `BLC.v` **都未被例化（死代码）**——
  连 gamma 都没有。
- ⇒ "原始去马赛克 + 白平衡"直出，发灰是**结构性**结果，不是参数没调好。

## 改动

| 文件 | 说明 |
|---|---|
| `04_embedded/03_project/rtl/axis_saturation_rgb96.v` | 新增模块（canonical）：4 像素/拍 96bit RGB888，2 拍流水，无背压；`out = clamp(Y + ((K_Q4*(c-Y)+8)>>4))`，`Y=(77R+150G+29B)>>8` |
| `lab_ex1_build/user_source/hdl_source/isp/isp_top.v` | AWB 之后、128bit 重排之前插入 `u_saturation`（**K_Q4=21 ≈ 1.31x**）；模块定义内嵌于同文件末尾（不动 `.prj` 源列表，降低构建风险） |

K 值：`16 = 1.00x（恒等）`、`21 ≈ 1.31x（当前）`、`24 = 1.50x`。改 K 只需改 `isp_top.v` 里
`.K_Q4` 后重跑两段（见"复现"）。

## 验证链（先仿真、再上板）

1. **整链仿真（虚拟 RAW10 传感器，3 帧）**：TB 内插同一模块（`SAT_EN` 开关）：
   `TB_RESULT: PASS frames_dumped=2 tuser_total=3 tlast_total=2008 ser_ovf=0`
   （与基线几何统计一致）；
2. **位精确对拍**：帧 0/1 各 921600 像素与 Python 参考（`tools/sat_tool.py`，同一整数公式）
   **逐字节一致**（PASS×2）；
3. **预览图**：`08_board_bringup/01_video_passthrough/sim/sim_out/`
   - `sat_sweep_sim.png`（仿真帧 K 档位对比）
   - `sat_sweep_photo.png`（实拍照片 K 档位示意）
4. **两段式无头构建**（厂商同款流程，`settings.cfg` 原样复用）：

| 段 | 步骤 | 结果 |
|---|---|---|
| `syn_1/` | read_design → opt_gate | ✓ 2m17s，Setup **WNS 860ps / TNS 0 / 0 违规端点**（与原版一致），新 `camera_to_dsi_display_gate.db`（8.95MB，+0.55MB ≈ 新增逻辑） |
| `phy_1/` | opt_place → bitgen（`parent ../syn_1` 导入新 gate.db） | ✓ 5m10s（place 3m4s + route 1m44s + fix_hold 11s + bitgen 8s）；**final 时序 Setup WNS +255ps / TNS 0 / 0 违规端点，Hold WNS +20ps / 0 违规** |

**新 bit 产物**（本目录）：

| 文件 | 说明 |
|---|---|
| `camera_to_dsi_display_sat_k21.bit` | 饱和度增强版比特流，md5 `d211a715…`（原版 `2ef0ec47…`） |
| `camera_to_dsi_display_sat_k21_inst.bid` | 配套下载文件 |
| `lab_ex1_build/.../phy_1/camera_to_dsi_display_pr.timing` | P&R final 时序报告（原始留档） |

**上板状态**：✓ 已烧录（2026-10-04 晚，`PRG-2014 Chip validation success: PH1P35MDG324`，
进度 100%，退出码 0）→ 待目视对比确认饱和度效果。

> 烧录插曲（已归档进 `anlogic-download` skill）：期间下载器曾被拔出（`device not found`）；
> 且发现**手动启动 hwserver 必须带 `-r`**（remote-bitbang 协议）——不带协议参数时只打开设备、
> 不建立 5555 服务端口，客户端会反复报 `PRG-8000 Connect server failed`。
> 投递包内三个 `burn_*.bat` 已修正为 `hwserver.exe -r`。

## 复现

```bat
cd lab_ex1_build\td_project\camera_to_dsi_display_Runs\syn_1
D:\TD6.2.1\bin\td_commands_prompt.exe D:\TD6.2.1\doc\scripts\DefaultFlow.tcl

cd ..\phy_1
D:\TD6.2.1\bin\td_commands_prompt.exe D:\TD6.2.1\doc\scripts\DefaultFlow.tcl
```

（`settings.cfg` 为厂商原版：相对路径 `../../../user_source/...`；构建副本目录结构保持一致。）

## 备注

- 构建副本 `lab_ex1_build/` = `lab_ex1` 全量拷贝 + 上述补丁；**厂商原版源码保留在
  `_sc520_src/`**（唯一原版基线）。
- **一致性同步（2026-10-04 晚）**：`01_video_passthrough/lab_ex1` 与投放包
  `02_TD_project_rebuild/lab_ex1` 的 `isp_top.v` 已同步为同一补丁版（三处 MD5 一致）——
  这两个位置现在**可以直接重建出板上运行的定版 bit**；两处的仿真 TB/清单也已同步为
  含饱和度级的当前版。
- `SYN-5011 undriven pin`（demosaic 的 blk_mem BE 位）与 `SYN-5041 RAM_STYLE` 警告为
  原设计与原版综合即存在的类型，非本改动引入。
- 上板验收（放 `TD_burn_tutorial.pdf` 第五/六章流程）：新 bit 烧 SRAM → 看画面饱和度对比
  → 满意后 QSPI 固化；参数不满意只需改 `.K_Q4` 重跑。

## 第二轮：K_Q4 21 → 28（1.31x → 1.75x，2026-10-04 晚）

用户上板反馈 1.31x"还不够"。处理：
- `axis_saturation_rgb96.v` 参数位宽扩至 **6 bit**（上限 3.94x）；K 默认实例改 `6'd28`；
- 仿真位精确对拍复验：帧 0/1 各 921600 像素与 Python 参考逐字节一致（K=28 PASS×2）；
- 重建：syn 新 gate.db（8,953,544B）+ phy 4m46s；**final WNS +703ps / TNS 0 / 0 违规，Hold +20ps**；
- 产物：`camera_to_dsi_display_sat_k28.bit`（md5 `5f2a33c4…`）；已烧录（`PRG-2014` + 返回 0）。

档位速查（改 `isp_top.v` 里 `.K_Q4` 即可重跑）：`16=1.00x` / `21≈1.31x` / `24=1.50x` /
`28≈1.75x（当前）` / `32=2.00x` / `36≈2.25x` / `63≈3.94x（上限）`。

## 收官（2026-10-04 晚）

- 用户选定 **保留 1.75x**（"目前先这样"）；**板上当前运行 = `camera_to_dsi_display_sat_k28.bit`**；
- K28 版 QSPI 固化镜像已生成：`camera_to_dsi_display_sat_k28_qspi_16M.bin`（W25Q128 / 16M）；
- ⏳ 待执行：QSPI 固化烧写 + 冷启动 15 秒验收（流程见投放包指南 A2 / 《TD_burn_tutorial.pdf》第六章）。

## 后续批次说明（2026-10-04 晚）

本目录的构建树 `lab_ex1_build/` 是**板级工程工作树**，后续批次改动会继续在此重建：
- 第 1 批（AWB 帧同步化 + tlast 对齐）：见 `../04_awb_framesync/`（含单元 TB 与复现）；
- 各批次 bit 归档在对应批次目录（第 1 批：`../04_awb_framesync/camera_to_dsi_display_sat_k28_awbfs.bit`）。

## 附：外部评审 #7 修复（2026-10-04 晚）

外部评审指出 `axis_saturation_rgb96` 的中间量 `v` 只有 10 位有符号：安全上界 **K≤32**
（v_max≈(K/16)·255≤511）；K≥33 会在限幅前溢出（示例：纯红 K=50 时 v=527 → 按有符号解释为
−497 → 被限幅成 0，亮点变黑）。**已修复**：`v` 扩为 12 位（K≤63 满量程），
并做 **K=50 整链仿真位精确对拍 PASS**（921600 像素，覆盖上述溢出场景）。

- **K=28（定版）行为不变**（最大 446 < 511，扩位宽不改变范围内结果）→ **板上已烧 bit 无需重烧**；
- 但**源码已比板上 bit 新一步**（功能等价、综合网表可能略不同）——若要求"源码产物哈希
  与板上完全一致"，改 K 或下次重建时顺带重烧即可。三处工程源码（01 / 03 / 投放包 02）已同步。
