param([switch]$UI,[string]$PreviewDirectory)
$ErrorActionPreference='Stop'
$source=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('Codex-install 中文 空格-'+[Guid]::NewGuid().ToString('N'))
$before=@{}
foreach($name in @('LOCALAPPDATA','APPDATA','USERPROFILE','CODEX_HOME','CODEX_ELECTRON_USER_DATA_PATH')){$before[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
try{
    $env:LOCALAPPDATA=Join-Path $fixture 'Local';$env:APPDATA=Join-Path $fixture 'Roaming';$env:USERPROFILE=Join-Path $fixture '用户'
    $env:CODEX_HOME=$null;$env:CODEX_ELECTRON_USER_DATA_PATH=$null
    $seed=Join-Path $fixture '下载包';$target=Join-Path $env:LOCALAPPDATA 'Programs\CodexConnectionHelper';$desktop=Join-Path $fixture '桌面'
    & (Join-Path $source 'Prepare-Share.ps1') -Destination $seed|Out-Null
    if($UI){
        if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Installer UI checks require PS5.1 -STA.'}
        if($PreviewDirectory){$PreviewDirectory=[IO.Path]::GetFullPath($PreviewDirectory);New-Item -ItemType Directory -Path $PreviewDirectory -Force|Out-Null}
        # Exercise the actual layout and event bindings, replacing only its blocking
        # ShowDialog and the outer OS error box. No successful install is clicked.
        $uiChecks=@'
$window.Show();$window.UpdateLayout()
function Check-SetupActions {
    foreach($name in @('installNow','installCancel')){
        $button=$window.FindName($name)
        $bounds=$button.TransformToAncestor($window.Content).TransformBounds([Windows.Rect]::new(0,0,$button.ActualWidth,$button.ActualHeight))
        if($bounds.Top -lt 0 -or $bounds.Left -lt 0 -or $bounds.Bottom -gt $window.Content.ActualHeight -or $bounds.Right -gt $window.Content.ActualWidth){throw ('Installer action outside viewport: '+$name)}
    }
}
try{
    Check-SetupActions
    $entry=Join-Path $PSScriptRoot 'Launch.exe';$disabled=$entry+'.fixture-disabled'
    Move-Item -LiteralPath $entry -Destination $disabled
    try{
        $window.FindName('installNow').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $window.UpdateLayout()
        if(-not $window.IsVisible -or -not $window.Tag.Install.IsEnabled -or $window.Tag.Error.Text -notmatch 'Launch.exe'){throw 'Failed payload validation must leave setup open and retry available.'}
        if(Test-Path -LiteralPath $window.Tag.Destination){throw 'Validation failure created installation files.'}
    }finally{Move-Item -LiteralPath $disabled -Destination $entry}
    $window.Width=550;$window.MaxHeight=390
    $window.Tag.Error.Text=('无法更新文件：D:\某位用户\较长的程序安装目录\CodexConnectionHelper\Launcher.ps1。文件正在被使用，请关闭旧助手后再试。 '*8)
    $window.UpdateLayout();$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
    Check-SetupActions
    $body=$window.FindName('installBody')
    if(-not $body -or $body.ScrollableHeight -le 0){throw 'Long installation errors must remain scrollable.'}
    $body.ScrollToBottom();$window.UpdateLayout()
    if($body.VerticalOffset -le 0){throw 'Installation error cannot be scrolled into view.'}
    if($PreviewDirectory){
        $drawing=[Windows.Media.DrawingVisual]::new();$dc=$drawing.RenderOpen();$rect=[Windows.Rect]::new(0,0,$window.Content.ActualWidth,$window.Content.ActualHeight)
        $brush=[Windows.Media.VisualBrush]::new($window.Content);$brush.ViewboxUnits=[Windows.Media.BrushMappingMode]::Absolute;$brush.Viewbox=$rect;$brush.Stretch=[Windows.Media.Stretch]::Fill
        $dc.DrawRectangle($window.Background,$null,$rect);$dc.DrawRectangle($brush,$null,$rect);$dc.Close()
        $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int][Math]::Ceiling($rect.Width),[int][Math]::Ceiling($rect.Height),96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($drawing)
        $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream=[IO.File]::Create((Join-Path $PreviewDirectory 'setup-small-error.png'));try{$encoder.Save($stream)}finally{$stream.Dispose()}
    }
    $window.FindName('installCancel').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    if($window.IsVisible){throw 'Setup cancel did not close its window.'}
}finally{if($window.IsVisible){$window.Close()}}
'@
        $installer=[IO.File]::ReadAllText((Join-Path $seed 'Install.ps1'))
        if(-not $installer.Contains('$null=$window.ShowDialog()')){throw 'Production installer UI entry changed; update the fixture.'}
        $installer=$installer.Replace('$null=$window.ShowDialog()',$uiChecks).Replace("[Windows.Forms.MessageBox]::Show(`$_.Exception.Message,'安装未完成')|Out-Null;exit 1",'throw')
        $uiScript=Join-Path $seed 'SetupFixture.Tests.ps1'
        [IO.File]::WriteAllText($uiScript,$installer,[Text.UTF8Encoding]::new($true))
        & $uiScript
        'PASS: production installer actions remain visible with long errors in a small work area; failure permits retry; cancel closes.'
    }
    New-Item -ItemType Directory -Path $desktop -Force|Out-Null
    . (Join-Path $source 'Install.ps1') -FunctionsOnly
    function Get-CimInstance {param($ClassName,$ErrorAction) return @()}
    $guard=@{}
    foreach($relative in @('Local\CodexLauncherSafe\profiles.json','Local\CodexLauncherSafe\paths.json','Local\CodexLauncherSafe\official-recovery.json','Local\CodexLauncherSafe\shared-switch.json','Local\CodexLauncherSafe\image-services.json','用户\.codex\auth.json','用户\.codex\config.toml','用户\.codex\sessions\history.jsonl','用户\.codex\plugins\installed.json')){
        $file=Join-Path $fixture $relative;New-Item -ItemType Directory -Path (Split-Path $file) -Force|Out-Null
        [IO.File]::WriteAllText($file,('synthetic-private-'+$relative));$guard[$file]=(Get-FileHash -LiteralPath $file).Hash
    }
    $null=Install-LauncherFiles $seed $target
    foreach($relative in @(Get-DistributionFiles)){if((Get-FileHash (Join-Path $seed $relative)).Hash -ne (Get-FileHash (Join-Path $target $relative)).Hash){throw 'First install file mismatch'}}
    $sentinel=Join-Path $target 'profiles.json';[IO.File]::WriteAllText($sentinel,'legacy-private-sentinel')
    [IO.File]::AppendAllText((Join-Path $seed 'README.md'),"`r`nsynthetic-update")
    $null=Install-LauncherFiles $seed $target
    $null=Install-LauncherFiles $seed $target
    & (Join-Path $target 'Repair-Shortcut.ps1') -DesktopDirectory $desktop|Out-Null
    $shortcutPath=Join-Path $desktop 'Codex 模式切换.lnk'
    if([CodexShortcut]::ReadTarget($shortcutPath) -ine (Join-Path $target 'Launch.exe') -or [CodexShortcut]::ReadArguments($shortcutPath) -or [CodexShortcut]::ReadWorkingDirectory($shortcutPath) -ine $target){throw 'Desktop shortcut is not a direct executable entry'}
    [IO.File]::WriteAllText((Join-Path $seed 'Launcher.ps1'),@'
param([switch]$ValidateOnly)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'entry-observed.txt'),[Threading.Thread]::CurrentThread.GetApartmentState().ToString())
exit 0
'@,[Text.UTF8Encoding]::new($true))
    $process=Start-Process -FilePath (Join-Path $seed 'Launch.exe') -ArgumentList '--check' -WindowStyle Hidden -PassThru -Wait
    if($process.ExitCode -ne 0 -or [IO.File]::ReadAllText((Join-Path $seed 'entry-observed.txt')) -ne 'STA'){throw 'Double-click executable did not launch PS5.1 STA correctly'}
    $hashes=@{};foreach($relative in @(Get-DistributionFiles)){$hashes[$relative]=(Get-FileHash (Join-Path $target $relative)).Hash}
    [IO.File]::AppendAllText((Join-Path $seed 'Distribution.ps1'),"`r`n# changed fixture")
    [IO.File]::AppendAllText((Join-Path $seed 'Install.ps1'),"`r`n# changed fixture")
    $script:FailureTarget=Join-Path $target 'Launcher.ps1';$script:FailureSource=Join-Path $seed 'Launcher.ps1'
    function Copy-Item {param($LiteralPath,$Destination,[switch]$Force)
        if($Destination -eq $script:FailureTarget -and $LiteralPath -eq $script:FailureSource){throw 'synthetic mid-update failure'}
        Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
    }
    $failed=$false;try{$null=Install-LauncherFiles $seed $target}catch{$failed=$true}finally{Remove-Item Function:Copy-Item}
    if(-not $failed){throw 'Injected installation failure not observed'}
    foreach($relative in $hashes.Keys){if((Get-FileHash (Join-Path $target $relative)).Hash -ne $hashes[$relative]){throw ('Program rollback failed: '+$relative)}}
    if([IO.File]::ReadAllText($sentinel) -cne 'legacy-private-sentinel'){throw 'Upgrade overwrote non-program file'}
    foreach($file in $guard.Keys){if((Get-FileHash -LiteralPath $file).Hash -ne $guard[$file]){throw 'Install/update modified account, configuration, history or plugins'}}
    'PASS: direct EXE STA entry; desktop shortcut; first install/update/idempotence; mid-update rollback; official/API settings, history and plugins unchanged.'
}finally{foreach($name in $before.Keys){[Environment]::SetEnvironmentVariable($name,$before[$name],'Process')}}
