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
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $launcherFile
$shortcut.Arguments = ''
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.IconLocation = $stableIcon + ',0'
$shortcut.Description = '官方账号与第三方 API 切换，共用原来的本机记录'
$shortcut.Save()
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
