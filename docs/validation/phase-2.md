# 阶段 2：本机单屏、键盘与异常处理

日期：2026-10-17（Asia/Shanghai）。本文已冻结为阶段 2 历史记录；最新构建见 [阶段 3](phase-3.md)。本轮按用户要求先完成本机单屏测试；多屏等原有门槛继续有效，尚未宣布首版最终验收通过。[阶段 1](phase-1.md) 及其 [覆盖快照](phase-1-coverage.md) 保留为历史，本阶段覆盖见 [历史快照](phase-2-coverage.md)，当前覆盖以 [coverage.md](coverage.md) 为准。

## 实测发现与修复

1. **键盘保存后无法继续 Tab。** 保存按钮在 worker 忙时被禁用，Win32 清空该线程的键盘焦点。现在先把焦点交给主窗口；操作完成后，仅在主窗口仍为前台且用户没有改选其他控件时，恢复到仍可用的原控件，否则回到主导航。用户切去其他应用时不恢复焦点。
2. **只读结果框拦截 Tab。** 最近结果和关联预览使用多行 EDIT，原生行为会保留 Tab。现在只对这两个输出框处理 Tab／Shift+Tab，按标准 tab stop 前后导航；方向键、选择和复制继续使用原生行为。
3. **关联预览缺少可访问名称。** 原生 UIA 读取确认该字段名称为空。增加可见的“关联预览与影响范围”标签，并保持标签与 EDIT 的创建顺序和版面关系；原生名称及控件角色断言通过。

焦点和 Tab 路由变化在 [shell.rs](../../src/shell.rs)，新增 [原生 UIA 探针](../../src/bin/accessibility_probe.rs) 和三份隔离脚本用于复现。探针默认只读；显式 `--focus` 仅允许经 PID 核对的 Screen Pin 首个导航按钮或自建热键 fixture，调用公开 UIA SetFocus。后续输入持续检查真实前台，焦点移出即取消。

测试过程中发现系统 AMD 工具占用某些 Alt 组合键；恢复由测试打开的面板后，主流程改为 Tab／空格。首次把 .NET Framework UIA 程序集装入 PowerShell 得到通用 Pane 回退，因此不以它判断应用缺陷；最终全部使用原生 COM UIA，报告保留微软 MSAA／HWND provider、角色、名称及实际 PID。

## 当前工件

版本仍为开发预览 0.1.0，Windows x64。格式、严格 Clippy、all-targets **60 项测试全部通过**；键盘与原生行为另由下面的集成报告证明，不混入单元测试计数。

| 文件 | SHA256 |
| --- | --- |
| [阶段 2 历史包校验](../../artifacts/packages/package-7990c7af631c4d918b2d70b2973dc15e/package-verification.json) | `3E3318A77E89712584459A7AA23A60A460CC447096D8DB9A2B575E97DDC27ABD` |
| Release EXE／解压后 EXE | `46A9FFF0DCE0E30B80121D4D82498BB99C7467E2E78D1658450FB72DA9D3FB28` |

环境：Windows 11 企业版 10.0.26300、x64；单屏 2560×1440、工作区 2560×1392、96 DPI；普通权限。测试配置、应用 profile 和 fixture 均独立；日用配置与真实 HKCU Run 值未改写。

## 当前构建实际证据

