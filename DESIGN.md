# 连接助手界面设计

2026-10-11 · 0.3.6。当前正文取代早期淡紫界面的视觉规格。实际使用已安装的 Design Partner 技能，读取其 redesign、typeset、foundations、accessibility 和 verification 指导；GitHub 项目作为参考，未安装新的设计引擎或组件运行包。

## 方向与排版

用户选择明亮日系工具风，并进一步要求字体更时尚、减少板正感。采用雾蓝画布、白色内容面、蓝色主操作和少量樱粉。保留用户指定的 GPT 图案，不增加宠物或角色。

界面使用本地 ChillRoundM（寒蝉半圆体）v1.805，原始 TTF 未修改，按 OFL 1.1 随软件分发。圆润字形用于导航、标题、中文标签、按钮和说明；地址、模型编辑与路径的 DataFont 也使用同一 ChillRoundM，缺失字形回退 Segoe UI / Microsoft YaHei UI。未写入 Windows 字体目录。标题 27 DIP、模块标题 18、字段与按钮 14、说明 13；主窗口采用 Ideal 字体排版。

Theme.xaml 是颜色、字体和控件样式的唯一正文：Canvas #F4F7FA、NavigationSurface #EDF2F7、Ink #243647、MutedInk #56697B、ActionInk #375EBB、InputBorder #8796AA。面板圆角 12，控件圆角 8；输入与按钮最小高 40。键盘焦点在控件边界内绘制，不使用负边距外环。

## 结构与交互

侧栏保持 300 DIP，API 配置入口始终显著；选中态用浅蓝面与左侧标记。主窗口默认 1280×940，最小 1080×760，启动时按可用工作区调整。中间内容滚动，配置页底部保存、撤销和启动固定。

首页把官方入口与所选 API 操作分开。图片页依次为服务选择、图片接口、图片检查；启动摘要与插件诊断为同级区域，不再嵌套诊断卡片。参数按需展开，连接检查改为直接显示。

下拉外框独立绘制，项目距四周边缘 5 DIP，弹出距离由 Popup.VerticalOffset 控制，避免菜单项目覆盖边框；滚动条复用细滑块。说明卡片、Tooltip、环境设置和顶部提示均复用主题。

Launcher.Dialogs.ps1 提供 New-ThemedWindow、New-AssistantDialog 和 Show-AssistantDialog；返回 save/discard/cancel/confirm，映射到保存、删除及提示逻辑；明确恢复按钮使用应急恢复合同。小窗有明确 Owner，不出现在任务栏；保存默认聚焦主按钮，删除默认聚焦取消，Enter 激活焦点按钮，Esc/关闭取消。模态期间阻止重复开窗，并恢复原焦点。保存失败不丢草稿。文件选择器与主题加载失败的启动错误保留 Windows 兜底。

连接检查仅在连接与模型页展示，首页旧控件保留隐藏以兼容事件。底部不重复错误正文。顶部提示不抢焦点：成功与取消约 8 秒收起，悬停/聚焦暂停；错误手动关闭。长提示限定显示高度，完整结果留在模块。所有状态同时使用文字、图标和颜色。

## 验证

本机 Windows PowerShell 5.1 / WPF，实际桌面缩放 150%。Interface.Tests 在 1280/1080 DIP 检查字段四边、菜单外框、弹窗可绘制边界、真实模态按钮与 Enter/Esc、默认焦点、长提示和环境取消；输出 100/150/200% 像素密度渲染。不同真实系统 DPI 切换与屏幕阅读器仍 unobserved，不能用离屏渲染代替。

隔离生产 UI 检查覆盖配置保存、草稿取消与保存失败、删除确认、图片绑定、测试成功/失败/取消、模型列表、密钥隔离与兼容诊断。实际检查截图包含普通/焦点、小窗口、展开的长菜单和确认小窗。审美满意度仍由用户判断。

## 参考

- [寒蝉圆体](https://github.com/Warren2060/ChillRound)：实际携带的字体，授权见 fonts/OFL.txt。
- [UI UX Pro Max](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill)：设计体系与字体角色的参考；未安装其 CLI。
- [Impeccable](https://github.com/pbakaus/impeccable)：视觉层次与细节审查参考；未安装其引擎或 Hook。
- [WPF UI](https://github.com/lepoco/wpfui)：导航、对话框与提示组织参考；未引入 NuGet 包。
- [Fuwari](https://github.com/saicaca/fuwari)：明亮表面与主题色参考；未引入网页框架。

Figma 本轮没有创建或修改文件。设计技能仅供开发，不是软件用户的运行依赖。

Key 字段统一为可见 TextBox，加载已保存的凭据并保留回显；草稿比较使用独立的内存基准，不因字段非空而反复提示保存。图片引用选项已移除，旧配置仅在用户明确保存时转换。连接页减少重复说明、卡片内边距与行间距，检查区使用普通 StackPanel，1280/1080 窗口的默认与对话生图方式无垂直溢出。

0.3.6 控件修正：TextBox 不再同时给边框和文字视图添加内边距；横向 Padding 8 DIP，模型可编辑区保留 2 DIP 字形留边，首字符与普通输入框误差不超过 1.5 DIP。下拉选择左对齐。连接检查等待期间保留当前字段编辑，操作使用不可变开始快照；新草稿不能被旧结果覆盖或误标成功。

0.3.6 修正字体行度量：原字体 g 轮廓下伸 0.207 em，原行下降空间仅 0.12 em。保留原 TTF，UiFont/DataFont 改用同源复合字体，Baseline 0.88、LineSpacing 1.2；New-ThemedWindow 在布局前将映射目标解析为当前目录的绝对字体 URI。确认实际解析到 ChillRoundM，防止复合映射悄悄回退到系统字体。首页接口名保持 16 DIP，模型名 18 DIP 作视觉大小补偿，共同行高 24 DIP。

0.3.6：ControlStroke 根据窗口实际 DPI 计算，SourceInitialized 与 DpiChanged 时刷新，框的四边共用同一 Thickness；采用像素对齐绘制。配置动作列宽 96 DIP、间距 10 DIP，读取模型与配置图片/测试生图同列。撤销动作保持位置，没有修改时禁用并在实际还原后反馈。


0.3.16补充：共享范围双入口使用现有InfoButton与帮助Popup；关闭/Esc返回触发焦点，导航收起，长正文可滚动。主标题和自有确认窗不再使用粉色装饰点。
