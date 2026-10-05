# 亮度更新：优先使用 balanced 4×版

画面过暗时，运行 `01_bitstream_flash_direct/burn_codex_balanced_sram.bat`。新位流启动 AG80（4×档）。旧 codex_main/unity 位流仍为 AG16（1×档）。详见 `04_codex_validation/BRIGHTNESS_UPDATE.md`。

> **2026-10-05 Codex 改进版已加入**：当前 02 源码默认启动增益为 1×（AG=16），曝光保持 1991；AWB 帧同步，饱和度 1.5×（K=24）。
> 新候选：`01_bitstream_flash_direct/camera_to_dsi_display_codex_main.bit`，烧录用 `burn_codex_main_sram.bat`。
> 诊断候选：`camera_to_dsi_display_codex_unity.bit`（AWB 固定 1×、饱和度 1×，同样 AG=16），用 `burn_codex_unity_sram.bat`。
> 两者仿真/时序通过，**尚未上板验收**；旧 bit、原烧录脚本与 QSPI 镜像均保留，仍对应旧配置。
> 新版说明、独立测试、构建工具和证据见 `04_codex_validation/README.md`。下文原教程作为旧版本记录保留。

# 先读我 —— SC520CS 摄像头 → 显示屏显示：烧录与使用说明

> **这包是干什么的**：让开发板（安路 PH1P35MDG324 / HX1P35A）把 SC520CS 摄像头拍到的画面，
> 显示在 HDMI 显示器上。内容 = 厂商 SC520CS 适配版官方例程 Lab1（1280x720@60fps）
> 的**成品比特流** + **完整 TD 工程** + 使用指导。
> 本包不含视觉算法（检测/OSD/云台）——那些是在这条通路跑通之后按仓库教程逐级挂载的上层。
> 生成日期：2026-10-04；来源：`D:\fpga-ptz-tracker\08_board_bringup\01_video_passthrough`。

---

## 一、包内容

