# 阶段 10：Explorer／Terminal 的状态与标题热键

历史构建：本阶段 EXE 为 `C8603D7F…`，最新预设草稿保护构建及回归见 [阶段 11](phase-11.md)。

日期：2026-10-17（Asia/Shanghai）。本轮补齐这两款实际应用的普通／最大化热键及动态标题规则证据，没有修改产品源码。仍按约定先完成功能、稳定性与验收，再集中优化外观和交互。

沿用 [阶段 8](phase-8.md) 的当前构建：EXE SHA256 `C8603D7FBF25B5AA3269AAA05CDFCFE644DB0482ECB59422D86D6922A43470B2`，ZIP SHA256 `23D2E5A6E6E381EF772316F004ED4F06B7CB26F80DADAFC692ED5CF2CC8A6622`。启动的实际就绪时间见 [阶段 9](phase-9.md)。本轮仍为 Win11 企业版 10.0.26300、普通权限、单屏 2560×1440／工作区 2560×1392、96 DPI。

## 当前结果

[原始报告](../../artifacts/shell-apps/shell-apps-78836db56c544664bfb4d616f688ca5b/report.json) 整体通过，记录 EXE、脚本、原生及输入辅助文件、UIA 探针哈希；真实 HKCU Run 保持不变。

| 样本 | 既有 GUI 基线 | 状态扩展 | 标题规则扩展 |
| --- | --- | --- | --- |
| Explorer 10.0.26100.8875 | 20 次循环，0 px | 9 条检查、3 次真实 F9 恢复及手动还原均 0 px | 7 条检查、8 次目录标题变化、6 次真实 F9 恢复均 0 px |
| Windows Terminal 产品版本 1.24.261001001／包版本 1.24.12741.0 | 20 次循环，0 px | 9 条检查、3 次真实 F9 恢复及手动还原均 0 px | 7 条检查、8 次 shell 标题变化、6 次真实 F9 恢复均 0 px |

共 **32 条扩展检查、18 次真实 F9 恢复**通过；另有每款 5 次真实 F10 更新，涵盖状态和规则范围。GUI 基线继续逐轮检查前台保持、恢复不写盘和无累计漂移。以上分开记录，不把 GUI 命令当成热键输入。

## 状态与目标范围

每款应用先由真实 F10 保存不同的普通矩形，移动后用真实 F9 恢复。再原生最大化、真实 F10 捕获，捕获前后均保持最大化且保存最大化状态；还原并移动后，真实 F9 恢复最大化及原可见边界。之后手动还原回到捕获时的普通矩形，误差 0 px。

再次真实 F10 保存普通状态后，从最大化按 F9 回到普通矩形，前台保持且配置哈希不变。状态切换由原生 API 准备，F10／F9 是实际 SendInput；不宣称已做瞬时闪烁的像素监测。

最小化窗口不能作为当前激活窗口，因此该部分使用 GUI 明确选择测试窗口，分别执行捕获及恢复。两者均报告最小化拒绝，不写配置、不还原窗口、不改变当时前台；这两项检查没有伪造 WM_HOTKEY。

## 动态标题规则

Explorer 通过同一个新窗口的 Shell COM Navigate2，切换四个自建目录。Terminal 由明确创建的测试 shell 更新控制台标题，通过启动参数 `--useApplicationTitle` 接受应用标题；参数行为见 [Microsoft 文档](https://learn.microsoft.com/en-us/windows/terminal/command-line-arguments?tabs=powershell)。该参数只作用于本轮新窗口，用户的 Terminal 设置文件不由脚本改写。

规则通过配置界面命令显式建立，实际匹配与更新使用真实热键：

- 标题 RuleAlpha 命中大小写不同的 `rUlEaLpHa`，标题 RuleBeta 命中另一条规则，恢复各自不同的位置。
- 标题同时含 RuleAlpha 和 RuleBeta 时，按创建顺序命中第一条 Alpha，恢复 Alpha 的矩形。
- 标题不含两个关键字时，回退应用默认，恢复默认矩形。
- Beta 标题下真实 F10 更新原 Beta 规则，ID 保留，Alpha 及共享默认完整内容不变；再按 F9 使用更新后的位置。
- 无匹配标题下真实 F10 只更新原应用默认，默认 ID 和两条规则内容／顺序均保留；再按 F9 使用更新后的默认位置。

正式匹配期间没有通过 GUI 刷新来替代标题变化后的热键判断。每次恢复读取结果范围、核对矩形与配置前后哈希；报告保留真实标题、窗口句柄、规则 ID 及完整更新前后数据。Terminal 仍保存为可靠 package 身份，不退回按临时版本目录识别。

## 操作归属与退出

窗口必须不在启动前的 HWND 集合中，并核对 PID、程序路径、唯一标题。Explorer 还须核对 Shell COM HWND 与自建目录的完整路径；只允许本轮列出的四个目录。Terminal 须核对独立测试子 shell 的 PID、EXE 和唯一脚本路径，标题变更由带序号的私有命令／确认文件驱动。

每组输入前可通过公共 UIA 聚焦自建引导窗口，再请求激活已核对的新应用窗口；不绕过 Windows 前台策略。每次按键前后及等待中核对实际前台、PID 和根窗口类，变化即停止后续输入。

只对经核对的测试 HWND 发正常关闭消息，不终止共享 Explorer／Terminal 宿主。[退出后的核查](../../artifacts/validation/phase-10-ownership.json) 确认两个测试窗口已关闭、测试 shell 已退出、Screen Pin 测试进程无残留；测试前存在的 Explorer HWND 仍存在。该核查不把“仍存在”扩大为用户窗口全部属性的前后比对。

## 复现与剩余范围

```powershell
pwsh -NoProfile -File scripts/shell-apps-smoke.ps1 -Cycles 20 -HotkeyStates -TitleRules
```

需要当前用户可用的 Explorer、Windows Terminal、PowerShell 7 和 [构建入口](phase-6.md#回归与复现) 准备的原生 UIA 探针。测试使用独立配置，输入期间不要切换窗口。不传新增开关时仍只执行普通 GUI 基线。

本轮不覆盖管理员／全屏状态、这些应用的临时对话框、其他应用的全部标题场景、跨屏／混合 DPI、物理插拔、自动隐藏任务栏或所有异步前台时序。当前构建完整证据与待验项继续见 [覆盖审计](coverage.md)，实机条件见 [操作单](manual.md)。
