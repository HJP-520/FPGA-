# SC520：JTAG 实时状态调试版

独立候选位流已生成，并带有匹配的 ChipWatcher `.cwc` 配置文件。保持摄像头→HDMI 正常画面，按键功能不变。
启动 AE=1991、AG=80（本工程表的 4×档）、AWB 开启、饱和度 K24。生产源工程和此前候选位流没有被改成调试版。
新增调试端口与六个采样核只存在于 `04_codex_validation/work_build/jtag/lab_ex1` 隔离工程。
2026-10-05 已经 SRAM 下载并完成六组真实板上采样；用户确认有画面，但仍偏暗。未写入 QSPI Flash。

## 与现有 debug 页面的区别

`hdmi_mixer.DEBUG_MODE=4` 原本输出整屏诊断颜色，提示 MIPI/I²C 故障类型，无法给电脑读 AE/AG。
本版保持 DEBUG_MODE=0，由安路 ChipWatcher 通过现有 JTAG 下载器捕获内部状态，无需新接 UART 引脚。
首次启用必须切换到本版位流，会重新启动通路并恢复默认 AE/AG；无法无损继承现在板上通过按键调好的数值。

## 使用 TD 实时观察

1. 使用 `01_bitstream_flash_direct/jtag_debug`（压缩包内为 `01_bitstream_flash_direct`）的匹配 `.bit`、`.cwc` 和 `.bid`。同一目录只放一个 `.bit`，避免 Watch 无法自动选定位流。
2. TD 6.2.1 菜单 Tools → Debug Tools → ChipWatcher，使用离线导入方式打开 `camera_to_dsi_display_codex_jtag.cwc`，随后进入 Watch。
   也可打开隔离工程 `04_codex_validation/work_build/jtag/lab_ex1/td_project/camera_to_dsi_display.al` 查看构建结果。
3. 确认可以中断当前显示后，再下载匹配位流。可使用 `burn_codex_jtag_sram.bat`，或 ChipWatcher 的下载按钮。
4. Debug Server 选择 AL-LINK-FT(Remote)，添加 `127.0.0.1:5555` 并 Apply（已有 hwserver 时使用这一方式；重复打开本地 USB 会显示 OCCUPIED）。每组实例先用绿色加号添加探针，再点 Instant Trigger 获取一次快照；等待返回 Idle 和波形显示完成。Continue Trigger 可连续刷新当前实例。
   采样时不会通过探针回写曝光/增益，六个实例各自使用本地时钟，深度1024，输入/输出管线各1级。
5. 按 KEY3/KEY4 改变增益，观察 `dbg_ag` 是否变化；再检查 `dbg_cam_flags` 中 I²C 错误位。
   若只是查看已经运行的匹配调试位流，用触发采样即可，不必再次下载。

| 实例 | 探针（按 probe0 起依次排列） | 含义 |
|---|---|---|
| u_sc520_watch_camera | dbg_ae、dbg_ag、dbg_sensor_id、dbg_cam_flags | 当前 FPGA AE/AG 控制值、传感器 ID、配置/事务状态 |
| u_sc520_watch_awb | dbg_awb_r_gain、dbg_awb_b_gain、dbg_awb_stat_beats、dbg_awb_total_beats | R/B Q16 增益、当前累计合格样本和总拍数 |
| u_sc520_watch_mipi | dbg_frames、dbg_lines、dbg_mipi_flags | CSI 帧尾计数、当前帧行计数、上一个完成帧的错误标志 |
| u_sc520_watch_write | dbg_overflow_count、dbg_frame_overflow、dbg_previous_overflow | 写 FIFO 溢出事件计数、本帧及上一帧溢出状态 |
| u_sc520_watch_read | dbg_underflow_count、dbg_read_corrupt | 显示读空事件计数、当前损坏帧置黑状态 |
| u_sc520_watch_ddr | dbg_ddr_flags | 校准完成、用户接口 ready、写忙状态 |

`dbg_cam_flags[4:0] = {cfg_done, ae_done, ae_req, sensor_id_ok, iic_error}`。
`dbg_mipi_flags[3:0] = {frame_done, last_line_error, last_length_error, last_lane_error}`。
`dbg_ddr_flags[2:0] = {calibrated, user_ready, write_busy}`。
AWB Q16 除以65536即倍数；AG16/48/80/112/144/176 分别对应表中的1/2/4/8/16/32×档。
读空/溢出计数饱和于65535。帧计数自然回绕；不同实例的快照不是全板原子快照。
采样深度1024不是完整视频帧缓存；不会通过 JTAG 导出完整图像。

## 当前能读什么

AE/AG 探针是控制器当前输出的写入值，**不等同于从传感器 3e00..3e09 寄存器重新读取的确认值**。
传感器 ID 是已有 I²C 读取结果，I²C 错误位可辅助检查事务；本次没有加入通用传感器寄存器读回命令。
实际 USB/JTAG 已通过板上波形确认。下载混合输出中的 `usb_open() failed` 对应额外的本地打开尝试；现有 Remote hwserver 的下载及采样成功。I²C error 是历史锁存位，仅复位清零，不能用于区分当前和此前事务错误。

ChipWatcher 图形界面提供连续采样；本次提供的 Python 工具读取它导出的 CSV，不是可无人值守直接操作下载器的 JTAG 服务。
将波形值设为 Unsigned Decimal，再通过 File → Export Wave Data 导出各实例 CSV，例如：

```powershell
python .\decode_debug_csv.py camera.csv awb.csv mipi.csv --radix decimal --output debug_snapshot.json
```

默认导出为二进制时使用 `--radix binary`；默认导出为二进制时使用 `--radix binary`；如果导出的是十六进制，显式使用 `--radix hex`，避免把AG的50(hex)误读为50(dec)。
导出 CSV 后可以读取实际曝光/增益和故障状态，作为保存当前满意参数的依据；截图颜色无法替代这些数值。

## 验证与复现

- 新增观测端口的 AWB 边界11项、FIFO恢复10项、I²C快照测试通过。
- 完整 ISP 行突发仿真：3帧、691200 RAW拍、518400输出字、2160行尾，通过。
- 六个实际采样核和顶层 JTAG hub 已生成；最终构建日志未发现 ERROR。
- Setup WNS +44 ps；Hold WNS +20 ps。
- Slice 占用83.24%，高于4×正常版的63.88%；本版作为临时诊断候选，正常使用可回到非调试位流。
- 位流与匹配 `.cwc`、源码哈希已记录；已在当前板子验证实时采样；亮度仍需调校。

```powershell
python .\build_profile.py --profile jtag
```

需现有 TD 6.2.1 及授权。具体原理与界面依据本机官方手册 `D:/TD6.2.1/doc/SWUG/SWUG111_Debug_Tools_User_Guide.pdf` 的2.2.1与2.4/2.5章节。
可用 `--startup-ag` 指定16..176档，重新构建与之匹配的位流和探针配置。

bit SHA256：`94a0cf81189efa4046f0246d2e8eeb50a57fa080ef20563bcef68795fc03efc9`。
cwc SHA256：`8d98b290f2e3d9568f8362867cb22f1dc48b3833eb2394aeb415e3353b3aaab7`。
