# SC520 亮度修正版：4×启动增益

根据“新版画面太暗”的反馈，将启动增益从 AG=16（1×档）改为 AG=80（4×档）。
此前从原版 AG=144（16×档）直接降到 1×，降低幅度过大；4×是待上板确认的中间值，不是自动曝光结果。
AE=1991、AWB 开启、饱和度 K=24 保持不变。源工程默认启动增益现为 80。

## 使用

在 `D:\SC520_display_burnpack\01_bitstream_flash_direct` 运行 `burn_codex_balanced_sram.bat`。
该脚本下载 `camera_to_dsi_display_codex_balanced.bit` 到 SRAM，仍需在实际光照下观察；本次未执行硬件下载。
已保留原厂位流，以及上一版 main/unity 位流；旧 main/unity 文件仍是 AG=16。

如果当前已运行上一版，可以先长按 KEY4 约 8 秒，从 AG16 提升到约 AG80；
从新 4×版继续长按约 4 秒可达到约 8×。太亮则用 KEY3 降增益。
时间是按 128 ms/级估算，会受按键和 I²C 事务节奏影响。复位后恢复各位流的启动默认值，不保存按键设置。

## 验证

- 曝光/增益按键回归：9 项通过。
- I²C 分组写入：原快照用例与新增 AE1991/AG80 用例通过；中途改变输入不影响当前事务。
- 4×档关键载荷：3e00=00、3e01=7c、3e02=70、3e09=09、3e07=80。
- 综合、布局布线完成，Setup WNS +356 ps，Hold WNS +20 ps。
- 位流与整套 user_source SHA256 对应关系已核对。

位流 SHA256：`be41095f908b97ffc16009c6c2f21901d84f931a1df24f27579e6015f2d790f6`。

## 重建

```powershell
python .\build_profile.py --profile balanced
```

如需固定 8×档，可用 `--startup-ag 112`；固定 16×档可用 `--startup-ag 144`。
AG 不是倍数值，不能直接填 4 或 8。`main` 与 `sat_bypass` 重建默认现为 AG80；`unity` 保留 AG16。
因此，做 AWB/饱和度对照时要显式给相同 `--startup-ag`，避免把增益差异当成颜色处理差异。
4×未必适合所有照明条件，若按 KEY4 提高增益后画面仍完全不变，应检查正在运行的位流、按键响应和 I²C 写入状态。
