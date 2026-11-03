# 第三方内容与许可范围

完整工程包含厂商IP与板卡参考例程。根目录MIT许可只覆盖独立开发内容与新增修改，不覆盖这些第三方内容；未删除原版权头，也未将其标为原创。

## 安路 Anlogic

`project/user_source/ip_source/`及 `hdl_source/`内的DDR2、PLL、FIFO、ERAM等生成模块含Anlogic版权头或厂商原语。使用依赖Tang Dynasty和器件库，适用厂商工具/IP条款。不能将MIT许可解释为对厂商IP或工具的再授权。

## 米联客 MiLianKe

CSI解包、视频时序和相机配置等基础模块含MiLianKe版权头，包括：

- `hdl_source/csi_unpacket.v`
- `hdl_source/isp/csi_unpacket_2lane.v`、`isp/raw10_unpacket_2lane.v`
- `hdl_source/uiisp_beta/`中的解包参考文件
- `hdl_source/vtc/uivtc.v`
- `hdl_source/uics500_cfg/`中的相机与I2C模块

这些文件位于 `project/user_source/`，保留原作者、网站、学习用途说明及all rights reserved声明。现有本地交付材料没有提供统一、明确的第三方开源再分发许可证。公开完整副本前需确认相应授权，不能把文件可获得等同于MIT授权。

## 图形与商标

视频Logo、ROM图形和参考资料中的商标权利归原权利人，软件许可不授予商标权。实机图来自作品演示视频。

未打包厂商工具可执行文件或安装包。
