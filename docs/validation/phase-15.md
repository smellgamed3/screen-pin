# 阶段 15：配置读取性能与大小边界

历史构建：本页对应 7AB66FC9 EXE；本页列出的写入上限待查项已在 [阶段 16](phase-16.md) 修复并验证。

日期：2026-10-17（Asia/Shanghai）。上一轮动态标题规则验收已提交。本轮复核 F14 的配置保护边界时，发现合法大配置启动过慢，已修复并补齐原件保留、备份恢复和边界检查。

## 复现、定位与修复

[旧 EXE 失败报告](../../artifacts/recovery/recovery-bc3bc9927b554f19bf8e4bf9680ad633/report.json) 使用阶段 14 的 `734960C2…` 构建和当前最终恢复脚本。原有 33 条恢复检查、4 个实例正常退出；合法且恰好 8,388,608 字节的配置在 6 秒内未就绪，尚未创建退出 host。脚本核对 EXE 路径与私有配置目录后清理该自建进程，失败报告未算作通过。

按文件读取、解析／校验 CPU、启动后拓扑／界面三个方向排查。将复现缩到解码器和真实文件读取：只用 32 KiB 合法 JSON，观测到 **32,769 次底层 Read 请求**，[回归先失败](../../artifacts/validation/phase-15-decoder-red.txt)。这与锁定版本 本机锁定版本 serde_json 1.0.149 的 from_reader 注释，以及[官方源代码说明](https://github.com/serde-rs/json/blob/master/src/de.rs) 一致：解析器不自行缓冲文件输入。

[store.rs](../../src/store.rs) 现以 BufReader 包装解码器输入，保持文件大小、版本、字段、引用及语义校验。读取主文件、保存前读取旧配置以及恢复备份共用该路径；不改变持久格式、备份轮换、保护模式或写入提交顺序。

新增真实文件读计数回归要求同一 32 KiB 输入保持完整配置语义且底层读请求不超过 16 次，不依赖易波动的毫秒断言；[修复后通过](../../artifacts/validation/phase-15-decoder-green.txt)。完整 GUI 复现也重新通过，说明差异来自输入缓冲而非放宽文件上限或跳过校验。

## 大小边界直接证据

[**55 条检查、7 个实例正常退出**](../../artifacts/recovery/recovery-b498e9c24dd74c27940fc10e84827d61/report.json)。旧 EXE 与新 EXE 的恢复脚本 SHA256 均为 `5D0B4BBD15BC324CB6F92C87C0D2E108FC5871679265A531679B40B9EFDFA97B`。

| 场景 | 结果 |
| --- | --- |
| 恰好 8,388,608 字节的合法 JSON | 正常可编辑，启动和刷新不改主文件／备份；窗口就绪及设置页检查 320.889 ms |
| 主文件 8,388,609 字节、备份有效 | 明确超限，设置字段禁用，刷新保留原件与备份；恢复后完整另存原件，配置语义与有效备份一致并恢复可编辑 |
| 主文件损坏、备份 8,388,609 字节 | 明确拒绝超限备份，主文件和备份字节不变，保持保护模式，GUI／host 仍响应 |

以上约 321 ms 为本轮配置窗口就绪、归属核验及打开设置页的观察计时，不替代下面托盘定位与两枚真实热键的实际启动就绪指标。


检查由 [recovery-smoke.ps1](../../scripts/recovery-smoke.ps1) 的可选 `-Oversized` 触发：在原有恢复检查后追加三种独立配置。先从本轮明确新建流程获取真实当前显示器的有效配置，再只补合法空白至精确 UTF-8 字节数；超过一字节的样本仍是合法 JSON，拒绝原因确为大小而非语法错误。仅操作私有目录、自建实例与自有 GUI 消息，不发送键盘／鼠标，不修改实际 HKCU Run。

## 当前构建与回归

仍为 0.1.0 开发预览，Win11 企业版 10.0.26300、普通权限、单屏 2560×1440／工作区 2560×1392、96 DPI。

| 工件 | SHA256 |
| --- | --- |
| [历史 ZIP 校验记录](../../artifacts/packages/package-803349c8ff61421ea2a5592ebd4353f4/package-verification.json) | `1444220B0241439580CB74ADB66B82EBDB10A35767F58BE491C1BFFAE4193586` |
| Release EXE／解压 EXE | `7AB66FC92984A589E0209DD41A96AE97A8EC5EEA49F605414E58CAE5BFC0470E` |

格式、严格 Clippy、all-targets **63 项测试**及离线构建打包通过。[嵌入清单](../../artifacts/validation/phase-15-embedded.manifest) 保持 PerMonitorV2／asInvoker，[导入依赖](../../artifacts/validation/phase-15-dependencies.txt) 仅系统 DLL。旧构建完整状态保存为 [阶段 14 历史快照](phase-14-coverage.md)。

本构建 **16 项集成回归全部通过**，完整顺序、参数和退出码见 [执行记录](../../artifacts/validation/phase-15-suite.json)。当前原始报告均与新 EXE 哈希核对一致。

| 回归 | 当前证据 |
| --- | --- |
| 配置恢复／大小边界 | [55 条，原有损坏／未来格式／替换故障与新增大小边界均通过](../../artifacts/recovery/recovery-b498e9c24dd74c27940fc10e84827d61/report.json) |
| 设置／预设草稿 | [55 条设置草稿检查](../../artifacts/settings-drafts/draft-2d1c8e86d37b4c3083942241d1b28ee0/report.json)；[17 条编辑交错检查](../../artifacts/editor-races/editor-b1ddac5629c64bc0875b0862a6c3e27a/report.json) |
| 键盘／确认框／托盘 | [177 条、96 次焦点、62 条 UIA 样本](../../artifacts/keyboard/keyboard-e3edcaef0da94bf4bcd36184c11de1a1/report.json)；[82 条／9 个对话框](../../artifacts/dialog-keyboard/dialog-b18e4f37d3044a5883baf7624f6030f8/report.json)；[19 条](../../artifacts/tray-keyboard/tray-177e4a3c88724de191e114f1003584e6/report.json) |
| 真实热键 | [100 循环、最大误差 0 px；可见 p95 16.123 ms，完成反馈 p95 32.857 ms](../../artifacts/hotkeys/hotkey-20261017T074653193Z-21abb106/report.json) |
| 生命周期竞态 | [3 场景／21 条，忙时拒绝、关闭和重建](../../artifacts/races/race-2370c8389ac24837b2a08f588e5bb898/report.json) |
| 设置事务／写入故障 | [93 条、14 次真实捕获／恢复、7 次正常退出](../../artifacts/settings/settings-91e361cd344a4defb99975de892d54ef/report.json) |
| ZIP | [34 条 GUI 断言、仅 EXE／README，解压哈希一致，无残留](../../artifacts/packages/package-803349c8ff61421ea2a5592ebd4353f4/package-verification.json) |
| 实际启动就绪 | [102 条；10 次已有配置实际就绪最大 313.077 ms，5 次首次键盘捕获最大 719.303 ms，16 次正常退出](../../artifacts/startup/startup-4c5c93237509496da599098027cb5143/report.json) |
| Explorer／Terminal | [各 20 次 GUI 精度、9 条状态、7 条标题检查；18 次实际 F9 均 0 px](../../artifacts/shell-apps/shell-apps-868ad788c0714d8cba1e1c71599f31d8/report.json) |
| Brave／VS Code | [各 20 次 GUI 精度、50 次普通真实恢复及最大化转换，状态组共 104 次 F9；标题组共 22 条、14 次 F9、6 次 F10，全部 0 px；普通完成 p95 167.931／163.071 ms，含归属核验与轮询](../../artifacts/apps-phase-15-release/application-smoke.json) |
| 默认路径覆盖升级 | [26 条，734960C2 → 当前 ZIP，独立中文／空格 LOCALAPPDATA，3 次恢复 0 px](../../artifacts/upgrade/upgrade-8a6e4ad7bc4848949ca1919c9673b62d/report.json) |
| 后台异常及循环 | [300 循环／600 次主要操作、逐轮 ≤2 px；暂停 261.782 ms 未确认，12 次响应观察；受限 201.963 ms；私有内存峰值 2.879 MiB，IdleSeconds=0](../../artifacts/backend/backend-2811f147aedd45018192613a43aaa61c/report.json) |
| 空闲资源 | [60.778 s，CPU 增量 0.000 ms；托盘私有峰值 2.059 MiB、界面 2.062 MiB；启动消息循环代理 265.669 ms，正常退出](../../artifacts/performance/perf-20261017T075055313Z-40432221/report.json) |

## 阶段审计与下一步

当前全项目完成仍未被证明。以下按原 [发布门槛](../acceptance.md) 区分证据和环境条件，不把“更多样本”泛化为无止境的新要求，也不以单屏通过替代多屏能力。

| 类别 | 当前结论／下一步 |
| --- | --- |
| 本机构建与基本操作 | 当前构建的格式、严格 Clippy、63 项测试及下表集成回归为直接证据；默认／标题规则、热键事务、撤销、保护恢复和单屏精度已有对应检查。F03、F08 等混合场景仍仅局部验证。 |
| 本机后续复核 | 核对配置写出大小与读取上限是否一致，避免工具写出下一次无法读取的配置；这是当前边界复核留下的具体待查项，尚未宣称通过。已有 F12 写临时／替换失败和编辑交错证据继续保留。 |
| F03–F08 与跨 DPI 性能 | 仍需真实多屏／混合 DPI、负坐标与工作区变化、同型号／换口身份、至少两个组合、插拔／唤醒／扩展坞，以及跨屏最大化／手动还原和自动隐藏任务栏；跨 DPI ≥50 次性能样本未取得。 |
| F15–F16 | 真实 UAC 成功／取消／跨账号、初始化或接管失败及交接中第三启动，高低权限重复启动、Explorer 重启、自启实际登录和移动路径修复，需操作者控制的会话或测试机。当前协议测试和广播模拟不填为实机通过。 |
| F17–F18 | 当前 Terminal 包身份和默认目录覆盖升级有证据；真实包升级、OS 重启、干净 Win11 运行及用户目录权限组合仍待对应环境。 |
| 易用性／可访问性 | 独立新用户无提示 60 秒、真实 Narrator、100%／150%／200%、大字体和高对比度仍需实际操作者／可恢复桌面。已有 Tab、焦点和 UIA 名称不替代这些门槛。 |
| 外观与交互 | 按用户顺序，在当前功能及稳定性阶段收尾后集中改进信息层级、间距、字体、首次使用和反馈；优化后复测热键、焦点、键盘、可访问性、DPI 与资源。所需硬件项目仍独立保留，进入此阶段不代表发布验收完成。 |

本轮没有重启系统／Explorer、触发 UAC、更改显示或字体设置、启用自启或修改既有应用；这些项目继续按操作单安排。完整 F01–F18 及限制保留于 [覆盖审计](coverage.md)，整体目标保持活动。


## 复现

```powershell
pwsh -NoProfile -File scripts/recovery-smoke.ps1 -Oversized
cargo test --locked --offline --lib configuration_decoder_batches_underlying_file_reads
```

完整构建入口见 [阶段 6](phase-6.md#回归与复现)。在 PowerShell 7 正常桌面顺序运行；输入型回归仅针对确认归属的 fixture，运行期间避免切换窗口。仍按 [实机操作单](manual.md) 补齐所需硬件、权限和独立操作者的检查，不能以消息模拟或本机脚本替代。
