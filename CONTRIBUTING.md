# 开发与验证

运行环境是 Windows 内置 PowerShell 5.1、WPF 和 .NET Framework；没有 npm、Python 或额外 GUI 运行时依赖。保留中文 PowerShell 文件的 UTF-8 BOM。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Portability.Tests.ps1
```

本机验证环境设置窗口时加 `-STA` 和 `-UI`。测试使用临时目录中的合成配置和凭据，不启动真实 Codex、不请求服务商，也不修改用户或系统环境变量。测试模拟 Windows 安装登记与进程列表，不能证明每种安装形式或真实 D 盘上的完整切换都已测试。临时夹位于系统 Temp 下，以 `CodexLauncher-Test-` 开头。

GitHub Actions 使用 Windows runner 验证 PowerShell 语法、XAML XML 及路径/恢复流程。尚未包含真实桌面、第三方服务、OS 弹窗或 API 长任务自动化。

`tests/ShareSafety.Tests.ps1` 将合成账号、路径设置和聊天文件加入隔离副本，验证它们不会被复制到分享目录，同时检查已有目标和嵌套目标不会被覆盖。

`tests/ApiProbe.Tests.ps1` 使用本机 TCP 假接口，不调用真实服务商，检查完整 SSE、压缩、UTF-8、结束事件缺失、HTTP 错误、失败/未完成事件、大小限制、超时、取消、隐私字段及兼容模块清理。生产检测使用 `ApiProbe.cs`，只返回成功状态、固定错误分类、HTTP 状态和耗时。Windows .NET 的流读取取消需独立等待取消信号，不能只依赖 ReadAsync 的 CancellationToken。

## 模块边界

- `Launcher.Paths.ps1`：读取环境位置、安装登记、用户选择及路径保护。
- `Launcher.Core.ps1`：多接口、DPAPI 凭据、受管理配置与恢复流程。
- `Launcher.ps1` / `UI.xaml` / `Environment.ps1`：WPF 页面、独立环境设置窗口、任务栏身份。
- `HttpBridge.ps1` / `HttpBridge.cs`：API 模式的本机 HTTP 兼容模块。
- `ApiProbe.cs`：显式点击触发的短 Responses 连接测试，复用兼容链路。
- `Launcher.Images.ps1` / `Launcher.ImageUI.ps1`：独立图片设置、对话绑定、受管理 MCP 区段与 WPF 图片页面。
- `ImageMcp.ps1` / `ImageTools.cs`：STDIO MCP、Images 自动/同步/任务轮询、Responses 图片工具；凭据和任务使用当前 Windows 用户 DPAPI。
- `NativeProbe.cs` / `Launcher.Compatibility.ps1` / `Launcher.CompatibilityUI.ps1`：原生清单、安全投影、两模式比较和限定本地登记修复。
- `Prepare-Share.ps1`：按固定清单复制公开文件，不读取用户配置目录。

修改路径或认证逻辑时，应验证：安装升级、中文及空格、环境变量优先级、错误目录、运行中禁止切换、API 活跃恢复备份绑定、官方恢复、外部修改冲突，以及旧配置迁移。不要通过改写会话或注入官方界面来掩盖状态问题。

提 issue 时附启动器版本、Windows/Codex 版本、安装方式、简化后的路径结构和错误提示。密钥、auth.json、聊天、恢复备份及整个 AppData 数据目录不应附入 issue。

公开仓库为 https://github.com/EEAA-us/codex-connection-helper ，版本发布使用 Git 标签和 GitHub Releases。当前 0.3.18 为预发布测试版；代码许可证尚未指定，不将字体 OFL 或品牌资源说明当作代码许可。图案来源见 NOTICE.md。

`tests/ImageTools.Tests.ps1` 在本机合成接口检查同步/base64/URL、异步队列、改图、取消后续取且不重交、错误脱敏、同源凭据引用/跨源隔离、官方恢复及真实 MCP 子进程握手。生产代码不开放测试用 HTTP 开关。CI 不运行付费生图或真实桌面会话。

`tests/Compatibility.Tests.ps1` 验证原生清单脱敏投影、目录差异、安装差异与本地修复范围，不执行真实插件安装或工具调用。图片测试还覆盖 Responses 生图/改图、未知任务不猜地址、同步收到任务仍可续取和旧配置缺省迁移。合成 TCP 服务要容忍取消造成的空连接/不完整请求，保持续取断言。

`Theme.xaml` 管共享字体与控件，`Launcher.Dialogs.ps1` 管主题加载和 save/discard/cancel/confirm 小窗。新 PS 文件必须使用 UTF-8 BOM，兼容 Windows PowerShell 5.1；主题资源不能依赖后声明的 StaticResource。字体不可从发行白名单遗漏，许可一同分发。

`powershell.exe -NoProfile -STA -File tests/Interface.Tests.ps1` 需要可交互的 Windows 桌面。可传 `-PreviewDirectory` 输出截图；100/150/200%截图是渲染像素密度，不代表真实系统 DPI 切换。CI 仅做 XML/语法及非交互协议检查。截图根视觉的边距不能裁去外框；字段、菜单、确认窗应查看真实输出。
