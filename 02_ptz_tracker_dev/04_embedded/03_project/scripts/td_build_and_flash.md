# TD 工程自动化与固化 Runbook（嵌入式方向）

> 状态：脚本基于 TD 6.2.1 TCL 习惯编写，**首次上机需按 SWUG101/TD 帮助校对命令名**。
> 目标：一条脚本从源码到 bit，一条命令固化 QSPI。

## 1. 工程组织

```
td_prj/                        # TD 工程（建议 E:\Anlogic\TD...同盘同结构）
  prj/prj.al                   # 工程主文件
  src/                         # 全部 RTL（见 scripts/filelist.f）
user_source/                   # 官方例程源码（lab_ex1 解包）
03_vision/04_embedded 的 rtl/  # 视觉与嵌入式新增
```

## 2. 文件清单（filelist.f，加入工程的源文件）

官方链路（lab_ex1 `user_source/hdl_source/`）：
- `design_top_wrapper.v`（或用 `04_embedded/03_project/rtl/system_top.v` 的对接版替换其视觉挂载部分）
- `isp/`（isp_top、demosaic 树、awb 树、BLC、data128_96、raw10/csi 解包）
- `mipi_dphy_rx/`（含 .enc，TD 内可解密编译）
- `ph1p35_ddr/**`、`hdmi_*.v`、`hdmi_mixer.v`、`vtc/`、`video_*.v`、`uics500_cfg/**`、
  `key_remove_shakes.v`、`pll_hdmi.v`、`ps_wrapper.v`、`mc_to_user_interface.v` 等
- **排除**：`03_vision/*/03_project/rtl/sim_video_src.v`、`frame_dump24.v`（仿真专用）
- **仿真专用替身**（仅 ModelSim 用，TD 工程**不加**）：
  `ph1p_logic_eram_stub.v`、`divider_gate_sim.v`

视觉与嵌入式新增：
- `03_vision/*/03_project/rtl/`：ser96to24、rgb2hsv、hsv_threshold、bin_smooth3x3、
  centroid_accum、detect_top、gimbal_ctrl、pwm_servo、osd_track、vision_top、
  font_rom_8x16（生成物）、pulse_sync、cdc_4phase
- `04_embedded/03_project/rtl/`：system_top（若采用对接版顶层）、uart_telemetry

## 3. TCL 骨架（td_run.tcl，TD GUI 的 Tcl 控制台或 batch 执行）

```tcl
# 工程与器件
set device PH1P35MDG324
prj_create -name vision_ptz -device $device -force
prj_add_files -file_list scripts/filelist.f
# 约束
prj_set_constraint -sdc  user_source/constraints_source/camera_to_dsi_display.sdc
prj_set_constraint -adc  user_source/constraints_source/pin.adc
# 全流程
compile -impl syn_1 ;# 综合
map    -impl syn_1 ;# 布局前映射
pnr    -impl syn_1 ;# 布局布线（出时序报告）
bitgen -impl syn_1 ;# 出 .bit
# 报告检查
rep_timing  -impl syn_1   ;# 关注 WNS ≥ 0
rep_resource -impl syn_1
```
> ⚠️ TD 各版本 TCL 命令名/参数以安装目录 SWUG 文档为准；本骨架为流程占位，
> 首跑时逐条核对（已知例程 run.bat 硬编码 E:\Anlogic 路径）。

## 4. 引脚约束增量（pin.adc 追加，脚位以原理图 40Pin DC3 空闲脚为准）

```
# 舵机 PWM（3.3V，独立 5V 供电共地）
set_pin_assign {O_pwm_x} -loc {XX} -io_type LVCMOS33
set_pin_assign {O_pwm_y} -loc {XX} -io_type LVCMOS33
# 阈值组/跟踪使能（按键或拨码）
set_pin_assign {I_btn_n[0]} -loc {XX} -io_type LVCMOS33
set_pin_assign {I_btn_n[1]} -loc {XX} -io_type LVCMOS33
```
（约束文件新增线网：O_pwm_x/O_pwm_y/I_btn_n[1:0]/O_uart_txd；clock 约束照例程 SDC 不动。）

## 5. 固化 QSPI（BitWizard，上电即运行）

1. TD → 工具 → BitWizard（或下载器界面）→ 器件选板载 QSPI Flash
2. 加载 `syn_1/vision_ptz.bit` → 转换/直接烧写 Flash（SWUG505 Boot Image Tool）
3. 烧写完成 → 断电 → 拔 USB → 重新上电 → **15 秒内应出图并进入跟踪**
   （视觉参数全部固化于 bit，冷启动即 LOCK 待目标）
4. 验证"拔 PC 运行"：显示器独立供电，整箱上电，无 PC 参与

## 6. 上板联调检查点（按序，每步过了才下一步）

1. 例程原样跑通出图（未挂视觉前）
2. 挂 detect_top（旁路）：画面无任何变化 + ChipWatcher 见 t_valid/tick
3. 挂 OSD：屏幕出现 TRK0 文字与框
4. 接舵机独立电源：duty 变化时画面稳定（不稳=供电问题）
5. 固化 → 冷启动验收

## 7. 已知仿真/上板差异清单（来自仿真迭代，上板先查）

- demosaic tuser 链（本仿真不激活）→ 上板无帧同步先查这里
- divider_gate 为门级网表 → 时序报告关注该路径
- AWB 对色彩目标的影响 → 演示前锁曝光或切阈值组
- 例程时序未收敛到正裕量为官方已知现象
