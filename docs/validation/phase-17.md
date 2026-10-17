# 阶段 17：阅读层级、固定导航与操作反馈

历史记录：本文对应 A0F8A180 构建，下面保留当时截图和执行证据。当前构建与回归见 [阶段 18](phase-18.md)，需求状态见 [覆盖审计](coverage.md)。

日期：2026-10-17（Asia/Shanghai）。按用户“完成后再优化外观和交互”的顺序，在阶段 15／16 已发现的配置读写缺陷修复并通过回归后，开始第一轮界面打磨。尚缺设备或人工条件的整体验收继续保留，不因进入本阶段而视为完成。

## 界面与交互

- 保留系统字体，正文至少 14 个逻辑像素；用户设定的更大字体继续保留。当前页和关键分区使用半粗体，沿用原生按钮、标签、输入框和系统颜色。
- 三页导航固定在顶部；撤销及最近结果固定在底部。编辑长表单或查看关联时，可以直接换页、撤销和查看反馈。短窗口将结果标题与结果框横排，留出更多正文空间。
- 正文单独滚动，并裁剪在导航与反馈之间；键盘聚焦正文控件时自动滚动，使整个控件进入可见区域。草稿保护、快捷键、匹配顺序、配置格式和原生控件 ID 保持原有约定。
- 简化预设列表标签为“规则从上到下匹配”。本轮没有引入额外界面运行时或图形资源。

正文裁剪保留原有控件父子关系；同时设置父子／兄弟绘制裁剪和移动时重绘，避免旧像素覆盖固定区域。区域只在变化时更新；成功交给系统的区域由系统管理，设置失败时由应用释放。字体先切换全部控件，再释放旧字体，退出时分别释放拥有的字体。区域所有权依据 [Microsoft SetWindowRgn 文档](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowrgn)。

## 尺寸、滚动与真实键盘检查

新增尺寸检查在 1100×800、720×440、900×600 三种窗口尺寸下逐页检查滚动顶部／底部，并在资源循环后复查，共 **19 个场景、389 条检查通过**。[原始报告](../../artifacts/viewport/viewport-b022ce4a53b14e099e99a6052afe60db/report.json)记录各控件实际窗口范围、原生裁剪区域和固定区坐标；区域边界与真实控件范围取交集，包含折叠下拉框的实际高度。

同一脚本比较 [旧 CB13762C 界面](../../artifacts/viewport/viewport-95d99d74b9494481b507b54d08010f50/report.json) 时，撤销控件在窗口之外，不满足本轮新设的固定反馈标准；这不否定旧版已通过的功能检查。旧／新报告脚本 SHA256 均为 `C456750BA1EE3164F4A012B334F971B3A30744B8F0A4761256F37073388E5509`。

当前实测系统字体为 Microsoft YaHei UI、14 px、96 DPI。预热后 40 次滚动及局部字体重载观察中，GDI 对象为 59 → 46，区间 46–59；私有内存样本最大 2.828 MiB，未见持续增长。配置与真实 Run 项不变，实例正常退出。这是有界资源观察，不证明永不泄漏。

[**177 条真实键盘流程检查、96 次焦点观察、62 条 UIA 名称／角色样本通过**](../../artifacts/keyboard/keyboard-ee5c1140d5054ba08945dc549f3fd5b1/report.json)。正反向 Tab 除了检查客户区边界，还检查焦点控件位于固定区之间且原生区域完整可见；输入、保存、撤销和规则排序继续通过。UIA 结构证据不代替 Narrator 试听。

六张最终 Release 截图已逐张检查：

| 页面 | 常用尺寸 | 最小尺寸 |
| --- | --- | --- |
| 窗口与预设 | [滚动底部](../../artifacts/viewport/viewport-b022ce4a53b14e099e99a6052afe60db/1100-page-100-bottom.png) | [滚动底部](../../artifacts/viewport/viewport-b022ce4a53b14e099e99a6052afe60db/720-page-100-bottom.png) |
| 设置 | [滚动底部](../../artifacts/viewport/viewport-b022ce4a53b14e099e99a6052afe60db/1100-page-101-bottom.png) | [滚动底部](../../artifacts/viewport/viewport-b022ce4a53b14e099e99a6052afe60db/720-page-101-bottom.png) |
| 关联显示器 | [滚动底部](../../artifacts/viewport/viewport-b022ce4a53b14e099e99a6052afe60db/1100-page-102-bottom.png) | [滚动底部](../../artifacts/viewport/viewport-b022ce4a53b14e099e99a6052afe60db/720-page-102-bottom.png) |


## 当前构建与完整回归

| 工件 | SHA256 |
| --- | --- |
| Release EXE | `A0F8A180A7D812D0D7668E4B4B35C6C6471D8AA178F060778FE78BA300A0C334` |
| [历史 ZIP 校验记录](../../artifacts/packages/package-753d083f405440948bd75cb1366c32ee/package-verification.json) | `A2034AE05FBC93871C93AC4F6C6040CB08B3B9FE805A5047F52F7AF8764124D6` |

本构建 **18 项集成回归全部通过**；[顺序、参数与退出码](../../artifacts/validation/phase-17-suite.json)、[原始报告索引](../../artifacts/validation/phase-17-evidence-index.json) 已与当前 EXE 哈希核对。

