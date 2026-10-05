# 05_isp_interface —— 第 2 批：接口修复与异常帧防护（2026-10-05）

落实外部评审（ChatGPT 复审）的 **#2 / #4 / #5 / #8** 与 Section-1 的两条更正。

## 改动清单（三处工程源码同哈希）

| 文件 | 改动 |
|---|---|
| `isp/data96_128/data96_128.v` 内 `data_96bit_to_128bit` | **评审#8**：气泡保相位（`valid=0` 不再清 `S_cnt`，仅帧首复位；新增 `cnt_eff` 帧首强制相位 0）；**评审#4/#5**：tlast 在 repack 内重建（新增 `I_96b_tlast`/`O_128b_tlast`，与 `O_128b_valid/O_128b_data` 同拍）。行长为 4 拍整数倍（720p 行 320 拍）时 tlast 恒在相位 3 |
| `isp/isp_top.v` | `repack` 的 tlast 端口接入；`O_tlast = repack_O_tlast`（与 `O_tdata/O_tvalid` 同拍，取代第1批的 `sat_O_tlast` 过渡方案）；新增 `I_frame_bad` 端口透传 AWB |
| `design_top_wrapper.v` | **评审#2**：新增按帧锁存坏帧标志 `S_frame_bad = S_mipi_last_length_error \| S_mipi_last_line_error \| S_mipi_last_lane_error`（frame_end 发布、稳定一整帧）；`video_in.I_mipi_rx_error` 由 `1'b0` 改为接入；`isp_top.I_frame_bad` 接入 |
| `awb.v` | **Section-1 更正**：采样数上下界 **20480 < beats < 300000**（防短帧/空帧 + 防漏 SOF 并帧：720p 并帧 460800 必拒）；**近黑剔除** `rgb_sum > 45`（低照度噪声驱动比值病态）；**frame_bad 门**（坏帧不更新 prev 统计）。声明上移至使用之前 |
| 顺带件 | 三个 `burn_*.bat`：烧录后 `findstr` 校验"PRG-2014"（失败即报错退出）+ 烧前打印文件与 MD5 + 文案更正；`sat_tool.py`：check 模式帧尺寸严格校验；`px_serializer_fifo.v`：`\$clog2` 参数化 + 溢出计数语义更正为"被反压拍数" |

## 验证（仿真先于上板）

**新 TB `tb_repack.v`（本目录）**——post-repack 记分板（评审指出的验证缺口）：

```
CHECK OK [P1 no-bubble]: 字流逐字一致 (24 字) / tlast at row-end words {5,11,17,23}
CHECK OK [P2 bubble@phase1/2/3/0]: 同上（气泡注入 4 个相位输出与无气泡完全一致）
CHECK OK [P4 back-to-back frame2]: 同上
TB_RESULT: PASS  (0 fail)  repack hold-phase + tlast rebuild verified
```

**`tb_awb.v` 扩展**（本批边界相位；共 **38/38 CHECK OK + PASS**）：

| 相位 | 判据 |
|---|---|
| G1/G2 | 20480 拍**拒**采信 / 20481 拍**采**信（判别性设计：误采信会以 3.0x 方向步进暴露） |
| H | 高亮非中性（sum=730>720）剔除；近黑非中性（sum=40<45）剔除 + 过下界对照（80）采信 |
| J | 超长帧 310000 拍（> 上界）拒（对应 720p 漏 SOF 并帧 460800 的保护） |
| K | frame_bad=1 的"上一帧坏"拒采信；下一帧恢复采信 |
| L | 帧中复位 → 增益精确回 0x10000 |

复现：双击 `run_tb.bat`（本目录）；AWB 侧 `../04_awb_framesync/run_tb.bat`。

## 重建与上板

- 重建：`03_td_rebuild_sat/lab_ex1_build` 两段无头流程；**final 时序 Setup WNS +143ps / TNS 0 / 0 违规端点，Hold +20ps / 0**；
- 产物：`camera_to_dsi_display_sat_k28_awbfs_b2.bit`（md5 `f1e3b561…`；本目录 + 投放包 01，投放包 sat 脚本已指向它）；
- 上板状态：✓ **已烧录（2026-10-05）**：`PRG-2014 Chip validation success` + 返回 0；
  待现场目视：① 正常出图；② 色彩稳定（第1批目标）；③（可选）断/接信号源观察异常帧防护。

## 与卷宗 v1.1 的对应

`docs/burnpack_review.pdf`（v1.1）已同步本批全部内容与更正后的表述（7.1/7.2/7.3 更新），
可直接发外部复核。
