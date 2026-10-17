# 阶段 5：四款实际应用的连续精度

历史记录：本文对应 0889BCE9 构建；当前构建与证据见 [阶段 6](phase-6.md)，旧构建覆盖快照见 [阶段 5 审计](phase-5-coverage.md)。

日期：2026-10-17（Asia/Shanghai）。补齐本机单屏实际应用矩阵及 F07 连续精度证据。本阶段只改测试脚本、公共测试辅助代码和文档，产品源码与发布包保持阶段 3 构建；整体开发验收仍未完成，外观与交互优化继续排在功能验收之后。

## 构建与环境

当前 EXE SHA256：`0889BCE91A15BB08E9BC197F4017F58D6AD39C94E8D0A408548AC18914985424`；[历史包校验](../../artifacts/packages/package-622ec0a08cc94ed283fd2dd237746838/package-verification.json) SHA256：`0C082493A62C5E3D85FEADFA072C18DE8DDF7655894CD10B0BA5DF972A25C1AA`。构建、61 项测试和热键／资源／保护恢复证据见 [阶段 3](phase-3.md)；最大化、实际对话框／全屏和覆盖升级见 [阶段 4](phase-4.md)，本轮不声称重新执行这些检查。

环境：Win11 企业版 10.0.26300，普通权限，单屏 2560×1440／工作区 2560×1392，96 DPI。每轮独立 Screen Pin 配置。

## 实际执行结果

| 应用 | 报告版本 | 循环 | 相对固定基准的最大边界误差 | 原始证据 |
| --- | --- | --- | --- | --- |
| Brave | 155.1.97.59 | 20 | 0 px | [精度报告](../../artifacts/apps-phase-5-precision/application-smoke.json) |
| VS Code | 1.130.0 | 20 | 0 px | [精度报告](../../artifacts/apps-phase-5-precision/application-smoke.json) |
| Explorer | 文件版本 10.0.26100.8875 | 20 | 0 px | [系统应用报告](../../artifacts/shell-apps/shell-apps-e155a5821f224827873c8b83b86fdce5/report.json) |
| Windows Terminal | 文件版本 1.24.261001001；包版本 1.24.12741.0 | 20 | 0 px | [系统应用报告](../../artifacts/shell-apps/shell-apps-e155a5821f224827873c8b83b86fdce5/report.json) |

每款应用以第 1 次循环前的实际 DWM 可见边界作为固定基准，之后每轮“捕获当前位置 → 确认捕获成功或同值无变化 → 实际位移并改尺寸 → 恢复”。**80 次循环均通过**，各轮原始边界保留在报告；不会逐轮重置基准来掩盖累计漂移。每次恢复均确认成功反馈、前台保持和配置文件字节哈希不变。相同位置的捕获允许走合法 no-op 路径。

本轮走显式选择窗口后的 GUI 命令路径，没有键盘或鼠标注入；不将这些样本写成真实热键延迟或跨 DPI 精度。未改动表单保存不反写舍入值的 GUI 证据仍引用同一构建的阶段 3 报告。

## Explorer 与 Terminal 的隔离方式

- Explorer 打开新建的唯一空文件夹。操作前核对 Shell COM 视图 HWND、实际文件夹绝对路径、进程映像／PID、唯一标题，且 HWND 不在启动前的窗口集合中。正常关闭该窗口，不结束 Explorer 进程；本机原有 Explorer 窗口句柄 `1639764` 在测试后仍存在。
- Terminal 使用 `wt -w new new-tab` 与唯一标题，只启动测试目录内的 PowerShell fixture；就绪文件含该子进程 PID 与 token。每次操作核对子进程映像和唯一脚本路径，以及新建窗口的 HWND、进程映像／PID、标题。按窗口正常关闭，并确认测试 shell 退出，不按进程名终止可能共享的 Terminal 主进程。
- 不改写 Terminal 设置文件；运行时使用本机已安装的设置。报告记录窗口类、DPI、工作区、操作前已有 HWND 及所有权信息。Screen Pin 正常退出，真实 HKCU Run 值未改动。

本机 Terminal 的预设身份实测为 `package:microsoft.windowsterminal_8wekyb3d8bbwe!app`，没有使用含版本的安装目录。仅证明当前安装版本的可靠包身份路径实际工作，不等于包应用真实版本升级已经验收。

## 测试代码改进

[application-smoke.ps1](../../scripts/application-smoke.ps1) 新增 `-PrecisionCycles`；原生 Win32 声明原样提取到共享 [application-native.cs](../../scripts/support/application-native.cs)，没有修改生产 API 路径。新增 [shell-apps-smoke.ps1](../../scripts/shell-apps-smoke.ps1)，复用原生声明及已有有界配置窗口命令。报告记录实际 EXE、脚本和辅助源码的哈希，以便核对执行版本。

## 复现及剩余范围

测试脚本使用 PowerShell 7；先完成 [阶段 3 构建](phase-3.md#可复现命令)，随后顺序运行：

```powershell
pwsh -NoProfile -File scripts/application-smoke.ps1 -OutputDir artifacts/apps-precision-new -PrecisionCycles 20
pwsh -NoProfile -File scripts/shell-apps-smoke.ps1 -Cycles 20
```

第一条要求两款目标应用实际可用；第二条要求本机 Explorer、已安装 Terminal 和可用 wt 执行别名。缺少条件或所有权证明不足时不能算通过。Brave／VS Code 使用独立 profile，本轮不重启 Explorer 或系统，不请求提权。原始窗口标题、设备信息和测试配置留在忽略的 artifacts 中。

仍待补充：Explorer／Terminal 的更多状态及真实热键兼容、快速切焦／关闭与编辑竞态、剩余配置 I/O 故障、托盘键盘与 Narrator、系统大字体／对比度。物理多屏／混合 DPI、真实 UAC、登录自启／Explorer 或系统重启、干净系统及真实包应用升级继续按 [完整审计](coverage.md) 与 [实机操作单](manual.md) 保留。不能将本机四个普通窗口的通过扩大为完整发布验收。

Terminal 测试启动参数依据：[Microsoft Windows Terminal 命令行参数](https://learn.microsoft.com/en-us/windows/terminal/command-line-arguments)。