| 回归 | 当前证据 |
| --- | --- |
| 尺寸／滚动／资源 | [389 条、19 场景、40 次资源观察；六张界面截图](../../artifacts/viewport/viewport-b022ce4a53b14e099e99a6052afe60db/report.json) |
| 写入上限／失败重试 | [28 条、5 次真实恢复、3 个正常退出](../../artifacts/write-limits/write-4bbcb0ec524c44198a607a162adc117f/report.json) |
| 配置恢复／大小边界 | [55 条、7 个正常退出，损坏／未来格式／替换故障及 8 MiB 大小边界](../../artifacts/recovery/recovery-f2841ee041f749ef84cc628a2bd6cc76/report.json) |
| 设置／预设草稿 | [55 条设置草稿检查](../../artifacts/settings-drafts/draft-6e187af12c224f478773b8a9ae619f59/report.json)；[17 条编辑交错检查](../../artifacts/editor-races/editor-d2884aaab9b24e108e2753bd32db3fd9/report.json) |
| 键盘／确认框／托盘 | [177 条、96 次完整焦点、62 条 UIA](../../artifacts/keyboard/keyboard-ee5c1140d5054ba08945dc549f3fd5b1/report.json)；[82 条／9 个对话框](../../artifacts/dialog-keyboard/dialog-24ecf27052f54998a534e4a2e4d19975/report.json)；[19 条](../../artifacts/tray-keyboard/tray-ddaebcf6c23b48769a2dc35720a8a59e/report.json) |
| 真实热键 | [100 循环，最大误差 0 px；可见 p95 16.058 ms，完成反馈 p95 32.603 ms](../../artifacts/hotkeys/hotkey-20261017T082901904Z-d3273b60/report.json) |
| 生命周期竞态 | [3 场景／21 条；忙时拒绝、关闭和重建](../../artifacts/races/race-44767230179440e28efa1943212ecc65/report.json) |
| 设置事务／写入故障 | [93 条、14 次真实捕获／恢复、7 次正常退出](../../artifacts/settings/settings-a351d4f2dd154074a1d1006e10ce026d/report.json) |
| ZIP | [34 条 GUI 断言、仅 EXE／README，解压哈希一致，无残留](../../artifacts/packages/package-753d083f405440948bd75cb1366c32ee/package-verification.json) |
| 实际启动就绪 | [102 条；已有配置 10 次最大 313.747 ms，首次键盘捕获 5 次最大 725.421 ms，16 次正常退出](../../artifacts/startup/startup-65410b3a7a544947823fa98c0aeba04a/report.json) |
| Explorer／Terminal | [各 20 次 GUI 精度、9 条状态、7 条标题检查；18 次实际 F9 均 0 px](../../artifacts/shell-apps/shell-apps-93a2673f4d4e4e53b9dda5fa7e009f34/report.json) |
| Brave／VS Code | [各 20 次 GUI 精度、50 次普通实际恢复及最大化转换，状态组共 104 次 F9；标题组共 22 条、14 次 F9、6 次 F10，全部 0 px；普通完成 p95 170.438／161.850 ms，含归属核验与轮询](../../artifacts/apps-phase-17-release/application-smoke.json) |
| 默认路径覆盖升级 | [26 条；CB13762C → 当前 ZIP，独立中文／空格 LOCALAPPDATA，3 次恢复 0 px](../../artifacts/upgrade/upgrade-f1f27e93e2a9473e93b262fa08cca334/report.json) |
| 后台异常及循环 | [300 循环／600 次主要操作，逐轮 ≤2 px；暂停 249.951 ms 未确认，15 次响应观察；受限 201.975 ms；私有内存峰值 2.887 MiB，IdleSeconds=0](../../artifacts/backend/backend-406d3c51cc2d4b23bb9dea18769de08b/report.json) |
| 空闲资源 | [60.888 s，CPU 增量 0.000 ms；托盘私有峰值 2.062 MiB、界面 2.203 MiB；启动消息循环代理 269.734 ms，正常退出](../../artifacts/performance/perf-20261017T083304078Z-faf562c4/report.json) |

构建执行格式检查、严格 Clippy 和 all-targets **66 项测试**，均通过。嵌入清单仍为 asInvoker、PerMonitorV2；[清单提取](../../artifacts/validation/phase-17-embedded.manifest) 和 [依赖检查](../../artifacts/validation/phase-17-dependencies.txt) 对应本构建，运行依赖仍为 Windows 系统 DLL。

## 复现与剩余范围

```powershell
pwsh -NoProfile -File scripts/build-release.ps1 -Offline
pwsh -NoProfile -File scripts/viewport-smoke.ps1
pwsh -NoProfile -File scripts/keyboard-smoke.ps1
```

各脚本顺序执行，使用独立配置和自有测试窗口。尺寸检查只调整自有窗口并向自有窗口发送设置重载消息，不改变系统显示、字体、主题或开机启动。真实键盘脚本在前台不符时中止，不能将 GUI 消息检查当作真实输入。

这是一轮本机单屏、96 DPI 的界面改进。真实混合 DPI、100%／150%／200% 显示缩放、大系统字体、高对比度和 Narrator 仍需实机验收；局部重载及窗口缩放不能替代这些条件。物理双屏／热插拔／屏幕身份、真实 UAC／跨账号、Explorer 或系统重启、自启登录、包应用升级、干净系统，以及独立新用户 60 秒首次使用仍未完成。完整范围以 [需求覆盖审计](coverage.md) 和 [实机操作单](manual.md) 为准。

本轮界面与交互回归通过后，继续按这些门槛推进；整个首版尚未取得完整验收证据。
