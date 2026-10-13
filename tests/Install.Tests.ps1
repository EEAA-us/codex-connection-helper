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
    $shortcut=(New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $desktop 'Codex 模式切换.lnk'))
    if($shortcut.TargetPath -ine (Join-Path $target 'Launch.exe') -or $shortcut.Arguments -or $shortcut.WorkingDirectory -ine $target){throw 'Desktop shortcut is not a direct executable entry'}
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
