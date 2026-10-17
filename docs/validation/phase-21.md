# 阶段 21：真实来宾托盘重建和自启项管理

日期：2026-10-17（Asia/Shanghai）。沿用 B141A2B2 发布构建；本轮只修改验收脚本和文档，未改产品源码、配置格式或发布包。

## 结果与范围

原 ZIP 在新建 Windows Sandbox 中完成 **20 条生命周期检查**：实际重启来宾 Explorer 后，原应用进程继续运行、配置字节不变、托盘重新注册，真实 Ctrl+Alt+F9 恢复边界误差 **0 px**；实际来宾 Run 项的启用、路径警告、修复和关闭均通过。

[宿主报告](../../artifacts/sandbox/sandbox-5f42cf24-2e10-4b61-acfa-352613fa1768/host-report.json)、[来宾报告](../../artifacts/sandbox/sandbox-5f42cf24-2e10-4b61-acfa-352613fa1768/result/guest-report.json)。两个测试实例均通过正常退出流程结束，退出码为 0；自建 Sandbox 已停止，后续列表不含本轮 ID。

| 场景 | 直接证据 |
| --- | --- |
| Explorer 重启 | 只选择当前来宾桌面的 explorer.exe；PID 5840 → 4208，Screen Pin PID 始终为 6696 |
| 托盘重建 | 重启前后 Shell_NotifyIconGetRect 返回成功，矩形均为 (1819,1063)–(1851,1111)，宽高均大于 0 |
| 恢复可用 | 实际 F9 后 DWM 可见边界与预期均为 (97,100)–(463,373)，保持前台且不写配置 |
| 启用自启 | 设置页明确保存后，真实来宾 HKCU Run 中出现当前 EXE 的 --background 命令 |
| 路径修复 | 将同一 EXE 复制到新目录后启动，界面提示启动路径不一致；明确保存后 Run 使用新路径，未改动原配置字节 |
| 关闭自启 | 设置页取消并保存后，真实来宾 Run 中 ScreenPin 项消失 |

来宾环境与阶段 20 同为 Windows 11 Enterprise 24H2 x64、26100.9711、内置 PowerShell 5.1、Sandbox 管理员账号、单虚拟屏 96 DPI。脚本额外核对 WDAGUtilityAccount、微软虚拟机型号、固定映射路径及不同于宿主的计算机名；只重启该隔离桌面的 shell，不操作宿主 Explorer、Run 项或操作系统。

托盘原生矩形查询依据 [Microsoft Shell_NotifyIconGetRect](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shell_notifyicongetrect)。成功返回后还等待非空矩形，避免把任务栏重建中的零高度占位矩形当作可用图标。

## 基础流程复测

修改后的公共脚本支持仅加载辅助函数；默认基本模式仍完整执行原 ZIP 的 47 条检查，[最终宿主报告](../../artifacts/sandbox/sandbox-6d96ae9d-0f1b-4bf8-9a7b-622c5b0f03a8/host-report.json)和[来宾报告](../../artifacts/sandbox/sandbox-6d96ae9d-0f1b-4bf8-9a7b-622c5b0f03a8/result/guest-report.json)均通过，两次主实例正常退出，环境已停止。20 次主要真实 F9、GUI 恢复和普通进程重启后的 F9 各边误差均为 0 px。产品保持阶段 18 的 66 项源码测试／严格检查结果，本轮没有重复执行或宣称重跑。

当前[证据索引](../../artifacts/validation/phase-21-evidence-index.json)共 22 项分阶段产品证据：本轮重跑基础 Sandbox 并增加生命周期，另外 20 项沿用既有执行记录，不算作本轮重跑。脚本哈希与本次输入逐项核对；独立夹具专项仍单列。

当前 EXE SHA256 `B141A2B2FA248CB7F764F648C5D186B97CDAAD52420E47B30212003B59505990`，ZIP SHA256 `28BF913D6D0B1D75F90F5D1A3F1AB552628C3DA205C7541E07114841B5ACF7FF`。

## 调试及尚未验证的重启登录

初次 [生命周期脚本调试](../../artifacts/sandbox/sandbox-f765ea09-b968-4aa4-a0ba-37daae8271db/result/guest-report.json) 已观察到 Explorer 更换 PID、应用和配置不变，但在任务栏尚未完整布局时立即聚焦失败。最终脚本等待非空托盘矩形，并在有界时间内重试自建 fixture 聚焦；没有修改产品的窗口恢复实现。

本轮还探索了来宾 shutdown /r 后的登录验证：[首次记录](../../artifacts/sandbox/sandbox-e93f8ad2-3c47-44d6-a982-26930dd3be17/host-report.json)、[复测记录](../../artifacts/sandbox/sandbox-529b3e9c-2001-4334-bfc2-400a7eaa986e/host-report.json)及各目录中的输入脚本、phase1.json 和最终来宾文件保留原样。过程中观察到实例一度不在列表、后续来宾计算机名改变、配置哈希检查失败，宿主读取时的摘要与最终来宾文件也不一致；尚不能确认连续的同一环境和完整证据链，也不能据此归因于产品。两个环境最终均核对为已停止。

重启登录探索代码没有并入日常验收入口；提交的生命周期脚本只执行已验证的 Explorer 重启及 Run 项管理。**实际系统重启、登录自动运行仍未验证**；不将启动项登记成功算作登录成功。完整 Win11 普通账号、真实 UAC、物理多屏／混合 DPI、Narrator 和独立新用户测试继续按 [覆盖审计](coverage.md) 和 [实机操作单](manual.md) 保留。

## 复现与后续

宿主已有 Windows Sandbox 和 PowerShell 7 时，顺序运行：

```powershell
pwsh -NoProfile -File scripts/sandbox-smoke.ps1
pwsh -NoProfile -File scripts/sandbox-smoke.ps1 -Lifecycle
```

两种模式均拒绝接管已有实例，创建只读输入和私有输出，只停止自身随机 ID。来宾使用内置 PowerShell 5.1，无额外开发工具安装。

按用户要求，先收尾可执行的本机单屏功能与回归，再继续外观和交互优化。第二轮重点为主界面信息层级、记住／恢复的日常路径、空状态和错误提示，以及键盘焦点与配置反馈；每次界面修改后复核截图和对应交互，既有待测门槛继续保留。
