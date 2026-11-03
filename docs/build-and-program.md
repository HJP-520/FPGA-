# 构建与下载

## 新下载的工程

建议解压到纯英文、无特殊字符路径。安装TD 6.2系列及USB/JTAG驱动，设置 `SC520_TD_ROOT`；安装Icarus后设置 `IVERILOG_BIN`。Python依赖安装命令与完整构建顺序见根目录README。

TD入口是 `project/td_project/camera_to_dsi_display.al`，顶层 `design_top_wrapper`。只有这一套生产工程。文件名继承早期项目命名，当前实际使用HDMI与DDR2。

自动构建脚本在空工作副本中从 `_build/templates/` 准备运行目录，并复制Logo、字体、空间补偿ROM数据。`*_Runs/` 属于生成物，不纳入版本控制。

1. `python scripts/prepare_sim.py` 在仓库根目录运行，生成三组合成测试向量。
2. 在 `project/` 运行 `_build/verify_current.py`，收集与当前源码哈希匹配的41项RTL结果。
3. 运行 `_build/build.py syn`，再运行 `_build/build.py phy 9 0.350`。
4. 运行 `_build/release_current.py 9`。导出入口要求源码、验证、物理结果、约束与时钟签名一致。

原始发布使用布局种子9，附加建立时间不确定度0.350ns，随后恢复签核约束。不同TD版本、安装环境和种子可能产生不同位流；不要把重新生成文件冒充原SHA256固件。

## 下载仓库中的固件

```powershell
$env:SC520_TD_ROOT = 'D:/TD6.2.1'
.\scriptsurn_sram.cmd
```

`scripts/burn_sram.cmd` 只下载 `firmware/SC520_view_manual_v17.bit`，先核对固定SHA256，再调用下载工具。也可设置 `TD_BIN` 直接指定TD的bin目录。

该脚本为 **SRAM下载**，掉电后丢失；未提供Flash固化脚本。烧录前接好USB/JTAG并供电。USB警告或传输日志不能代替肉眼确认实时画面和按键功能；发生下载错误先检查线缆、驱动、hwserver与芯片识别。

原发布固件SHA256：

```text
e0c147ed5133b1bdc336799fa405b0aab4d65b9b33572a5eb34633a473f3b020
```

下载新构建固件时，使用TD界面明确选择 `project/outputs/release/SC520_view_manual_v17.bit`，并核对本次生成的manifest；本仓库快捷脚本仍固定指向原发布文件。
