# 阶段 16：配置写入边界、备份与失败重试

日期：2026-10-17（Asia/Shanghai）。本轮关闭阶段 15 留下的具体待查项：写出的文件和读入上限必须一致，且失败不改主文件、备份、预设或撤销记录。

## 复现与修复

三个真实文件回归先失败，见 [修复前输出](../../artifacts/validation/phase-16-write-red.txt)：超限候选保存返回 Ok，但再读取时被 8 MiB 上限拒绝；恰好 8 MiB 的紧凑有效 JSON 被美化后超过上限；有效紧凑备份恢复也写出不可读主文件。

最终 [窗口集成脚本](../../scripts/write-limit-smoke.ps1) 在 [旧发布包失败报告](../../artifacts/write-limits/write-65be932a41a64254805c824f5201b58b/report.json) 中同样复现：真实 F10 提示成功后，主文件和备份均超过读取上限，实例正常退出。没有操作日用配置。

[store.rs](../../src/store.rs) 现在采用同一 8 MiB 字节上限，保存前在内存中完成有限大小的编码：

- 普通配置继续输出格式化 JSON。若只因排版超限，重用缓冲并改用保留全部字段的紧凑 JSON；紧凑输出仍超限则明确拒绝，在修改主文件或备份前返回错误。
- 备份读取为同一份有界且已校验的字节快照，保留原格式和字节；恢复也直接写入经过校验的备份字节，避免重新排版造成超限。快照读取另有上限＋1的界限，防止文件在元数据检查后增长而不受约束。
- 唯一写入权、保护模式、原件保留和原子文件替换顺序保持。新文件写出前仍校验配置，只有持久化成功才发布内存状态及撤销记录。

[三个回归修复后通过](../../artifacts/validation/phase-16-write-green.txt)，覆盖超限候选的原文件／备份不变、恰好上限的紧凑配置可保存和重新读取、紧凑备份恢复后原件／备份字节保留。

## 实际热键及配置界面

[**28 条检查、5 次实际 F9、3 个实例正常退出**](../../artifacts/write-limits/write-c8e76606f483404b9bc111995a8ae8ca/report.json)。最终旧／新 EXE 使用相同脚本，SHA256 均为 `08B4FE43AD721D01E83FFB07C3C604C5825534F41255861B579FC79451F42111`。

| 场景 | 结果 |
| --- | --- |
| 近 8 MiB 的合法配置，实际 F10 成功更新 | 主文件仍在读取上限内，备份等于之前的主文件原字节，撤销可用 |
| 新建规则将超过上限 | 明确未保存；主文件、备份哈希和旧预设不变，仍可编辑；F9 使用旧预设 |
| 失败后撤销前一次成功 F10 | 撤销仍有效且不移动窗口；F9 使用撤销后的原位置 |
| 删除已核对的未使用预设后重试 | 规则创建成功且文件可读；F9 命中规则，撤销只删除该规则，再回退默认 |
| 普通重启 | 保持近上限配置原字节和可写状态，F9 仍恢复原默认 |

主文件成功更新／失败保存前后均为 8,388,480 字节，失败不轮换备份。三个状态快照的私有内存约 18.363 MiB；这是特定近上限样本的瞬时观察，不当作峰值或 60 秒空闲证据。


测试配置只在实例停止时准备：实际当前显示器和 fixture 预设不变，追加一个非活动的合成库存记录以填充大小，以及一个可删除的未使用预设。它不证明物理多屏、真实设备身份或实际安装过该合成应用。规则输入、删除及撤销为自有 GUI 消息；F10／F9 为持续核对前台的实际 SendInput，不将 GUI 消息操作当作键盘导航。

初轮脚本过严地要求删除预设时连应用容器一起消失，[该次报告](../../artifacts/write-limits/write-245129755cd64e1a88071f28dc445fb9/report.json) 保留且不计为最终通过。实际目标预设已删除并释放容量；最终脚本核对预设消失和文件缩小，不依赖是否保留空应用容器。应用代码没有为迎合这条错误断言而修改。

## 当前构建与回归

仍为 0.1.0 开发预览。环境：Win11 企业版 10.0.26300、普通权限、单屏 2560×1440／工作区 2560×1392、96 DPI。

| 工件 | SHA256 |
| --- | --- |
| [ZIP](../../dist/ScreenPin-0.1.0-windows-x64.zip) | `ADA930CA071E409C642382C29A3F73BC89F6C2C398D8521255F078B9F1A117DB` |
| Release EXE／解压 EXE | `CB13762CA387EBD7E84C17BDD5BB41785AC7BDB4AB2A9F86C41B2B2192367DFE` |

格式、严格 Clippy、all-targets **66 项测试**及离线构建打包通过。[嵌入清单](../../artifacts/validation/phase-16-embedded.manifest) 为 PerMonitorV2／asInvoker，[依赖检查](../../artifacts/validation/phase-16-dependencies.txt) 仅系统 DLL。旧构建完整状态见 [阶段 15 历史快照](phase-15-coverage.md)。

本构建 **17 项集成回归全部通过**，完整顺序、参数和退出码见 [执行记录](../../artifacts/validation/phase-16-suite.json)。当前原始报告均与新 EXE 哈希核对一致。

