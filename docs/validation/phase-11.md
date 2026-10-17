# 阶段 11：预设草稿与热键交错

日期：2026-10-17（Asia/Shanghai）。本轮修复恢复窗口时丢失未保存预设编辑的问题，补齐草稿与热键更新、保存、撤销及忙时命令的交错检查。外观与交互集中打磨仍安排在功能验收之后；本轮属于影响正常使用的交互缺陷修复。

## 复现与改进

旧版每次后台响应都会重建预设表单，F9 即使不改配置，也把未保存的百分比重置为已存值。同一最终脚本的 [旧版失败报告](../../artifacts/editor-races/editor-22c678c0413c4bcb853baee930ba5782/report.json) 使用 `C8603D7F…` EXE：输入 `12.5` 后实际 F9 恢复，配置哈希不变，但表单草稿消失，实例正常退出。

[shell.rs](../../src/shell.rs) 现在在后台响应前采集有改动的预设草稿，重建后仅还原到同一方案、应用及预设 ID，显示器选择按逻辑 ID 对应。行为如下：

- 恢复、无变化更新及其他预设更新保留未保存输入。原目标内容及版本未变时，采用最新配置基础版本，保存只修改原目标。
- 同一目标已更新时保留旧草稿及旧基础版本，结果明确提示冲突；保存旧草稿被拒绝，不覆盖新配置或备份。
- 点击刷新明确载入冲突目标的当前值并放弃旧草稿。没有冲突的正常刷新继续保留有效草稿。
- 本表单保存成功后显示已提交值；保存失败继续保留草稿。切换预设、删除或迁移目标时重新载入对应编辑区。

只保存临时界面状态，没有改变持久格式、单一写入者或后台串行提交。规则和预设仍按 ID 提交，已有基础版本检查继续有效。交互约定已补入 [设计基线](../design.md) 与 [实机操作单](manual.md)。

## 直接交错证据

[新版报告](../../artifacts/editor-races/editor-e4b43d5ec7354b098eee9a3f05fc29f4/report.json)：**17 条检查、6 个完整状态快照通过，实例正常退出**。设置文本、选记录、保存／撤销／刷新使用自有 GUI 消息；F9／F10 均为实际 SendInput，没有伪造热键消息。全程只操作自建 fixture 和独立配置，真实 HKCU Run 未改变。

| 场景 | 结果 |
| --- | --- |
| 默认预设有未保存 `12.5`，实际 F9 恢复及 F10 无变化更新 | 草稿原样保留，配置哈希不变 |
| 草稿仍在默认预设，实际 F10 更新另一条标题规则 | 原默认和草稿不变；随后保存草稿仅改默认，规则更新保留；撤销仅撤回草稿保存，独立热键更新仍在 |
| 有百分比和关键字草稿时，实际 F10 更新同一规则 | 草稿保留并提示冲突；旧草稿保存被拒，主文件和备份哈希不变；后续 F9 使用已持久化的新预设 |
| 明确刷新冲突表单 | 载入当前关键字和百分比，未改动保存为 no-op |
| 暂停目标 1.2 秒，在真实 F9 忙时强制提交 GUI 保存 | 实际编辑和保存控件禁用，命令被拒；有界等待后返回未确认，草稿和配置保持；目标恢复后迟到放置仍只作用于原目标，拒绝的保存没有排队；此后新的明确保存可成功 |

暂停由 fixture 的私有消息实现；只在其真正不响应后触发 F9，读到刷新及编辑控件禁用才提交忙时保存。等待控件状态实际生效，避免用读到第一个禁用控件的时刻推断整组已更新。百分比 `33.3 / 100` 的浮点结果按 `1e-12` 容差核对，不错误要求其与十进制 `0.333` 的二进制表示完全相同。

以上覆盖单屏普通 fixture 的这些明确交错；不等于物理拔屏、句柄数值复用、跨方案或所有实际应用时序。初始准备失败及过早控件观察的报告保留，未计为产品通过结果。本轮草稿保护针对预设编辑区，设置页未保存输入的保留仍待单独改进。

## 当前构建与回归

仍为 0.1.0 开发预览，Win11 企业版 10.0.26300、普通权限、单屏 2560×1440／工作区 2560×1392、96 DPI。

| 工件 | SHA256 |
| --- | --- |
| [ZIP](../../dist/ScreenPin-0.1.0-windows-x64.zip) | `4A52DEC47C7B143479EF2D7314D70431EC52C9490D97542D4A2184D4497AFF6B` |
| Release EXE／解压 EXE | `0590ECE2CF3E276533F952F4AB4F614D5AB6A3B99CA6BE7ECB3030F8C3E5A715` |

