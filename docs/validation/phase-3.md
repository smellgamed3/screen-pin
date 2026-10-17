# 阶段 3：热键事务、配置保护与恢复

日期：2026-10-17（Asia/Shanghai）。继续本机单屏功能验收；用户要求先完成功能、稳定性与验收，再集中优化外观和交互。当前首版整体仍未通过全部发布门槛。历史见 [阶段 2](phase-2.md)，当前需求审计见 [coverage.md](coverage.md)。

## 实测问题与改进

1. **恢复备份后热键仍使用旧绑定。** 原实现只有“保存设置”会更新 shell 的运行时设置，恢复备份替换了配置却保留默认热键。旧 Release 的 [失败报告](../../artifacts/settings/settings-86055394b75747e9a00756f74be77c37/report.json) 在配置恢复、原件保留和编辑恢复均通过后，因实际映射错误失败。现在每次 worker 回包都将持久化设置同步到 shell，释放退役键并注册恢复后的组合；若外部占用，保留恢复后的配置、在结果和实际注册状态中明确显示不可用，允许原地修改修复。后续拓扑刷新失败也不能让已恢复的配置与运行时设置长期不一致。
2. **JSON 读取使比例值末位漂移。** 进一步恢复检查发现 `145 / 1392` 的已保存值 `0.10416666666666667` 读回成为 `0.10416666666666669`。偏差远小于像素，但不符合保留完整比例精度的设计。通过真实 ConfigStore 读写回归先复现失败，再启用已锁定版本 serde_json 的 `float_roundtrip`，不新增依赖。连续 20 次完整读取／保存及损坏后恢复均保持模型与已生成配置字节一致；这不是承诺保留任意外部 JSON 的缩进和字段顺序。

实现见 [shell.rs](../../src/shell.rs)、[Cargo.toml](../../Cargo.toml)，回归见 [store.rs](../../src/store.rs)。原生热键测试补充了恢复同步、外部冲突和再次保存修复；全部 **61 项测试**、格式与严格 Clippy 通过。

## 当前工件

| 文件 | SHA256 |
| --- | --- |
| [当前 ZIP](../../dist/ScreenPin-0.1.0-windows-x64.zip) | `0C082493A62C5E3D85FEADFA072C18DE8DDF7655894CD10B0BA5DF972A25C1AA` |
| Release EXE／包内 EXE | `0889BCE91A15BB08E9BC197F4017F58D6AD39C94E8D0A408548AC18914985424` |

仍为 0.1.0 开发预览，Win11 x64、普通权限；本机 2560×1440，工作区 2560×1392，96 DPI。当前二进制 [manifest](../../artifacts/validation/phase-3-embedded.manifest) 为 PerMonitorV2／asInvoker；[导入依赖](../../artifacts/validation/phase-3-dependencies.txt) 仅列系统 DLL。不能据此宣称干净系统已经实测。

## 当前构建证据

