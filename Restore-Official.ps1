param([switch]$ConsoleOnly,[switch]$ResetLogin)
$ErrorActionPreference='Stop'
# Independent of UI, API profiles, image settings and desktop install discovery.
$message='';$failed=$false
try{
    . (Join-Path $PSScriptRoot 'Launcher.Core.ps1')
    if($ResetLogin){Reset-OfficialConnection -Confirmed}else{Restore-OfficialOnly -Force}
    $message='官方连接与保存的官方登录已恢复。现在可以从开始菜单正常打开 Codex。'
    if(-not $script:LastRecoveryPerformed){$message='没有助手的待恢复切换。可从开始菜单打开官方 Codex；若账号已退出，仍需正常登录。'}
    if($script:RecoveryNotice){$message+="`n`n"+$script:RecoveryNotice}
    if($script:LastRecoveryDirectory){$message+="`n`n恢复前文件已备份："+$script:LastRecoveryDirectory}
}catch{
    $failed=$true;$message=$_.Exception.Message
    if(-not $ConsoleOnly -and $script:CanResetOfficial){
        try{
            Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
            . (Join-Path $PSScriptRoot 'Launcher.Dialogs.ps1')
            $confirm=New-AssistantDialog $null 'reset-login' '重置连接并重新登录官方？' ($message+"`n`n将先加密备份当前配置与登录，再清除 API 连接。聊天和项目保留，原来的其他参数可从备份找回。")
            $null=$confirm.ShowDialog()
            if($confirm.Tag.Choice -eq 'confirm'){Reset-OfficialConnection -Confirmed;$failed=$false;$message=$script:RecoveryNotice}
        }catch{$message=$_.Exception.Message}
    }
}
if(-not $ConsoleOnly){
    try{
        Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
        . (Join-Path $PSScriptRoot 'Launcher.Dialogs.ps1')
        $kind='notice';$title='已恢复官方';if($failed){$kind='error';$title='暂时无法恢复'}
        $notice=New-AssistantDialog $null $kind $title $message
        $null=$notice.ShowDialog()
    }catch{Write-Host $message}
}else{Write-Host $message}
if($failed){exit 1}
