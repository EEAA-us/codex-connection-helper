# Local installation and data paths. Loading this file never writes user data.
function Convert-LauncherPath([string]$Value,[string]$Label) {
    $expanded=[Environment]::ExpandEnvironmentVariables($Value.Trim())
    if($expanded -notmatch '^[a-zA-Z]:[\\/]' -or $expanded -match '[\x00-\x1f"<>|?*%]' -or $expanded.Substring(2).Contains(':')) {
        throw ($Label+'须为本机完整路径，例如 D:\Apps\Codex；不支持相对路径或网络共享。')
    }
    $full=[IO.Path]::GetFullPath($expanded).Replace('/','\')
    if($full.Length -gt 3){$full=$full.TrimEnd('\')}
    return $full
}

function Get-PathPreferences {
    $path=Join-Path $script:LauncherData 'paths.json'
    if(-not(Test-Path -LiteralPath $path)){return [pscustomobject]@{version=1;desktop_exe='';codex_home='';ui_data_path=''}}
    try{
        $data=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
        if($data.version -ne 1){throw 'Unsupported path schema'}
        foreach($field in @('desktop_exe','codex_home','ui_data_path')){
            if(-not $data.PSObject.Properties[$field] -or $data.$field -isnot [string]){throw 'Invalid path field'}
        }
        return $data
    }catch{throw '环境位置配置无法读取。可在“环境设置”重新选择并保存；原文件会先备份。'}
}

function Initialize-LauncherPaths {
    $script:PathSettingsError='';$script:DesktopOverride=''
    $script:OfficialHome=Join-Path $env:USERPROFILE '.codex'
    $script:OfficialUi=Join-Path $env:APPDATA 'Codex'
    $script:HomePathSource='当前用户默认目录';$script:UiPathSource='当前用户默认目录'
    try{
        $settings=Get-PathPreferences
        if($settings.desktop_exe){$script:DesktopOverride=Convert-LauncherPath $settings.desktop_exe '桌面程序'}
        if($settings.codex_home){$script:OfficialHome=Convert-LauncherPath $settings.codex_home '聊天数据目录';$script:HomePathSource='手动选择'}
        if($settings.ui_data_path){$script:OfficialUi=Convert-LauncherPath $settings.ui_data_path '界面数据目录';$script:UiPathSource='手动选择'}
    }catch{$script:PathSettingsError=$_.Exception.Message}
    try{
        if($env:CODEX_HOME){$script:OfficialHome=Convert-LauncherPath $env:CODEX_HOME 'CODEX_HOME';$script:HomePathSource='环境变量 CODEX_HOME'}
        if($env:CODEX_ELECTRON_USER_DATA_PATH){$script:OfficialUi=Convert-LauncherPath $env:CODEX_ELECTRON_USER_DATA_PATH 'CODEX_ELECTRON_USER_DATA_PATH';$script:UiPathSource='环境变量 CODEX_ELECTRON_USER_DATA_PATH'}
    }catch{$script:PathSettingsError=$_.Exception.Message}
    $script:SwitchFile=Join-Path $script:LauncherData 'shared-switch.json'
}

function Assert-DesktopFile([string]$Path) {
    $full=Convert-LauncherPath $Path '桌面程序'
    if([IO.Path]::GetFileName($full) -notin @('ChatGPT.exe','Codex.exe') -or -not(Test-Path -LiteralPath $full -PathType Leaf)){
        throw '请选择 Codex 桌面程序 ChatGPT.exe 或 Codex.exe，不能选择 CLI 或卸载程序。'
    }
    $resources=Join-Path (Split-Path $full) 'resources'
    if(-not(Test-Path -LiteralPath (Join-Path $resources 'app.asar') -PathType Leaf) -or
       -not(Test-Path -LiteralPath (Join-Path $resources 'codex.exe') -PathType Leaf)){
        throw '所选位置缺少 Codex 桌面资源和引擎，请选择完整安装中的桌面程序。'
    }
    return $full
}

function Get-RegisteredDesktopPaths {
    if(Get-Command Get-AppxPackage -ErrorAction SilentlyContinue){
        foreach($package in @(Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue)){
            $manifestPath=Join-Path $package.InstallLocation 'AppxManifest.xml'
            if(Test-Path -LiteralPath $manifestPath){try{
                [xml]$manifest=[IO.File]::ReadAllText($manifestPath)
                foreach($application in @($manifest.Package.Applications.Application)){
                    if($application.Executable){Join-Path $package.InstallLocation ([string]$application.Executable).Replace('/','\')}
                }
            }catch{}}
            Join-Path $package.InstallLocation 'app\ChatGPT.exe'
            Join-Path $package.InstallLocation 'app\Codex.exe'
        }
    }
}

function Get-WindowsDesktopCandidates {
    # Read registration and running desktop paths, never scan drives or launch
    # registry command strings. Every candidate must pass Assert-DesktopFile.
    foreach($root in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths','HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths')){
        foreach($name in @('Codex.exe','ChatGPT.exe')){
            $key=Get-Item -LiteralPath (Join-Path $root $name) -ErrorAction SilentlyContinue
            if($key){$value=[string]$key.GetValue('');if($value){$value.Trim('"')}}
        }
    }
    foreach($root in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')){
        foreach($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)){
            try{
                if([string]$key.GetValue('DisplayName') -notmatch 'Codex|ChatGPT'){continue}
                $location=[string]$key.GetValue('InstallLocation')
                if($location){foreach($relative in @('ChatGPT.exe','Codex.exe','app\ChatGPT.exe','app\Codex.exe')){Join-Path $location $relative}}
                $icon=[regex]::Match([string]$key.GetValue('DisplayIcon'),'\A\s*(?:"(?<path>[^"]+\.exe)"|(?<path>[^",]+\.exe))(?:\s*,\s*-?\d+)?\s*\z',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if($icon.Success){$icon.Groups['path'].Value}
            }catch{continue}
        }
    }
    foreach($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)){
        if($process.Name -in @('ChatGPT.exe','Codex.exe') -and $process.ExecutablePath){[string]$process.ExecutablePath}
    }
}

function Get-DesktopExe {
    if($script:PathSettingsError){throw $script:PathSettingsError}
    # An explicit choice must fail visibly, never silently launch a different installation.
    if($script:DesktopOverride){return Assert-DesktopFile $script:DesktopOverride}
    foreach($candidate in @(Get-RegisteredDesktopPaths)){
        try{return Assert-DesktopFile $candidate}catch{}
    }
    $valid=@(foreach($candidate in @(Get-WindowsDesktopCandidates|Select-Object -Unique)){
        try{Assert-DesktopFile $candidate}catch{}
    })
    if($valid.Count -eq 1){return $valid[0]}
    if($valid.Count -gt 1){throw '找到多个完整 Codex 安装。请在“环境设置”选择要使用的版本，避免启动错误的安装。'}
    throw '未自动找到 Codex 桌面版。请在“环境设置”选择桌面程序；仅安装 CLI 不够。'
}

function Test-CodexHome([string]$Path) {
    if($Path.Length -le 3){return $false}
    if(-not(Test-Path -LiteralPath $Path -PathType Container)){return $false}
    foreach($name in @('config.toml','auth.json','sessions','state_5.sqlite')){
        if(Test-Path -LiteralPath (Join-Path $Path $name)){return $true}
    }
    return $false
}

function Get-OfficialDesktopExe {
    try{return Get-DesktopExe}catch{
        $savedError=$script:PathSettingsError;$savedOverride=$script:DesktopOverride
        try{
            $script:PathSettingsError='';$script:DesktopOverride=''
            $exe=Get-DesktopExe
            $script:RecoveryNotice+=' 已自动使用 Windows 发现的完整官方安装；原手工位置设置保留。'
            return $exe
        }finally{$script:PathSettingsError=$savedError;$script:DesktopOverride=$savedOverride}
    }
}

function Get-RegisteredDesktopIdentity([string]$Exe) {
    if(-not(Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)){return $null}
    foreach($package in @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue)){
        if(-not $package.PackageFamilyName -or -not $package.InstallLocation){continue}
        try{
            [xml]$manifest=[IO.File]::ReadAllText((Join-Path $package.InstallLocation 'AppxManifest.xml'))
            foreach($application in @($manifest.Package.Applications.Application)){
                if(-not $application.Executable -or -not $application.Id){continue}
                $registered=[IO.Path]::GetFullPath((Join-Path $package.InstallLocation ([string]$application.Executable).Replace('/','\')))
                if($registered.Equals([IO.Path]::GetFullPath($Exe),[StringComparison]::OrdinalIgnoreCase)){
                    return [pscustomobject]@{app_id=([string]$package.PackageFamilyName+'!'+[string]$application.Id);exe=$registered}
                }
            }
        }catch{continue}
    }
    return $null
}

function Get-DesktopLaunchPlan([string]$Exe,[string]$HomePath,[string]$UiPath='') {
    $identity=Get-RegisteredDesktopIdentity $Exe
    $defaultHome=Join-Path $env:USERPROFILE '.codex';$defaultUi=Join-Path $env:APPDATA 'Codex'
    $customEnvironment=$false
    foreach($name in @('OPENAI_API_KEY','CODEX_API_KEY','OPENAI_BASE_URL','CODEX_HOME','CODEX_ELECTRON_USER_DATA_PATH')){
        foreach($scope in @('Process','User','Machine')){
            if([Environment]::GetEnvironmentVariable($name,$scope)){$customEnvironment=$true}
        }
    }
    # Shell activation has no per-launch environment block. Use it only when
    # its inherited/default directories match the launcher's resolved directories.
    $sameHome=[IO.Path]::GetFullPath($HomePath).TrimEnd('\').Equals($defaultHome.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)
    $sameUi=(-not $UiPath) -or [IO.Path]::GetFullPath($UiPath).TrimEnd('\').Equals($defaultUi.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)
    if($identity -and $sameHome -and $sameUi -and -not $customEnvironment){
        return [pscustomobject]@{kind='registered';app_id=$identity.app_id;exe=$Exe}
    }
    return [pscustomobject]@{kind='process';app_id='';exe=$Exe}
}

function Assert-ResolvedDataPaths([switch]$Api) {
    if($script:PathSettingsError){throw $script:PathSettingsError}
    if($script:OfficialUi.Length -le 3){throw '界面数据目录不能选择整个磁盘根目录，请修正位置或环境变量。'}
    $settings=Get-PathPreferences
    if(($settings.codex_home -or $env:CODEX_HOME -or $Api) -and -not(Test-CodexHome $script:OfficialHome)){
        throw '聊天数据目录不存在或没有 Codex 数据。请在“环境设置”选择原目录，或先打开官方 Codex 完成初始化。'
    }
    if(($settings.ui_data_path -or $env:CODEX_ELECTRON_USER_DATA_PATH) -and -not(Test-Path -LiteralPath $script:OfficialUi -PathType Container)){
        throw '界面数据目录不存在。请选择已使用的目录，避免误建一套空白界面记录。'
    }
}

function Assert-PathChangeClosed([string[]]$DesktopPaths=@()) {
    $registered=@(Get-RegisteredDesktopPaths)
    foreach($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)){
        if($process.Name -ieq 'codex.exe'){throw 'Codex 或 CLI 仍在运行，请正常退出后再保存环境位置。'}
        if($process.Name -ine 'ChatGPT.exe'){continue}
        if(-not $process.ExecutablePath){throw '无法核对正在运行的桌面程序，请先正常退出后再保存环境位置。'}
        if($process.ExecutablePath -in @($registered+$DesktopPaths) -or $process.ExecutablePath -match 'OpenAI\.Codex_[^\\]+\\app\\ChatGPT\.exe$'){
            throw 'Codex 桌面版仍在运行，请完全退出（包括托盘）后再保存环境位置。'
        }
        $resource=Join-Path (Split-Path $process.ExecutablePath) 'resources\codex.exe'
        if(Test-Path -LiteralPath $resource){throw '检测到另一个 Codex 桌面安装正在运行，请先正常退出。'}
    }
}

function Save-PathPreferences([string]$DesktopExe,[string]$CodexHome,[string]$UiDataPath) {
    $data=[pscustomobject]@{version=1;desktop_exe='';codex_home='';ui_data_path=''}
    if($DesktopExe.Trim()){$data.desktop_exe=Assert-DesktopFile $DesktopExe}
    if($CodexHome.Trim()){
        $data.codex_home=Convert-LauncherPath $CodexHome '聊天数据目录'
        if(-not(Test-CodexHome $data.codex_home)){throw '请选择含有 Codex 配置或聊天记录的原数据目录，不能选择空文件夹。'}
    }
    if($UiDataPath.Trim()){
        $data.ui_data_path=Convert-LauncherPath $UiDataPath '界面数据目录'
        if($data.ui_data_path.Length -le 3){throw '界面数据目录不能选择整个磁盘根目录。'}
        if(-not(Test-Path -LiteralPath $data.ui_data_path -PathType Container)){throw '请选择已存在的界面数据目录。'}
    }
    # Validate environment overrides too: they continue to take priority after saving.
    if($env:CODEX_HOME -and -not(Test-CodexHome (Convert-LauncherPath $env:CODEX_HOME 'CODEX_HOME'))){throw 'CODEX_HOME 指向无效目录，请先修正该环境变量。'}
    if($env:CODEX_ELECTRON_USER_DATA_PATH){
        $envUi=Convert-LauncherPath $env:CODEX_ELECTRON_USER_DATA_PATH 'CODEX_ELECTRON_USER_DATA_PATH'
        if($envUi.Length -le 3 -or -not(Test-Path -LiteralPath $envUi -PathType Container)){throw 'CODEX_ELECTRON_USER_DATA_PATH 须指向已存在的界面目录，不能是整盘。'}
    }
    Assert-PathChangeClosed @($script:DesktopOverride,$data.desktop_exe)
    $statePath=Join-Path $script:LauncherData 'shared-switch.json'
    if(Test-Path -LiteralPath $statePath){
        try{$state=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json}catch{throw '恢复备份无法读取，先处理原备份再修改位置。'}
        $newHome=Join-Path $env:USERPROFILE '.codex'
        if($data.codex_home){$newHome=$data.codex_home}
        if($env:CODEX_HOME){$newHome=Convert-LauncherPath $env:CODEX_HOME 'CODEX_HOME'}
        if($state.active -and $state.home -ne $newHome){
            throw '仍有未恢复的 API 切换。请先在原环境恢复官方，再更改位置；目录选错时仅允许改回备份所绑定的原目录。'
        }
    }
    $path=Join-Path $script:LauncherData 'paths.json'
    if(Test-Path -LiteralPath $path){
        Write-Atomic (Join-Path $script:LauncherData ('path-backups\'+[Guid]::NewGuid().ToString('N')+'.json')) ([IO.File]::ReadAllText($path))
    }
    Write-Atomic $path ($data|ConvertTo-Json)
    Initialize-LauncherPaths
}

Initialize-LauncherPaths
