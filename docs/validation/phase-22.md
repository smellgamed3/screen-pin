# 阶段 22：系统大字体、对比度与阅读门槛

日期：2026-10-17（Asia/Shanghai）。产品仍为 B141A2B2 构建；本轮增加隔离来宾的真实设置切换和文字测量。功能几何、键盘可达与文字可读性分开判定，整个首版验收仍未完成。

## 已执行的检查

在新建 Windows Sandbox 中，从原始 ZIP 启动默认配置，实际改变系统消息字体并应用系统自带 hcblack.theme；回读字体、对比度标志、主题路径和原生配色，不以本地 WM_SETTINGCHANGE 模拟代替真实系统设置。

三种状态为默认正文 14 px、实际系统／应用消息字体 24 px、24 px 加内置高对比度主题。每种状态逐页测试常用尺寸和最小尺寸请求下的顶部／底部、正反向 Tab，以及一次真实 F9 恢复。实际客户区和控件范围保留在原始报告中；大字体下 Windows 会将过小的高度请求约束到应用最小尺寸，不把 720×440 请求当作始终得到同样大小的窗口。

本轮最终功能检查、阅读测量和复测路径在下方记录。原 EXE 和 ZIP 未重新构建；阶段 18 的 66 项源码测试及严格检查沿用原有记录，没有宣称本轮重跑。

最终[宿主报告](../../artifacts/sandbox/sandbox-45f2186c-906c-48d9-b933-df7c5c443788/host-report.json)和[来宾报告](../../artifacts/sandbox/sandbox-45f2186c-906c-48d9-b933-df7c5c443788/result/guest-report.json)记录 **1085 条功能检查通过、36 个布局场景、288 次焦点观察、3 次实际 F9 恢复均为 0 px**，前台和配置字节保持。实例正常退出，字体指标、对比度标志与主要配色恢复，Sandbox 已停止。控件布局最终采样耗时最大约 33.713 ms，本次无额外重试；不以此作为逐帧闪烁验证。

**整个 Appearance 检查按预期返回失败**：新增阅读门槛测得 36 个单行文本样本中有 14 个溢出，覆盖下面三个具体控件。自动功能成功不覆盖这个失败，也不宣称当前大字体界面已经验收合格。

| 控件 | 24 px 字体实际文字宽度 | 控件可用宽度 | 现象 |
| --- | --- | --- | --- |
| 查看方案 | 127 px | 100 px | 助记键信息落到下一行并被裁切 |
| 记住位置热键 | 183 px | 180 px | 尾部助记键被裁切 |
| 窄窗口撤销 | 718 px | 655 px | 居中截断可使动作开头也不可见 |

已检查[大字体设置页](../../artifacts/sandbox/sandbox-45f2186c-906c-48d9-b933-df7c5c443788/result/large-font-720-page-101-top.png)、[高对比度设置页](../../artifacts/sandbox/sandbox-45f2186c-906c-48d9-b933-df7c5c443788/result/large-font-high-contrast-720-page-101-top.png)和主界面对应截图。实际对比度主题就绪后，原生复选框文字和边界可读；早期过渡截图不作为最终主题效果。

本轮另复测[基础 Sandbox 47 条检查](../../artifacts/sandbox/sandbox-afc5e429-d36b-40a5-860a-1f02b2d444c4/host-report.json)、[生命周期 20 条检查](../../artifacts/sandbox/sandbox-408e22cc-a5ac-4c08-a64a-f50649f9662d/host-report.json)及[抽取公共辅助代码后的视口回归](../../artifacts/viewport/viewport-84c39ca5b63a4363acd6fe0f282f6e07/report.json)：视口 389 条检查、19 场景通过。三个执行记录均与当前脚本／输入哈希核对，实例退出及环境清理通过。

当前[证据索引](../../artifacts/validation/phase-22-evidence-index.json)保留 22 项已通过的分阶段产品记录，本轮复测其中三项，其余 19 项沿用旧记录；Appearance 的阅读失败单列，不混入通过数。EXE SHA256 `B141A2B2FA248CB7F764F648C5D186B97CDAAD52420E47B30212003B59505990`，ZIP SHA256 `28BF913D6D0B1D75F90F5D1A3F1AB552628C3DA205C7541E07114841B5ACF7FF`。

## 当前阅读缺陷

- 系统字体 24 px 时，“查看方案”及“记住位置热键”的单行标签宽度不足，完整助记键信息被截断。原生 UIA 名称和实际键盘可达不证明绘制文字完整。
- 窄窗口的撤销按钮将长目标说明居中绘制，可能连开头的“撤销”动作名也被裁掉。按钮本身完整落在窗口内，并不足以证明用户能看懂动作与作用范围。

