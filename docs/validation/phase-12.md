# 阶段 12：设置草稿与实际热键保持一致

同一构建的浏览器／编辑器真实热键状态补充验收见 [阶段 13](phase-13.md)。

日期：2026-10-17（Asia/Shanghai）。本轮修复设置页未保存输入被后台响应清除的问题；功能和稳定性验收继续进行，集中外观与交互打磨安排在其后。

## 复现与修复

同一最终脚本在 [旧构建失败报告](../../artifacts/settings-drafts/draft-1aade38db0094b44ad2ac383552184e3/report.json) 中复现：输入 F7／F8 并勾选尚未保存的自启草稿，实际 F9 后表单被重置，持久配置并未改变。旧 EXE SHA256 为 `0590ECE2CF3E276533F952F4AB4F614D5AB6A3B99CA6BE7ECB3030F8C3E5A715`。

[shell.rs](../../src/shell.rs) 在重建控件前保留热键原始文本及自启勾选。后台恢复、无变化更新、刷新、查看其他方案以及无关预设更新继续保留输入；只有明确保存成功或恢复备份改变实际设置时载入权威值。保存注册冲突或写盘失败保留输入供重试，实际注册状态仍反映旧映射。处理操作期间和配置保护模式中，设置字段与保存一起禁用，防止已接受的保存覆盖继续输入的新草稿。

没有改变持久格式、注册事务或配置提交顺序；只增加临时表单状态。设置输入与实际已生效热键明确分离，原有“持久化成功才发布新映射”约定保持有效。

## 专项证据

[最终 Release 报告](../../artifacts/settings-drafts/draft-8a708a59bc9f48448990f1518749ad8f/report.json)：**55 条检查、3 次实际热键完整循环、4 个实例正常退出**。旧版与新版使用相同最终脚本，SHA256 均为 `E7A6D31993C4CE2E9685685BACBBCD004DB0986808C7592304C13D5D6890F9C7`。

| 场景 | 结果 |
| --- | --- |
| 实际 F9、无变化 F10、刷新、查看离线方案再返回、无关预设更新 | 热键原始文本和勾选草稿保留；主文件及实际映射仍为旧值 |
| 重复热键／第二键被 fixture 占用 | 拒绝保存，草稿可重试；新增临时注册释放，旧实际热键仍有效 |
| 主文件被测试独占限制替换 | 已接受保存失败，保留原文件字节与草稿；旧 F9 实际恢复有效，拟用新键仍可注册 |
| 暂停目标，真实 F9 处理期间强制提交保存 | 整组设置控件禁用；命令被拒且没有排队，未确认响应及迟到放置均不提交草稿 |
| 解除故障后明确重试 | 只提交 F7／F8 与自启关闭；旧键释放，新键实际捕获／恢复通过；普通重启载入提交值 |
| 损坏主文件后从备份恢复 | 保护模式字段禁用；恢复后表单及实际映射同步到备份的 F11／F12，完整循环通过 |

字段编辑和方案选择使用自有 GUI 消息，F9／F10 及改绑后捕获／恢复使用实际 SendInput，持续核对自建窗口前台；不将消息编辑当作键盘导航证据。离线方案通过停止实例后编辑私有 JSON 准备，只证明查看切换时的全局表单保留，不证明物理多屏。自启勾选仅作未提交草稿，任何实际保存前均清除；真实 HKCU Run 前后相同，没有启用自启或改变日用配置。备份恢复也只操作测试私有目录。

## 当前构建与回归

当前仍为 0.1.0 开发预览。环境：Win11 企业版 10.0.26300、普通权限、单屏 2560×1440／工作区 2560×1392、96 DPI。

| 工件 | SHA256 |
| --- | --- |
| [ZIP](../../dist/ScreenPin-0.1.0-windows-x64.zip) | `1DECF740817DF6B7E3B41FC20573FD2F685D6EA89CDD347DC0E76C865DB188C0` |
| Release EXE／解压 EXE | `734960C2508A2A45B2A6108AFD57FB4256D74AE133350427F7145F0FA4D5B41B` |

格式、严格 Clippy、all-targets **62 项测试**及离线构建打包通过。[嵌入清单](../../artifacts/validation/phase-12-embedded.manifest) 为 PerMonitorV2／asInvoker，[导入依赖](../../artifacts/validation/phase-12-dependencies.txt) 保留系统 DLL 检查证据。旧构建覆盖保存在 [阶段 11 历史快照](phase-11-coverage.md)。

回归中保留了 [一次启动探针失败](../../artifacts/shell-apps/shell-apps-4ce3305b24cb49e3a1f3ee85045e2a77/report.json)：脚本发现顶层窗口后立即读取结果控件，50 ms 有界读取超时就中断，同时尚未记录 host 句柄，导致退出命令没有发给实例。随后独立核对实例路径与私有配置、读取到就绪状态并用已验证 host 的退出命令关闭。没有结束用户窗口或共享宿主。脚本现在先保存发现的自有句柄，检查结果控件存在，并在启动总期限内仅重试读取超时；其他异常仍失败。最终完整应用报告单独记录，不把失败报告算作通过。