格式、严格 Clippy、all-targets **62 项测试**和离线打包通过。[嵌入清单](../../artifacts/validation/phase-11-embedded.manifest) 保持 PerMonitorV2／asInvoker，[导入依赖](../../artifacts/validation/phase-11-dependencies.txt) 仅为系统 DLL；干净环境仍待实测。旧 `C8603D7F…` 证据保存在 [阶段 10 历史快照](phase-10-coverage.md)。

本构建 **15 项回归全部通过**，顺序、命令参数和退出码见 [执行记录](../../artifacts/validation/phase-11-suite.json)。原始结果以实际 EXE 哈希区分，当前完整索引见 [覆盖审计](coverage.md)。

| 回归 | 当前证据 |
| --- | --- |
| 键盘 | [177 条检查](../../artifacts/keyboard/keyboard-3ba47d34f7544f1fb1f1012aa59d6d51/report.json)，96 次焦点观察、62 条 UIA 名称／角色样本 |
| 确认框 | [82 条检查／9 次确认框](../../artifacts/dialog-keyboard/dialog-bcd8e56083d54eeab118302ea93671fe/report.json)，默认否、真实键盘取消／确认及焦点恢复 |
| 托盘键盘 | [19 条检查](../../artifacts/tray-keyboard/tray-1de231ff621c4ff8aea739cf42114b9a/report.json)，Win+B／菜单撤销／打开／退出及热键释放 |
| 真实热键 | [100 循环](../../artifacts/hotkeys/hotkey-20261017T070836736Z-2f768b1d/report.json)，最大误差 0 px；可见 p95 16.108 ms，完成反馈 p95 32.773 ms |
| 目标生命周期 | [3 场景／21 条检查](../../artifacts/races/race-923a71177c354148beee0861ce98b5dd/report.json)，暂停切焦、关闭／重建和忙时真实 F10 拒绝 |
| 设置／恢复 | [93 条设置与存储故障检查](../../artifacts/settings/settings-8ac21b434bd24b0cb5550c1402b54956/report.json)和 [33 条恢复保护检查](../../artifacts/recovery/recovery-80882949b6bf4adf9346518048e67f18/report.json)，原有热键事务、故障与保留文件碰撞继续通过 |
| ZIP | [34 条解压 GUI 检查](../../artifacts/packages/package-d7677396e4db403182a39df298fb9672/package-verification.json)，仅 EXE／README，哈希一致且退出无残留 |
| 启动 | [102 条检查](../../artifacts/startup/startup-83c4b12d1cd2400fbccd07113d34292b/report.json)，10 次已有配置实际托盘及双热键完成最大 386.470 ms；5 次首次 UI 实际键盘捕获最大 655.747 ms |
| Explorer／Terminal | [GUI 基线及扩展](../../artifacts/shell-apps/shell-apps-d41696e63765407a904104a60c411516/report.json)：各 20 循环、9 条状态和 7 条标题检查，18 次真实 F9 及手动还原均 0 px |
| Brave／VS Code | [实际应用报告](../../artifacts/apps-phase-11-release/application-smoke.json)，各 20 次精度循环及普通／最大化／最小化、真实文件对话框与全屏拒绝 |
| 默认目录升级 | [26 条检查](../../artifacts/upgrade/upgrade-bd16c52d3a5040fea73ad94c77c27bde/report.json)，从 C8603D7F 升为当前 ZIP；独立子进程 LOCALAPPDATA 含中文／空格，三次实际恢复 0 px，日用配置不变 |
| 后台异常 | [300 循环／600 次主要操作](../../artifacts/backend/backend-7da9e10f4bc94dcba8262fabd7693168/report.json)，逐轮 ≤2 px；暂停 263.837 ms 未确认，11 次响应观察；受限 201.408 ms 诚实反馈；私有内存峰值 2,990,080 B（2.852 MiB）；IdleSeconds=0 |
| 空闲资源 | [60.789 s 独立观察](../../artifacts/performance/perf-20261017T071121479Z-bb008e05/report.json)，CPU 时间无可测增量；托盘私有内存峰值 2,142,208 B（2.043 MiB），界面 2,150,400 B（2.051 MiB）；消息循环就绪代理 266.582 ms，正常退出 |

## 复现与待验范围

```powershell
pwsh -NoProfile -File scripts/editor-race-smoke.ps1
```

按 [构建入口](phase-6.md#回归与复现) 准备 Release 和原生 UIA 探针，使用 PowerShell 7 正常桌面。输入期间不要切换窗口；清理仅操作核对归属的实例和窗口。物理多屏／混合 DPI、真实 UAC、Narrator、字体／高对比度、系统／Explorer 重启、干净环境及独立首次使用仍须按 [操作单](manual.md) 完成，不能以本轮脚本替代。
