# 阶段 28：置顶编辑模式

日期：2026-10-18。新增 `v0.1.0-preview.2` 开发预览，整体实机验收仍未完成。

## 实现

- 顶部开关开启简洁置顶面板，其他应用正常接收输入；自动显示外部窗口的应用、标题、显示器及可见边框的位置／大小（物理像素）。移动、缩放、改标题时自动更新。
- 返回面板保留目标，按钮及面板内原有热键可记住／恢复。应用默认、有序标题规则及活动方案沿用现有匹配逻辑；保存／恢复仍锁定 HWND、PID、窗口代际，由操作 worker 再核验。
- 旧采样与当前目标不一致时拒绝；目标关闭、重建、最小化或不支持时取消可操作状态，不暗中回退到其他窗口。最小化目标仍需先还原。
- 自动观察不写配置、不移动窗口，保留预设及设置草稿。默认关闭；取消、最小化、回托盘及退出时停止并回收线程，取消置顶。
- 独立线程每 120 ms 轻量核验前台、标题、边框和状态，变化时才读取完整身份／显示器；返回面板另提交刚离开的目标，覆盖极快切换。普通模式及托盘不轮询。

主要代码：`src/watch.rs`、`src/shell.rs`、`src/desktop.rs`。配置格式与旧预设兼容。

## 构建及通过证据

`scripts/build-release.ps1 -Offline` 完成格式检查、全目标严格 Clippy、66 项库测试及全部二进制目标测试、release 打包。日志：`artifacts/edit-mode-final-build.txt`。

| 对象 | SHA-256 |
| --- | --- |
| EXE | `3FCF17AFE74262EF4674DB26703D50351240DB8702B03B3FC65F690675B56371` |
| ZIP | `9BF01CD4DA96025BDAC3652A2C4C214B2592B552E422A2DBAF0FDB1E1C449773` |

以下三个新建 Sandbox 均使用上述同一 EXE／ZIP，顺序执行并正常停止。主机焦点、按键、字体未改动；输入和工具哈希固定在宿主报告。

| 执行 | 结果 | 本地宿主报告 |
| --- | --- | --- |
| `-Fixtures -FixtureTests edit-mode` | 23 项具名检查通过：两个独立窗口、10 次连续切换、实时位置／大小、按钮保存／恢复、面板内真实 Ctrl+Alt+F9、标题变化、目标关闭／最小化、草稿、取消／最小化／回托盘、正常退出 | `artifacts/edit-mode-complete/sandbox-78112364-dcb8-4cdd-99ff-ebdc309b9137/host-report.json` |
| `-Appearance` | 36 场景、1,251 项检查、234 个单行文字样本通过，含新开关；真实 24 px 字体、高对比度、三页完整界面、小窗口、键盘导航、原有真实热键恢复 | `artifacts/edit-mode-appearance/sandbox-20120996-3e9a-487c-a284-19b10912b5ec/host-report.json` |
| 基本分发 | 原 ZIP 在未映射额外测试运行时的来宾完成 47 项基本流程检查 | `artifacts/edit-mode-basic/sandbox-b133ae49-6744-4cfb-8af2-b8d913b05aa3/host-report.json` |

同二进制另一次 21 项编辑检查通过：`artifacts/edit-mode-final/sandbox-c86a48f3-19aa-4b10-86da-eb20076a4c6a/host-report.json`。两次静止面板各测 5 秒，累计进程 CPU 折合单核约 0.31% 和 0%；短样本及计时粒度不能证明长期零占用，也不替代原有长期性能门槛。恢复以可见边框误差 ≤2 px 判定，并核验配置字节不变及焦点保留。

实际截图已查看，快速按钮完整可见。原始报告、配置及截图只存本地 artifacts，不上传。驱动 `scripts/edit-mode-smoke.ps1` 的环境保护拒绝在宿主注入输入。

## 失败与改进

初始 WinEvent EXE 为 `2CC5598A4064A841DF982264D19C4163610515A1DA6E53FE4B223D161F69FD90`。普通保存／恢复通过，但“最小化 → 还原 → 激活另一窗口”在两轮独立来宾稳定停留旧目标，记录例如 `artifacts/edit-mode-sandbox/sandbox-cbce7b00-9ee8-4d73-800a-8c00dc494fa9/host-report.json`。

诊断构建显示，最小化后的后续前台通知未到达监听回调，界面没有拒绝相应新结果。底层系统／来宾原因未确认，没有宣称修好了 WinEvent 本身。最终移除该依赖，直接核验前台；完整失败用例及扩展检查通过。中间通过在 `artifacts/edit-mode-fixed`，诊断在 `artifacts/edit-mode-diagnostic`；临时 `[DEBUG-edit-watch]` 日志已移除。

驱动初期的编译、签名和清理失败均保留。来宾切焦器原先无条件取消目标置顶，快速重复标题栏点击还可能触发最大化；现恢复原置顶状态，并避开双击时间窗。宿主切焦和输入保护未放宽；历史报告按其实际辅助器哈希解释。

## 复现与边界

```powershell
scripts/build-release.ps1 -Offline
scripts/sandbox-smoke.ps1 -Fixtures -FixtureTests edit-mode -OutputDir artifacts/edit-mode
scripts/sandbox-smoke.ps1 -Appearance -OutputDir artifacts/appearance
scripts/sandbox-smoke.ps1 -OutputDir artifacts/basic
```

Preview 1 的 23 项组件证据仍属于旧 EXE，见 [coverage.md](coverage.md)，不自动继承到新二进制。物理多屏／混合 DPI、真实 UAC、Narrator、首次使用计时、重启登录及新版完整宿主应用回归仍未完成。原有 Sandbox UIA 差异及首轮 Brave 性能失败没有被本轮结果消除。
