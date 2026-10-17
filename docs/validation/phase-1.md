# 阶段 1：原生实现与受控单屏验证

日期：2026-10-17。本记录为阶段 1 历史快照；最新构建与证据见 [阶段 6](phase-6.md)。整体开发验收目标保持活动，原 Q1–Q18 及 [完整验收门槛](../acceptance.md) 继续有效，阶段 1 逐项证据见 [历史覆盖审计](phase-1-coverage.md)。

## 已完成的改进

已实现 Rust／Win32 托盘与基础配置界面、两个可配置全局热键、应用默认及有序标题规则、显示器组合方案、比例几何、撤销、JSON 保护与备份，以及同账号提权交接。

复核后的交互改进包括首次使用说明、默认／特定规则范围和匹配预览、按需展开编辑区、创建缺失默认的入口、应用路径变更时整体迁移，以及自启路径诊断和修复入口。日常记住与恢复各用一个热键，反馈保持原窗口焦点。

本阶段发现并处理的主要可靠性问题：

1. 最大化公开 API 可能激活后台窗口。需要状态转换时要求用户先聚焦目标，再触发热键；保留公开 API，并记录无法原子锁住全局前台的系统竞态边界。
2. 无响应目标不能因旧矩形暂时稳定就报告“受限恢复”。增加有界 liveness 检查，诚实返回未确认，后续操作仍可继续。
3. 新拓扑保存失败时先取消旧活动路由，避免旧方案配上新屏幕；每次延迟纠偏和成功确认前复核整个拓扑。
4. 序列号冲突和同型号屏幕不能猜测对应；唯一强证据确定方案后，仅停用尚未关联的目标，保留已确认屏幕可用。
5. 列表和热键请求携带窗口世代标记，拒绝已关闭／重建目标，退出只清理自身标记。
6. 提权子实例获父确认前禁止配置写入；恢复／重置入口同样必须持有唯一写入锁。
7. 写入锁移交时，第三次普通启动可能抢占。增加贯穿父子生命周期的独立启动锁，认证子进程复制同一文件对象，保留无空档的启动占用。
8. Explorer 广播会到达两个顶层窗口；重复添加同一托盘图标会误报失败。改为只由隐藏宿主处理，原生回归验证两种投递顺序。

## 当前构建与证据

当前开发预览为 0.1.0 Windows x64，构建检查包含格式、严格 Clippy 和 all-targets 测试，**60 项通过、0 项失败**。静态 CRT 配置及实际 PE 导入检查均未发现需另随包提供的 VC 运行库；这仍不能替代干净机器运行。

| 工件 | SHA256 |
| --- | --- |
| 阶段 1 ZIP（历史校验值） | `4EFF81FD809AA4455BE7B89B4AFF22DC1DEC26A2480B765360ED938787AAC28F` |
| 解压后 screen-pin.exe | `3349C9819B32DDF278E15A1033529360B9611CC8D72F13E1BDD1AFEC3973002C` |

