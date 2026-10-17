# 阶段 8：确认框焦点修复与托盘键盘操作

日期：2026-10-17（Asia/Shanghai）。本轮完成本机可执行的托盘和确认框键盘检查，发现并修复取消确认后键盘焦点丢失的问题。先完成功能、稳定性与验收，再优化外观和交互的顺序保持不变。

相同二进制的普通启动／首次 UI 实际就绪计时补证见 [阶段 9](phase-9.md)。

## 问题与修复

旧 EXE `46D34B9B…` 中，用键盘打开“迁移应用预设”，选默认“否”关闭后，前台回到设置窗口，但实际焦点为窗口本身（控件 ID 0），未回到触发按钮。等待六秒仍如此。相同最终脚本的 [旧版失败报告](../../artifacts/dialog-keyboard/dialog-19541ee52c894aa4ac03cfb7460c4312/report.json) 保留了该结果，两个测试实例正常清理退出。

[shell.rs](../../src/shell.rs) 现在由同一个确认入口保存原控件，显示默认“否”的原生确认框，关闭后按已有焦点保护规则恢复：主界面仍在前台且尚无新的子控件选择时才恢复；原控件不可用时回到主页面入口。三个确认流程共用该行为。后台操作也继续使用同一恢复规则。没有调用 SetForegroundWindow 抢回其他应用的前台。

[新版确认框报告](../../artifacts/dialog-keyboard/dialog-bacdc503deee4aac88d660af2f54dc11/report.json)：**82 条检查、9 次确认框、4 个实例正常退出**。

| 流程 | 真实键盘结果 |
| --- | --- |
| 迁移应用预设 | 默认及焦点均为“否”；Tab／Shift+Tab 可在是／否间切换；否不改配置字节并恢复触发按钮焦点；明确选是后迁移整个应用，默认及两条规则的 ID、顺序、位置完整保留 |
| 新环境 | 相同取消及焦点检查通过；明确选是后新增空方案，原两个方案与显示器记录保持不变 |
| 新建配置 | 损坏测试配置先保持保护模式；否不改原件；明确选是后原件按字节另存，创建空配置并恢复可编辑状态 |

新环境的歧义来自独立 JSON 中重复的显示器证据，迁移源是独立 JSON 的旧应用身份；不代表物理多屏或真实应用升级。测试准备使用原生命令；确认框由实际 Tab／Space 打开，后续操作为 SendInput。18 条按钮名称／角色样本由独立原生 UIA 探针读取，不算 Narrator 试听。

原生 MB_YESNO 没有取消按钮，Esc 会保留确认框；本轮验证 Esc 不提交且“否”仍能关闭并恢复焦点。这符合 [Microsoft 的 MessageBox 说明](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-messagebox)。不宣称 Esc 已实现关闭。早期测试误把该平台行为判为失败，记录仍保留；后续外观与交互打磨可再评估确认按钮和取消方式。

## 托盘的真实键盘路径

[托盘报告](../../artifacts/tray-keyboard/tray-972f3a3581f948e798602bd2d9b129b5/report.json)：**19 条检查**通过。每例先以公共 UIA 聚焦自建窗口，随后真实 Win+B 进入通知区域，Enter 展开隐藏图标，Shift+F10 打开 Screen Pin 菜单；Home／方向键选中项目，读取高亮命令 ID 后才按 Enter。没有注入托盘回调或用 WM_COMMAND 代替测试动作。

- 两次真实 F10 创建有效覆盖后，托盘撤销恢复原配置内容和预设 ID，事务版本继续递增；窗口位置不因撤销而改变。
- 随后真实 F9 按撤销后的预设恢复窗口，不写配置；下次实际托盘菜单中撤销已禁用。
- 托盘打开主界面可用；Alt+F4 隐藏界面且进程保留；托盘退出正常结束，之后可重新注册两枚热键，证明注册已释放。

仅在已验证的系统 Explorer 通知区域发送导航按键。目标图标名称及中心位置必须与测试进程 Host HWND／uID 1 的 Shell_NotifyIconGetRect 结果一致；菜单必须属于该进程。读取菜单高亮和启用状态后才执行目标命令，没有触发提权。

测试修正包括：撤销应恢复内容和身份，同时保留单调递增的版本；已有通知区域弹出层关闭后，等待动画完成再重开。旧的准备失败记录保留，未作为产品通过结果。当前中英文隐藏图标名称及本机 Windows 11 布局有识别支持，其他 Shell 布局未证明。

## 当前发布工件

仍为 0.1.0 开发预览，Win11 企业版 10.0.26300、普通权限、单屏 2560×1440／工作区 2560×1392、96 DPI。

| 文件 | SHA256 |
| --- | --- |
| [ZIP](../../dist/ScreenPin-0.1.0-windows-x64.zip) | `23D2E5A6E6E381EF772316F004ED4F06B7CB26F80DADAFC692ED5CF2CC8A6622` |
| Release EXE／解压 EXE | `C8603D7FBF25B5AA3269AAA05CDFCFE644DB0482ECB59422D86D6922A43470B2` |

