$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Launcher.Core.ps1')
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('CodexRecovery-'+[Guid]::NewGuid().ToString('N'))
$script:LauncherData=Join-Path $fixture '本机 空格';$script:OfficialHome=Join-Path $fixture '官方 数据';$script:SwitchFile=Join-Path $script:LauncherData 'shared-switch.json'
New-Item -ItemType Directory -Path $script:OfficialHome -Force|Out-Null
function Get-CimInstance {param($ClassName) return $script:TestProcesses}
$script:TestProcesses=@()
function Get-DesktopExe {if($script:PathSettingsError){throw $script:PathSettingsError};if($script:AllowOfficialDiscovery){return 'C:\synthetic\ChatGPT.exe'};throw 'Recovery must not require installation discovery'}
$script:DesktopOverride=''
$script:FixtureBlock="[mcp_servers.codex_launcher_images]`r`ncommand = `"fixture-image-only`"`r`nargs = []`r`nstartup_timeout_sec = 30`r`ntool_timeout_sec = 630`r`nrequired = false`r`n"
function Get-OptionalImageIntegrationPlan($Chat){return [pscustomobject]@{block=$script:FixtureBlock;path='';warning=''}}
function Check($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Must-Fail([scriptblock]$Action){$failed=$false;try{& $Action}catch{$failed=$true};Check $failed 'Expected guard rejection'}
$config=Join-Path $script:OfficialHome 'config.toml';$auth=Join-Path $script:OfficialHome 'auth.json'
$original="model = `"official-original`"`r`n[mcp_servers.user_figma]`r`ncommand = `"keep-existing`"`r`n# 保留用户配置`r`n"
$officialAuth=[Text.Encoding]::UTF8.GetBytes('{"auth_mode":"chatgpt","marker":"fixture-original"}')
function Apply {
    [IO.File]::WriteAllText($config,$original);[IO.File]::WriteAllBytes($auth,$officialAuth)
    Set-SharedApi 'http://127.0.0.1:4321/v1' 'gpt-6.1-sol' 'fixture-key'
}
Apply
$applied=[IO.File]::ReadAllText($config);[IO.File]::WriteAllText($config,$applied.Replace("`r`n","`n"))
Assert-ManagedConnection (Get-SwitchState)
Restore-OfficialOnly
Check ([IO.File]::ReadAllText($config).Replace("`r`n","`n") -ceq $original.Replace("`r`n","`n")) 'LF rewrite lost unrelated MCP text'
Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($auth)) -ceq [Convert]::ToBase64String($officialAuth)) 'Official auth bytes differ'
foreach($damage in @('changed-image','duplicate-image','complex-transport')){
    Apply;$applied=[IO.File]::ReadAllText($config)
    switch($damage){
        'changed-image' {$broken=$applied.Replace('tool_timeout_sec = 630','tool_timeout_sec = 631')}
        'duplicate-image' {$broken=$applied+$script:FixtureBlock}
        'complex-transport' {$broken=$applied.Replace('model = "gpt-6.1-sol"','model = { invalid = true }')}
    }
    [IO.File]::WriteAllText($config,$broken);$authBefore=(Get-FileHash -LiteralPath $auth).Hash
    Must-Fail {Restore-SharedOfficial}
    Check ([IO.File]::ReadAllText($config) -ceq $broken) 'Strict guard wrote broken config'
    Check ((Get-FileHash -LiteralPath $auth).Hash -ceq $authBefore) 'Strict guard changed auth'
    Restore-OfficialOnly -Force
    Check ([IO.File]::ReadAllText($config) -ceq $original) ('Emergency recovery did not restore baseline: '+$damage)
    Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($auth)) -ceq [Convert]::ToBase64String($officialAuth)) 'Emergency auth differs'
    Check (-not (Get-SwitchState).active) 'Recovered state remains active'
    $quarantine=Unprotect-LocalText ([IO.File]::ReadAllText((Join-Path $script:LastRecoveryDirectory 'config.encrypted')))
    Check ($quarantine -ceq ('backup:'+$broken)) 'Conflict config was not backed up exactly'
}
Apply
$applied=[IO.File]::ReadAllText($config)
$formatted="[ mcp_servers.codex_launcher_images ] # generated tool`nrequired=false`nargs = [ # keep order`n]`n# internal comment`ntool_timeout_sec=6_30`ncommand='fixture-image-only' # same command`nstartup_timeout_sec=30"
$rewritten=$applied.Replace($script:FixtureBlock,$formatted)
[IO.File]::WriteAllText($config,$rewritten)
Assert-ManagedConnection (Get-SwitchState)
Restore-SharedOfficial
Check ([IO.File]::ReadAllText($config) -ceq $original) 'Equivalent TOML formatting did not preserve unrelated MCP'
$expected="[mcp_servers.codex_launcher_images]`ncommand = `"C:\\工具 #目录\\powershell.exe`"`nargs = [`"-File`",`"C:\\工具 #目录\\ImageMcp.ps1`",`"-RuntimePath`",`"C:\\runtime.json`"]`nstartup_timeout_sec = 30`ntool_timeout_sec = 630`nrequired = false`n"
$equivalent="[mcp_servers.codex_launcher_images]`ncommand='C:\工具 #目录\powershell.exe' # literal hash stays`nstartup_timeout_sec=30`nrequired=false`ntool_timeout_sec=630`nargs = [`n'-File', # comment`n'C:\工具 #目录\ImageMcp.ps1',`n'-RuntimePath',`n'C:\runtime.json',`n]`n"
$prefix="# before managed section`n";$suffix="# keep trailing comment`n[mcp_servers.other]`ncommand='preserve'`n"
$synthetic=[pscustomobject]@{active=$true;image_mcp_block=$expected}
Check ((Remove-ManagedImageBlock ($prefix+$equivalent+$suffix) $synthetic) -ceq ($prefix+$suffix)) 'Multiline args/hash path or neighboring text lost'
Must-Fail {Remove-ManagedImageBlock ($prefix+$equivalent.Replace("'-RuntimePath'","'-Other'")+$suffix) $synthetic}
Apply
$applied=[IO.File]::ReadAllText($config);[IO.File]::WriteAllText($config,$applied.Replace($script:FixtureBlock,''))
Assert-ManagedConnection (Get-SwitchState)
Set-SharedApi 'http://127.0.0.1:4321/v1' 'gpt-6.1-sol' 'fixture-key'
Check ([IO.File]::ReadAllText($config).Contains($script:FixtureBlock)) 'Missing owned MCP was not rebuilt'
Check ((Get-SwitchState).image_warning -match '重新建立') 'Missing MCP repair was not reported'
Restore-SharedOfficial
Check ([IO.File]::ReadAllText($config) -ceq $original) 'Missing MCP repair changed official baseline'
Apply
$localPlugin="[plugins.`"figma@local`"]`nenabled = true`n"
[IO.File]::WriteAllText($config,[IO.File]::ReadAllText($config)+$localPlugin)
Restore-OfficialOnly -Force
Check ([IO.File]::ReadAllText($config) -ceq ($original+$localPlugin)) 'Normal official recovery dropped local plugin registration added during API mode'
$localMarket='[marketplaces.codex-launcher-local-design-partner]`nsource_type = "local"`nsource = ''\\?\C:\synthetic\portable-plugins\design-partner''`n'
Apply
[IO.File]::WriteAllText($config,[IO.File]::ReadAllText($config)+$localMarket)
Restore-OfficialOnly -Force
Check ([IO.File]::ReadAllText($config) -ceq ($original+$localMarket)) 'Normal official recovery dropped local CLI marketplace registration added during API mode'
foreach($change in @('unknown-field','exact-prefix-extra-field','changed-command','changed-args','duplicate-key','partial-block')){
    Apply;$applied=[IO.File]::ReadAllText($config)
    switch($change){
        'unknown-field' {$block=$formatted+"`nuser_setting=true`n"}
        'exact-prefix-extra-field' {$block=$script:FixtureBlock+"user_setting=true`n"}
        'changed-command' {$block=$formatted.Replace('fixture-image-only','other-command')}
        'changed-args' {$block=$formatted.Replace('args = [ # keep order',"args = [ 'unexpected', # keep order")}
        'duplicate-key' {$block=$formatted+"`nrequired=false`n"}
        'partial-block' {$block=$formatted.Replace('required=false','')}
    }
    $broken=$applied.Replace($script:FixtureBlock,$block);[IO.File]::WriteAllText($config,$broken)
    $authBefore=(Get-FileHash -LiteralPath $auth).Hash
    Must-Fail {Set-SharedApi 'http://127.0.0.1:4321/v1' 'gpt-6.1-sol' 'fixture-key'}
    Check ([IO.File]::ReadAllText($config) -ceq $broken -and (Get-FileHash -LiteralPath $auth).Hash -ceq $authBefore) 'Semantic conflict changed config or login'
    Restore-OfficialOnly -Force
    Check ([IO.File]::ReadAllText($config) -ceq $original) 'Semantic conflict could not recover official baseline'
}
# A storage layer that silently writes different content must never produce ready.
Apply;Restore-SharedOfficial
$realWrite=${function:Write-Atomic}
function Write-Atomic([string]$Path,[string]$Content){if($Path -eq $config){$Content=$Content.Replace('tool_timeout_sec = 630','tool_timeout_sec = 631')};& $realWrite $Path $Content}
try{
    Must-Fail {Set-SharedApi 'http://127.0.0.1:4321/v1' 'gpt-6.1-sol' 'fixture-key'}
    Check ((Get-SwitchState).phase -eq 'switching') 'Readback failure incorrectly committed ready'
}finally{Set-Item Function:Write-Atomic $realWrite}
Restore-OfficialOnly -Force
Check ([IO.File]::ReadAllText($config) -ceq $original) 'Readback failure lost official recovery'
Apply;Restore-SharedOfficial
$script:InjectedAuthPath=$auth
function Write-Atomic([string]$Path,[string]$Content){if($Path -eq $script:InjectedAuthPath){$Content=$Content.Replace('fixture-key','injected-key')};& $realWrite $Path $Content}
try{
    Must-Fail {Set-SharedApi 'http://127.0.0.1:4321/v1' 'gpt-6.1-sol' 'fixture-key'}
    Check ((Get-SwitchState).phase -eq 'switching') 'Login readback failure incorrectly committed ready'
}finally{Set-Item Function:Write-Atomic $realWrite}
Restore-OfficialOnly -Force
Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($auth)) -ceq [Convert]::ToBase64String($officialAuth)) 'Login readback failure lost official credentials'
Apply
function Write-Atomic([string]$Path,[string]$Content){if($Path -eq $config){$Content+=' # injected storage corruption'};& $realWrite $Path $Content}
try{
    Must-Fail {Restore-OfficialOnly -Force}
    Check ((Get-SwitchState).active -and (Get-SwitchState).phase -eq 'restoring') 'Failed recovery incorrectly marked inactive'
    Must-Fail {Assert-ManagedConnection (Get-SwitchState)}
}finally{Set-Item Function:Write-Atomic $realWrite}
Restore-OfficialOnly -Force
Check (-not (Get-SwitchState).active -and (Get-SwitchState).phase -eq 'ready') 'Interrupted recovery could not finish'
Check ([IO.File]::ReadAllText($config).StartsWith($original)) 'Recovery retry lost original settings'
Apply;$legacy=Get-SwitchState;$legacy.PSObject.Properties.Remove('official_config_encrypted');Save-SwitchState $legacy
[IO.File]::WriteAllText($config,[IO.File]::ReadAllText($config).Replace('tool_timeout_sec = 630','tool_timeout_sec = 631'))
Restore-OfficialOnly -Force
Check ([IO.File]::ReadAllText($config) -ceq $original) 'Legacy official checkpoint fallback failed'
Apply;$state=Get-SwitchState;$state.auth_encrypted=Protect-LocalText 'backup:invalid-base64';Save-SwitchState $state
$state.official_config_encrypted=Protect-LocalText 'backup:official baseline';Save-OfficialRecoveryCopy $state
$configBefore=(Get-FileHash -LiteralPath $config).Hash;$authBefore=(Get-FileHash -LiteralPath $auth).Hash
Must-Fail {Restore-OfficialOnly -Force}
Check ((Get-FileHash -LiteralPath $config).Hash -ceq $configBefore -and (Get-FileHash -LiteralPath $auth).Hash -ceq $authBefore) 'Both bad backups caused partial writes'
Check ($script:CanResetOfficial) 'Both unusable backups did not enable the confirmed reset route'
$state.active=$false;Save-SwitchState $state;Apply
[IO.File]::Delete($config);Restore-OfficialOnly -Force
Check ([IO.File]::ReadAllText($config) -ceq $original) 'Missing config lost the original MCP baseline'
# The independent copy must survive either a truncated or missing main journal.
foreach($journalDamage in @('truncated','missing')){
    Apply
    if($journalDamage -eq 'truncated'){[IO.File]::WriteAllText($script:SwitchFile,'{"version":',[Text.UTF8Encoding]::new($false))}
    else{[IO.File]::Delete($script:SwitchFile)}
    Restore-OfficialOnly -Force
    Check ([IO.File]::ReadAllText($config) -ceq $original -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($auth)) -ceq [Convert]::ToBase64String($officialAuth)) ('Independent official copy did not recover '+$journalDamage+' journal')
    Check (-not (Get-SwitchState).active) ('Recovered '+$journalDamage+' journal remains active')
}

