# SC520 中心泛绿：公开案例与工程处理方案

日期：2026-10-05。范围：联网调研、源码对照及下一步设计建议；本轮未改 RTL、未重新下载、未更改当前 AE/AG。

## 判断及适用条件

若绿斑平滑、固定在图像中心，并在均匀灰白目标上仍然存在，优先检查空间颜色不均匀（colour shading），再检查饱和度放大及黑电平问题。若绿环跟着灯光位置移动，则优先排查镜头/滤光片反射和强光裁剪。当前没有直接取得用户的原始图像，不能确认属于哪一类。

本轮未找到可核验的“SC520CS + PH1P35，同一绿心现象并已修复”的公开实例。其他传感器案例能提供方法，参数和标定表不能直接搬用。

## 公开依据

1. [Arducam 官方 Lens Shading Calibration](https://docs.arducam.com/Raspberry-Pi-Camera/Native-camera/Lens-Shading/) 有标定前后示例，解释更换镜头后边缘粉色/洋红及镜头匹配补偿表。
2. [OV5647 + LN001 用户及厂家排查](https://forum.arducam.com/t/lens-shading-issue-with-ov5647-arducam-and-ln001-lens/11685) 描述绿/粉渐变；厂家讨论针对镜头与传感器组合生成 shading 标定的必要性。这是相关案例，不是 SC520 的故障证明。
3. [Raspberry Pi Camera Algorithm and Tuning Guide](https://datasheets.raspberrypi.com/camera/raspberry-pi-camera-guide.pdf) 将亮度和颜色 shading 分开处理，并使用 R/B 相对 G 的校正表。PDF 本轮直接打开失败，相关段落由网页索引返回；实现另可查 [官方 ALSC 源码](https://github.com/raspberrypi/libcamera/blob/main/src/ipa/rpi/controller/rpi/alsc.cpp)。
4. [TI 光晕案例](https://e2e.ti.com/support/sensors-group/sensors/f/sensors-forum/1220704/does-ti-isp-support-light-halo-suppression-at-night) 中 TI 工程师指出亮点周围绿环已存在 RAW，说明光学/采集端也可能产生绿光晕。

## 当前工程的可核验事实

实际 JTAG 隔离工程：`D:/SC520_display_burnpack/04_codex_validation/work_build/jtag/lab_ex1`。

- `user_source/hdl_source/design_top_wrapper.v:4`：SAT_K_Q4=24，即1.5×；`:742` 例化 ISP；`:913` DEBUG_MODE=0。
- `user_source/hdl_source/isp/isp_top.v:59`：BAYER_MODE="BGGR"。实际连接依次为 demosaic、data128_96、awb、saturation、96→128重排，没有空间 shading 校正或 CCM。Gamma 模块存在但未例化。
- `isp/awb/awb.v:252` 附近的 `in_r_r1/in_b_r1` 是整帧公共增益，`:341` 起对所有像素使用同一组 R/B 增益，`:423` 起输出。不能分别平衡中心和边缘。
- 饱和度 `sat_ch` 计算 `Y + K*(C-Y)` 并裁剪；K24会扩大已有色差，仍需对照实验判断它放大了多少。
- 生产工程 `isp/demosaic_4x_2_0/mipi_to_raw_converter.v:50` 将 RAW10 四像素取高8位；若后来加 RAW 校正，应放在这个截位之前。
- `image_correction.v` 实际是裁剪/时序逻辑，不能按模块名字认为工程已有镜头颜色校正。
- 最近保存的 AWB R/B 约1.023×/1.085×，仅为此前场景的全局增益。全局数值接近1不能排除空间偏色；MIPI/FIFO状态也不能证明颜色正确。

## 最小验证顺序

1. 保持当前满意的 AE/AG，填满画面拍摄均匀、无反光、不过曝的灰白目标。分别换场景、转动相机、避开直射灯光，观察绿区是否固定在图像坐标中心。需要时用显示器自检或另一信号源纯灰画面排除显示器自身色不均。
2. 生成独立 K16 对照版，其他参数不动，比较同一场景。K16下仍有固定绿心，说明需要继续检查前级；明显减轻说明饱和度参与放大，但不能直接证明传感器/镜头没有偏色。本轮尚未生成或下载这个对照版。
3. 在去马赛克之后、AWB之前测中心和四角的 RGB 累计值和样本数；条件允许再加 RAW R/Gr/Gb/B 分区统计。避开近黑、饱和及无样本区，多帧平均。若 RAW 就有同样的空间比值变化，支持光学/传感器端 shading；若只在 demosaic 后出现，则检查 Bayer 相位和插值。
4. 对比各区 G/R、G/B；先只比较相对空间差异，避免把照明总体色温误当作 shading。固定全局增益不会改变中心/边缘的比值比，因此可利用这一性质区分全局 AWB 和空间偏色。

## 推荐实现（确认空间偏色后）

先实现离线标定、静态系数表，默认校正系数全1，并保留旁路。当前调试位流已用83.24% Slice，不能未经重新综合布线就保证新增模块能塞入。

诊断阶段可用中心及四角5个区域；标定阶段建议扩为8×6网格（720p每格160×120）。每格记录通道和/有效样本数，通过JTAG读取**帧边界锁存且带帧序号**的统计快照。已有JTAG只读全局状态，不能导出整帧图像，也不能直接生成空间校正表。

若以 G 为参考，定义每格 `qR=mean(G)/mean(R)`、`qB=mean(G)/mean(B)`，取参考比值 `qR_ref/qB_ref`，则颜色校正系数可选 `cR=qR/qR_ref`、`cB=qB/qB_ref`。这使各区色比趋于一致，剩余全局白平衡交给 AWB。若 G 较高，既可以增加 R/B，也可通过公共缩放降低 G，须根据高光余量选择；不能预设中心 G 一定应减10%。

系数必须平滑插值，避免网格边界块状色差。应支持小于1的系数、足够乘法位宽、舍入和饱和，并在帧首切换表。第一版只校颜色，亮度阴影单独调，减少无必要的角落噪声放大。

长期建议放在 RAW10 截位/去马赛克前，按实际图像 x/y 奇偶处理 R/Gr/Gb/B，四像素并行。黑电平要先确认传感器内部是否已校正，不能直接再次减现有BLC默认15；工程的四lane也不能直接等同于固定四种Bayer颜色。若为了快速验证在 RGB 域做空间校正，应放在AWB/饱和度前，并承认已经裁剪或截位的细节无法恢复。

验证至少覆盖：全1旁路逐拍一致、气泡不推进x、SOF重同步、行尾/帧尾对齐、连续行/帧、每lane坐标和颜色相位、极值及裁剪、网格边界连续性、表切换只在帧首。通过后才产生匹配JTAG候选，板上对照多种光源和灰白目标。

普通场景含有绿色物体，直接让算法不断把每区RGB强制拉成灰会改变真实物体颜色。自动空间校正需另外设计可信度和照明约束；静态标定是目前更容易核验的起点。