新增文字门槛使用控件实际 LOGFONT 在验收进程创建临时字体，以 GDI 独立测量显示文字宽度，并与原生控件可用宽度比较。局部字体副本在测量后释放，不能把其他进程的 HFONT 直接选入本进程 DC。选取已知单行标签和撤销按钮，暂不把所有可能换行的说明或滚动列表当作单行文本检查。

上述问题保留为待修复的产品阅读缺陷。下一步应调整标签列宽及撤销的呈现方式，在同一门槛下取得通过；不能通过删减既定字段语义、缩小用户字号或移除失败断言来解决。

## 验收夹具与调试范围

- 前台切换采用原生点击自建窗口标题栏：先核对 HWND／PID、实际命中点与窗口根归属，再注入鼠标输入，之后每次键盘输入继续核对前台。仅操作隔离来宾及自建 fixture；宿主字体、主题、显示和 Run 项保持不变。
- 使用更新来宾用户首选项并广播的 SystemParametersInfo 标志。仅更改内存参数时，曾出现系统回读 24 px、应用维持 14 px，本地通知后才采用 24 px；最终路径验证自然广播后的更新。
- 模式标志与主题配色分开检查。该系统内置黑色主题的 Window 为 #202020、WindowText 为白色；从主题文件解析预期颜色，并等待实际配色就绪，避免硬编码“黑色一定是 #000000”。
- 一次较早的夹具进程发生原生堆错误 0xc0000374；来宾事件日志和只读进程探针确认故障进程为 powershell.exe，Screen Pin 仍存在并响应。早期互操作版本曾释放 API 返回的主题名指针，所有权尚未可靠确定；最终短生命周期探针只复制字符串，不释放该返回指针。不能将这一夹具故障算作产品崩溃，也未宣称彻底证明了历史根因。
- 原生 GDI 截图使用 24 位 RGB 位图，避免未定义的 Alpha 让 PNG 中部分内容透明；最终引用截图已重新检查。
- 布局采样等待不超过 2 秒的稳定范围，并记录尝试次数和耗时；不将过程中看到的变化丢失后宣称“没有任何闪烁”。当前检查不证明逐帧无闪烁。
- 最终清理核对系统字体指标、对比度标志及主要色值恢复，并保存实际主题名。Windows 可保留最后选过的对比度主题名，即使模式已经关闭；这一名称差异单独记录。整个自建 Sandbox 最后销毁，不保留测试设置。

原始调试记录：[前台聚焦失败](../../artifacts/sandbox/sandbox-41e39938-111a-4c52-96f4-ca8c722e37c5/result/guest-report.json)、[内存首选项未广播](../../artifacts/sandbox/sandbox-04b7b8e6-c0fa-4307-9e89-2a179975cebc/result/guest-report.json)、[原生堆错误事件](../../artifacts/sandbox/sandbox-52ca5168-cf93-446e-a405-77582dd7e53e/result/debug-crash.json)、[读取主题文件及配色判定调试](../../artifacts/sandbox/sandbox-0a1579eb-3ac7-41cf-8090-7d1b4435cc9d/host-report.json)。早期直接选择其他进程字体的宽度测量无效，以最终创建本地字体副本的结果为准；初次边界采样失败见[记录](../../artifacts/sandbox/sandbox-680b7e05-39fa-4dc0-a70b-c172bd275d01/result/guest-report.json)，没有认定它证明持续布局错误。

API 依据见 [SystemParametersInfoW](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-systemparametersinfow)、[HIGHCONTRASTW](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-highcontrastw) 和 [Microsoft 高对比度主题指南](https://learn.microsoft.com/en-us/windows/win32/controls/supporting-high-contrast-themes)。

## 复现与剩余范围

```powershell
pwsh -NoProfile -File scripts/sandbox-smoke.ps1 -Appearance
```

需要宿主已有 Windows Sandbox 和 PowerShell 7；来宾使用内置 PowerShell 5.1，未安装额外 SDK。脚本拒绝接管已有 Sandbox。它使用来宾账号、虚拟显示器及本轮主题样本，不能替代真实 Narrator、物理缩放／混合 DPI、独立首次使用、UAC、完整系统重启登录等门槛。

先修复上述阅读缺陷并继续收尾本机可执行验收，再按用户要求开展下一轮外观与交互打磨。原有多屏和真实操作者要求保持有效，详见 [覆盖审计](coverage.md)。