# Confirmed reset is the only route that clears API credentials, and it preserves exact bytes.
Apply
$sessions=Join-Path $script:OfficialHome 'sessions';New-Item -ItemType Directory -Path $sessions -Force|Out-Null
$sessionFile=Join-Path $sessions 'fixture-session.json';[IO.File]::WriteAllText($sessionFile,'{"conversation":"synthetic-preserved"}')
$resetConfigBefore=[IO.File]::ReadAllText($config);$resetAuthBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes($auth));$sessionHashBefore=(Get-FileHash -LiteralPath $sessionFile -Algorithm SHA256).Hash
$recoveryCountBefore=@(Get-ChildItem -LiteralPath (Join-Path $script:LauncherData 'recovery-checkpoints') -Directory -ErrorAction SilentlyContinue).Count
Must-Fail {Reset-OfficialConnection}
Check ([IO.File]::ReadAllText($config) -ceq $resetConfigBefore -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($auth)) -ceq $resetAuthBefore) 'Unconfirmed reset changed live config or auth'
Check (@(Get-ChildItem -LiteralPath (Join-Path $script:LauncherData 'recovery-checkpoints') -Directory -ErrorAction SilentlyContinue).Count -eq $recoveryCountBefore) 'Unconfirmed reset wrote a recovery checkpoint'
Reset-OfficialConnection -Confirmed
$resetConfig="model_provider = `"openai`"`nforced_login_method = `"chatgpt`"`ncli_auth_credentials_store = `"file`"`n"
Check ([IO.File]::ReadAllText($config) -ceq $resetConfig -and -not(Test-Path -LiteralPath $auth)) 'Confirmed reset did not clear API login and set official login parameters'
$savedConfig=Unprotect-LocalText ([IO.File]::ReadAllText((Join-Path $script:LastRecoveryDirectory 'config.encrypted')))
$savedAuth=Unprotect-LocalText ([IO.File]::ReadAllText((Join-Path $script:LastRecoveryDirectory 'auth.encrypted')))
Check ($savedConfig -ceq ('backup:'+$resetConfigBefore) -and $savedAuth -ceq ('backup:'+$resetAuthBefore)) 'Confirmed reset backup did not preserve exact config/auth bytes'
Check ((Get-FileHash -LiteralPath $sessionFile -Algorithm SHA256).Hash -ceq $sessionHashBefore) 'Confirmed reset changed session file'

