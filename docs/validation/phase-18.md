# 阶段 18：长标题与规则列表的完整阅读

本文保留阶段 18 的执行快照；同一构建的后续夹具诊断和 Shell 复测见 [阶段 19](phase-19.md)，当前验收状态见 [覆盖审计](coverage.md)。

日期：2026-10-17（Asia/Shanghai）。继续复核配置流程时，发现窗口和预设列表的横向滚动范围仍按字符粗略估算，宽字母较多时无法滚到文字末尾。本轮修复实际日用中的长标题阅读问题，不改变匹配、捕获及持久化规则。

## 复现与修复

同一条最终脚本在 [旧 A0F8A180 构建](../../artifacts/list-widths/list-c7a889469b294a76973ffc4ad6c3ed9b/report.json) 失败：独立测试窗口长标题实测宽度 7,677 px，滚动范围只有 5,489 px，末尾有 2,188 px 无法到达。仅操作自建窗口与独立配置，没有移动或修改日用窗口，也未改变全局字体或显示缩放。

诊断先替换单一的字符估算，当前 96 DPI 的长标题和规则已正确。随后在 [中间诊断构建](../../artifacts/list-widths/list-ffac1f7512204707ba1c20471f113cf5/report.json) 中，仅向自有配置窗口发送有效矩形及局部缩放消息，144 处理后的文字变为 11,531 px，范围却仍为 7,693 px，单独证实字体切换后没有重算。该中间记录不是最终 Release 验收。

[shell.rs](../../src/shell.rs) 现在：

- 选用列表实际使用的字体，通过原生 GDI 测量整条文字，再加少量随缩放变化的留白；不再把所有 ASCII 字符视为同宽。
- 字体重建后，重新测量两个列表现有内容；刷新列表前清空旧范围，长标题变短或长规则删除后不留下过长的空白滚动区。
- 测量后恢复原 GDI 对象并释放 DC；获取或测量失败时采用保守宽度。本轮未注入 GDI 获取失败，不把降级分支声明为实测通过。

