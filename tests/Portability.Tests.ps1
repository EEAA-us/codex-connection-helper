param([switch]$UI)
$ErrorActionPreference='Stop'
$source=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('CodexLauncher-Test-'+[Guid]::NewGuid().ToString('N'))
$before=@{}
foreach($name in @('LOCALAPPDATA','APPDATA','USERPROFILE','CODEX_HOME','CODEX_ELECTRON_USER_DATA_PATH','OPENAI_API_KEY','CODEX_API_KEY','OPENAI_BASE_URL')){$before[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
function Expect-Failure([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};if(-not $failed){throw 'Expected operation to fail'}}
try{
    $env:LOCALAPPDATA=Join-Path $fixture 'Local';$env:APPDATA=Join-Path $fixture 'Roaming';$env:USERPROFILE=Join-Path $fixture '用户 中文'
    $env:CODEX_HOME=$null;$env:CODEX_ELECTRON_USER_DATA_PATH=$null
    $env:OPENAI_API_KEY=$null;$env:CODEX_API_KEY=$null;$env:OPENAI_BASE_URL=$null
    . (Join-Path $source 'Launcher.Core.ps1')
    Add-Type -Path (Join-Path $source 'DesktopActivation.cs')
    $script:TestInstall=Join-Path $fixture '另一盘的安装 模拟\OpenAI.Codex_v1'
    $script:TestProcesses=@()
    function Get-AppxPackage {param($Name,$ErrorAction) [pscustomobject]@{InstallLocation=$script:TestInstall;PackageFamilyName='OpenAI.Codex_Synthetic'}}
    function Get-CimInstance {param($ClassName,$ErrorAction) $script:TestProcesses}
    function New-FakeDesktop([string]$Directory){
        $resources=Join-Path $Directory 'resources';New-Item -ItemType Directory -Path $resources -Force|Out-Null
        foreach($name in @('app.asar','codex.exe')){[IO.File]::WriteAllText((Join-Path $resources $name),'synthetic')}
        $exe=Join-Path $Directory 'ChatGPT.exe';[IO.File]::WriteAllText($exe,'synthetic');return $exe
    }
    $registered=New-FakeDesktop (Join-Path $script:TestInstall 'app')
    [IO.File]::WriteAllText((Join-Path $script:TestInstall 'AppxManifest.xml'),'<Package><Applications><Application Id="App" Executable="app/ChatGPT.exe"/></Applications></Package>')
    if((Get-DesktopExe) -ne $registered){throw 'Registered location failed'}
    $testHomePath=Join-Path $env:USERPROFILE '.codex';$testUiPath=Join-Path $env:APPDATA 'Codex'
    $identity=Get-RegisteredDesktopIdentity $registered
    if($identity.app_id -ne 'OpenAI.Codex_Synthetic!App'){throw 'Official package identity was not derived from the manifest'}
    $plan=Get-DesktopLaunchPlan $registered $testHomePath $testUiPath
    $persistentEnvironment=$false
    foreach($variable in @('OPENAI_API_KEY','CODEX_API_KEY','OPENAI_BASE_URL','CODEX_HOME','CODEX_ELECTRON_USER_DATA_PATH')){foreach($scope in @('User','Machine')){if([Environment]::GetEnvironmentVariable($variable,$scope)){$persistentEnvironment=$true}}}
    if(-not $persistentEnvironment -and $plan.kind -ne 'registered'){throw 'Default installation did not use the official activation contract'}
    if($persistentEnvironment -and $plan.kind -ne 'process'){throw 'Persistent environment was silently ignored'}
    if((Get-DesktopLaunchPlan $registered (Join-Path $fixture 'custom-home') $testUiPath).kind -ne 'process'){throw 'Custom home was lost through shell activation'}
    if((Get-DesktopLaunchPlan $registered $testHomePath (Join-Path $fixture 'custom-ui')).kind -ne 'process'){throw 'Custom UI directory was lost through shell activation'}
    $env:OPENAI_API_KEY='synthetic-key'
    if((Get-DesktopLaunchPlan $registered $testHomePath $testUiPath).kind -ne 'process'){throw 'Credential environment bypassed sanitized process launch'}
    $env:OPENAI_API_KEY=$null
    if((Convert-LauncherPath 'D:/Apps/Codex/' 'test') -ne 'D:\Apps\Codex'){throw 'D drive path normalization failed'}
    foreach($invalid in @('relative\Codex','C:relative','\Users\Codex','\\server\share','C:\bad%UNDEFINED_CODEX_TEST%','C:\bad"quote')){Expect-Failure {Convert-LauncherPath $invalid 'test'}}
    $fresh=Get-ProfileStore
    if($fresh.profiles[0].base_url -or $fresh.profiles[0].encrypted_key -or $fresh.profiles[0].name -ne '我的 API'){throw 'Fresh profile leaked provider defaults'}
    $testHomePath=Join-Path $env:USERPROFILE '.codex';$testUiPath=Join-Path $env:APPDATA 'Codex'
    New-Item -ItemType Directory -Path $testHomePath,$testUiPath -Force|Out-Null
    Write-Atomic (Join-Path $testHomePath 'config.toml') 'model="synthetic-model"'
    $script:TestInstall=Join-Path $fixture '另一盘的安装 模拟\OpenAI.Codex_v2'
    $updated=New-FakeDesktop (Join-Path $script:TestInstall 'app')
    [IO.File]::WriteAllText((Join-Path $script:TestInstall 'AppxManifest.xml'),'<Package><Applications><Application Id="UpdatedApp" Executable="app/ChatGPT.exe"/></Applications></Package>')
    if((Get-DesktopExe) -ne $updated){throw 'Package upgrade path was cached'}
    if((Get-RegisteredDesktopIdentity $updated).app_id -ne 'OpenAI.Codex_Synthetic!UpdatedApp'){throw 'Package application identity was cached across upgrades'}
    $manual=New-FakeDesktop (Join-Path $fixture '便携安装 空格')
    # Production fallback discovery with isolated registry/process providers.
    $registeredInstall=$script:TestInstall
    $script:TestInstall=Join-Path $fixture 'unregistered'
    function Get-Item {param($LiteralPath,$ErrorAction) return $null}
    function Get-ChildItem {param($LiteralPath,$ErrorAction) return @()}
    try{
        $script:TestProcesses=@([pscustomobject]@{Name='ChatGPT.exe';ExecutablePath=$manual},[pscustomobject]@{Name='Codex.exe';ExecutablePath=(Join-Path (Split-Path $manual) 'resources\codex.exe')})
        if((Get-DesktopExe) -ne $manual){throw 'Running complete installation not detected or CLI accepted'}
        $second=New-FakeDesktop (Join-Path $fixture '第二安装')
        $script:TestProcesses+=@([pscustomobject]@{Name='ChatGPT.exe';ExecutablePath=$second})
        Expect-Failure {Get-DesktopExe}
        $script:TestProcesses=@()
        $script:RegistryExe=$manual
        function Get-Item {param($LiteralPath,$ErrorAction)
            if($LiteralPath -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\Codex.exe'){
                $key=[pscustomobject]@{};$key|Add-Member ScriptMethod GetValue {param($Name) return ('"'+$script:RegistryExe+'"')};return $key
            };return $null
        }
        if((Get-DesktopExe) -ne $manual){throw 'App Paths installation not detected'}
        function Get-Item {param($LiteralPath,$ErrorAction) return $null}
        function Get-ChildItem {param($LiteralPath,$ErrorAction)
            if($LiteralPath -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'){
                $key=[pscustomobject]@{};$key|Add-Member ScriptMethod GetValue {param($Name) switch($Name){'DisplayName'{'Codex'}'DisplayIcon'{return ('"'+$script:RegistryExe+'",0')}}};return $key
            };return @()
        }
        if((Get-DesktopExe) -ne $manual){throw 'Uninstall registration not detected'}
        $script:RegistryExe=Join-Path (Split-Path $manual) 'resources\codex.exe'
        Expect-Failure {Get-DesktopExe}
    }finally{
        Remove-Item Function:Get-Item,Function:Get-ChildItem
        $script:TestProcesses=@();$script:TestInstall=$registeredInstall
    }
    $manifestDesktop=New-FakeDesktop (Join-Path $script:TestInstall 'changed-layout')
    [IO.File]::WriteAllText((Join-Path $script:TestInstall 'AppxManifest.xml'),'<Package><Applications><Application Id="UpdatedApp" Executable="changed-layout/ChatGPT.exe"/></Applications></Package>')
    if((Get-DesktopExe) -ne $manifestDesktop){throw 'Manifest-driven discovery still assumes app directory'}
    $pathFile=Join-Path $script:LauncherData 'paths.json'
    Write-Atomic $pathFile '{broken';Initialize-LauncherPaths
    $savedBrokenPaths=[IO.File]::ReadAllText($pathFile);$savedOverride=$script:DesktopOverride
    if(-not $script:PathSettingsError){throw 'Corrupt path settings were not reported before automatic recovery discovery'}
    if((Get-OfficialDesktopExe) -ne $manifestDesktop){throw 'Official recovery did not fall back to a uniquely discovered installation'}
    if(-not $script:PathSettingsError -or $script:DesktopOverride -ne $savedOverride -or [IO.File]::ReadAllText($pathFile) -cne $savedBrokenPaths){throw 'Automatic recovery discovery changed or hid saved path settings'}
    $ambiguousInstall=Join-Path $fixture '无已登记安装';$script:TestInstall=$ambiguousInstall
    $secondCandidate=New-FakeDesktop (Join-Path $fixture '自动发现候选二')
    $script:TestProcesses=@([pscustomobject]@{Name='ChatGPT.exe';ExecutablePath=$manual},[pscustomobject]@{Name='ChatGPT.exe';ExecutablePath=$secondCandidate})
    $ambiguity='';try{$null=Get-OfficialDesktopExe}catch{$ambiguity=$_.Exception.Message}
    if($ambiguity -notmatch '多个完整 Codex 安装'){throw 'Automatic recovery discovery silently selected among multiple valid installations'}
    if(-not $script:PathSettingsError -or [IO.File]::ReadAllText($pathFile) -cne $savedBrokenPaths){throw 'Ambiguous recovery discovery changed or hid saved path settings'}
    $script:TestInstall=$registeredInstall;$script:TestProcesses=@()
    if((Get-DesktopLaunchPlan $manual $testHomePath $testUiPath).kind -ne 'process'){throw 'Unregistered manual installation used the wrong package identity'}
    Save-PathPreferences $manual $testHomePath $testUiPath
    if((Get-DesktopExe) -ne $manual){throw 'Manual desktop selection failed'}
    $launch=New-LaunchInfo $manual $script:OfficialHome $script:OfficialUi
    if($launch.EnvironmentVariables['CODEX_HOME'] -ne $testHomePath -or $launch.EnvironmentVariables['CODEX_ELECTRON_USER_DATA_PATH'] -ne $testUiPath -or $launch.UseShellExecute){throw 'Child path propagation failed'}
    $script:DesktopOverride=Join-Path $fixture 'missing\ChatGPT.exe'
    Expect-Failure {Get-DesktopExe};Initialize-LauncherPaths
    Expect-Failure {Save-PathPreferences (Join-Path (Split-Path $manual) 'resources\codex.exe') $testHomePath $testUiPath}
    $empty=Join-Path $fixture '空目录';New-Item -ItemType Directory -Path $empty|Out-Null
    Expect-Failure {Save-PathPreferences $manual $empty $testUiPath}
    Expect-Failure {Save-PathPreferences $manual $testHomePath (Join-Path $fixture 'missing-ui')}
    Expect-Failure {Save-PathPreferences $manual $testHomePath 'C:\'}
    $env:CODEX_ELECTRON_USER_DATA_PATH='C:\';Initialize-LauncherPaths
    Expect-Failure {Assert-ResolvedDataPaths};Expect-Failure {Save-PathPreferences $manual $testHomePath $testUiPath}
    $env:CODEX_ELECTRON_USER_DATA_PATH=$null;Initialize-LauncherPaths
    $pathFile=Join-Path $script:LauncherData 'paths.json';$saved=[IO.File]::ReadAllText($pathFile)
    $alternateHome=Join-Path $fixture '运行时不可切换的数据';New-Item -ItemType Directory -Path $alternateHome|Out-Null
    Write-Atomic (Join-Path $alternateHome 'config.toml') 'model="synthetic-alternate"'
    $script:TestProcesses=@([pscustomobject]@{Name='codex.exe';ExecutablePath='synthetic'})
    Expect-Failure {Save-PathPreferences '' $alternateHome ''}
    if([IO.File]::ReadAllText($pathFile) -ne $saved){throw 'Running process changed path settings'}
    Use-AutomaticLauncherPaths
    if($script:OfficialHome -ne $testHomePath -or $script:OfficialUi -ne $testUiPath -or (Get-PathPreferences).desktop_exe){throw 'Automatic discovery changed data while running'}
    $script:TestProcesses=@([pscustomobject]@{Name='ChatGPT.exe';ExecutablePath=$manual})
    Expect-Failure {Save-PathPreferences '' $alternateHome ''};$script:TestProcesses=@()
    $missingUi=Join-Path $fixture '未创建桌面界面目录';$script:OfficialUi=$missingUi
    Assert-PluginCheckPaths
    if(Test-Path -LiteralPath $missingUi){throw 'Read-only plugin preflight created an interface directory'}
    Initialize-LauncherPaths
    $env:CODEX_ELECTRON_USER_DATA_PATH=$missingUi;Initialize-LauncherPaths
    Use-AutomaticLauncherPaths
    if($script:OfficialUi -ne $missingUi -or (Test-Path -LiteralPath $missingUi)){throw 'Automatic discovery changed or created overridden missing UI directory'}
    Assert-PluginCheckPaths
    $env:CODEX_ELECTRON_USER_DATA_PATH=$null;Initialize-LauncherPaths
    $otherHome=Join-Path $fixture '环境变量目录';New-Item -ItemType Directory -Path $otherHome|Out-Null
    Write-Atomic (Join-Path $otherHome 'config.toml') 'model="synthetic-model"'
    $env:CODEX_HOME=$otherHome;Initialize-LauncherPaths
    if($script:OfficialHome -ne $otherHome -or $script:HomePathSource -notmatch 'CODEX_HOME'){throw 'Environment precedence failed'}
    $env:CODEX_HOME='relative';Initialize-LauncherPaths
    Expect-Failure {Get-DesktopExe};Expect-Failure {Save-PathPreferences '' '' ''}
    $env:CODEX_HOME=$null;Initialize-LauncherPaths
    Write-Atomic $pathFile '{broken'
    Initialize-LauncherPaths
    if(-not $script:PathSettingsError){throw 'Invalid preferences silently accepted'}
    Save-PathPreferences $manual $testHomePath $testUiPath
    if($script:PathSettingsError -or -not(Test-Path (Join-Path $script:LauncherData 'path-backups'))){throw 'Corrupt preferences recovery failed'}
    $original='model="synthetic-model"';Write-Atomic (Join-Path $testHomePath 'config.toml') $original
    Write-Atomic (Join-Path $testHomePath 'auth.json') '{"auth_mode":"chatgpt","marker":"synthetic-official"}'
    Set-SharedApi 'https://provider.example.invalid/v1' 'synthetic-model' 'synthetic-api'
    $active=[IO.File]::ReadAllText($script:SwitchFile)
    Expect-Failure {Save-PathPreferences $manual $otherHome $testUiPath}
    if([IO.File]::ReadAllText($script:SwitchFile) -ne $active){throw 'Active recovery altered'}
    # A mistakenly chosen home may be repaired back to the bound home only.
    $script:OfficialHome=$otherHome
    Save-PathPreferences $manual $testHomePath $testUiPath
    Restore-SharedOfficial
    if([IO.File]::ReadAllText((Join-Path $testHomePath 'config.toml')).Trim() -ne $original){throw 'Recovery failed'}
    # A failure at the new desktop activation boundary must restore both assets.
    $taskAuthBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $testHomePath 'auth.json')))
    $script:ActivationReached=$false;$script:FailedBridgeStopped=$false
    function Start-HttpCompatibility {param($Url,$Key,$Cancellation) [pscustomobject]@{url='http://127.0.0.1:32123/v1';token=('a'*64)}}
    function Stop-HttpCompatibility {param($Bridge) $script:FailedBridgeStopped=$true}
    function Start-Desktop {param($Exe,$HomePath,$UiPath) $script:ActivationReached=$true;throw 'Synthetic activation failure'}
    Expect-Failure {Start-ThirdParty 'https://provider.example.invalid/v1' 'synthetic-model' 'synthetic-api'}
    if(-not $script:ActivationReached -or -not $script:FailedBridgeStopped -or (Get-SwitchState).active){throw 'Activation failure did not release the bridge and restore official state'}
    if([IO.File]::ReadAllText((Join-Path $testHomePath 'config.toml')).Trim() -ne $original -or [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $testHomePath 'auth.json'))) -cne $taskAuthBefore){throw 'Activation failure changed original configuration or credentials'}
    Save-PathPreferences $manual $otherHome $testUiPath
    if(Get-SwitchState){throw 'Inactive backup reused for a different home'}
    Set-SharedApi 'https://provider.example.invalid/v1' 'synthetic-model' 'synthetic-api'
    if(-not(Test-Path (Join-Path $script:LauncherData 'recovery-archives'))){throw 'Old recovery was not preserved'}
    Restore-SharedOfficial
    if($UI){
        Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml,System.Windows.Forms
        . (Join-Path $source 'Launcher.Dialogs.ps1')
        . (Join-Path $source 'Environment.ps1')
        $window=New-EnvironmentWindow;$window.Show();$window.UpdateLayout()
        if($window.Tag.resolvedPaths.Text -notmatch [regex]::Escape($otherHome)){throw 'Resolved path UI mismatch'}
        $window.Tag.homePath.Text=$empty
        $window.Tag.savePaths.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if(-not $window.IsVisible -or $window.Tag.Saved -or -not $window.Tag.pathError.Text){throw 'Invalid path UI did not remain editable'}
        $window.Tag.homePath.Text=$otherHome
        $window.Tag.savePaths.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if(-not $window.Tag.Saved -or $window.IsVisible){throw 'Path UI save failed'}
        $beforeAutomaticHome=$script:OfficialHome;$beforeAutomaticUi=$script:OfficialUi
        $window=New-EnvironmentWindow;$window.Show();$window.UpdateLayout()
        $window.Tag.autoPaths.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if(-not $window.Tag.Saved -or -not $window.IsVisible -or $window.Tag.pathError.Text -notmatch '无需再点保存'){throw 'Automatic detection still requires a second save or closes without feedback'}
        $window.Close();Initialize-LauncherPaths
        $window=New-EnvironmentWindow;$window.Show();$window.UpdateLayout()
        if($script:OfficialHome -ne $beforeAutomaticHome -or $script:OfficialUi -ne $beforeAutomaticUi -or $window.Tag.desktopPath.Text){throw 'Automatic settings did not persist across reopening or changed custom data'}
        $window.Close()
    }
    'PASS: clean defaults; manifest/App Paths/uninstall/running installation discovery; CLI rejection and ambiguous fallback; D/Unicode/spaces, environment priority, recovery binding and repair.'
}finally{
    foreach($name in $before.Keys){[Environment]::SetEnvironmentVariable($name,$before[$name],'Process')}
    # Only disposable synthetic files are created; CI/temp cleanup may remove this fixture.
}