# API credentials inside either official snapshot must never be treated as an official login backup.
foreach($badBackupAuth in @(
    '{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic-invalid-key"}',
    '{"auth_mode":"chatgpt","OPENAI_API_KEY":"synthetic-invalid-key"}'
)){
    Apply
    $badState=Get-SwitchState
    $badState.auth_present=$true
    $badState.auth_encrypted=Protect-LocalText ('backup:'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($badBackupAuth)))
    Save-SwitchState $badState
    Save-OfficialRecoveryCopy $badState
    $badConfigHash=(Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
    $badAuthHash=(Get-FileHash -LiteralPath $auth -Algorithm SHA256).Hash
    $badBackupError='';try{Restore-OfficialOnly -Force}catch{$badBackupError=$_.Exception.Message}
    Check ($badBackupError -match '重新登录官方' -and $script:CanResetOfficial) 'API-auth official backups did not offer confirmed reset'
    Check ((Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash -ceq $badConfigHash -and (Get-FileHash -LiteralPath $auth -Algorithm SHA256).Hash -ceq $badAuthHash) 'Rejected API-auth backups changed live config or auth'
    Reset-OfficialConnection -Confirmed
    $badSavedConfig=Unprotect-LocalText ([IO.File]::ReadAllText((Join-Path $script:LastRecoveryDirectory 'config.encrypted')))
    $badSavedAuth=Unprotect-LocalText ([IO.File]::ReadAllText((Join-Path $script:LastRecoveryDirectory 'auth.encrypted')))
    Check ($badSavedConfig -ceq ('backup:'+ $resetConfigBefore) -and $badSavedAuth -ceq ('backup:'+ $resetAuthBefore)) 'Confirmed reset did not preserve exact bytes after rejecting API-auth backups'
    Check ((Get-FileHash -LiteralPath $sessionFile -Algorithm SHA256).Hash -ceq $sessionHashBefore) 'Confirmed reset after rejected API-auth backup changed session file'
}

# Missing journal and independent copy with API auth: report reset availability without writes.
[IO.File]::Delete($script:SwitchFile);$officialCopy=Join-Path $script:LauncherData 'official-recovery.json';if(Test-Path $officialCopy){[IO.File]::Delete($officialCopy)}
$apiOnlyConfig="model = `"synthetic-api-model`"`nmodel_provider = `"openai`"`nopenai_base_url = `"https://provider.example.invalid/v1`"`n"
$apiOnlyAuth='{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic-api-key"}'
[IO.File]::WriteAllText($config,$apiOnlyConfig);[IO.File]::WriteAllText($auth,$apiOnlyAuth)
$apiOnlyConfigHash=(Get-FileHash -LiteralPath $config).Hash;$apiOnlyAuthHash=(Get-FileHash -LiteralPath $auth).Hash
$missingBackupError='';try{Restore-OfficialOnly -Force}catch{$missingBackupError=$_.Exception.Message}
Check ($missingBackupError -match '重新登录官方' -and $script:CanResetOfficial) 'Missing official backup did not expose a confirmed-reset route'
Check ((Get-FileHash -LiteralPath $config).Hash -ceq $apiOnlyConfigHash -and (Get-FileHash -LiteralPath $auth).Hash -ceq $apiOnlyAuthHash) 'Missing-backup warning changed API files'
$missingRecoveryConfig=$apiOnlyConfig;$missingRecoveryAuth=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($apiOnlyAuth))
Reset-OfficialConnection -Confirmed
$savedMissingConfig=Unprotect-LocalText ([IO.File]::ReadAllText((Join-Path $script:LastRecoveryDirectory 'config.encrypted')))
$savedMissingAuth=Unprotect-LocalText ([IO.File]::ReadAllText((Join-Path $script:LastRecoveryDirectory 'auth.encrypted')))
Check ($savedMissingConfig -ceq ('backup:'+$missingRecoveryConfig) -and $savedMissingAuth -ceq ('backup:'+$missingRecoveryAuth)) 'Missing-backup confirmed reset did not encrypt exact API config/auth'
Check ([IO.File]::ReadAllText($config) -ceq $resetConfig -and -not(Test-Path $auth)) 'Missing-backup reset left API connection active'

