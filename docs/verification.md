# 验证与发布证据

生产目录的215个文件与2026-11-01最终v17工程逐字节SHA256相同，固件仍为原发布文件。目录整理没有改变RTL、ROM或管脚约束。

`docs/evidence/implementation.json`给出原发布结果的必要摘要及对应原始文件SHA256；不收录包含内部绝对路径的完整日志。生产源哈希见 `production_sha256.json`，固件精简发布清单见 `firmware/manifest.json`。

| 指标 | 原发布结果 |
|---|---:|
| Slice | 20068/21216 |
| ERAM | 71/108 |
| DSP | 28/40 |
| 寄存器 | 17964/42432 |
| Setup/Hold WNS | +250ps / +20ps |
| STA覆盖率 | 95.53% |
| 固件大小 | 1789493字节 |

原发布有65个具名RTL通过记录，其中依赖哈希一致时复用了此前结果。当前开源整理包去掉历史RTL对照实现及其差分测试，保留41个只依赖当前设计的测试任务；这41项提供可运行入口，不能直接声称本次已完整重新通过。历史测试总数不等于上板次数。

在仓库根目录执行 `python scripts/prepare_sim.py` 后，进入project运行 `python _build/verify_current.py` 执行完整41项。`--list`列出任务，`--test SERVO_PWM`可运行子集；子集结果单独写入verification_subset.json，不能替代完整导出所需的verification.json。

导出入口检查当前套件清单哈希、完整41项结果、生产源、依赖、约束及物理签核一致性。生成数据和运行结果位于被忽略的outputs与测试向量目录，不进入仓库。

RTL存储使用行为模型，厂商加密RAM模型和完整门级时序动态验收未完成；机械精度、功耗和端到端延迟尚未统一测量。原固件清单的programmed与board_verified保持false，不能把软件签核视作本次上板验收。
