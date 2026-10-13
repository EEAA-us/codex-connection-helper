param([Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
$target=[IO.Path]::GetFullPath($Destination)
$origin=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
if($target.Equals($origin,[StringComparison]::OrdinalIgnoreCase) -or $target.StartsWith($origin+'\',[StringComparison]::OrdinalIgnoreCase)){
    throw '分享目录必须在源码文件夹之外。'
}
if(Test-Path -LiteralPath $target){throw '目标已经存在。请选择新的空目录，避免混入本机数据；脚本不会覆盖或删除旧目录。'}
$allowed=@(
 'Launcher.Core.ps1','Launcher.Paths.ps1','Launcher.ps1','Launcher.Dialogs.ps1','Restore-Official.ps1','恢复官方配置.cmd','Environment.ps1','UI.xaml','Theme.xaml',
 'HttpBridge.ps1','HttpBridge.cs','ApiProbe.cs','DesktopActivation.cs','Repair-Shortcut.ps1','Prepare-Share.ps1',
 'NativeProbe.cs','Launcher.Compatibility.ps1','Launcher.CompatibilityUI.ps1','tests\Compatibility.Tests.ps1',
 'Launcher.Images.ps1','Launcher.ImageUI.ps1','ImageTools.cs','ImageMcp.ps1',
 '打开启动器.vbs','打开启动器.cmd','修复桌面快捷方式.cmd',
 'codex-star.ico','logo.svg','logo.png','fonts\ChillRoundM.ttf','fonts\OFL.txt','fonts\README.md',
 '界面预览.png','API参数预览.png','启动检查预览.png','切换首页预览.png','配置选择预览.png','推理说明预览.png',
 '图片服务预览.png','保存确认预览.png',
 '使用说明.html','README.md','DESIGN.md','验证记录.md','CONTRIBUTING.md','NOTICE.md','.gitignore',
 'tests\Portability.Tests.ps1','tests\ShareSafety.Tests.ps1','tests\ApiProbe.Tests.ps1','tests\ImageTools.Tests.ps1','tests\Interface.Tests.ps1','tests\Recovery.Tests.ps1','tests\Workers.Tests.ps1','tests\NativePipe.Tests.ps1','.github\workflows\windows.yml'
)
foreach($relative in $allowed){
    $path=Join-Path $origin $relative
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw ('发行文件缺失：'+$relative)}
    $item=Get-Item -LiteralPath $path -Force
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw '分享文件不能是链接。'}
    $parent=$item.Directory
    while($parent -and $parent.FullName.Length -ge $origin.Length){
        if($parent.Attributes -band [IO.FileAttributes]::ReparsePoint){throw '分享文件的父目录不能是链接。'}
        $parent=$parent.Parent
    }
}
New-Item -ItemType Directory -Path $target|Out-Null
foreach($relative in $allowed){
    $destinationFile=Join-Path $target $relative
    New-Item -ItemType Directory -Path (Split-Path $destinationFile) -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $origin $relative) -Destination $destinationFile
    if((Get-FileHash -LiteralPath (Join-Path $origin $relative)).Hash -ne (Get-FileHash -LiteralPath $destinationFile).Hash){throw '分享文件校验失败。'}
}
Write-Output ('已创建干净分享目录，共 '+$allowed.Count+' 个文件：'+$target)
