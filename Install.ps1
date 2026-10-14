param([switch]$ValidateOnly,[switch]$FunctionsOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Distribution.ps1')

function Assert-ProgramFiles([string]$Root) {
    foreach($relative in @(Get-DistributionFiles)){
        $file=Join-Path $Root $relative
        if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw ('请完整解压下载包，缺少：'+$relative)}
        $ancestor=$file
        while($ancestor -and $ancestor.Length -ge $Root.TrimEnd('\').Length){
            if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '程序文件不能通过链接安装，请使用普通本机文件夹。'}
            $ancestor=Split-Path $ancestor -Parent
        }
    }
}

function Assert-InstallPath([string]$Path) {
    $ancestor=$Path
    while($ancestor){
        if(Test-Path -LiteralPath $ancestor){if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '安装位置包含链接，请使用普通程序目录。'}}
        $ancestor=Split-Path $ancestor -Parent
    }
}

function Install-LauncherFiles([string]$Source,[string]$Destination) {
    $Source=[IO.Path]::GetFullPath($Source).TrimEnd('\');$Destination=[IO.Path]::GetFullPath($Destination).TrimEnd('\')
    if($Destination -notmatch '^[A-Za-z]:\\' -or $Destination.Length -le 3){throw '安装位置必须是本机程序文件夹。'}
    Assert-ProgramFiles $Source
    Assert-InstallPath $Destination
    if($Source.Equals($Destination,[StringComparison]::OrdinalIgnoreCase)){return $Destination}
    foreach($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)){
        if($process.Name -in @('powershell.exe','pwsh.exe') -and $process.CommandLine -and $process.CommandLine.IndexOf((Join-Path $Destination 'Launcher.ps1'),[StringComparison]::OrdinalIgnoreCase) -ge 0){throw '请先关闭旧版连接助手，再点击安装。官方 Codex 可以继续运行。'}
    }
    # Only public program files are replaced. Account/profile/session/plugin directories
    # are outside this installation and are neither opened nor copied by this installer.
    $backup=Join-Path (Split-Path $Destination) ('CodexConnectionHelper-backups\'+[Guid]::NewGuid().ToString('N'))
    $changed=@()
    try{
        foreach($relative in @(Get-DistributionFiles)){
            $sourceFile=Join-Path $Source $relative;$target=Join-Path $Destination $relative
            Assert-InstallPath $target
            $exists=Test-Path -LiteralPath $target
            if($exists -and (Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '目标程序文件是链接，请选择普通程序目录。'}
            if($exists -and (Get-FileHash -LiteralPath $target).Hash -eq (Get-FileHash -LiteralPath $sourceFile).Hash){continue}
            $old=Join-Path $backup $relative
            Assert-InstallPath $old
            if($exists){New-Item -ItemType Directory -Path (Split-Path $old) -Force|Out-Null;Copy-Item -LiteralPath $target -Destination $old}
            $changed+=@([pscustomobject]@{target=$target;backup=$old;existed=$exists})
            New-Item -ItemType Directory -Path (Split-Path $target) -Force|Out-Null
            Copy-Item -LiteralPath $sourceFile -Destination $target -Force
            if((Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath $sourceFile).Hash){throw '程序复制校验失败，请重新安装。'}
        }
    }catch{
        $failure=$_
        $rollbackErrors=@()
        if($changed.Count){foreach($entry in @($changed)[($changed.Count-1)..0]){
            try{
                if($entry.existed){Copy-Item -LiteralPath $entry.backup -Destination $entry.target -Force}
                elseif(Test-Path -LiteralPath $entry.target){Remove-Item -LiteralPath $entry.target}
            }catch{$rollbackErrors+=@($entry.target)}
        }
        }
        if($rollbackErrors.Count){throw ('程序更新未完成：'+$failure.Exception.Message+'；部分程序文件还原失败，旧版保存在 '+$backup+'。请关闭助手后重新安装。官方数据未执行更新。')}
        throw $failure
    }
    return $Destination
}

if($FunctionsOnly){return}
if($ValidateOnly){Assert-ProgramFiles $PSScriptRoot;'PASS: complete desktop installation payload.';exit 0}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml,System.Windows.Forms
. (Join-Path $PSScriptRoot 'Launcher.Dialogs.ps1')
$layout=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="安装 · Codex 连接助手" Width="660" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterScreen" Background="{DynamicResource Canvas}" FontFamily="{DynamicResource UiFont}" FontSize="14" Foreground="{DynamicResource Ink}">
 <Window.Resources><ResourceDictionary><ResourceDictionary.MergedDictionaries><ResourceDictionary Source="Theme.xaml"/></ResourceDictionary.MergedDictionaries></ResourceDictionary></Window.Resources>
 <Border Padding="30"><Grid>
  <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <ScrollViewer x:Name="installBody" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,0,0,16"><StackPanel>
  <TextBlock Text="把连接助手放到桌面" FontSize="25" FontWeight="SemiBold" Margin="0,0,0,12"/>
  <TextBlock Text="安装后，双击桌面图标就能打开。更新也使用这个入口，沿用已保存的配置。" TextWrapping="Wrap" Foreground="{StaticResource MutedInk}" LineHeight="24"/>
  <Border Background="{StaticResource Surface}" BorderBrush="{StaticResource Divider}" BorderThickness="{DynamicResource ControlStroke}" CornerRadius="12" Padding="18" Margin="0,20,0,18"><StackPanel>
   <TextBlock Text="只更新助手程序" FontWeight="SemiBold"/>
   <TextBlock Text="保留官方登录、聊天与项目、插件文件、API 和图片服务设置。无需管理员权限。" TextWrapping="Wrap" Margin="0,8,0,14" LineHeight="24" Foreground="{StaticResource MutedInk}"/>
   <TextBlock Text="程序位置" Foreground="{StaticResource MutedInk}"/>
   <TextBlock x:Name="installPath" FontSize="12" TextWrapping="Wrap" Margin="0,5,0,0"/>
  </StackPanel></Border>
  <TextBlock x:Name="installError" TextWrapping="Wrap" Foreground="{StaticResource DangerInk}"/>
  </StackPanel></ScrollViewer>
  <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="installCancel" Content="取消" IsCancel="True" Margin="0,0,10,0"/><Button x:Name="installNow" Content="安装并打开" Style="{StaticResource Primary}" IsDefault="True"/></StackPanel>
 </Grid></Border>
</Window>
'@
try{
    $window=New-ThemedWindow $layout;$window.Icon=[Windows.Media.Imaging.BitmapFrame]::Create([Uri](Join-Path $PSScriptRoot 'codex-star.ico'))
    $destination=Join-Path $env:LOCALAPPDATA 'Programs\CodexConnectionHelper'
    $window.Tag=@{Destination=$destination;Error=$window.FindName('installError');Install=$window.FindName('installNow')}
    $window.FindName('installPath').Text=$destination
    $window.FindName('installCancel').Add_Click({param($sender,$args)([Windows.Window]::GetWindow($sender)).Close()})
    $window.FindName('installNow').Add_Click({param($sender,$args)
        $win=[Windows.Window]::GetWindow($sender);$ctx=$win.Tag;$ctx.Install.IsEnabled=$false
        try{
            $root=Install-LauncherFiles $PSScriptRoot $ctx.Destination
            & (Join-Path $root 'Repair-Shortcut.ps1')|Out-Null
            Start-Process -FilePath (Join-Path $root 'Launch.exe') -WorkingDirectory $root -WindowStyle Hidden|Out-Null
            $win.Close()
        }catch{$ctx.Error.Text=$_.Exception.Message;$ctx.Install.IsEnabled=$true}
    })
    $window.Width=[Math]::Min($window.Width,[Windows.SystemParameters]::WorkArea.Width-24)
    $window.MaxHeight=[Windows.SystemParameters]::WorkArea.Height-24
    $null=$window.ShowDialog()
}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'安装未完成')|Out-Null;exit 1}