| 检查 | 实际结果与边界 |
| --- | --- |
| 最终 ZIP 解压后 GUI | 34 条断言全部通过；捕获／恢复、规则预览／排序、表单精度、撤销、迁移确认／取消／冲突、显式默认、关闭驻留、重复启动与退出，以及自启诊断。实际运行解压后的 Release，HKCU Run 值未变，测试实例正常退出。[原始报告](../../artifacts/package-smoke-5c38702d5893465c93d498f5185bea5c/evidence/gui-smoke.json) |
| 真实应用主窗口 | Brave 155.1.97.59、VS Code 1.130.0，独立用户数据目录及唯一测试文档；通过 GUI 记住、只移动自建主窗口、恢复。两应用 DWM 四边误差均为 0 px，成功反馈及前台保持检查通过；所有自建实例正常退出，真实自启注册值未变。限普通权限、普通状态、单屏 96 DPI；未覆盖其临时对话框、最大化或跨屏。[原始报告](../../artifacts/real-apps-release-3349C981/application-smoke.json) |
| 最终 Release 真实热键 | 100 次“F10 记住→移动 fixture→F9 恢复”，200 个主要热键动作；全部使用 SendInput 而非伪造 WM_HOTKEY。单屏 96 DPI、工作区 2560×1392，最大可见边误差 0 px；首个可见匹配矩形 p95 15.559 ms，成功反馈完成 p95 32.337 ms；每轮都等完成反馈再继续。全过程前台为自建 fixture；无预设不写／不移动、同值不写、长按重复抑制均通过。[原始报告](../../artifacts/hotkeys/hotkey-20261017T044542536Z-7c986e30/report.json) |
| 100 次循环后资源 | 上述 Release 的 Private Bytes 为 2,404,352 B，较循环前增加 327,680 B；低于预算，但这是一次工作负载样本，不能证明长期无泄漏。CPU 工作负载增量不当作空闲 CPU |
| 最终 Release 空闲资源 | 同一 EXE，预热后 60.704 秒 CPU 计数无可测增量；托盘 Private Bytes 峰值约 2.051 MiB，界面样本约 2.027 MiB。后台启动至 host 回应 WM_NULL 代理约 266 ms，不把该代理视为实际托盘／热键完整就绪；正常退出且无残留。[原始报告](../../artifacts/performance/perf-20261017T044647762Z-b2569ac9/report.json) |
| Debug 适配层探针 | 自建独立子进程窗口，50 次恢复最大边误差 0 px；最大化及正常还原、无响应约 235 ms、错误 PID／token 拒绝及标记清理通过。OS 本次未实际复用同一 HWND 数值，不能声称该分配事件已实测。[原始报告](../../artifacts/validation/desktop-probe-token-debug.json) |
| 生命周期回归 | 真实多进程证明交锁时第三启动被拒、首次竞争仅一方成功、不同目录隔离、父持有者退出后子复制句柄继续保护启动占用；托盘回归模拟自有图标丢失后向两个自建窗口投递消息。均未触发真实 UAC 或重启用户 Explorer |

热键延迟从测试发送输入开始，包括桌面调度及脚本轮询；并非内部“收到热键”的精确打点。它们只描述该单屏 fixture 的本地分布，不推定真实应用或跨 DPI 性能。原始 artifacts 为本地忽略目录；仓库保留测试脚本及上述审计摘要，避免提交窗口标题、设备路径等原始信息。

## 复现入口

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-release.ps1 -Offline
pwsh -NoProfile -File scripts/ui-smoke.ps1 -ExePath target/release/screen-pin.exe -FixturePath target/debug/desktop_probe.exe -OutputDir artifacts/recheck-gui
pwsh -NoProfile -File scripts/hotkey-smoke.ps1 -ExePath target/release/screen-pin.exe -OutputDir artifacts/hotkeys -Cycles 100
pwsh -NoProfile -File scripts/perf-smoke.ps1 -ExePath target/release/screen-pin.exe -OutputDir artifacts/performance
```

首次源码构建可去掉 `-Offline` 下载依赖。smoke 脚本要求 PowerShell 7（`pwsh`），当前证据来自 7.6.5；应用自身没有这一依赖。GUI fixture 来自 `cargo build --locked --bin desktop_probe`；每个脚本均使用独立配置，顺序执行，避免热键争用。真实热键脚本要求新建 fixture 保持前台，用户切换焦点时即取消输入；不操作已有用户窗口。真实应用脚本为 [application-smoke.ps1](../../scripts/application-smoke.ps1)，通过参数指定本机 Brave／VS Code 路径，只测试其新建独立实例。

## 尚未完成的验收

- 物理多屏、混合 DPI、同型号屏幕、交换端口／扩展坞、唤醒及任务栏位置变化。
- 真实 UAC 成功、取消、跨账号及故障回退；模拟或同权限进程测试不能替代。
- 独立新用户首次使用、Narrator、系统大字体、高对比度和实际不同缩放。
- 真实 Explorer 重启、系统登录自启及路径修复、干净无开发工具链机器与覆盖升级。
- 扩充真实应用的状态／对话框／身份兼容性与跨 DPI 性能矩阵，长期资源观察及其余 F 场景交错。

已准备 [实机验收操作单](manual.md)。缺少设备、权限或独立操作者的项目保留未验证；所有这些门槛继续属于原目标，不由单元测试或受控单屏结果代替。