格式检查、严格 Clippy、all-targets **62 项测试**和离线 Release 打包通过。[嵌入清单](../../artifacts/validation/phase-8-embedded.manifest) 为 PerMonitorV2／asInvoker，[导入依赖](../../artifacts/validation/phase-8-dependencies.txt) 仅为系统 DLL；不代替干净机器实测。[ZIP 校验](../../artifacts/packages/package-50f845177bea46c9b53af3a567f110ce/package-verification.json) 含 34 条 GUI 检查，只有 EXE 和 README，解压哈希一致，退出无残留。

## 当前构建回归

八项检查的顺序执行及退出码见 [套件记录](../../artifacts/validation/phase-8-suite.json)。所有报告均核对本阶段 EXE 哈希，不沿用旧构建结果。

| 检查 | 结果与证据 |
| --- | --- |
| 三页键盘／UIA | [177 条检查](../../artifacts/keyboard/keyboard-b78483f993ea4e71aa5f49ae491f567b/report.json)，96 次焦点观察、62 条名称／角色样本 |
| 真实热键 | [100 次完整循环](../../artifacts/hotkeys/hotkey-20261017T063636032Z-8421410f/report.json)，最大误差 0 px；可见匹配 p95 16.198 ms，完成反馈 p95 33.184 ms；重复抑制／no-op／前台保持通过 |
| 生命周期竞态 | [3 场景／21 条检查](../../artifacts/races/race-72b53ebc823e41b0ac1a9f8454c92b64/report.json)，暂停切焦／关闭／同进程类标题重建、忙时真实 F10 拒绝及下一操作可用；未强制同数值 HWND 复用 |
| 恢复与保护 | [33 条检查](../../artifacts/recovery/recovery-0c9e28b8df3e4299a313802159b87a10/report.json)，损坏／未来格式保护、取消不写、保留原件、失败可重试 |
| 设置与存储故障 | [93 条检查](../../artifacts/settings/settings-57dd65265c4c4b9bb34aa1af390a2d35/report.json)，14 次真实输入、7 次正常退出；热键冲突／交换／失败回滚／恢复同步、真实 I/O 创建受阻、原件保留失败及历史文件碰撞均通过 |

实际应用、升级和资源复测的顺序执行及退出码见 [回归执行记录](../../artifacts/validation/phase-8-regression.json)，均通过：

| 检查 | 结果与证据 |
| --- | --- |
| Brave／VS Code | [实际应用报告](../../artifacts/apps-phase-8-release/application-smoke.json)：Brave 155.1.97.59、VS Code 1.130.0 各 22 条普通／状态检查；各 20 次 GUI 连续恢复 0 px，最大化还原、最小化拒绝、真实 Ctrl+O 对话框及 F11 全屏的 F10／F9 拒绝通过；独立 profile 无残留 |
| Explorer／Terminal | [每款 20 次 GUI 恢复](../../artifacts/shell-apps/shell-apps-291d1fd1cc64428e923dbe27831550b6/report.json)均 0 px；自建窗口正常关闭，测试 shell 退出，保留已有用户窗口 |
| 默认路径升级 | [26 条检查／3 次真实恢复](../../artifacts/upgrade/upgrade-eb089a23de94428d93bdcbe91faf7e5f/report.json)均 0 px；从 46D34B9B 升为当前 ZIP，子进程专用 LOCALAPPDATA 含中文／空格，不传 config-dir；旧规则／热键／撤销可用，日用配置和父进程环境未变；不代表真实用户 ACL 或旧格式迁移 |
| 后台与异常 | [300 循环／600 次主要操作](../../artifacts/backend/backend-c030f40763cd4f0795ac608bf61b1514/report.json)，逐轮 ≤2 px；暂停 1.2 s 时 260.972 ms 未确认，13 次 host／设置响应观察；受限 200.525 ms 诚实反馈；峰值 2,998,272 B（2.859 MiB），分段有涨有降；IdleSeconds=0 |
| 空闲资源 | [独立空配置 60.758 s](../../artifacts/performance/perf-20261017T063904656Z-1ff04de4/report.json)，CPU 计数无可测增量；托盘私有内存峰值 2,150,400 B（2.051 MiB），界面 2,125,824 B（2.027 MiB）；消息循环就绪代理 273.185 ms，正常退出。代理不等于实际托盘／热键完整就绪 |

全部当前结果也纳入 [覆盖审计](coverage.md)。历史 `46D34B9B…` 的证据保留在 [阶段 7 快照](phase-7-coverage.md)。

## 复现与剩余门槛

先按 [构建及通用回归入口](phase-6.md#回归与复现) 准备 Release 和原生探针，然后顺序运行：

```powershell
pwsh -NoProfile -File scripts/tray-keyboard-smoke.ps1
pwsh -NoProfile -File scripts/dialog-keyboard-smoke.ps1
```

需要 PowerShell 7、正常 Explorer 桌面。测试准备可用 UIA 聚焦自有窗口；输入期间不要切换窗口。所有测试用独立配置和自建窗口，清理只针对核对归属的实例；真实 HKCU Run 保持不变。托盘脚本用系统 UIAutomationClient 读取焦点，确认框名称／角色使用原生探针；这些是测试依赖，发布程序没有 PowerShell／.NET 依赖。

真实 Narrator、独立首次使用、缩放／大字体／高对比度、物理多屏／混合 DPI、UAC、系统／Explorer 重启和干净环境等仍须按 [实机操作单](manual.md) 完成。整体目标保持活动，功能验收后再集中打磨外观与交互；不把本轮通过视为最终验收。