# Clean official state with no journal is not reset by the official start route.
[IO.File]::Delete($script:SwitchFile);if(Test-Path $officialCopy){[IO.File]::Delete($officialCopy)}
[IO.File]::WriteAllText($config,$original);[IO.File]::WriteAllBytes($auth,$officialAuth)
$realGetOfficialExe=${function:Get-OfficialDesktopExe};$realStartDesktop=${function:Start-Desktop}
$script:OfficialStartStubReached=$false
function Get-OfficialDesktopExe {return 'C:\synthetic\ChatGPT.exe'}
function Start-Desktop {param($Exe,$HomePath,$UiPath)$script:OfficialStartStubReached=$true;return 4242}
try{
    $script:CanResetOfficial=$false;$null=Start-Official
    Check ($script:OfficialStartStubReached -and -not $script:CanResetOfficial) 'Clean official start prompted for reset or missed launch stub'
    Check ([IO.File]::ReadAllText($config) -ceq $original -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($auth)) -ceq [Convert]::ToBase64String($officialAuth)) 'Clean official start changed official config/auth'
}finally{Set-Item Function:Get-OfficialDesktopExe $realGetOfficialExe;Set-Item Function:Start-Desktop $realStartDesktop}

# A running engine blocks before restore and must not enable reset.
$script:TestProcesses=@([pscustomobject]@{Name='codex.exe';ExecutablePath='synthetic-engine'})
$script:CanResetOfficial=$false;Must-Fail {Start-Official}
Check (-not $script:CanResetOfficial -and [IO.File]::ReadAllText($config) -ceq $original) 'Running-engine guard offered reset or changed config'
$script:TestProcesses=@()

