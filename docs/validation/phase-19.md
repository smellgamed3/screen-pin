# 阶段 19：Terminal 夹具异常诊断

日期：2026-10-17（Asia/Shanghai）。本轮针对阶段 18 保留的 Terminal 子脚本确认超时完善诊断。仅修改验收脚本，Rust 产品代码、Release EXE、ZIP 及配置格式均未改变。

## 诊断缺口与改进

阶段 18 那次偶发超时的原始原因仍未确定，见 [原始失败](../../artifacts/shell-apps/shell-apps-b672a188dc1d4917a9310fe54ece496e/report.json)。本轮实测的是另一个明确缺口：子脚本发生确认写入异常后，父脚本只能等到通用超时，缺少错误阶段、命令序列及进程状态。

夹具从内嵌字符串提取为 [terminal-title-fixture.ps1](../../scripts/support/terminal-title-fixture.ps1)，正常命令、确认及轮询行为保留。子脚本异常时先保存 PID、令牌、当前／上一命令序列、执行阶段、异常类型、消息及栈，再抛出原异常。

[shell-apps-smoke.ps1](../../scripts/shell-apps-smoke.ps1) 每次确认等待检查异常记录并核对身份，直接报告具体阶段。失败报告在关闭窗口前保存子进程是否存在、身份是否匹配，以及就绪／命令／确认／异常文件的有界快照。正常确认还核对实际子进程 PID；既有窗口、前台及配置保护继续执行。

没有为偶发超时延长原来的等待预算，也没有自动重跑失败场景。异常被明确记录，仍以失败退出。

## 故障与正常复测

| 检查 | 结果与原始记录 |
| --- | --- |
| 旧内嵌夹具逻辑的最小故障复现 | [确认路径被目录占用，只有通用超时，没有结构化错误](../../artifacts/terminal-fixtures/fixture-65e0123b56564a7a9f890edd19c1daab/report.json)；仅为旧逻辑增加参数适配，未修改其执行行为 |
| 新夹具协议与端到端故障 | [33 条检查通过](../../artifacts/terminal-fixtures/fixture-46bfc43196f94c738896086effa7a20f/report.json)；受阻确认、20 次正常更新、重复序列、错误令牌、半写 JSON 后继续处理，以及父脚本异常传递 |
| 真正的 Terminal 父流程故障 | [按预期以失败退出并报告 writing-ack](../../artifacts/tfi-7651946a1f7245bc855fdc8bae5e68b0/shell-apps-fb4e41bb375c4150a149c5a983be5d17/report.json)；命令序列与异常一致，子进程身份匹配，Screen Pin 正常退出，Run 不变 |
| Explorer／Terminal 完整正常流程 | [各 20 次 GUI 恢复、9 条状态、7 条标题规则检查通过](../../artifacts/shell-apps/shell-apps-e77d5945112f4f169fd0c4c32ca14cdb/report.json)；几何误差 0 px，原有 18 次真实 F9 检查继续通过，测试窗口正常关闭 |
| 默认模式 | [不启用状态／标题规则时，各 20 次 GUI 检查通过](../../artifacts/shell-apps/shell-apps-8f9c5a2fe29b49b48974a67959bd6247/report.json)；覆盖不传 CommandPath 的启动分支，正常关闭及 Run 保持 |

旧最小复现与新专项使用相同脚本，SHA256 `2742A1E99818575468413C2DBCD8EFA1D9DCE825BB329F6D156BB6EBCB2C634E`。独立检查、真实 Terminal 正常流程及实际故障流程的夹具源码 SHA256 均为 `771DFD52CD5703F168A6468D906993A1C7CEB2570133C6EAA3A5A105E2FCDCBF`，与当前源文件及复制进私有目录的文件一致。


端到端故障注入首次使用嵌套目录时，Explorer 的 261／270 字符测试路径影响导航和路径比较，未到达 Terminal，见 [被中断的夹具验证](../../artifacts/terminal-fixtures/fixture-92e749778e1a45deba151ab6c37ce619/report.json)。之后改用工作区内较短的独立目录；[遗留窗口关闭记录](../../artifacts/validation/phase-19-long-path-cleanup.json) 对应经唯一标题、进程路径和私有目录核对的自有 Explorer 窗口。没有重启或终止共享 Explorer 进程。

## 构建与证据范围

EXE SHA256 `B141A2B2FA248CB7F764F648C5D186B97CDAAD52420E47B30212003B59505990`，ZIP SHA256 `28BF913D6D0B1D75F90F5D1A3F1AB552628C3DA205C7541E07114841B5ACF7FF`。本轮未重建程序；[阶段 18](phase-18.md) 的 66 项源码测试及其他同构建执行记录继续保留。

当前产品证据索引见 [阶段 19 索引](../../artifacts/validation/phase-19-evidence-index.json)：只将 Shell 正常流程更新为本轮新脚本的复测报告，其余 19 项使用阶段 18 同一 EXE 的原始记录。额外的夹具协议及故障注入报告单独列出，不冒充产品测试或整套重新执行。

```powershell
pwsh -NoProfile -File scripts/terminal-fixture-smoke.ps1 -WithTerminal
pwsh -NoProfile -File scripts/shell-apps-smoke.ps1 -HotkeyStates -TitleRules
```

独立夹具使用自建且身份核对的 PowerShell 子进程，清理时终止这些无限等待的专用子进程；Screen Pin 及真实 Shell 集成由其测试脚本正常关闭，只关闭明确属于测试的窗口。故障只占用私有确认路径，不影响日用配置或 Run 项。

本轮增强了可定位性，尚不能认定阶段 18 的偶发超时已解释或消除。真实多屏、混合 DPI、大字体／高对比度、Narrator、UAC／跨账号、重启／登录、自启、包应用升级、干净系统和独立新用户首次使用仍按 [覆盖审计](coverage.md) 与 [实机操作单](manual.md) 保留，完整目标尚未完成。
