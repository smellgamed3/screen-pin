# 阶段 20：干净 Windows Sandbox 发布包验证

日期：2026-10-17（Asia/Shanghai）。本轮补充干净隔离桌面的分发证据；产品源码、EXE、ZIP 和配置格式均未改变。

## 环境与隔离

宿主已启用 Windows Sandbox，安装了 0.8.107.0 客户端。只读查询确认没有已有实例后，以本轮随机 ID 新建环境；输入只读映射原始发布 ZIP 和验收脚本，结果映射到独立目录。配置禁用网络、剪贴板、音视频输入、打印机重定向及 vGPU。完成后只停止本轮创建的 ID，并再次核对实例已消失。

Sandbox 每次启动提供隔离的初始 Windows 环境，宿主安装的应用不直接出现在来宾中，见 [Microsoft Sandbox 说明](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/)。本脚本采用 [官方 CLI](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-cli) 的列举、指定 ID 创建、连接和停止，以及 [只读文件映射与登录命令配置](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file)。没有启用新系统功能、请求提权或安装来宾开发工具。

最终来宾：Windows 11 Enterprise 24H2 x64，build 26100.9711，UI 语言 en-US，内置 PowerShell 5.1.26100.9711；32 个逻辑处理器，约 4 GiB 可见内存。当前诊断记录 1 个虚拟显示器，2032×1111，工作区 2032×1063，96 DPI。

命令检查未发现 cargo、rustc、cl、vswhere、dotnet 或 pwsh；没有额外安装 SDK 或运行时。测试脚本使用 Windows 内置 .NET Framework／PowerShell 组件编译自有 API 辅助代码；应用自身加载的非 Windows 目录模块为空。宿主只读输入的 ZIP、脚本和辅助文件哈希均与来宾核对。

[宿主报告](../../artifacts/sandbox/sandbox-3f3cb237-c806-48dc-88ef-ebfc3828ad78/host-report.json)、[来宾报告](../../artifacts/sandbox/sandbox-3f3cb237-c806-48dc-88ef-ebfc3828ad78/result/guest-report.json)、[显示器诊断](../../artifacts/sandbox/sandbox-3f3cb237-c806-48dc-88ef-ebfc3828ad78/result/guest-diagnose.json)、[界面截图](../../artifacts/sandbox/sandbox-3f3cb237-c806-48dc-88ef-ebfc3828ad78/result/guest-ui.png)。截图已检查，中文字段和反馈可读。

## 实际流程

**47 条检查通过**；GUI 与普通真实 F9 恢复各边误差均为 0 px。每轮保存预期／实际 DWM 矩形、耗时和前台核对结果。

| 场景 | 结果 |
| --- | --- |
| 首次默认启动 | 不传 show／background，约 379.369 ms 显示可见界面；在来宾默认 LOCALAPPDATA 创建配置，两枚默认热键注册成功 |
| 捕获与恢复 | GUI 只捕获所选自建窗口；GUI 恢复不写配置；实际 F10 更新该应用默认，20 次真实 F9 均保持前台、误差 0 px、配置字节不变 |
| 关闭与重复启动 | 关闭界面继续驻留；重复启动正常退出，只保留一个 host，并显示原界面 |
| 普通进程重启 | 两个主实例均正常退出；已有配置后默认驻留托盘，配置原字节保持；实际 F9 继续恢复原预设，误差 0 px |
| 自启默认 | 来宾真实 Run 项前后均未改变 |


所有按键由来宾进程在来宾桌面发送；只操作其自建 fixture，发送前后核对前台身份。GUI 捕获与恢复使用自有控件消息，单独记录，不算作真实热键输入。

## 验收脚本调试记录

本轮保留调试版失败，不把它们列为产品缺陷：

- [首轮](../../artifacts/sandbox/sandbox-4ce4cb70-31c5-4236-9316-e4aba0bd0e99/host-report.json) 在窗口句柄与按钮出现后立即检查可见性，判定过早。[下一轮](../../artifacts/sandbox/sandbox-0c65fad0-81a7-4a95-989b-3af8ef6899c7/result/guest-report.json) 记录到句柄就绪约 268 ms 时仍不可见，约 449 ms 已显示；最终脚本等待实际可见状态。
- Windows PowerShell 5.1 读取无 BOM 的 UTF-8 配置时必须显式指定编码；原先按 ANSI 解码造成中文字段解析失败。最终脚本以 UTF-8 读取 JSON，脚本自身保留 UTF-8 BOM，依据见 [Microsoft 编码说明](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_character_encoding?view=powershell-7.5)。
- [追加诊断命令的调试轮次](../../artifacts/sandbox/sandbox-a63e3d65-27ab-4067-bbda-162342c507ea/host-report.json) 已输出完整诊断 JSON，但快速退出子进程的状态校验失败。[宿主最小复现](../../artifacts/validation/debug-ps51-exit.ps1) 三次得到 Start-Process 返回对象的空退出码，直接创建 .NET Process 则返回 0，见 [观测转录](../../artifacts/validation/phase-20-process-observation.json)。最终脚本直接持有进程对象，并按 UTF-8 读取管道输出。

三个被中断的环境均正常停止；调试版脚本、配置及报告保留在各自独立目录。最终验收只引用最后一轮与当前脚本哈希一致的结果。

## 构建、复现与剩余范围

EXE SHA256 `B141A2B2FA248CB7F764F648C5D186B97CDAAD52420E47B30212003B59505990`，ZIP SHA256 `28BF913D6D0B1D75F90F5D1A3F1AB552628C3DA205C7541E07114841B5ACF7FF`。本轮沿用 [阶段 18](phase-18.md) 的 66 项源码测试和同一产品构建，不重复宣称源码测试已重新执行。

当前 [证据索引](../../artifacts/validation/phase-20-evidence-index.json) 在阶段 19 的 20 项产品组件记录之外新增 Sandbox 验证，共 21 项分阶段产品证据；原有 33 条夹具专项仍单列，不视为本轮整套重跑。

```powershell
pwsh -NoProfile -File scripts/sandbox-smoke.ps1
```

宿主需要已有的 Windows Sandbox 功能和客户端，以及 PowerShell 7；来宾只使用内置 PowerShell 5.1 和 Windows 组件。若已有 Sandbox 实例，脚本直接停止准备工作，不接管该实例。

本轮证明原 ZIP 在这个干净的 Windows 11 x64 虚拟桌面中可启动、捕获、恢复、重复启动、保留配置并退出。来宾账号是 Sandbox 管理员账号；不据此证明普通新账号的全部权限组合、真实 UAC 交接、物理多屏／混合 DPI、系统重启／自启登录、真实 Narrator 或独立新用户首次使用。完整目标仍按 [覆盖审计](coverage.md) 和 [实机操作单](manual.md) 推进。
