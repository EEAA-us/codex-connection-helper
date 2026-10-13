param()
$ErrorActionPreference='Stop'
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not(Test-Path -LiteralPath $compiler)){$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
foreach($name in @('Launch','Setup')){
    $output=Join-Path $PSScriptRoot ($name+'.exe')
    $arguments=@('/nologo','/target:winexe','/optimize+',('/out:'+$output),('/win32icon:'+(Join-Path $PSScriptRoot 'codex-star.ico')),'/reference:System.Windows.Forms.dll',(Join-Path $PSScriptRoot 'DesktopEntry.cs'))
    if($name -eq 'Setup'){$arguments+=@('/define:SETUP')}
    & $compiler @arguments
    if($LASTEXITCODE -ne 0){throw ('桌面入口编译失败：'+$name)}
}
'PASS: desktop Launch.exe and Setup.exe built as Windows applications.'