| 回归 | 当前证据 |
| --- | --- |
| 写入上限／失败重试 | [28 条、5 次真实恢复、3 个正常退出，紧凑写入与备份原字节、失败不丢撤销及重试／重启](../../artifacts/write-limits/write-c8e76606f483404b9bc111995a8ae8ca/report.json) |
| 配置恢复／大小边界 | [55 条，原有损坏／未来格式／替换故障与新增大小边界均通过](../../artifacts/recovery/recovery-874cd46f81b147cabf6e0accb6b26255/report.json) |
| 设置／预设草稿 | [55 条设置草稿检查](../../artifacts/settings-drafts/draft-db0367e5fa93431f801ee8d36e9a83a6/report.json)；[17 条编辑交错检查](../../artifacts/editor-races/editor-9390f2faf4cb42b9a4e75b517a7949fe/report.json) |
| 键盘／确认框／托盘 | [177 条、96 次焦点、62 条 UIA 样本](../../artifacts/keyboard/keyboard-974c822bd2b942faaad1c8bd5d218c6b/report.json)；[82 条／9 个对话框](../../artifacts/dialog-keyboard/dialog-ea429072df95421e8bacab7358195263/report.json)；[19 条](../../artifacts/tray-keyboard/tray-6cbd44c880af4d6996bf257d94f58353/report.json) |
| 真实热键 | [100 循环、最大误差 0 px；可见 p95 15.726 ms，完成反馈 p95 32.743 ms](../../artifacts/hotkeys/hotkey-20261017T080307820Z-0babf14a/report.json) |
| 生命周期竞态 | [3 场景／21 条，忙时拒绝、关闭和重建](../../artifacts/races/race-ce19e5694e814d6aa6ae2f9d3f43c2e1/report.json) |
| 设置事务／写入故障 | [93 条、14 次真实捕获／恢复、7 次正常退出](../../artifacts/settings/settings-b5bb0d2f672a4c2fb2e9875ab0883c8f/report.json) |
| ZIP | [34 条 GUI 断言、仅 EXE／README，解压哈希一致，无残留](../../artifacts/packages/package-8ee481994a634600ad5a9c480faf6a7f/package-verification.json) |
| 实际启动就绪 | [102 条；10 次已有配置实际就绪最大 308.789 ms，5 次首次键盘捕获最大 726.492 ms，16 次正常退出](../../artifacts/startup/startup-91a31eca431a415ea8ebe8c3d0b372b8/report.json) |
| Explorer／Terminal | [各 20 次 GUI 精度、9 条状态、7 条标题检查；18 次实际 F9 均 0 px](../../artifacts/shell-apps/shell-apps-36b9e1e4adb1452c8f3b85688b8f2c4d/report.json) |
| Brave／VS Code | [各 20 次 GUI 精度、50 次普通真实恢复及最大化转换，状态组共 104 次 F9；标题组共 22 条、14 次 F9、6 次 F10，全部 0 px；普通完成 p95 162.041／162.669 ms，含归属核验与轮询](../../artifacts/apps-phase-16-release/application-smoke.json) |
| 默认路径覆盖升级 | [26 条，7AB66FC9 → 当前 ZIP，独立中文／空格 LOCALAPPDATA，3 次恢复 0 px](../../artifacts/upgrade/upgrade-3b410679d8b94ab4864a01ad57b2d262/report.json) |
| 后台异常及循环 | [300 循环／600 次主要操作、逐轮 ≤2 px；暂停 264.238 ms 未确认，15 次响应观察；受限 203.944 ms；私有内存峰值 2.992 MiB，IdleSeconds=0](../../artifacts/backend/backend-52d5e4c49c33406eaedb571dfc6b43f1/report.json) |
| 空闲资源 | [60.833 s，CPU 增量 0.000 ms；托盘私有峰值 2.047 MiB、界面 2.047 MiB；启动消息循环代理 270.738 ms，正常退出](../../artifacts/performance/perf-20261017T080711035Z-c3e6c376/report.json) |

## 阶段结论与复现

阶段 15 的读写上限一致性待查项已关闭。当前已发现的相关功能缺陷均有修复和直接回归；后续外观与交互评估仍按用户顺序安排，优化后复测热键、焦点、键盘、可访问性、DPI 与资源。

原验收范围保持：真实多屏／混合 DPI、插拔及身份关联、跨屏最大化／自动隐藏任务栏、UAC 成功／取消／跨账号与接管故障、系统／Explorer 重启及自启登录、真实包升级、干净 Win11、Narrator、字体／高对比度和独立首次使用仍需 [实机操作单](manual.md) 所列条件。当前整体目标未完成，不把进入界面优化阶段视为发布验收通过。F01–F18 及所有限制见 [覆盖审计](coverage.md)。

```powershell
cargo test --locked --offline --lib write_size_
pwsh -NoProfile -File scripts/write-limit-smoke.ps1
pwsh -NoProfile -File scripts/recovery-smoke.ps1 -Oversized
```

先按 [构建入口](phase-6.md#回归与复现) 准备 Release 和原生 UIA 探针；PowerShell 7 正常桌面顺序运行，真实输入期间避免切换窗口。全部原始数据保留在私有测试目录，测试不更改真实 HKCU Run 或既有用户窗口。
