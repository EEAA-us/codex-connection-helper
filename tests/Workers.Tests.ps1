param([string]$ReportPath)
$ErrorActionPreference='Stop'
$source=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('CodexLauncher-Workers-'+[Guid]::NewGuid().ToString('N'))
$profileDir=Join-Path $fixture 'profile';$appDir=Join-Path $fixture 'appdata';$localDir=Join-Path $fixture 'localappdata';$dataHome=Join-Path $fixture 'codex-home';$uiDir=Join-Path $fixture 'codex-ui'
New-Item -ItemType Directory -Path $profileDir,$appDir,$localDir,$dataHome,$uiDir -Force|Out-Null
# Isolate before importing any production code, including initialization in the worker.
$env:USERPROFILE=$profileDir;$env:APPDATA=$appDir;$env:LOCALAPPDATA=$localDir;$env:CODEX_HOME=$dataHome;$env:CODEX_ELECTRON_USER_DATA_PATH=$uiDir
$env:OPENAI_API_KEY=$null;$env:CODEX_API_KEY=$null;$env:OPENAI_BASE_URL=$null
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'Launcher.ps1'),[ref]$tokens,[ref]$errors)
if($errors){throw 'Launcher parse failed'}
# Execute the exact production AddScript, rather than a substitute result worker.
$scripts=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -match 'param\(' -and $node.Value -match 'Start-ThirdParty'},$true))
if($scripts.Count -ne 1){throw 'Expected one production API worker'}
$workerSource=$scripts[0].Value
$workerAst=[Management.Automation.Language.Parser]::ParseInput($workerSource,[ref]$tokens,[ref]$errors)
if($errors){throw 'API worker parse failed'}
$constantNames=@('home','pid','psversiontable','pshome','shellid','psculture','psuiculture','executioncontext','host','true','false','null')
foreach($node in $workerAst.FindAll({param($n) $n -is [Management.Automation.Language.ParameterAst]},$true)){
    if($node.Name.VariablePath.UserPath.ToLowerInvariant() -in $constantNames){throw 'Worker parameter conflicts with an automatic variable'}
}
$copy=Join-Path $fixture '软件 中文 空格';New-Item -ItemType Directory -Path $copy|Out-Null
Get-ChildItem -LiteralPath $source -File -Filter '*.ps1'|ForEach-Object{Copy-Item -LiteralPath $_.FullName -Destination $copy}
$corePath=Join-Path $copy 'Launcher.Core.ps1'
$testStub=@'
function Start-ThirdParty {
    param($BaseUrl,$Model,$Key,$Profile)
    if($script:OfficialHome -cne $env:CODEX_HOME -or $script:OfficialUi -cne $env:CODEX_ELECTRON_USER_DATA_PATH -or $script:LauncherData -cne (Join-Path $env:LOCALAPPDATA 'CodexLauncherSafe')){throw 'Worker data arguments lost'}
    if($Profile.name -eq 'failure-case'){throw 'Synthetic launch failure'}
    if($Profile.name -eq 'handled-warning-case'){try{throw 'Synthetic handled advisory'}catch{}}
    $script:PluginSharingNotice='Synthetic sharing notice';return 4242
}
function Get-SwitchState {return [pscustomobject]@{image_warning='Synthetic image warning'}}
'@
[IO.File]::AppendAllText($corePath,"`r`n"+$testStub,[Text.UTF8Encoding]::new($true))
foreach($case in @('success-case','handled-warning-case','failure-case')){
    $worker=[PowerShell]::Create()
    try{
        $taskProfile=@{name=$case;base_url='https://api.example.test/v1';model='synthetic-model'}|ConvertTo-Json -Compress
        [void]$worker.AddScript($workerSource).AddArgument($copy).AddArgument((Join-Path $localDir 'CodexLauncherSafe')).AddArgument($dataHome).AddArgument($uiDir).AddArgument($taskProfile)
        $async=$worker.BeginInvoke();$result=@($worker.EndInvoke($async))
        if($result.Count -ne 1 -or -not $result[0].PSObject.Properties['error']){throw 'Production worker did not return a valid result'}
        if($case -ne 'failure-case'){
            if($result[0].error -or $result[0].pid -ne 4242 -or $result[0].sharing -ne 'Synthetic sharing notice' -or $result[0].image_warning -ne 'Synthetic image warning'){throw 'Worker success result contract lost'}
        }elseif($result[0].error -ne 'Synthetic launch failure'){throw 'Worker failure result contract lost'}
    }finally{$worker.Dispose()}
}
$finishAst=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Finish-ApiLaunch'},$true)[0]
. ([scriptblock]::Create($finishAst.Extent.Text))
function Set-Busy($Value){$script:Busy=[bool]$Value}
function Show-Failure($Message){$script:WorkerFailure=$Message}
function Update-ModeBadge {}
function Set-Status($Message,[switch]$ErrorState) {}
function Show-ResultToast($Kind,$Title,$Message){$script:LaunchToastKind=$Kind;$script:LaunchToastTitle=$Title;$script:LaunchToastMessage=$Message}
$runtimeStatus=[pscustomobject]@{Text=''};$appliedConnection=[pscustomobject]@{Text=''}
foreach($case in @('success-case','handled-warning-case','failure-case')){
    $worker=[PowerShell]::Create();$script:WorkerFailure='';$script:Busy=$true
    $taskProfile=@{name=$case;base_url='https://api.example.test/v1';model='synthetic-model'}|ConvertTo-Json -Compress
    [void]$worker.AddScript($workerSource).AddArgument($copy).AddArgument((Join-Path $localDir 'CodexLauncherSafe')).AddArgument($dataHome).AddArgument($uiDir).AddArgument($taskProfile)
    $async=$worker.BeginInvoke();if(-not $async.AsyncWaitHandle.WaitOne(10000)){$worker.Stop();$worker.Dispose();throw 'Worker exceeded test deadline'}
    $timer=[pscustomobject]@{};$timer|Add-Member ScriptMethod Stop {}
    $script:LaunchRequest=[pscustomobject]@{Worker=$worker;Async=$async;Timer=$timer;ProfileName=$case}
    Finish-ApiLaunch
    if($script:Busy -or $script:LaunchRequest){throw 'Production finish left launch busy'}
    if($case -eq 'failure-case'){
        if($script:WorkerFailure -ne 'Synthetic launch failure'){throw 'Specific handled failure was replaced by generic error'}
    }elseif($script:WorkerFailure -or $appliedConnection.Text -ne ('API / '+$case)){throw 'A valid success result was blocked by worker error history'}
    elseif($script:LaunchToastKind -ne 'notice' -or $script:LaunchToastTitle -ne '启动检查有提示' -or $script:LaunchToastMessage -notmatch 'Synthetic sharing notice' -or $script:LaunchToastMessage -notmatch 'Synthetic image warning'){throw 'Optional image warning was shown as launch failure or overwrote plugin feedback'}
}
$script:LauncherData=Join-Path $localDir 'CodexLauncherSafe'
. (Join-Path $source 'Launcher.Core.ps1')
foreach($kind in @('timeout','exit')){
    $exception=[TimeoutException]::new('Synthetic private native text');if($kind -eq 'exit'){$exception=[IO.IOException]::new('Synthetic private native text')}
    $failure=[Management.Automation.ErrorRecord]::new($exception,'SyntheticFailure',[Management.Automation.ErrorCategory]::NotSpecified,$null)
    $message=Get-CompatibilityFailureMessage $failure
    if($message -match 'Synthetic private native text' -or $message -notmatch '超时|提前退出'){throw 'Diagnostic failure lost classification or exposed raw payload'}
}
$script:PluginSourceStatus='pass';$script:ConfirmedLocalPlugins=@('design-partner');$script:PluginSharingNotice='Synthetic local installation confirmed'
Save-PluginSharingResult
if((Get-LastPluginSharingSummary) -notmatch '已确认 1 个' -or (Get-LastPluginSharingSummary) -match 'design-partner' -or (Get-LastPluginSharingDetail) -notmatch 'design-partner'){throw 'Sharing summary did not use count or details lost the actual plugin name'}
$many=@(1..25|ForEach-Object{'synthetic-plugin-'+$_+'-'+('a'*40)})
$script:ConfirmedLocalPlugins=$many;$script:UnconfirmedLocalPlugins=$many;Save-PluginSharingResult
$short=Get-PluginSharingNotice $many $many
if($short.Length -gt 150 -or $short -notmatch '已确认 25 个' -or $short -notmatch '25 个插件尚未确认' -or $short -match 'synthetic-plugin'){throw 'Many plugins overflowed the toast or hardcoded a plugin name'}
foreach($name in $many){if(-not(Get-LastPluginSharingDetail).Contains($name)){throw 'Full list was lost from sharing details'}}
if((Get-PluginSharingNotice @() @()) -or (Get-PluginSharingNotice $null $null)){throw 'Empty result was shown as a confirmed plugin'}
$script:UnconfirmedLocalPlugins=@()
$script:PluginSourceStatus='unobserved';$script:ConfirmedLocalPlugins=@();Save-PluginSharingResult
if((Get-LastPluginSharingSummary) -notmatch '未完成.*没有确认共享'){throw 'Missing discovery was reported as shared'}
$moduleAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'Launcher.CompatibilityUI.ps1'),[ref]$tokens,[ref]$errors)
$compatFinish=$moduleAst.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Finish-CompatibilityRequest'},$true)[0]
. ([scriptblock]::Create($compatFinish.Extent.Text))
function Show-ResultToast($Kind,$Title,$Message){$script:TestToastKind=$Kind;$script:TestToastTitle=$Title}
$compatibilityDetail=[pscustomobject]@{Text=''};$compatibilitySummary=[pscustomobject]@{Text=''};$compatibilityCancel=[pscustomobject]@{Visibility='Visible'}
$compatibilityRepairPanel=[pscustomobject]@{Visibility='Collapsed'};$compatibilityRepairChoice=[pscustomobject]@{Items=[Collections.ArrayList]::new()}
foreach($case in @('partial','complete')){
    $payload=@{account=@{type='apiKey'};plugins=@{query_status='unobserved'};skills=@{data=@()};mcp=@{data=@()};apps=@{apps=@()}}
    if($case -eq 'complete'){$payload.plugins=@{marketplaces=@()}}
    $worker=[PowerShell]::Create();[void]$worker.AddScript('param($json) $json').AddArgument(($payload|ConvertTo-Json -Depth 8 -Compress));$async=$worker.BeginInvoke()
    if(-not $async.AsyncWaitHandle.WaitOne(10000)){throw 'Synthetic query worker exceeded deadline'}
    $timer=[pscustomobject]@{};$timer|Add-Member ScriptMethod Stop {}
    $probe=[pscustomobject]@{};$probe|Add-Member ScriptMethod Dispose {}
    $identity=[pscustomobject]@{mode='api';home=$script:OfficialHome;ui=$script:OfficialUi;cwd=$fixture;observed_at=[DateTime]::UtcNow.ToString('o')}
    $script:CompatibilityRequest=[pscustomobject]@{Worker=$worker;Async=$async;Timer=$timer;Probe=$probe;Identity=$identity;Repair=$false}
    $script:Busy=$true;Finish-CompatibilityRequest
    if($script:Busy -or $script:CompatibilityRequest -or $script:TestToastKind -ne 'notice'){throw 'Compatibility finish left busy or reported sharing success'}
    if($case -eq 'partial' -and $script:TestToastTitle -ne '部分检查未完成'){throw 'Partial inventory was reported as a complete check'}
    if($case -eq 'complete' -and $script:TestToastTitle -ne '插件清单已读取'){throw 'Complete inventory was not distinguished from invocation'}
}
# Retry from an active API must discover sources from the original official baseline.
function Get-DesktopExe {return (Join-Path $script:OfficialUi 'ChatGPT.exe')}
function Assert-DesktopClosed {}
function Start-HttpCompatibility {
    $io=[pscustomobject]@{};foreach($method in @('WriteLine','Flush','Close')){$io|Add-Member ScriptMethod $method {}}
    $process=[pscustomobject]@{StandardInput=$io};$process|Add-Member ScriptMethod Dispose {}
    return [pscustomobject]@{url='http://127.0.0.1:1/v1';token='synthetic-bridge-token';process=$process}
}
function Start-Desktop {return 4242}
function Invoke-PluginInventory {
    param($Engine,$Repair='')
    $kind=(Get-Content (Join-Path $script:OfficialHome 'auth.json') -Raw|ConvertFrom-Json).auth_mode
    if($kind -ne 'chatgpt'){throw 'Source queried from API instead of original official connection'}
    $script:OfficialSourceObserved=$true
    return [pscustomobject]@{version=2;identity=[pscustomobject]@{native_auth_status='pass';mode='official';home=$script:OfficialHome;ui=$script:OfficialUi;cwd=$source};plugins_status='pass';skills_status='pass';plugins=@();skills=@()}
}
[IO.File]::WriteAllText((Join-Path $script:OfficialHome 'config.toml'),'model_provider = "openai"')
[IO.File]::WriteAllText((Join-Path $script:OfficialHome 'auth.json'),'{"auth_mode":"chatgpt","synthetic":"official"}')
$retryProfile=New-ApiProfile 'retry';$retryProfile.base_url='https://api.example.test/v1';$retryProfile.key_url=$retryProfile.base_url;$retryProfile.model='synthetic-model';$retryProfile.image_mode='off';$retryProfile=Complete-ApiProfile $retryProfile 'synthetic-not-real-key'
Set-SharedApi 'http://127.0.0.1:1/v1' 'synthetic-model' 'synthetic-not-real-key' '' $retryProfile
if(-not(Get-SwitchState).active -or (Get-Content (Join-Path $script:OfficialHome 'auth.json') -Raw|ConvertFrom-Json).auth_mode -ne 'apikey'){throw 'Retry test did not start in active API mode'}
$script:OfficialSourceObserved=$false
$retryPid=Start-ThirdParty $retryProfile.base_url $retryProfile.model '' $retryProfile
if(-not $script:OfficialSourceObserved -or $retryPid -ne 4242 -or -not(Get-SwitchState).active){throw 'API retry lost official discovery or final API state'}
$sharing=Get-Content (Join-Path $script:LauncherData 'sharing-status.json') -Raw -Encoding UTF8|ConvertFrom-Json
if($sharing.source_mode -ne 'official'){throw 'Source identity was not retained in diagnostic record'}
Restore-SharedOfficial -Force
if((Get-Content (Join-Path $script:OfficialHome 'auth.json') -Raw|ConvertFrom-Json).auth_mode -ne 'chatgpt'){throw 'Retry replaced original official recovery baseline'}
$report=[ordered]@{status='pass';powershell=$PSVersionTable.PSVersion.ToString();fixture=$fixture;exactProductionWorkerExecuted=$true;realCoreImported=$true;parameterBinding='pass';pathsForwarded='pass';successResult='pass';failureResult='pass';apiRetryOfficialSource='pass';realDesktopLaunch='unobserved';realApiRequest='unobserved'}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
Write-Output 'Worker checks passed: exact production script, real import, isolated paths, success and failure.'
