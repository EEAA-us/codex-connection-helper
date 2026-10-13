function Get-DistributionFiles {
return @(
 'Distribution.ps1','Install.ps1','DesktopEntry.cs','Build-Desktop.ps1','Launch.exe','Setup.exe','tests\Install.Tests.ps1','Launcher.Core.ps1','Launcher.Paths.ps1','Launcher.ps1','Launcher.Dialogs.ps1','Restore-Official.ps1','恢复官方配置.cmd','Environment.ps1','UI.xaml','Theme.xaml',
 'HttpBridge.ps1','HttpBridge.cs','ApiProbe.cs','DesktopActivation.cs','Shortcut.cs','Repair-Shortcut.ps1','Prepare-Share.ps1',
 'NativeProbe.cs','Launcher.Compatibility.ps1','Launcher.CompatibilityUI.ps1','tests\Compatibility.Tests.ps1',
 'Launcher.Images.ps1','Launcher.ImageUI.ps1','ImageTools.cs','ImageMcp.ps1',
 '打开启动器.vbs','打开启动器.cmd','修复桌面快捷方式.cmd',
 'codex-star.ico','logo.svg','logo.png','fonts\ChillRoundM.ttf','fonts\OFL.txt','fonts\README.md',
 '界面预览.png','API参数预览.png','启动检查预览.png','切换首页预览.png','配置选择预览.png','推理说明预览.png',
 '图片服务预览.png','保存确认预览.png','安装预览.png','环境设置预览.png',
 '使用说明.html','README.md','DESIGN.md','验证记录.md','CONTRIBUTING.md','NOTICE.md','.gitignore',
 'tests\Portability.Tests.ps1','tests\ShareSafety.Tests.ps1','tests\ApiProbe.Tests.ps1','tests\ImageTools.Tests.ps1','tests\Interface.Tests.ps1','tests\Recovery.Tests.ps1','tests\Workers.Tests.ps1','tests\NativePipe.Tests.ps1','.github\workflows\windows.yml'
)
}
