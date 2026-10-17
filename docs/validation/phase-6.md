# 阶段 6：历史原件保护与存储故障

日期：2026-10-17（Asia/Shanghai）。本轮修复恢复配置时可能覆盖历史保留副本的问题，补齐存储失败与默认路径升级证据，并为新构建执行本机回归。整体目标仍活动，外观与交互优化继续安排在功能、稳定性与验收之后。

相同二进制的后续切焦／关闭／重建及忙时真实 F10 证据见 [阶段 7](phase-7.md)。

## 实测发现与修复

原实现使用 `fs::copy` 保存 `config.preserved-进程号-计数器.json`。进程号复用且计数器重新开始时，目标可能是旧保留文件，复制会覆盖它。新增文件碰撞回归先复现失败；现在以 `create_new` 原子新建目标，复制后 `sync_all`，再允许替换主配置。遇到已有文件换名重试，单次最多 128 个候选；冲突耗尽或其他 I/O 错误明确失败，原主文件不变。后续重试从新的计数继续，不静默覆盖历史文件。

实现与回归见 [store.rs](../../src/store.rs)。全部 **62 项测试**、格式与严格 Clippy 通过。原子新建保证不覆盖已有目标；本轮不宣称已模拟断电、磁盘写满或所有复制／刷盘失败。

## 本阶段工件（历史）

| 文件 | SHA256 |
| --- | --- |
| ZIP 的 [历史校验记录](../../artifacts/packages/package-e248f6e51543408c86d49a3e08c8095e/package-verification.json) | `F966B1F76A9013DEB058EA254FC815A63C6D06B64E0D7788C1663085366CCA28` |
| [留存解压 EXE](../../artifacts/packages/package-e248f6e51543408c86d49a3e08c8095e/extracted/screen-pin.exe) | `46D34B9B649061BE7DEEF6B4EEA8F0E2946275EE53A35100B388AF2E36780EF2` |

当前发布包已由 [阶段 8](phase-8.md) 的焦点修复构建替代；本文件中的“当前／新构建”均指阶段 6 当时的版本。

仍为 0.1.0 开发预览，Win11 企业版 10.0.26300、普通权限、单屏 2560×1440／工作区 2560×1392、96 DPI。当前 [manifest](../../artifacts/validation/phase-6-embedded.manifest) 为 PerMonitorV2／asInvoker，[导入依赖](../../artifacts/validation/phase-6-dependencies.txt) 仅为系统 DLL；不替代干净机器实测。旧构建证据与待验项保留在 [阶段 5 历史审计](phase-5-coverage.md)，不能当作新 EXE 的执行记录。

## 新构建的存储证据

[设置与存储故障报告](../../artifacts/settings/settings-003a4860627c4c1bba8006d89e3844e6/report.json)：**93 条检查、14 次真实输入捕获／恢复、7 个实例正常退出**，包含原有热键拒绝／互换／冲突／回滚／恢复同步，以及以下新增场景：

| 场景 | 直接结果 |
| --- | --- |
| 备份临时文件创建失败 | 主配置和旧备份字节均不变，旧绑定及可见撤销入口保留；新增热键已释放；解除后设置保存和实际按键可用 |
| 主配置临时文件创建失败 | 主文件保留，备份只提升为上一次有效主配置；失败的真实 F10 不发布新预设，F9 仍恢复旧值；实际撤销随后可撤回到更早一次成功更新，恢复误差 0 px |
| 保留原件失败 | 主文件与有效备份字节保持，仍为保护模式，恢复入口可重试；解除后精确恢复有效配置 |
| 保留文件名碰撞 | 在新进程的前两个候选名称预置旧原件，恢复后两文件哈希不变，新损坏原件保存至下一个空名称；恢复配置精确一致，热键立即可用 |

故障通过新建测试配置目录中的空目录占用目标名触发真实文件 I/O 错误，没有生产故障开关或 ACL／系统磁盘设置变更。脚本只删除自己创建、路径核对且为空的占位目录，所有原始报告和测试数据保留。文件名碰撞模拟保留了旧名称，并未宣称控制了 OS 实际 PID 分配。

[恢复与保护报告](../../artifacts/recovery/recovery-c61333ae371c482c9617f94ed67f37e6/report.json)：**33 条检查**通过，包括截断／非法字段／未来主文件、缺失／损坏／未来备份、替换受阻与重试，以及新建配置默认“否”、取消不写、确认后保留原件。

## 默认路径与覆盖升级

[默认路径升级报告](../../artifacts/upgrade/upgrade-10ecca425fd945f983c1bec6d6e6ec94/report.json)：**26 条检查、3 次实际按键恢复均 0 px**。以阶段 3–5 的 `0889BCE9…` EXE 为旧构建，覆盖为当前 ZIP 后复测。