测量所选字体及整条字符串的依据见 [GetTextExtentPoint32W](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-gettextextentpoint32w)；原生列表不会自动维护横向范围，见 [LB_SETHORIZONTALEXTENT](https://learn.microsoft.com/en-us/windows/win32/controls/lb-sethorizontalextent)。

测试探针初版曾跨进程直接选择字体句柄，选择失败后误测了默认字体；该差异没有被当作产品缺陷。最终探针读取实际 LOGFONT，创建本进程副本，明确检查创建、选择成功，再测量原生列表内容；退出前恢复并释放自有资源。旧／新比较均使用修正后的同一脚本。

## 专项检查

[**30 条检查、11 次实际列表测量、20 次预热后的局部缩放循环通过**](../../artifacts/list-widths/list-b88ab9b5aca545a9a5fe585a153ddac6/report.json)。最终旧／新报告脚本 SHA256 均为 `D9B750CE2A0CD3A06A9A6A2C0C852CC4F6280CFD218695EECEE8441A988DF3B1`。

| 场景 | 字体高度 px | 文字宽度 px | 滚动范围 px |
| --- | --- | --- | --- |
| wide-title-96 | 14 | 7687 | 7695 |
| wide-rule-96 | 14 | 2411 | 2419 |
| wide-title-handler-144 | 21 | 11529 | 11541 |
| wide-rule-handler-144 | 21 | 3619 | 3631 |
| wide-title-handler-192 | 28 | 15880 | 15896 |
| wide-rule-handler-192 | 28 | 4985 | 5001 |
| wide-title-handler-96 | 14 | 7687 | 7695 |
| wide-rule-handler-96 | 14 | 2411 | 2419 |
| short-title-after-refresh | 14 | 595 | 603 |
| wide-and-short-rules | 14 | 2411 | 2419 |
| short-rules-after-delete | 14 | 226 | 234 |

资源样本 GDI 对象 61 → 56，区间 56–61；未见持续增长。字体处理和资源循环不写配置，真实 Run 项保持，实例正常退出。刷新只改测试窗口的标题；删除只涉及独立配置中的长规则，中文短规则仍保留。该脚本没有创建额外的产品测试接口。


## 当前构建与回归

| 工件 | SHA256 |
| --- | --- |
| Release EXE | `B141A2B2FA248CB7F764F648C5D186B97CDAAD52420E47B30212003B59505990` |
| [ZIP](../../dist/ScreenPin-0.1.0-windows-x64.zip) | `28BF913D6D0B1D75F90F5D1A3F1AB552628C3DA205C7541E07114841B5ACF7FF` |

本构建 **20 项集成回归最终通过（含下述一次重跑）**；[顺序、参数与退出码](../../artifacts/validation/phase-18-suite.json) 及 [原始报告索引](../../artifacts/validation/phase-18-evidence-index.json) 已逐项核对当前 EXE 哈希。

| 回归 | 当前证据 |
| --- | --- |
| 长标题／规则列表 | [30 条、11 次测量、20 次局部缩放资源观察；长文本可完整滚动，变短后范围收缩](../../artifacts/list-widths/list-b88ab9b5aca545a9a5fe585a153ddac6/report.json) |
| 直接桌面滚动绘制 | [32 条检查、10 场景，稳定滚动与完整重绘的文字区域像素相同](../../artifacts/scroll-paint/paint-4a0afeb1d2dd498b9cdf6c02f1bb00d8/report.json) |
| 尺寸／滚动／资源 | [389 条、19 场景、40 次资源观察；六张界面截图](../../artifacts/viewport/viewport-04a3caf786e4414ea3ce73a23f122738/report.json) |
| 写入上限／失败重试 | [28 条、5 次真实恢复、3 个正常退出](../../artifacts/write-limits/write-78576aef850e46bd96478bbdbc93740c/report.json) |
| 配置恢复／大小边界 | [55 条、7 个正常退出，损坏／未来格式／替换故障及 8 MiB 大小边界](../../artifacts/recovery/recovery-47a43f0e9f6a4241bba911129ecd2ddc/report.json) |
| 设置／预设草稿 | [55 条设置草稿检查](../../artifacts/settings-drafts/draft-7f20c004627d4227850ed2be6daacb3d/report.json)；[17 条编辑交错检查](../../artifacts/editor-races/editor-1ab824964cff43bbbadbbedac20c2b2d/report.json) |
| 键盘／确认框／托盘 | [177 条、96 次完整焦点、62 条 UIA](../../artifacts/keyboard/keyboard-eaaff59941c4419c8b3aac18f1c7be8e/report.json)；[82 条／9 个对话框](../../artifacts/dialog-keyboard/dialog-6dfe08ea3cce4eea85d8fadd7a53e2aa/report.json)；[19 条](../../artifacts/tray-keyboard/tray-9b5c9eeb7d9748718434d7e6f57d7378/report.json) |
| 真实热键 | [100 循环，最大误差 0 px；可见 p95 15.964 ms，完成反馈 p95 32.669 ms](../../artifacts/hotkeys/hotkey-20261017T084131128Z-cc8e1d29/report.json) |
| 生命周期竞态 | [3 场景／21 条；忙时拒绝、关闭和重建](../../artifacts/races/race-3bd97bbb5f714290a88ce47fc84ed584/report.json) |
| 设置事务／写入故障 | [93 条、14 次真实捕获／恢复、7 次正常退出](../../artifacts/settings/settings-a8c600649ab34476812e611bed1a3ccc/report.json) |
| ZIP | [34 条 GUI 断言、仅 EXE／README，解压哈希一致，无残留](../../artifacts/packages/package-a564b280ef0e4eef9ffe740ce8c68fef/package-verification.json) |
| 实际启动就绪 | [102 条；已有配置 10 次最大 327.187 ms，首次键盘捕获 5 次最大 623.281 ms，16 次正常退出](../../artifacts/startup/startup-ee09dcb64702494fb3d0dc5aa1cebfd0/report.json) |
| Explorer／Terminal | [各 20 次 GUI 精度、9 条状态、7 条标题检查；18 次实际 F9 均 0 px](../../artifacts/shell-apps/shell-apps-35c022333aa3432db5b9e106cfeb61a1/report.json) |
| Brave／VS Code | [各 20 次 GUI 精度、50 次普通实际恢复及最大化转换，状态组共 104 次 F9；标题组共 22 条、14 次 F9、6 次 F10，全部 0 px；普通完成 p95 169.515／164.667 ms，含归属核验与轮询](../../artifacts/apps-phase-18-release/application-smoke.json) |
| 默认路径覆盖升级 | [26 条；A0F8A180 → 当前 ZIP，独立中文／空格 LOCALAPPDATA，3 次恢复 0 px](../../artifacts/upgrade/upgrade-58aa7670022c4fde81cb870afcba18e2/report.json) |
| 后台异常及循环 | [300 循环／600 次主要操作，逐轮 ≤2 px；暂停 263.185 ms 未确认，15 次响应观察；受限 203.275 ms；私有内存峰值 3.059 MiB，IdleSeconds=0](../../artifacts/backend/backend-6d3968de66ce4e0291b660ab7dad5106/report.json) |
| 空闲资源 | [60.901 s，CPU 增量 0.000 ms；托盘私有峰值 2.066 MiB、界面 2.207 MiB；启动消息循环代理 269.834 ms，正常退出](../../artifacts/performance/perf-20261017T084731018Z-1db7d766/report.json) |

初次联跑在 Terminal 自建子 shell 的标题确认步骤超时而停止，见 [首次失败报告](../../artifacts/shell-apps/shell-apps-b672a188dc1d4917a9310fe54ece496e/report.json) 和 [初次执行记录](../../artifacts/validation/phase-18-suite-initial.json)。新标题命令文件完整，确认文件仍为上一序列；该次标题准备尚未完成，未进入后续恢复断言。同一 EXE、同一脚本的 [独立重跑](../../artifacts/shell-apps/shell-apps-35c022333aa3432db5b9e106cfeb61a1/report.json) 全部通过，最终执行记录保留 retry_history。没有为此修改产品或测试逻辑；该次确认超时原因尚未确定，列为测试稳定性待查项。

最终三页常用／最小尺寸的六张截图已检查；ZIP 的关联页前台截图文字完整。初看后台截图的关联预览时产生疑点，另做原始文件与直接桌面捕获核对，结果如下。

[直接桌面专项](../../artifacts/scroll-paint/paint-4a0afeb1d2dd498b9cdf6c02f1bb00d8/report.json) **32 条检查、10 场景通过**：在自有配置窗口获得前台后，只捕获关联预览的文字区域，滚动稳定后的像素与显式完整重绘后的像素逐组相同，实际文本与配置均不变。检查使用当次图像对照，没有预设机器相关的金图。

[独立核对记录](../../artifacts/debug-association-paint-51b822b201f34051ba9caafbcc4c9b45/report.json) 中，同一区域顶部／底部／重绘后、桌面／PrintWindow 的六张原始 PNG 均为 1035×120，SHA256 均为 `9D5DB92E18FABC6C60FA9CB12D202180A49066AECA5B54F766B7456FE61A1C05`。初看缩略展示时曾误判缺字；原始文件和直接桌面像素未证实重绘缺陷，因此没有额外修改产品绘制逻辑。


直接桌面检查复现：`pwsh -NoProfile -File scripts/scroll-paint-smoke.ps1`。只通过公共 UIA 聚焦自有窗口的第一个导航按钮；前台变化时取消捕获，没有发送键盘输入。

格式、严格 Clippy、all-targets **66 项测试**及 Release 构建通过，见 [构建输出](../../artifacts/validation/phase-18-build.txt)。本构建的 [嵌入清单](../../artifacts/validation/phase-18-embedded.manifest) 仍为 asInvoker／PerMonitorV2，[运行依赖](../../artifacts/validation/phase-18-dependencies.txt) 仍为系统 DLL。

## 复现与边界

```powershell
pwsh -NoProfile -File scripts/build-release.ps1 -Offline
pwsh -NoProfile -File scripts/list-width-smoke.ps1
```

专项脚本只使用自有窗口、独立配置及原生 GUI 消息，没有发送键盘输入或改变全局设置。96／144／192 的局部消息仅检查缩放处理分支及字体切换后的列表测量；当前仍是单个实际 96 DPI 显示器，不能作为真实混合 DPI、实际跨屏或全局缩放验收。

完整首版仍需真实物理多屏／热插拔／身份、混合 DPI／大字体／高对比度、Narrator、UAC／跨账号、Explorer 或系统重启、自启登录、包应用升级、干净 Win11 和独立新用户首次使用验收。本轮关闭长文本阅读缺陷，继续按 [覆盖审计](coverage.md) 与 [实机操作单](manual.md) 推进，尚未达到全部验收门槛。
