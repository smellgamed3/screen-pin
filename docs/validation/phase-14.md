# 阶段 14：浏览器与编辑器动态标题规则

历史构建：本页对应 734960C2 EXE；新构建的配置读取性能修复见 [阶段 15](phase-15.md)。

日期：2026-10-17（Asia/Shanghai）。上一轮真实热键状态检查已提交。本轮补 F01 的实际浏览器／编辑器标题变化，核对特定规则、首条优先、默认回退和更新范围；功能验收继续先于集中外观与交互打磨。

## 方法与范围

[应用脚本](../../scripts/application-smoke.ps1) 新增可选 `-TitleRules`。每款独立应用打开自建、唯一标题的本地文档，分别显示无关键字、`RuleAlpha`、`RuleBeta` 及同时包含两者的标题。浏览器使用实际 Ctrl+L 地址栏导航，VS Code 使用实际 Ctrl+P 转到文件；随后输入测试文档完整路径并确认打开，持续验证同一 HWND、PID、唯一 profile、标题前缀和前台归属。没有调用 SetWindowText 伪造应用标题，没有直接改写 Screen Pin JSON 来构造规则。

快捷入口依据 [Chromium 键盘访问说明](https://www.chromium.org/user-experience/keyboard-access/) 和 [VS Code 默认快捷键](https://code.visualstudio.com/docs/reference/default-keybindings)。打开文档后的实际标题和前后句柄写入原始报告，作为本机行为证据；不只根据快捷键文档推断执行成功。

- 通过自有配置界面依次捕获两条规则，Alpha 使用大小写不同的关键字 `rUlEaLpHa`。原应用默认预设及规则创建顺序保持。
- 用真实 F9 分别恢复 Alpha、Beta、同时匹配和默认回退四种标题。两条都匹配时采用首条 Alpha；关键字大小写不影响命中；每次核对实际边界、明确反馈范围、配置哈希及前台。
- 在 Beta 标题下用真实 F10 更新，要求只修改既有 Beta 预设并保留其 ID，Alpha 和共享默认不变；随后 F9 使用新 Beta 位置。
- 同时包含两个关键字时，用真实 F10 更新首条 Alpha，要求与 F9 的优先级一致，Beta 和共享默认不变；随后 F9 使用新 Alpha 位置。
- 切回无关键字文档，用真实 F10 更新共享默认，要求两条规则不变且默认 ID 保留；随后 F9 使用新默认位置。

标题导航使用原生 SendInput，文本按 16 个 UTF-16 单元一批发送，每批前后验证窗口归属和前台；遇到修饰键占用或输入不完整会停止并释放本次注入键。只打开当前测试目录中生成的既有文档，不使用剪贴板，不选择或修改用户文件。规则表单使用自有 GUI 控件，不当作纯键盘导航验收。

## 构建与结果

应用运行代码和发布包没有变化；继续沿用阶段 12 的 Release，既有构建检查和 16 项回归见 [阶段 12](phase-12.md)，上一轮真实热键状态证据见 [阶段 13](phase-13.md)。本轮在同一次应用执行中复测原有路径和新增标题路径。

| 工件 | SHA256 |
| --- | --- |
| [历史 ZIP 校验记录](../../artifacts/packages/package-a9f48db8e4a1416ab66a1ec5fca252a5/package-verification.json) | `1DECF740817DF6B7E3B41FC20573FD2F685D6EA89CDD347DC0E76C865DB188C0` |
| Release EXE | `734960C2508A2A45B2A6108AFD57FB4256D74AE133350427F7145F0FA4D5B41B` |

[最终完整报告](../../artifacts/apps-phase-14-final/application-smoke.json) 全部通过；[最终命令输出](../../artifacts/validation/phase-14-final-output.txt) 保留同次执行结果。环境：Win11 企业版 10.0.26300、单屏 2560×1440／工作区 2560×1392、96 DPI、普通权限。

| 应用／版本 | 新增标题检查 | 实际标题切换 | 新增真实 F9 | 最大边界误差 | 同次 50 次普通恢复 p95 |
| --- | --- | --- | --- | --- | --- |
| Brave 155.1.97.59 | 11 | 9 | 7 | 0 px | 189.120 ms |
| VSCode 1.130.0 | 11 | 9 | 7 | 0 px | 182.160 ms |

两款应用新增共 **22 条标题检查、18 次实际标题切换、14 次真实 F9 和 6 次真实 F10 更新**。前后标题均实际变化且仍为同一 HWND；大小写命中、双规则首条优先、默认回退和更新范围通过。双匹配标题的实际 F10 与 F9 均采用首条 Alpha，未改 Beta 或共享默认；每次恢复不写配置且不切焦，已有默认和两条规则的 ID 均保留。

同一次执行还通过各 20 次 GUI 精度循环、各 50 次普通实际恢复及两次最大化／普通转换（共 104 次状态组实际 F9），以及最小化 GUI 拒绝、真实文件对话框和全屏热键拒绝。所列边界误差与手动还原误差均为 0 px。普通 p95 包含额外进程归属核对和 10 ms 轮询，不直接与 fixture 的开销较小的计时比较。

两款应用主进程正常关闭，唯一 profile 路径扫描无残留；Screen Pin 正常退出，真实 HKCU Run 前后不变。最终脚本及三份辅助代码的 SHA256 与报告逐一一致，Release／ZIP 哈希未变。本轮未发现需要修改应用运行逻辑的问题。


## 复现及剩余验收

```powershell
pwsh -NoProfile -File scripts/application-smoke.ps1 -OutputDir artifacts/apps-phase-14-final -PrecisionCycles 20 -ExtendedStates -TemporaryDialogs -Fullscreen -HotkeyStates -HotkeyCycles 50 -TitleRules
```

按 [构建入口](phase-6.md#回归与复现) 准备 Release；使用 PowerShell 7 正常桌面、独立配置及 profile，按顺序运行。真实输入阶段不要切换窗口，已有 Screen Pin 实例会拒绝启动本组输入检查。关闭仅针对核对归属的测试窗口，真实 HKCU Run 和既有日用配置保持不变。

本轮仅验证当前版本、单屏、96 DPI、默认任务栏和普通权限。物理多屏／混合 DPI、插拔和身份关联、跨屏最大化、自动隐藏任务栏、异步切焦／拔屏竞态、真实 UAC、Narrator、字体／高对比度、系统／Explorer 重启、干净 Win11 和独立首次使用仍按 [实机操作单](manual.md) 保留。整体目标未完成；后续外观与交互优化后仍需回归。