# An inactive record bound to an old home must not redirect recovery for the current home.
$oldHome=Join-Path $fixture '旧聊天目录';$currentHome=Join-Path $fixture '当前聊天目录'
New-Item -ItemType Directory -Path $oldHome,$currentHome -Force|Out-Null
$oldState=[pscustomobject]@{version=2;home=$oldHome;active=$false;phase='ready'}
$oldCopy=[pscustomobject]@{version=2;home=$oldHome;active=$true;auth_present=$false}
[IO.File]::WriteAllText($script:SwitchFile,($oldState|ConvertTo-Json));[IO.File]::WriteAllText($officialCopy,($oldCopy|ConvertTo-Json))
$script:OfficialHome=$currentHome;$currentConfig=Join-Path $currentHome 'config.toml';$currentAuth=Join-Path $currentHome 'auth.json'
[IO.File]::WriteAllText($currentConfig,'model="current-official"');[IO.File]::WriteAllText($currentAuth,'{"auth_mode":"chatgpt"}')
Restore-OfficialOnly -Force
Check ($script:OfficialHome -eq $currentHome -and [IO.File]::ReadAllText($currentConfig) -ceq 'model="current-official"' -and [IO.File]::ReadAllText($currentAuth) -ceq '{"auth_mode":"chatgpt"}') 'Inactive old-home state or copy was applied to current data'