| 检查 | 结果和实际范围 |
| --- | --- |
| [设置事务与恢复](../../artifacts/settings/settings-4c42cee9bf8f48a38bed900352c309cf/report.json) | **66 条检查**；同键拒绝、拟注册第二键占用时撤销第一键、互换、自定义、主文件共享锁造成保存失败后的旧绑定保留、普通重启、启动冲突修复、备份恢复及恢复冲突修复。10 次真实 SendInput 捕获／恢复均 0 px；退役键由独立线程重新注册证明释放；5 个应用实例正常退出 |
| [配置保护与失败恢复](../../artifacts/recovery/recovery-cdecaa9d8272494e92ce32b2bf776802/report.json) | **33 条检查**；截断主文件／无备份、未来主文件／损坏备份、非法字段／未来备份、有效备份但替换受阻四组。失败保留主文件和既有备份；解除测试锁可重试；明确新建默认“否”，取消保留未来文件，确认后单独保留原件并新建空方案；4 个实例正常退出 |
| [ZIP 解压运行](../../artifacts/packages/package-622ec0a08cc94ed283fd2dd237746838/package-verification.json) | 仅 EXE 和 README；解压 EXE 与 Release 哈希相同，**34 条 GUI 断言通过**，正常退出且无解压目录下的残留进程 |
| [键盘回归](../../artifacts/keyboard/keyboard-123f21d9384949cca7e5488da83eccac/report.json) | **177 条检查**；三页正反 Tab、保存／撤销、创建／排序；96 次焦点观察完整可见，62 条原生 UIA 样本有名称及预期角色；正常退出 |
| [默认真实热键](../../artifacts/hotkeys/hotkey-20261017T052744611Z-40aa609d/report.json) | **100 次真实 F10→位移→F9**，边界误差 0 px；可见 p95 16.122 ms，完成反馈 p95 32.775 ms；无预设、无变化不写、长按重复抑制与前台保持通过 |
| [异常与连续操作](../../artifacts/backend/backend-bbc59b310e8a479f980ecfb66931460c/report.json) | **300 次循环／600 次主要操作**，逐轮边界误差 ≤2 px；目标暂停 1.2 s 时约 248 ms 报未确认，15 次 host／配置响应探测通过，忙时拒绝重叠命令且不写盘；尺寸约束约 201 ms 报受限，解除后恢复。私有内存峰值 2.848 MiB，分段采样未见持续单调增长。该次 IdleSeconds=0，不作为 60 秒空闲证据 |
| [资源复测](../../artifacts/performance/perf-20261017T052826298Z-ecc4ada7/report.json) | 预热后空闲 **60.738 s，CPU 计数无可测增量**；托盘私有内存峰值 2,146,304 B（2.047 MiB），界面 2,121,728 B（2.023 MiB）。启动消息循环代理 267.393 ms，不等于实际托盘／热键完整就绪；正常退出，无残留 |
| [实际应用回归](../../artifacts/apps-phase-3-release/application-smoke.json) | Brave 155.1.97.59、VS Code 1.130.0，独立 profile 的普通主窗口 GUI 记住／位移／恢复各边误差 0 px；前台保持、正常退出，按唯一 profile 路径扫描无残留。未覆盖最大化、临时对话框或管理员窗口 |

新增脚本只修改各自新建的配置和 fixture。设置表单及保护／确认路径使用有界 GUI 消息；只有设置映射验证及默认热键测试使用真实 SendInput，发送前后核对自建 fixture 的 PID、类名和实际前台。首次可调用公开 UIA 聚焦自建测试窗口，用户切焦即取消后续输入。共享 [real-keys.cs](../../scripts/support/real-keys.cs) 从原热键脚本提取，报告同时记录脚本和辅助源码哈希。

配置共享锁是可控的替换失败注入，不代表已覆盖所有磁盘与权限错误。UIA 不替代真实 Narrator，消息操作确认按钮不替代键盘对话框验收。恢复失败可留下额外的原件保留副本；测试核对这些副本均为原始字节。

## 可复现命令

应用运行不需要 PowerShell；测试脚本使用 PowerShell 7，需在本机桌面顺序执行，避免全局热键或输入争用。

```powershell
cargo build --locked --offline --bins
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-release.ps1 -Offline
pwsh -NoProfile -File scripts/settings-smoke.ps1
pwsh -NoProfile -File scripts/recovery-smoke.ps1
pwsh -NoProfile -File scripts/package-smoke.ps1
pwsh -NoProfile -File scripts/keyboard-smoke.ps1
pwsh -NoProfile -File scripts/hotkey-smoke.ps1 -ExePath target/release/screen-pin.exe -OutputDir artifacts/hotkeys -Cycles 100
pwsh -NoProfile -File scripts/backend-smoke.ps1 -Cycles 300 -IdleSeconds 0
pwsh -NoProfile -File scripts/perf-smoke.ps1 -ExePath target/release/screen-pin.exe -OutputDir artifacts/performance
pwsh -NoProfile -File scripts/application-smoke.ps1
```

未缓存依赖时去掉 `--offline`／`-Offline`。原始报告、独立配置及设备路径保留在忽略的 artifacts 中，仓库提交可复现脚本及摘要。

## 后续验收

继续实际应用状态／临时对话框、热键与编辑竞态、ZIP 覆盖升级保留配置、剩余 I/O 失败路径。独立用户 60 秒上手、真实 Narrator／UAC／Explorer 或系统重启、干净 Win11，以及物理多屏／混合 DPI／换口唤醒仍按 [实机操作单](manual.md) 待验。功能验收后再集中优化外观和交互，并对改动再次回归；没有条件的项目不能以界面打磨代替验收。
