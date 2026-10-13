param([string]$DesktopDirectory='')
$ErrorActionPreference = 'Stop'
$launcherFile = Join-Path $PSScriptRoot 'Launch.exe'
$bundledIcon = Join-Path $PSScriptRoot 'codex-star.ico'
if (-not (Test-Path -LiteralPath $launcherFile) -or -not (Test-Path -LiteralPath $bundledIcon)) {
    throw '启动器或图标文件缺失，请保留完整的 Codex 启动器文件夹。'
}
$assetDir = Join-Path $env:LOCALAPPDATA 'CodexLauncherSafe\assets'
New-Item -ItemType Directory -Path $assetDir -Force | Out-Null
$iconDigest = [Security.Cryptography.SHA256]::Create()
try { $iconTag = [BitConverter]::ToString($iconDigest.ComputeHash([IO.File]::ReadAllBytes($bundledIcon))).Replace('-','').Substring(0,12).ToLowerInvariant() }
finally { $iconDigest.Dispose() }
$stableIcon = Join-Path $assetDir ('codex-launcher-' + $iconTag + '.ico')
Copy-Item -LiteralPath $bundledIcon -Destination $stableIcon -Force
Add-Type -AssemblyName System.Drawing
$iconCheck = [Drawing.Icon]::new($stableIcon)
$iconCheck.Dispose()
$desktopDir = $DesktopDirectory
if(-not $desktopDir){$desktopDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)}
if (-not $desktopDir -or -not (Test-Path -LiteralPath $desktopDir)) { throw '未找到当前用户的桌面目录。' }
$shortcutPath = Join-Path $desktopDir 'Codex 模式切换.lnk'
if(-not ('CodexShortcut' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'Shortcut.cs')}
[CodexShortcut]::Create($shortcutPath,$launcherFile,$PSScriptRoot,$stableIcon)
if([CodexShortcut]::ReadTarget($shortcutPath) -ine $launcherFile){throw '桌面入口回读不一致，请重新安装。'}
if (-not ('CodexLauncherShortcutShell' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexLauncherShortcutShell {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern void SHChangeNotify(uint eventId, uint flags, string item1, string item2);
}
'@
}
# Notify Explorer about this shortcut only; no process restarts or cache deletion.
[CodexLauncherShortcutShell]::SHChangeNotify(0x2000,0x5,$shortcutPath,$null)
Write-Output '桌面快捷方式已修复。图标保存在固定目录，不随 Codex 版本更新移动。'
