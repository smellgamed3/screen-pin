# 阶段 4：覆盖升级与实际应用状态

历史记录：本文对应 0889BCE9 构建；当前构建与证据见 [阶段 6](phase-6.md)，旧构建覆盖快照见 [阶段 5 审计](phase-5-coverage.md)。

日期：2026-10-17（Asia/Shanghai）。本阶段补齐本机单屏证据，产品源码和发布二进制保持阶段 3 版本；没有重新打包。整体目标仍活动，原 Q1–Q18 和 [完整验收门槛](../acceptance.md) 保持有效。按用户要求，外观与交互打磨继续安排在功能、稳定性与验收之后。

同一构建的四款实际应用连续精度及 Explorer／Terminal 普通窗口证据已补于 [阶段 5](phase-5.md)，本页保留阶段 4 执行范围。

## 当前工件与已有验证

当前 [历史包校验](../../artifacts/packages/package-622ec0a08cc94ed283fd2dd237746838/package-verification.json) SHA256 为 `0C082493A62C5E3D85FEADFA072C18DE8DDF7655894CD10B0BA5DF972A25C1AA`；EXE SHA256 为 `0889BCE91A15BB08E9BC197F4017F58D6AD39C94E8D0A408548AC18914985424`。格式、严格 Clippy、61 项测试和该二进制的既有键盘／热键／资源／配置恢复结果见 [阶段 3](phase-3.md)。本轮仅增加测试脚本和文档，不将原有结果冒充再次执行。

环境仍为 Win11 企业版 10.0.26300、普通权限、单屏 2560×1440／工作区 2560×1392、96 DPI，使用独立配置和新建应用 profile。

## ZIP 覆盖升级

[升级报告](../../artifacts/upgrade/upgrade-2bf230953a514c4bb8f04e178efafca3/report.json)：**24 条检查通过**。旧二进制是阶段 2 已验证的 `46A9FFF0DCE0E30B80121D4D82498BB99C7467E2E78D1658450FB72DA9D3FB28`，新二进制为上述阶段 3 哈希；两者均标为开发预览 0.1.0，格式均为 v1，不宣称旧格式迁移。

操作在新建的 `program` 目录和相邻 `user-data` 目录中进行。先由旧构建保存不同位置的应用默认与标题规则、改绑 F11／F12，再正常退出；校验 ZIP 仅有两个预期根文件后覆盖程序目录，新构建使用相同的独立配置启动。

- 覆盖程序与新版首次启动，均未改变主配置和备份的字节哈希。
- 新版实际注册保存的自定义热键；未重新捕获就能用真实按键恢复旧标题规则，再变更标题回退到旧应用默认。
- 新版按键更新后可撤销到旧位置，预设 ID 保持；三次恢复各边误差均 **0 px**，恢复过程不写配置。
- 两个版本均正常退出；退出后可重新注册已释放热键；真实 HKCU Run 值未改动。

本项证明同账号、本机、显式隔离配置路径的 schema-v1 构建覆盖升级。不能替代默认 LOCALAPPDATA 路径、开机启动路径修复、系统重启、权限切换或干净机器的完整 F18 验收。

## Brave 与 VS Code 的状态矩阵

[最终应用报告](../../artifacts/apps-phase-4-stable/application-smoke.json)：Brave **155.1.97.59**、VS Code **1.130.0**，每款应用包括原有 6 条普通窗口检查及 **16 条新增状态检查**，两款合计 44 条检查。仅操作其新建 profile 和独立本地文档，主进程正常关闭，按唯一 profile 路径扫描无残留。