| 文件/目录 | 内容 | 用途 |
|---|---|---|
| `01_bitstream_flash_direct\camera_to_dsi_display.bit` | 成品比特流（720p60） | **最快路径**：直接烧进板子看画面 |
| `01_bitstream_flash_direct\..._inst.bid` | 厂商下载工具配套文件 | 与 .bit 一同使用（BitWizard/下载器） |
| `01_bitstream_flash_direct\diag_hdmi_colorbar_1280x720.bit` | HDMI 自检彩条图 | 显示器无信号时**先烧它**，验证"板子→显示器"链路 |
| `01_bitstream_flash_direct\burn_camera_sram.bat` / `burn_colorbar_sram.bat` | 一键无头烧录脚本（**已实测**） | **双击即可**，不需要打开任何 GUI |
| `01_bitstream_flash_direct\camera_to_dsi_display_sat_k28_awbfs_b2.bit` / `..._inst.bid` | **当前定版**：饱和度 1.75x + AWB 帧同步化 + 接口修复（第2批，2026-10-05；**已烧录实测**） | 烧录脚本 `burn_camera_sat_sram.bat`（已指向本文件） |
| `01_bitstream_flash_direct\camera_to_dsi_display_sat_k28.bit` / `..._awbfs.bit` | 历史版本留档（K28 曾定版 / K28+AWB 第1批） | 对比与回退用 |
| `01_bitstream_flash_direct\camera_to_dsi_display_qspi_16M.bin` | QSPI 固化镜像（原版 bit） | 固化烧 Flash 用（见 A2） |
| `01_bitstream_flash_direct\camera_to_dsi_display_sat_k28_qspi_16M.bin` | QSPI 固化镜像（**饱和度增强版 K28**，2026-10-04 生成） | 计划固化版本（板上当前运行的即 K28） |
| `02_TD_project_rebuild\lab_ex1\` | 完整 TD 工程（**已含饱和度增强 K28 + AWB 帧同步化（第1批）**，与本包 01 的成品 bit 同源可重建；厂商原版基线见仓库 `_sc520_src/`） | 需要改代码/重新生成比特流时用 |
| `03_simulation_optional\sim\` | ModelSim 整链仿真（虚拟传感器，不需要板子；TB 含**饱和度级 SAT_EN 开关**，与板上版本一致） | 上板前预演；也含 `dump2png.py` 可把仿真画面导出 PNG |
| `video_passthrough_guide.pdf` | 9 页完整指导（硬件/工程/TD/仿真/烧录/排障） | **详细版说明**，遇到问题先查它 |
| `burnpack_review.pdf` + `review_prompt.txt` | **评审卷宗（41 页）**：本包全部工程技术内容+我方源码全文+验证证据+开放问题清单，供外部 AI 评审；`review_prompt.txt` 为配套提问提示词 |
| `TD_burn_tutorial.pdf` | **烧录实战教程（14 页，2026-10-04 实测）**：试错全记录、GUI 逐步点击（每步点什么）、命令行烧录、QSPI 固化 | **烧录必读**：从"工程打不开/下载器不识别"到烧录成功的完整路径 |

---

## 二、硬件连接（插线前务必看红字）

| 连接 | 接口 | 注意 |
|---|---|---|
| 摄像头模组 | 板上 CAM FPC 座 | ⚠ **排线金手指方向按座子丝印，勿反插**（反插可能短路烧摄像头）|
| HDMI 显示器 | 板上 HDMI TX 座 | 显示器需支持 **1280x720@60** |
| 电源 | 板上电源口 | 接好显示器与摄像头后再上电 |
| 下载器 | JTAG/USB 口 | 调试与固化共用；本机 TD 在 `D:\TD6.2.1` |

---

## 三、方式 A：直接用现成比特流（最快，五分钟见画面）

### A1. JTAG 下载进 SRAM（调试用，断电即失）

**方式 ①（推荐，2026-10-04 已实测）：双击脚本一键烧**

| 脚本（`01_bitstream_flash_direct\` 下） | 作用 |
|---|---|
| `burn_camera_sram.bat` | 烧摄像头画面 bit（原版，主目标） |
| `burn_camera_sat_sram.bat` | 烧**饱和度增强版** bit（2026-10-04 重建，当前 K≈1.75x） |
| `burn_colorbar_sram.bat` | 烧彩条自检 bit（隔离显示器链路） |

- 实测链路：识别芯片 `PH1P35MDG324` → 下载 **100% / 11.9 秒** → 出图；
- 日志里可能夹着一行 `Error @ mpsse.cpp: usb_open() failed`——那是 bw 退出时重复拉起
  hwserver 的噪声，**无害**；只要看到 `PRG-2014 : Chip validation success` 和进度条到 100% 即成功；
- 脚本内部：确认/启动 `hwserver.exe`（端口 5555）→ 调 `bw_commands_prompt.exe` 执行
  `connect_cable -host_name 127.0.0.1:5555 -open` + `download -bit <路径>`；
- 前置条件：FT2232 的 A 通道已装 **WinUSB 驱动**（一次性，用厂商 `UsbDriverTool.exe` 装），
  下载器插在 USB-JTAG 口。

**方式 ②（图形界面）**：TD → **Tools → BitWriter** → Debug Server 选 `AL-LINK-FT(Local Host)`、
Cable `0:123456789`（BitWriter 会自动拉起 hwserver）→ File Selection 表 **Add** 选 `.bit`
→ Mode Selection 选 `PROGRAM_SRAM` → **Run**。
若报 `PRG-9505 USB device open error`：WinUSB 驱动没装好（回到方式 ① 的前置条件）。

### A2. QSPI 固化（上电即运行，比赛/演示用）

1. TD → **Tools → BitWriter** → 先按 A1 方式 ② 连好（芯片显示 `0:PH1P35MDG324`）；
2. 用 QSPI 镜像（可直接用已备好的 `camera_to_dsi_display_sat_k28_qspi_16M.bin`；
   或用 BitWriter 的 **Create Flash File** 从任一 `.bit` 现场生成）；
3. Mode Selection 选 **`PROGRAM_SPI`**（目标=板载 QSPI Flash，不是 FPGA SRAM）→ Run；
4. 烧写完成 → **断电** → 拔下载器 → **重新上电**；
5. 验收：**15 秒内**显示器出图；再试"拔掉电脑，只留显示器与板子"重新上电仍出图
   = **"无 PC 参与"达标**（这是赛事要求）。

### A3. 显示器无信号时（先二分定位）

- 先双击 `burn_colorbar_sram.bat`（= 烧 `diag_hdmi_colorbar_1280x720.bit`）：
  - 彩条出图 → 板子→显示器链路正常，问题在摄像头侧（查排线/摄像头供电/I2C 配置）；
  - 彩条也不出 → 查显示器是否支持 720p60、换 HDMI 线、查供电。

---

## 四、方式 B：自己重新生成比特流（TD 6.2.1）

> ⚠ 厂商 `.al` 在本机 TD 6.2.1 GUI **打不开**（报 `PRJ-8641`；已修 4 类 XML 问题仍无效，
> 属工程文件与 TD 版本的兼容性问题，**不影响本包成品 .bit 的使用**）。
> 需要重编译/改代码时，按「新建工程」路线走：

1. 把整个 `02_TD_project_rebuild\lab_ex1\` 拷到**英文路径**下（避免任何工具踩中文路径坑）；
2. TD 6.2.1 → **File → New Project**：器件 `PH1P35MDG324`，速度等级 **-3**；
3. 按厂商 `.al` 的列表添加源码：
   - `user_source\hdl_source\` 整树（96 个 `.v` + 4 个 `.sv` + 12 个 `.vh` 等）；
   - `user_source\ip_source\`（IP 块：blk_mem_gen / divider / MCU 等，53 个文件）；
   - 约束：`user_source\constraints_source\pin.adc` 与 `timing.sdc`；
   - 顶层设为 **`design_top_wrapper`**；
4. 跑完整流程：**compile → map → place → route → bitgen** → 产出新 `.bit`；
5. 回到**方式 A** 烧录。

**红线**：
- `td_project\camera_to_dsi_display_Runs\` 里是厂商成功结果的留档（含 `best_result\readMe.txt`），
  不要删——那是"厂商成功过"的证据基线，不是垃圾；
- 后续从仓库挂视觉模块时：`*_stub.v` / `*_sim.v` 只属于仿真，**禁止加入 TD 工程**；
- 改代码后用 TD 重新跑时序报告确认（WNS≥0 再上板）。

---

## 五、上电验收判据（本步目标）

- [ ] 显示器 720p60 出图，画面为**摄像头实时图像**（移动摄像头画面跟着动）；
- [ ] QSPI 固化后：冷启动（拔 PC）15 秒内出图；
- [ ] 图像无明显花屏/错行（有则见下方排查表）。

---

## 六、故障速查

| 症状 | 先查 | 处置 |
|---|---|---|
| 完全黑屏 | 摄像头 I2C 配置是否完成 | 抓 SCL/SDA；传感器 ID 应读到 `EE4B/9E4B`；查排线方向与 `O_cam_rst`/`O_cam_24m` |
| 有数据无帧同步 | demosaic 的 tuser 链 | 见仓库《嵌入式教程（一）》第 5 节"界碑"复盘 |
| 图像花屏/错位 | DDR 帧缓存 | 确认没有改动分辨率连锁配置；查 DDR 供电与复位时序 |
| 颜色偏色 | AWB 自动白平衡 | **正常现象**；演示前锁曝光或切阈值组即可 |
| **颜色发灰、饱和度低** | 原版链路只有 demosaic+AWB，无 CCM/饱和度（结构性，非参数问题） | 烧**饱和度增强版**：双击 `burn_camera_sat_sram.bat`（当前 K≈1.75x）；仍嫌淡/过浓可改 K 重建（约 8 分钟） |
| 反复 `PRG-8000 Connect server failed` | 5555 上没有服务在听 | `netstat` 查 5555；手动启 hwserver **必须带 `-r`**（不带只开设备不开服务）；包内脚本已内置 |
| hwserver 报 `device not found` / `usb_open() failed` | 下载器未连接/未上电，或残留 hwserver 占着设备 | 检查 USB 数据线（不是电源口）；任务管理器杀光 hwserver 后重试 |
| HDMI 无信号 | 显示器/TMDS | 先烧自检彩条 bit 定位；查显示器 720p60 支持 |
| 上电后 15 秒无图，重上电有 | 上电时序 | 按"先显示器和摄像头、后主电源"的顺序再试 |
| **TD 打开工程报 `PRJ-8641 XML tag Project is invalid`** | 厂商 `.al` 与本机 TD 6.2.1 GUI 的工程文件格式不兼容 | 本包已修 4 类问题（裸 `&`→`&amp;`、`TD_Encoding` 标签、`::` 属性块、过期 `Path`），**GUI 仍拒绝打开**——已确认属版本/格式兼容问题，**不影响成品 .bit**；要重编译请按「方式 B」用 GUI 新建工程挂源码 |

---

## 七、关键参数速查

| 项 | 值 |
|---|---|
| 分辨率/帧率 | 1280x720 @ 60fps（SC520CS 原厂 HD 模式） |
| 摄像头 | SC520CS，MIPI 2-lane RAW10，MCLK 24MHz |
| 摄像头 I2C 地址 | 7bit `0x36`（8bit 写 `0x6C`） |
| 传感器 ID 校验 | `0xEE4B` / `0x9E4B`（`uicfgcs520` 读 CHIP_ID） |
| 显示输出 | HDMI（TMDS，720p60） |
| 器件/工具 | PH1P35MDG324（-3）/ TD 6.2.1；ModelSim SE 10.4（仿真用） |

---

## 八、相关位置（后续步骤）

- **烧录实战教程（本次实测全记录，含每步点击）**：本包根目录《`TD_burn_tutorial.pdf`》；
- 完整指导 PDF：本包根目录《video_passthrough_guide.pdf》；
- 仓库：`D:\fpga-ptz-tracker`（`08_board_bringup/01_video_passthrough/` 为本包源目录；
  教程源稿 `docs/td_burn_tutorial.md`）；
- 下一步（挂视觉模块、云台、OSD 与固化）：见仓库 `03_vision/`、`04_embedded/` 各步教程与评审卷宗。