# StartOfficial recovers with broken path/API/image settings, but launches only through a test stub.
$previousUserProfile=$env:USERPROFILE;$previousAppData=$env:APPDATA
$env:USERPROFILE=Join-Path $fixture 'isolated-profile';$env:APPDATA=Join-Path $fixture 'isolated-roaming'
$script:OfficialHome=Join-Path $env:USERPROFILE '.codex';$script:OfficialUi=Join-Path $env:APPDATA 'Codex';$script:SwitchFile=Join-Path $script:LauncherData 'shared-switch.json'
New-Item -ItemType Directory -Path $script:OfficialHome,$script:OfficialUi -Force|Out-Null
$config=Join-Path $script:OfficialHome 'config.toml';$auth=Join-Path $script:OfficialHome 'auth.json'
[IO.File]::WriteAllText($config,$original);[IO.File]::WriteAllBytes($auth,$officialAuth)
Apply
foreach($badFile in @('paths.json','profiles.json','image-services.json')){[IO.File]::WriteAllText((Join-Path $script:LauncherData $badFile),'invalid-json')}
Initialize-LauncherPaths
$script:AllowOfficialDiscovery=$true;$script:TestProcesses=@();$script:OfficialStartStubReached=$false
$realStartDesktop=${function:Start-Desktop}
function Start-Desktop {param($Exe,$HomePath,$UiPath)$script:OfficialStartStubReached=$true;return 5252}
try{
    $started=Start-Official
    Check ($started -eq 5252 -and $script:OfficialStartStubReached) 'Official start did not reach isolated launch stub with corrupt settings'
    Check ([IO.File]::ReadAllText($config) -ceq $original -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($auth)) -ceq [Convert]::ToBase64String($officialAuth)) 'Official start failed to recover with corrupt settings'
    Check ((Get-SwitchState) -and -not (Get-SwitchState).active) 'Official start did not finish recovery under corrupt settings'
    Check ((Get-Content -LiteralPath (Join-Path $script:LauncherData 'paths.json') -Raw) -ceq 'invalid-json') 'Automatic installation fallback overwrote saved paths file'
}finally{$script:AllowOfficialDiscovery=$false;Set-Item Function:Start-Desktop $realStartDesktop;$env:USERPROFILE=$previousUserProfile;$env:APPDATA=$previousAppData}
# The child entry point must start from API mode; otherwise its restore check would be a no-op.
Apply
$childState=Get-SwitchState
Check ($childState.active -and $childState.phase -eq 'ready' -and [IO.File]::ReadAllText($config) -match 'openai_base_url') 'Independent-entry fixture was not in API mode before invocation'
$childLocal=Join-Path $fixture '独立恢复';$childData=Join-Path $childLocal 'CodexLauncherSafe'
New-Item -ItemType Directory -Path $childData -Force|Out-Null
Copy-Item -LiteralPath $script:SwitchFile -Destination (Join-Path $childData 'shared-switch.json')
foreach($badFile in @('profiles.json','image-services.json','paths.json')){[IO.File]::WriteAllText((Join-Path $childData $badFile),'invalid-json')}
$previousLocal=$env:LOCALAPPDATA
try{$env:LOCALAPPDATA=$childLocal;. (Join-Path $PSScriptRoot '../Restore-Official.ps1') -ConsoleOnly}finally{$env:LOCALAPPDATA=$previousLocal}
Check ([IO.File]::ReadAllText($config) -ceq $original -and -not (Get-SwitchState).active) 'Independent entry depends on broken API/image/path settings'
'PASS: equivalent TOML and missing MCP repair; real conflicts preserved; transaction readback and emergency fallback; official auth bytes; encrypted quarantine; legacy checkpoints; invalid backup fails before writes; independent recovery.'