| 场景 | 直接结果 | 输入范围 |
| --- | --- | --- |
| 普通记住／移动／恢复 | 两款应用边界误差 0 px，前台保持 | 选择目标后走真实 GUI 命令路径 |
| 最大化捕获与恢复 | 捕获前后仍为最大化，保存最大化状态；恢复最大化边界误差 0 px，不改写配置 | 原生状态转换及 GUI 命令；不冒充真实热键最大化路径或完整瞬时闪烁监测 |
| 最大化恢复后手动还原 | 回到捕获时的普通窗口矩形，误差 0 px | 原生窗口还原 |
| 普通预设从最大化恢复 | 正确退出最大化，边界误差 0 px，保留前台且不写配置 | GUI 命令 |
| 最小化 | 记住和恢复均明确拒绝；目标不被还原，配置不变 | GUI 命令 |
| 实际文件对话框 | Ctrl+O 打开后，真实 F10／F9 明确拒绝；对话框与主窗口均未移动、配置和前台保持；取消后主窗口仍可配置 | 真实 SendInput；未选择文件，正常取消 |
| 实际全屏 | F11 进入覆盖整屏的全屏状态，再用真实 F10／F9，均明确拒绝且不移动、不写盘、不切焦；F11 正常退出 | 真实 SendInput；两款全屏样本 IsZoomed 均为 false |

## 测试准备发现与修正

初始对话框／全屏准备失败的报告保留在 artifacts，未作为产品通过证据。只核对主进程会漏掉本机 Brave 的文件对话框：实测它由带相同独立 profile 的 `chrome.mojom.UtilWin` 直接子进程承载，原生 root-owner 仍指向测试主窗口。脚本现在在输入和关闭前同时核对主窗口 PID、子进程映像／父 PID／唯一 profile、对话框类及原生窗口归属，输入前后核对实际前台；不将“类名相同”当作所有权证明。

失败时对自建 VS Code 窗口的 [截图](../../artifacts/apps-phase-4-owned-broker/VSCode-failure.png) 显示首次欢迎层拦截了快捷键。测试实例改用官方测试采用的 `--skip-welcome`／`--skip-release-notes`，不登录账户、不改变日用 profile；随后真实文件对话框和 F11 路径通过。辅助输入使用目标线程键盘布局映射扫描码，记录脚本与辅助源码哈希；前面的失败不作为“零扫描码是根因”的证据。

应用脚本现在要求两款目标应用都实际执行并通过，跳过或准备失败会使总结果失败。普通／最大化与真实输入各有范围声明；当前所有测试实例正常退出，真实开机启动值未改动。没有触发 UAC，没有重启 Explorer 或系统。

一次复测在对话框打开后立即比较几何时失败，未把它直接归因为产品移动。脚本现要求父窗口和对话框连续 10 次采样几何稳定，再开始按键检查；最终报告保存每次按键前后两者的原始边界，均不变。真实输入路径发生准备或断言错误时停止后续应用输入，只清理已核对所有权的测试实例，不能在用户切焦后继续切入下一应用发送按键。

## 复现

测试要求 PowerShell 7、桌面会话和对应应用；真实输入检查期间保持测试目标前台，切焦后后续输入取消。先完成 [阶段 3 构建](phase-3.md#可复现命令)，再顺序执行：

```powershell
pwsh -NoProfile -File scripts/upgrade-smoke.ps1 -PreviousExe <已验证旧构建的绝对路径>
pwsh -NoProfile -File scripts/application-smoke.ps1 -OutputDir artifacts/apps-matrix-new -ExtendedStates -TemporaryDialogs -Fullscreen
```

升级脚本默认使用当前 dist ZIP 和 Release EXE，比对包内哈希；旧 EXE 需是不同内容的可信历史构建。重复应用检查使用新的 OutputDir，报告和测试配置保留在忽略的 artifacts 中。

后续继续 Explorer／Terminal 等矩阵、实际应用连续精度、快速切焦与编辑竞态、剩余配置 I/O 故障及可访问性。物理多屏／混合 DPI、真实 UAC／系统重启／干净系统、独立用户上手与 Narrator 等仍待 [实机验收](manual.md)，不能由本轮替代。

测试实现依据：[Microsoft KEYBDINPUT](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-keybdinput)、[MapVirtualKeyExW](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-mapvirtualkeyexw)、[VS Code 官方集成测试启动参数](https://github.com/microsoft/vscode/blob/main/scripts/test-integration.sh)。
