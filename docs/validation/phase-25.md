# 阶段 25：UIA 环境差异诊断与宿主只读对照

更新：2026-10-18。发布的 `v0.1.0-preview.1` 未重建；EXE SHA-256 仍为 `2F73650CE5A26D42B9A344A8B24196227D1A0A506140133B7CD189812EAD4623`，ZIP 仍为 `5C7D7559F5BC167C64470FD7FC0BB205175BBDD1A9C2105CFAAB03ABC2E2F15A`。

本轮缩小阶段 24 确认框／托盘键盘测试在 Sandbox 中失败的范围，未新增通过的完整验收组件。19 项当前二进制组件证据继续沿用[阶段 24](phase-24.md)；确认框键盘、托盘键盘、实际应用和 Explorer／Terminal 四项仍待宿主复测，物理多屏／混合 DPI、真实 UAC、Narrator、独立首次使用计时、系统重启登录仍未完成。

## 复现与对照

原始两项测试在新 Sandbox `a8f637c9-e8de-4b0e-85b3-071c42d25a93` 中重现：Win32 HWND 所属进程与期望一致，但原生 UIA 的 `CurrentProcessId` 返回 0，归属检查拒绝继续。

按单个变量尝试后，保留以下结论：

| 对照 | 实际结果及边界 |
| --- | --- |
| 将相同探针复制到来宾本地目录 | `a749dd85` 中两项仍失败；不能把差异归因于从映射目录启动探针 |
| 原生客户端代理表与名称 | `6574b649` 中加载 17 项代理、窗口名称可读，进程 ID 仍为 0；有代理不证明其属性和角色完整正确 |
| `CUIAutomation8` 替代 `CUIAutomation` | `3f89209a` 中三次仍为 0；未保留替换 |
| STA 替代 MTA | `61032bc2` 中三次仍为 0；未保留替换 |
| 普通属性读取替代快捷 getter | `2a7aebbb` 中 `GetCurrentPropertyValue(ProcessId)` 同样返回 0；未保留额外 Cargo feature 和读取方式 |
| .NET 跨进程读取同一 HWND | `018bccd1` 中三次均读取到真实所属进程；最初的同进程读取不作为这个结论的证据 |
| 显式 .NET 客户端试跑原键盘脚本 | `b0533a55` 中 UIA 聚焦被拒；改用受保护的来宾初始点击后，`9fd32b8c` 仍因按钮类型为 50033（Pane）而非 50000（Button）、托盘焦点 PID 为 0 被原断言拒绝；未保留替代验收接入 |

因此，目前只有可重现的 UIA 环境差异，尚未确定底层根因。不能把它写成 Screen Pin 功能故障已经修复，也不能把更换客户端或控件名称可读当作整项可访问性通过。中途的工具错误和失败输出保留在本地，不作通过证据。

宿主只读对照 `artifacts/uia-host-ae15f9150e1047078a16c3b88ebc736f/report.json` 通过：同一候选以独立配置后台启动，原生探针校验隐藏配置页按钮的进程归属、名称、角色及助记键。未发送按键或调用聚焦，观察前后前台 HWND 相同，自建实例正常退出。这只证明该宿主读取样本正常，不替代完整键盘、Narrator 或来宾验证。

## 保留的改进

原生探针失败时增加代理数量、提供者描述和名称诊断，原有 HWND／UIA 进程归属拒绝条件不变。新增只读 .NET UIA 探针用于对照，校验 Win32 HWND 归属、UIA 进程 ID、UIA 原生句柄以及读取后的归属；它没有聚焦或输入能力。

新增可选的最小复现入口：

```powershell
cargo build --locked --offline --bin accessibility_probe
pwsh -NoProfile -File scripts/sandbox-smoke.ps1 -Fixtures -FixtureTests uia-diagnostic
```

它只允许由隔离来宾驱动运行。在同一个自有测试窗口上，分别启动独立的原生和 .NET 读取进程，采样三次，并检查错误所属进程及无效 HWND 必须拒绝且不输出可接受结果。无任何 UIA 属性回退或默认通过逻辑。它不是默认九项矩阵的一部分；当前环境下应返回非零退出码，原矩阵也仍包含确认框和托盘。

最终入口运行于 `8de953d1-5f1c-4ec0-a2e5-b0c64e688a39`：三个原生读取均失败，三个 .NET 跨进程读取均正确，两个拒绝场景通过；整个诊断仍报告失败，自建 Sandbox 已停止。该报告仅用于定位问题，不增加产品验收通过数。

PowerShell 语法检查、原生探针构建、Rust 格式及探针严格 Clippy 检查通过。应用源码和已发布二进制均未改变。原始报告及哈希索引保留在本地 `artifacts/validation/phase-25-evidence-index.json`，未上传包含窗口或环境信息的原始材料。

API 背景参考：[Microsoft 的代理机制说明](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-clientsideprovider)和[.NET AutomationElement 定义](https://learn.microsoft.com/en-us/dotnet/api/system.windows.automation.automationelement)。它们只用于解释客户端接口，以上环境结论来自实际执行记录。