| 检查 | 结果及范围 |
| --- | --- |
| [解压 ZIP](../../artifacts/packages/package-7990c7af631c4d918b2d70b2973dc15e/package-verification.json) | 包仅含 EXE 与 README；解压 EXE 哈希与 Release 相同。GUI 34 条断言通过；实例正常退出，解压目录下无剩余进程 |
| [真实键盘与 UIA](../../artifacts/keyboard/keyboard-9cd12a31d6104299a69cdfdad4021f84/report.json) | Release，177 条检查通过。真实 SendInput 选择／捕获／百分比编辑／保存／撤销／两条规则创建及前后排序，Alt+F4 隐藏保留进程。三页正反向 Tab 均遍历全部启用控件，96 次焦点观察均完整可见；62 条 UIA 样本均有名称与预期原生角色 |
| [真实热键回归](../../artifacts/hotkeys/hotkey-20261017T051321080Z-2136f34e/report.json) | Release 自建 fixture，100 次真实 F10→位移→F9 循环，最大边界误差 0 px；可见匹配 p95 16.193 ms，明确完成反馈 p95 32.895 ms；同值不写、无预设不写／不移动、长按重复抑制及前台保持均通过 |
| [暂停响应及尺寸约束](../../artifacts/backend/backend-a2124e2a857c4031b0ade582a84c359f/report.json) | 仅向隔离实例发送 shell 命令。fixture 消息泵暂停 1.2 s，约 259 ms 返回暂无法确认；15 次探测中 host 与配置窗口均响应，重叠命令被拒绝、未排队改写预设。请求允许晚到；恢复响应后下一次操作成功。强制最小尺寸时约 189 ms 报受限、不反写；解除限制后精确恢复 |
| [连续操作与资源](../../artifacts/backend/backend-a2124e2a857c4031b0ade582a84c359f/report.json) | 300 次 GUI 命令捕获／恢复，共 600 次主要操作；每轮可见边界误差 ≤2 px。每 25 次采样，Private Bytes 从 2,633,728 B 到 2,961,408 B，峰值约 2.824 MiB；25–300 次阶段波动约 0.148 MiB，无持续单调增长。操作后空闲 60.606 s，CPU 计数无可测增量，Private Bytes 降至 2,867,200 B。限本次有界观察，不宣称长期无泄漏 |
| [空配置资源复测](../../artifacts/performance/perf-20261017T051410991Z-b4e5947b/report.json) | 同一 Release，启动消息循环代理 268.676 ms；预热后空闲 60.723 s，CPU 累计 15.625 ms（预算 300 ms）；托盘私有内存峰值约 2.051 MiB，界面约 2.059 MiB；正常退出，无残留。启动代理不等于实际托盘／热键完整就绪时间 |
| [实际应用回归](../../artifacts/apps-phase-2-release/application-smoke.json) | Brave 155.1.97.59、VS Code 1.130.0，独立 profile／文档主窗口；GUI 记住→位移→恢复，各边误差 0 px，前台不变。主进程正常退出，按唯一 user-data 目录的后续扫描无残留。限普通窗口，不扩大为对话框、管理员或最大化通过 |

热键耗时包括输入包装、桌面调度和轮询；后台命令脚本不冒充真实键盘路径。UIA 名称／角色和焦点可见性不是 Narrator 试听，也不能证明系统大字体、高对比度或不同 DPI。

## 可复现命令

测试脚本要求 PowerShell 7；应用运行不需要它。先构建测试辅助二进制，再顺序执行前台输入检查，避免热键和焦点争用：

```powershell
cargo build --locked --bins
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-release.ps1
pwsh -NoProfile -File scripts/package-smoke.ps1
pwsh -NoProfile -File scripts/keyboard-smoke.ps1
pwsh -NoProfile -File scripts/hotkey-smoke.ps1 -ExePath target/release/screen-pin.exe -OutputDir artifacts/hotkeys -Cycles 100
pwsh -NoProfile -File scripts/backend-smoke.ps1 -Cycles 300 -IdleSeconds 60
```

依赖已缓存时可给 Cargo 添加 `--offline`、构建脚本添加 `-Offline`。键盘脚本如遇前台限制可加 `-WaitForForeground`；等待期间不发送输入，超时正常退出。所有截图和原始报告保存在忽略的 artifacts；仓库保存脚本与不含设备路径的摘要。

## 尚未取得的证据

- 独立新用户 60 秒上手、真实 Narrator、系统大字体／高对比度、完整托盘纯键盘退出及确认对话框路径。
- 完整应用矩阵，包括 Explorer／Terminal、临时对话框、打包应用升级、实际应用最大化／全屏、自调整尺寸及竞态。
- 系统登录自启／真实路径修复、Explorer 和系统重启、实际 UAC 成功／取消／跨账号／故障接管、干净系统及 ZIP 覆盖升级。
- 物理多屏、同型号屏幕、混合 DPI、换线／扩展坞／唤醒等，继续按 [实机操作单](manual.md) 保留。

本轮单屏验证显著补强了输入、异常和资源证据；它仍不替代 [完整发布门槛](../acceptance.md)。后续以对应原始证据逐项收口。

实现依据：[Windows 对话框 Tab 导航](https://learn.microsoft.com/en-us/windows/win32/dlgbox/dlgbox-programming-considerations)、[UIA SetFocus](https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomationelement-setfocus)、[Win32 控件名称](https://learn.microsoft.com/en-us/accessibility-tools-docs/items/win32/control_name)。
