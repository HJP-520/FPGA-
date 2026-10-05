# 迭代记录 —— Step4 OSD 与系统联调

## 迭代 1：目标包宽度不一致（本步骤最大缺陷）
- 现象：OSD 永远显示 LOST、云台 duty 恒 1500 不动；OSD 文字区 2260 像素 X 值污染
- 根因链：vision_top 拼 69bit → 截断成 67bit（valid 位丢失）；TB 侧 67bit 接 68bit 端口
  （MSB 悬空 Z）；osd_track 按 67bit 解包。三处三个宽度。
- 修复：统一 68bit，全部位偏移重排（tv=[67] preset=[66:64] cx=[63:53] cy=[52:42]
  minx=[41:31] maxx=[30:20] miny=[19:10] maxy=[9:0]），冻结进 IF-VISION.md
- 修复中发现连带 bug：word 分支仍判断旧位 [66]（现 preset 位）→ 显示 LOST 但坐标
  数字正常（数字用的是 [67]）。一字符修复。

## 迭代 2：坐标文件字段溢出
- 现象：包围框画到 (72,18)、十字错位
- 根因：osd_coord.txt 的 y0/y1 用 %02X 写 300 → "12C" 3 字符，TB $fscanf 按 %2x 读
  → miny=18、maxy=209
- 修复：生成器全部 y 字段 %03X，TB fscanf 同步（此类 bug 共 3 处：osd/chain/centroid exp，
  根因同一——hex 字段宽度纪律缺失，已写入方法论）

## 迭代 3：tb_vision_top 采样过早
- 现象：duty 恒 1500 判 FAIL，实际云台 2 帧后正常动作（检测→除法→CDC→消费 ≈ 2 帧滞后为设计行为）
- 修复：采样点移至第 4 帧末，转储 5 帧
- 结果：duty=(1428,1500)（X 朝目标动 −36×2，Y 死区保持）✓

## 验证终态
- tb_osd_track：整帧 921600 像素与金标准逐位一致
- tb_vision_top：OSD 帧 + 云台方向/死区/丢失断言全过 + 直通零扰动
- tb_closed_loop：36 帧锁定（相机-舵机模型在环）