- 两个版本均不传 `--config-dir`，只为各自子进程设置独立的 LOCALAPPDATA 根，路径含空格和中文；界面报告实际路径为该根下的 `ScreenPin/config.json`。
- 程序目录覆盖和新版启动，均不改主配置与备份字节哈希；旧应用默认、标题规则、自定义热键直接可用，标题变化可回退默认，更新后撤销可恢复旧位置及预设身份。
- 父进程 LOCALAPPDATA、日用配置／备份和真实 HKCU Run 均未改变；两个实例正常退出并释放热键。

这证明默认目录选择分支，不是向用户真实 LOCALAPPDATA 写入的验收；其真实 ACL／权限、登录自启、系统重启和干净环境仍未证明。两版本格式均为 v1，不算旧格式迁移。

## 回归与复现

[ZIP 校验](../../artifacts/packages/package-e248f6e51543408c86d49a3e08c8095e/package-verification.json)：仅含 EXE 与 README，解压哈希与 Release 一致；34 条 GUI 检查通过，实例正常退出。

本轮完整回归的原始报告索引在 [当前覆盖审计](coverage.md)。报告按实际 EXE 哈希核对，实际输入、GUI 命令和后台命令分别注明范围；未取得的硬件、权限或读屏证据仍标为未验证。

| 当前构建回归 | 结果与原始证据 |
| --- | --- |
| 键盘与可访问名称 | [177 条检查](../../artifacts/keyboard/keyboard-0d0cbf3f161f497593cae3bf40ef1c2f/report.json)通过，96 次焦点观察、62 条 UIA 样本；不替代 Narrator |
| 真实热键 | [100 次循环](../../artifacts/hotkeys/hotkey-20261017T060224626Z-94cbfb23/report.json)，最大误差 0 px；可见 p95 15.813 ms，完成反馈 p95 32.684 ms，前台保持及 no-op／重复抑制通过 |
| 实际应用 | [Brave／VS Code](../../artifacts/apps-phase-6-release/application-smoke.json)各 22 条普通／状态检查通过，含真实文件对话框及全屏拒绝；各 20 次 GUI 连续恢复 0 px。[Explorer／Terminal](../../artifacts/shell-apps/shell-apps-1447b5837f434b5497ca634387af519f/report.json)各 20 次普通 GUI 恢复 0 px，窗口正常关闭，测试 shell 退出 |
| 后台与异常 | [300 次循环／600 次主要操作](../../artifacts/backend/backend-199e49c95de24109a779874ee66b77b8/report.json)，逐轮 ≤2 px；暂停 1.2 s 时约 261 ms 未确认，15 次 host／设置响应探测通过；约束约 190 ms 如实报告；私有内存峰值 2.926 MiB，分段有涨有降。IdleSeconds=0，不以其空闲字段证明 60 秒预算 |
| 独立资源复测 | [空闲 60.767 s](../../artifacts/performance/perf-20261017T060416459Z-393eaefb/report.json)，CPU 计数无可测增量；托盘峰值和界面私有内存均 2,170,880 B（2.070 MiB）；启动消息循环代理 265.575 ms；正常退出，无残留。代理不等于实际托盘／热键完整就绪 |

```powershell
cargo build --locked --offline --bins
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-release.ps1 -Offline
pwsh -NoProfile -File scripts/settings-smoke.ps1 -StorageFaults
pwsh -NoProfile -File scripts/recovery-smoke.ps1
pwsh -NoProfile -File scripts/package-smoke.ps1
pwsh -NoProfile -File scripts/upgrade-smoke.ps1 -PreviousExe <可信旧构建绝对路径> -UseDefaultConfigPath
pwsh -NoProfile -File scripts/keyboard-smoke.ps1
pwsh -NoProfile -File scripts/hotkey-smoke.ps1 -ExePath target/release/screen-pin.exe -OutputDir artifacts/hotkeys -Cycles 100
pwsh -NoProfile -File scripts/application-smoke.ps1 -OutputDir artifacts/apps-regression-new -PrecisionCycles 20 -ExtendedStates -TemporaryDialogs -Fullscreen
pwsh -NoProfile -File scripts/shell-apps-smoke.ps1 -Cycles 20
pwsh -NoProfile -File scripts/backend-smoke.ps1 -Cycles 300 -IdleSeconds 0
pwsh -NoProfile -File scripts/perf-smoke.ps1 -ExePath target/release/screen-pin.exe -OutputDir artifacts/performance
```

脚本需 PowerShell 7；`-UseDefaultConfigPath` 依赖 PowerShell 7.4+ 的子进程 Environment 参数，本机为 7.6.5（[官方参数说明](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/start-process#-environment)）。应用无 PowerShell 运行依赖。依赖未缓存时去掉离线参数。顺序运行桌面输入检查，切焦后输入取消；不启动真实 UAC 或重启系统。后续继续 [完整验收](../acceptance.md) 的剩余状态／竞态、可访问性和实机条件，不以本轮成功收窄原始范围。
