# Screen Pin

Windows 11 x64 窗口位置工具：记住应用窗口在指定显示器的位置和大小，随时按热键恢复。

## 使用

1. 解压发布 ZIP，运行 screen-pin.exe。首次启动会显示主界面，之后驻留托盘。
2. 把目标应用窗口摆到合适的显示器、位置和大小。
3. 聚焦目标窗口，按 **Ctrl+Alt+F10** 记住位置。
4. 随意移动窗口，按 **Ctrl+Alt+F9** 恢复。

两个热键均可在设置中修改。关闭配置界面仍会运行，退出请使用托盘菜单。

默认同一应用的窗口共用一份预设。如需区分项目或文档，在主界面选择目标窗口，输入标题关键字，捕获为特定窗口规则；按规则顺序选择第一条匹配，没有特定匹配时使用应用默认。更新结果会说明改了哪条规则，托盘可撤销最近一次预设更新。

每种显示器组合自动使用对应方案，单纯切换方案不移动窗口。调整屏幕排列后预设仍跟随物理屏幕。身份不明时在“关联显示器”中识别并关联；确定是新环境时可明确建立空方案，旧方案保留。

## 配置与故障处理

- 配置位于当前用户 %LOCALAPPDATA%\ScreenPin，升级程序时保留。
- 热键冲突请到设置中更换；失败修改不会丢弃旧有效绑定。
- 默认普通权限。只有确实需要操作管理员窗口时，才使用托盘中的管理员重启；同账号交接仍需实机验证。
- 普通与最大化状态可保存；全屏、临时对话框、任务栏和工具自身窗口跳过。
- 最大化或还原涉及激活语义，后台目标需要状态切换时请先聚焦目标，再按恢复热键。
- 对尺寸有特殊限制或无响应的应用，会报告受限或暂未确认，不把偏差自动写成新预设。
- 配置损坏或格式过新时保护原文件，可从设置明确恢复备份或新建。
- 预设编辑草稿在窗口恢复后保留；同一预设被更新时会提示冲突，拒绝旧草稿覆盖。点击刷新可放弃冲突草稿并载入最新值。
- 设置页输入在恢复和刷新后保留，明确保存成功才生效；保存失败可直接重试，原有热键继续有效。

当前交付为开发预览；实测范围和未验证项见 [阶段验收记录](docs/validation/phase-13.md) 和 [需求覆盖审计](docs/validation/coverage.md)。多屏、混合 DPI、真实 UAC 和干净环境验证完成前，不能视为最终验收通过。补充硬件与交互验证可按 [实机操作单](docs/validation/manual.md) 执行。

## 开发

需要 Rust 1.89+、MSVC x64 C++ Build Tools 及 Windows SDK。项目采用原生 Win32 控件，发布包不依赖 .NET 或 WebView。

```powershell
cargo test --locked --all-targets
cargo run --locked -- --show
```

本机已缓存依赖时可添加 --offline。构建和打包脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-release.ps1
```

隔离测试支持 --config-dir 指定目录；--background 仅驻留托盘，--show 显示主界面。--diagnose 输出显示器几何及可配置窗口数量。

真实窗口探针只操作它自己创建的独立进程窗口，不移动已有用户窗口：

```powershell
cargo run --locked --bin desktop_probe -- --output artifacts/desktop-probe.json
```

当前构建、配置故障、默认目录升级的回归脚本调用方式见 [复现入口](docs/validation/phase-6.md#回归与复现)。先用 `cargo build --locked --bins` 构建原生辅助探针；各检查使用独立配置并顺序执行，输入检查在用户切换焦点时取消。脚本需 PowerShell 7，默认目录升级选项需 7.4+；应用本身没有这一依赖。切焦与关闭／重建竞态检查见 [阶段 7](docs/validation/phase-7.md#复现)；托盘和确认框键盘检查见 [阶段 8 复现入口](docs/validation/phase-8.md#复现与剩余门槛)。默认启动实际就绪检查见 [阶段 9](docs/validation/phase-9.md#复现与观察边界)。Explorer／Terminal 状态与标题热键复现见 [阶段 10](docs/validation/phase-10.md#复现与剩余范围)。预设草稿交错复现见 [阶段 11](docs/validation/phase-11.md#复现与待验范围)；设置草稿及保存失败重试见 [阶段 12](docs/validation/phase-12.md#复现与剩余范围)；浏览器／编辑器真实热键状态与恢复样本见 [阶段 13](docs/validation/phase-13.md#复现与边界)。

[设计基线](docs/design.md) · [验收门槛](docs/acceptance.md) · [领域术语](CONTEXT.md)