本构建 **16 项回归最终全部通过**，顺序、参数、失败尝试与退出码见 [执行记录](../../artifacts/validation/phase-12-suite.json)。

| 回归 | 当前证据 |
| --- | --- |
| 设置草稿 | [55 条检查、3 次实际完整循环、4 个实例正常退出](../../artifacts/settings-drafts/draft-8a708a59bc9f48448990f1518749ad8f/report.json) |
| 预设草稿 | [17 条检查，冲突拒绝、无关更新和忙时保存继续通过](../../artifacts/editor-races/editor-38fe40cc94694ba9aa31eddd244b1b61/report.json) |
| 键盘／确认框／托盘 | [177 条、96 次焦点及 62 条 UIA 样本](../../artifacts/keyboard/keyboard-ab8ef03090cc4982a398e4761fb8c59f/report.json)；[82 条／9 个对话框](../../artifacts/dialog-keyboard/dialog-e971748d419d419baa3d76cbf7468e75/report.json)；[19 条](../../artifacts/tray-keyboard/tray-ca1adf1e79d5455b9822278e4a9d5733/report.json) |
| 真实热键 | [100 循环、最大误差 0 px；可见 p95 15.741 ms，完成反馈 p95 32.477 ms](../../artifacts/hotkeys/hotkey-20261017T072336180Z-bfefb823/report.json) |
| 目标生命周期 | [3 场景／21 条检查，忙时拒绝、关闭与重建保持安全](../../artifacts/races/race-1474c4c3dede4853814fcff4a48e92bd/report.json) |
| 设置事务／恢复 | [93 条、14 次真实捕获／恢复及 7 次正常退出](../../artifacts/settings/settings-57f5a8901d124b84925c1ac6bfe922cf/report.json)；[33 条保护恢复检查](../../artifacts/recovery/recovery-47dff1caf1a742c2befc8f4283335c4c/report.json) |
| ZIP | [34 条 GUI 断言，解压哈希一致，仅 EXE／README，无残留](../../artifacts/packages/package-a9f48db8e4a1416ab66a1ec5fca252a5/package-verification.json) |
| 启动 | [102 条；10 次已有配置实际就绪最大 393.344 ms，5 次首次键盘捕获最大 658.668 ms，16 次正常退出](../../artifacts/startup/startup-039457369c1a4b699027f7f8d8ac4adb/report.json) |
| Explorer／Terminal | [各 20 次 GUI 循环、9 条状态及 7 条标题检查，18 次实际 F9 恢复均 0 px，测试窗口正常关闭](../../artifacts/shell-apps/shell-apps-f66c145895fe4b19a866d76dc25a2509/report.json) |
| Brave／VS Code | [各 20 次精度循环误差 0 px；普通／最大化／最小化及真实文件对话框、全屏拒绝通过，独立实例无残留](../../artifacts/apps-phase-12-release/application-smoke.json) |
| 默认目录升级 | [26 条，从阶段 11 的 0590ECE2 构建覆盖升级；子进程独立中文／空格 LOCALAPPDATA，3 次恢复 0 px，日用配置未改](../../artifacts/upgrade/upgrade-3bbfd0481ff14958bc6ed9bcace3ff21/report.json) |
| 后台异常 | [300 循环／600 次主要操作、逐轮 ≤2 px；暂停 247.742 ms 未确认，13 次响应观察；受限 202.133 ms；私有内存峰值 2.836 MiB，IdleSeconds=0](../../artifacts/backend/backend-87ddcd66cf6b44e3a5f767bb282de566/report.json) |
| 空闲资源 | [60.810 s、CPU 增量 0.000 ms；托盘私有内存峰值 2.059 MiB，界面 2.168 MiB；启动消息循环代理 268.981 ms，正常退出](../../artifacts/performance/perf-20261017T072709043Z-eb3ff74a/report.json) |

## 复现与剩余范围

```powershell
pwsh -NoProfile -File scripts/settings-draft-smoke.ps1
```

按 [构建入口](phase-6.md#回归与复现) 准备 Release 和原生 UIA 探针，在 PowerShell 7 正常桌面顺序执行。只操作独立配置、自建 fixture 和核对归属的实例；输入期间避免切换窗口。

当前仍须按 [实机操作单](manual.md) 完成物理多屏／混合 DPI、真实 UAC、Narrator、字体／高对比度、系统／Explorer 重启、干净 Win11 及独立首次使用等验收。更多编辑交错与其余 I/O 故障也保留。单屏局部通过不代表整个首版完成；后续外观与交互优化后还需重新验证热键、焦点、键盘、可访问性、DPI 与资源预算。
