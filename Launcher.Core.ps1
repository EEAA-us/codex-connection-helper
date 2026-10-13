$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
$script:LauncherData = Join-Path $env:LOCALAPPDATA 'CodexLauncherSafe'
. (Join-Path $PSScriptRoot 'Launcher.Paths.ps1')
$script:LegacyManagedKeys = @('model','model_provider','openai_base_url','model_catalog_json','cli_auth_credentials_store','forced_login_method','service_tier')
$script:AdvancedKeys = @('model_context_window','model_auto_compact_token_limit','web_search','model_verbosity','tool_output_token_limit','model_reasoning_effort')
$script:ManagedKeys = $script:LegacyManagedKeys + $script:AdvancedKeys
$script:PreferenceFile = Join-Path $script:LauncherData 'preferences.json'
$script:Utf8 = [Text.UTF8Encoding]::new($false)

function Get-Preferences {
    if (Test-Path -LiteralPath $script:PreferenceFile) {
        try { return (Get-Content -LiteralPath $script:PreferenceFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { throw '旧版接口配置无法读取，请先检查 preferences.json，原文件未修改。' }
    }
    return [pscustomobject]@{ base_url = ''; model = ''; key_url = ''; encrypted_key = '' }
}

function Write-Atomic([string]$Path, [string]$Content) {
    $parent = Split-Path $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = Join-Path $parent ([Guid]::NewGuid().ToString('N') + '.tmp')
    $previous = $temporary + '.previous'
    try {
        [IO.File]::WriteAllText($temporary, $Content, $script:Utf8)
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, $previous, $true) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
        if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous }
    }
}

function Normalize-Endpoint([string]$Url) {
    $parsed = $null
    if (-not [Uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref]$parsed) -or
        $parsed.Scheme -ne 'https' -or $parsed.UserInfo -or $parsed.Query -or $parsed.Fragment) {
        throw '接口地址须为 HTTPS 地址，不能包含账号密码、查询参数或片段。'
    }
    return $parsed.AbsoluteUri.TrimEnd('/')
}

function Get-LocalKey($Preferences, [string]$Url, [string]$EnteredKey) {
    if (-not [string]::IsNullOrWhiteSpace($EnteredKey)) { return $EnteredKey.Trim() }
    if ($Preferences.key_url -ne $Url -or [string]::IsNullOrWhiteSpace($Preferences.encrypted_key)) {
        throw '请填写这个接口对应的 API Key。更换接口后须重新输入。'
    }
    $pointer = [IntPtr]::Zero
    try {
        $secure = ConvertTo-SecureString -String $Preferences.encrypted_key
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    catch { throw '本机保存的 Key 无法解密，请重新输入。' }
    finally { if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) } }
}

function Save-Preferences([string]$Url, [string]$Model, [string]$Key) {
    if(Test-Path -LiteralPath $script:PreferenceFile){Write-Atomic (Join-Path $script:LauncherData ('preference-backups/'+[Guid]::NewGuid().ToString('N')+'.encrypted')) (Protect-LocalText ('backup:'+ [IO.File]::ReadAllText($script:PreferenceFile)))}
    $secure = ConvertTo-SecureString -String $Key -AsPlainText -Force
    $data = [pscustomobject]@{
        base_url = $Url; model = $Model; key_url = $Url
        encrypted_key = (ConvertFrom-SecureString -SecureString $secure)
    }
    Write-Atomic $script:PreferenceFile ($data | ConvertTo-Json)
}

function Sync-NativeCatalog([string]$Url, [string[]]$ModelIds, [string]$ProfileId = '') {
    $url = Normalize-Endpoint $Url
    $source = Join-Path $script:OfficialHome 'models_cache.json'
    if (-not (Test-Path -LiteralPath $source)) { throw '本机模型元数据尚未就绪。请先正常使用官方 Codex，再读取第三方模型列表。' }
    $cache = Get-Content -LiteralPath $source -Raw -Encoding UTF8 | ConvertFrom-Json
    $entries = @($cache.models | Where-Object { $_.slug -ne 'codex-auto-review' -and $ModelIds -ccontains $_.slug })
    if (-not $entries.Count) { throw '服务商列表中没有本机已知的兼容模型，暂时无法生成原生菜单。仍可手动输入默认模型。' }
    # Use exact matching metadata; do not invent capability metadata for unknown aliases.
    foreach ($entry in $entries) {
        $entry.visibility = 'list'
        $entry.supported_in_api = $true
        $entry.upgrade = $null
    }
    $catalogPath = Join-Path $script:LauncherData 'native-models.json'
    $endpointPath = Join-Path $script:LauncherData 'native-models-endpoint.txt'
    if ($ProfileId) {
        if ($ProfileId -notmatch '^[a-f0-9]{32}$') { throw '接口标识无效。' }
        $catalogPath = Join-Path $script:LauncherData ('catalogs\' + $ProfileId + '.json')
        $endpointPath = Join-Path $script:LauncherData ('catalogs\' + $ProfileId + '-endpoint.txt')
    }
    Write-Atomic $catalogPath (@{ models = $entries } | ConvertTo-Json -Depth 100)
    Write-Atomic $endpointPath $url
    return [pscustomobject]@{ count = $entries.Count; skipped = ($ModelIds.Count - $entries.Count); path = $catalogPath }
}

function Start-HttpCompatibility([string]$Url,[string]$Key,$Cancellation=$null) {
    $scriptFile=Join-Path $PSScriptRoot 'HttpBridge.ps1'
    if(-not (Test-Path -LiteralPath $scriptFile)){throw 'HTTP 兼容模块缺失，请保留完整启动器文件夹。'}
    $token=[Guid]::NewGuid().ToString('N')+[Guid]::NewGuid().ToString('N')
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$scriptFile+'"'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($info)
    try {
        $process.StandardInput.WriteLine((@{url=$Url;key=$Key;token=$token}|ConvertTo-Json -Compress))
        $process.StandardInput.Flush()
        $ready=$process.StandardOutput.ReadLineAsync()
        $deadline=[Diagnostics.Stopwatch]::StartNew()
        while(-not $ready.Wait(100)){
            if($Cancellation -and $Cancellation.IsCancelled){throw '连接检查已取消。'}
            if($deadline.ElapsedMilliseconds -ge 15000){throw 'HTTP 兼容模块启动超时。'}
        }
        $port=0
        if(-not [int]::TryParse($ready.Result,[ref]$port) -or $port -lt 1 -or $port -gt 65535){throw 'HTTP 兼容模块未能初始化。'}
        return [PSCustomObject]@{process=$process;url=('http://127.0.0.1:'+$port+'/v1');token=$token}
    }catch{
        $process.StandardInput.Close()
        if(-not $process.WaitForExit(2000)){$process.Kill()}
        $process.Dispose();throw
    }
}

function Stop-HttpCompatibility($Bridge) {
    if(-not $Bridge){return}
    try{$Bridge.process.StandardInput.Close();if(-not $Bridge.process.WaitForExit(2000)){$Bridge.process.Kill()}}catch{}
    finally{$Bridge.process.Dispose()}
}

function New-ApiConnectionProbe {
    if(-not ('CodexApiProbe' -as [type])){
        Add-Type -Path (Join-Path $PSScriptRoot 'ApiProbe.cs') -ReferencedAssemblies 'System.Net.Http','System','System.Core','System.Web.Extensions'
    }
    return [CodexApiProbe]::new()
}

function Test-ProfileConnection($Profile,$Probe=$null) {
    $url=Normalize-Endpoint $Profile.base_url
    $null=New-ThirdPartyConfig $url $Profile.model
    $key=Get-LocalKey $Profile $url ''
    $owned=$false;$bridge=$null
    try{
        if(-not $Probe){$Probe=New-ApiConnectionProbe;$owned=$true}
        $body=@{model=$Profile.model;stream=$true;store=$false;input='Reply exactly OK. Do not use tools.';tools=@();max_output_tokens=512}
        $options=Get-ModelReasoningOptions $Profile.model
        if($options.known){
            foreach($effort in @('none','minimal','low')){
                if($effort -in $options.levels){$body.reasoning=@{effort=$effort};break}
            }
        }
        if($Probe -and $Probe.GetType().GetMethod('RunAsync') -eq $null){throw '连接测试组件不完整。'}
        $bridge=Start-HttpCompatibility $url $key $Probe;$key=$null
        $bridge.process.StandardInput.WriteLine('test');$bridge.process.StandardInput.Flush()
        return $Probe.RunAsync(($bridge.url+'/responses'),$bridge.token,($body|ConvertTo-Json -Depth 8 -Compress),45).GetAwaiter().GetResult()
    }finally{
        $key=$null
        if($bridge){Stop-HttpCompatibility $bridge}
        if($owned){$Probe.Dispose()}
    }
}

function Get-HttpCompatibilityCatalog([string]$Path,[string]$Model) {
    $source=$Path
    if(-not $source){$source=Join-Path $script:OfficialHome 'models_cache.json'}
    if(-not (Test-Path -LiteralPath $source)){return ''}
    $metadata=Get-Content -LiteralPath $source -Raw -Encoding UTF8|ConvertFrom-Json
    $models=@($metadata.models)
    if(-not $Path){$models=@($models|Where-Object {$_.slug -ceq $Model})}
    if(-not $models.Count){return ''}
    foreach($entry in $models){
        $entry|Add-Member -NotePropertyName use_responses_lite -NotePropertyValue $false -Force
        $entry.visibility='list';$entry.supported_in_api=$true;$entry.upgrade=$null
    }
    $destination=Join-Path $script:LauncherData 'http-models.json'
    if($Path){$destination=$Path+'.http.json'}
    Write-Atomic $destination (@{models=$models}|ConvertTo-Json -Depth 100)
    return $destination
}

function Assert-DesktopClosed([string]$Exe) {
    $running = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq 'ChatGPT.exe' -and $_.ExecutablePath -and
        ($_.ExecutablePath.Equals($Exe, [StringComparison]::OrdinalIgnoreCase) -or $_.ExecutablePath -match 'OpenAI\.Codex_[^\\]+\\app\\ChatGPT\.exe$' -or
         (Test-Path -LiteralPath (Join-Path (Split-Path $_.ExecutablePath) 'resources\codex.exe')))
    }
    if ($running) { throw 'Codex 桌面版还在运行。请等任务结束，完全退出（包括托盘），再点击启动。启动器不会强制关闭它。' }
    $engines = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'codex.exe' })
    if ($engines.Count) { throw '检测到 Codex CLI 或后台引擎仍在运行。为避免共享登录配置互相影响，请先正常结束这些任务并退出，再切换连接。启动器不会强制关闭进程。' }
}

function New-ThirdPartyConfig([string]$Url, [string]$Model, [string]$CatalogPath = '', $Settings = $null, [string]$OfficialTransport = '') {
    if($Model -match '^gpt-image(?:-|$)'){throw '图片专用模型不能作为默认对话模型；请在图片服务中配置，并选择正常对话模型。'}
    if ([string]::IsNullOrWhiteSpace($Model) -or $Model.Length -gt 200 -or $Model -match '[\r\n\x00-\x1f]') {
        throw '请填写服务商支持的准确模型名，或先读取模型列表。'
    }
    $urlLiteral = ConvertTo-Json $Url -Compress
    $modelLiteral = ConvertTo-Json $Model -Compress
    $catalogLine = ''
    if ($CatalogPath) { $catalogLine = 'model_catalog_json = ' + (ConvertTo-Json ($CatalogPath.Replace('\', '/')) -Compress) }
    $extra = Get-AdvancedTransport $Settings $OfficialTransport
    $transport = @"
model = $modelLiteral
model_provider = "openai"
openai_base_url = $urlLiteral
$catalogLine
cli_auth_credentials_store = "file"
forced_login_method = "api"
$extra
"@
    return [regex]::Replace($transport,'(?m)^[ \t]*\r?\n','')
}

function Convert-TokenSetting([string]$Value,[string]$Label) {
    $value = $Value.Trim()
    if (-not $value -or $value -in @('auto','自动','继承原设置')) { return '' }
    if ($value -notmatch '^(\d+(?:\.\d+)?)([kKmM]?)$') { throw ($Label + '请填写正整数、200K 或 1M；留空为默认。') }
    $amount = [decimal]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture)
    if ($Matches[2] -match '[kK]') { $amount *= 1000 }
    if ($Matches[2] -match '[mM]') { $amount *= 1000000 }
    if ($amount -le 0 -or $amount -gt [int]::MaxValue -or [decimal]::Truncate($amount) -ne $amount) { throw ($Label + '须为有效的正整数。') }
    return ([long]$amount).ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Get-ModelReasoningOptions([string]$Model) {
    $options=[pscustomobject]@{known=$false;levels=@('low','medium','high','xhigh','max','ultra')}
    try {
        $cachePath=Join-Path $script:OfficialHome 'models_cache.json'
        if(Test-Path -LiteralPath $cachePath){
            $cache=Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $entry=@($cache.models | Where-Object {$_.slug -ceq $Model})[0]
            if($entry -and $entry.supported_reasoning_levels){
                $levels=@($entry.supported_reasoning_levels | ForEach-Object {[string]$_.effort} | Where-Object {$_ -in @('none','minimal','low','medium','high','xhigh','max','ultra')} | Select-Object -Unique)
                if($levels.Count){$options.known=$true;$options.levels=$levels}
            }
        }
    }catch{ }
    return $options
}

function Get-AdvancedTransport($Settings,[string]$OfficialTransport) {
    $result = @{}
    $customBudget = $false
    foreach ($key in $script:AdvancedKeys) {
        $match = [regex]::Match($OfficialTransport,('(?m)^[ \t]*' + $key + '[ \t]*=([^\r\n]*)'))
        if ($match.Success) { $result[$key] = $match.Groups[1].Value.Trim() }
    }
    if ($Settings) {
        foreach ($pair in @(@('context_window','model_context_window'),@('compact_limit','model_auto_compact_token_limit'),@('tool_output_limit','tool_output_token_limit'))) {
            $property = $Settings.PSObject.Properties[$pair[0]]
            if ($property -and $property.Value) {
                $normalized = Convert-TokenSetting ([string]$property.Value) $pair[0]
                if ($normalized) {
                    $result[$pair[1]] = $normalized
                    if ($pair[0] -in @('context_window','compact_limit')) { $customBudget = $true }
                }
            }
        }
        foreach ($pair in @(@('web_search','web_search'),@('verbosity','model_verbosity'),@('reasoning_effort','model_reasoning_effort'))) {
            $property = $Settings.PSObject.Properties[$pair[0]]
            if ($property -and $property.Value -and $property.Value -ne 'inherit') {
                $allowed = @('disabled','cached','live')
                if ($pair[0] -eq 'verbosity') { $allowed = @('low','medium','high') }
                if ($pair[0] -eq 'reasoning_effort') {
                    $allowed=@('none','minimal','low','medium','high','xhigh','max','ultra')
                    if($property.Value -notin $allowed){throw '推理强度值无效，请从列表选择。'}
                    if($Settings.PSObject.Properties['model']){
                        $options=Get-ModelReasoningOptions ([string]$Settings.model)
                        if($options.known -and $property.Value -notin $options.levels){throw '当前模型的本机元数据不支持这个推理强度。请改用列表中的档位或继承原设置。'}
                    }
                }
                if ($property.Value -notin $allowed) { throw '高级参数值无效。' }
                $result[$pair[1]] = ConvertTo-Json ([string]$property.Value) -Compress
            }
        }
    }
    if ($customBudget -and $result.ContainsKey('model_context_window') -and $result.ContainsKey('model_auto_compact_token_limit')) {
        $window = [regex]::Match($result['model_context_window'],'^[\d_]+').Value.Replace('_','')
        $limit = [regex]::Match($result['model_auto_compact_token_limit'],'^[\d_]+').Value.Replace('_','')
        if ($window -and $limit -and [long]$limit -ge [long]$window) { throw '自动压缩阈值必须小于有效的上下文长度；请同时调整这两个值。' }
    }
    return ($script:AdvancedKeys | Where-Object { $result.ContainsKey($_) } | ForEach-Object { $_ + ' = ' + $result[$_] }) -join "`r`n"
}

function Get-UniqueApiName([string]$Base,$Profiles=@()) {
    $names=@($Profiles|ForEach-Object{([string]$_.name).Trim()})
    for($n=1;;$n++){$suffix=' '+$n;$candidate=$Base.Substring(0,[Math]::Min($Base.Length,60-$suffix.Length))+$suffix;if($candidate -notin $names){return $candidate}}
}
function Get-ApiDisplayName($Profile,$Profiles) {
    $same=@($Profiles|Where-Object{([string]$_.name).Trim() -ieq ([string]$Profile.name).Trim()})
    if($same.Count -gt 1){return ([string](1+[Array]::IndexOf(@($same.id),$Profile.id)))+' · '+$Profile.name}
    return $Profile.name
}
function New-ApiProfile([string]$Name = '新 API 接口') {
    return [pscustomobject]@{
        id = [Guid]::NewGuid().ToString('N'); name = $Name; base_url = ''
        model = ''; key_url = ''; encrypted_key = ''; models = @(); image_service_id = ''; image_mode = ''
        context_window = ''; compact_limit = ''; tool_output_limit = ''; web_search = 'inherit'; verbosity = 'inherit'; reasoning_effort = 'inherit'
    }
}

function Get-ProfileStore {
    $path = Join-Path $script:LauncherData 'profiles.json'
    if (Test-Path -LiteralPath $path) {
        try {
            $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($data.version -ne 2 -or -not @($data.profiles).Count) { throw 'Invalid schema' }
            foreach ($profile in @($data.profiles)) {
                if ($profile.id -notmatch '^[a-f0-9]{32}$') { throw 'Invalid ID' }
                $defaults = New-ApiProfile
                foreach ($property in $defaults.PSObject.Properties) {
                    if (-not $profile.PSObject.Properties[$property.Name]) { $profile | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value }
                }
            }
            if (@($data.profiles.id | Sort-Object -Unique).Count -ne @($data.profiles).Count) { throw 'Duplicate ID' }
            if ($data.selected_id -notin @($data.profiles.id)) { $data.selected_id = $data.profiles[0].id }
            return $data
        } catch { throw '多接口配置无法读取。原文件仍保留，请先恢复 profiles.json 的备份，避免覆盖已有 Key。' }
    }
    $legacy = Get-Preferences
    $profileName='我的 API'
    if($legacy.base_url){$profileName='原有接口'}
    $profile = New-ApiProfile $profileName
    foreach ($key in @('base_url','model','key_url','encrypted_key')) { $profile.$key = $legacy.$key }
    $catalog = Join-Path $script:LauncherData 'native-models.json'
    $endpointPath = Join-Path $script:LauncherData 'native-models-endpoint.txt'
    if ((Test-Path -LiteralPath $catalog) -and (Test-Path -LiteralPath $endpointPath) -and [IO.File]::ReadAllText($endpointPath).Trim() -eq $legacy.base_url) {
        try { $profile.models = @((Get-Content $catalog -Raw -Encoding UTF8 | ConvertFrom-Json).models.slug) } catch { }
    }
    return [pscustomobject]@{ version = 2; selected_id = $profile.id; profiles = @($profile) }
}

function Save-ProfileStore($Store) {
    if (-not @($Store.profiles).Count) { throw '至少保留一个 API 配置。' }
    $path = Join-Path $script:LauncherData 'profiles.json'
    if (Test-Path -LiteralPath $path) {
        $backup = Join-Path $script:LauncherData ('profile-backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N') + '.json')
        Write-Atomic $backup ([IO.File]::ReadAllText($path))
    }
    Write-Atomic $path ($Store | ConvertTo-Json -Depth 12)
}

function Complete-ApiProfile($Profile,[string]$EnteredKey = '') {
    $copy = $Profile | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    if(-not $copy.PSObject.Properties['reasoning_effort']){$copy | Add-Member -NotePropertyName reasoning_effort -NotePropertyValue 'inherit'}
    elseif([string]::IsNullOrWhiteSpace([string]$copy.reasoning_effort)){$copy.reasoning_effort='inherit'}
    $copy.name = $copy.name.Trim()
    if (-not $copy.name -or $copy.name.Length -gt 60) { throw '请填写 1–60 字的接口名称。' }
    $copy.base_url = Normalize-Endpoint $copy.base_url
    if ($copy.key_url -and $copy.key_url -ne $copy.base_url) { $copy.models = @() }
    $mode=Get-ImageMode $copy
    if($mode -notin @('off','current','service')){throw '图片使用方式无效。'}
    $copy.model = $copy.model.Trim()
    if ($copy.model.Length -gt 200 -or $copy.model -match '[\r\n\x00-\x1f]') { throw '模型名无效。' }
    foreach ($key in @('context_window','compact_limit','tool_output_limit')) { $copy.$key = Convert-TokenSetting ([string]$copy.$key) $key }
    $null = Get-AdvancedTransport $copy ''
    if ($EnteredKey.Trim()) {
        $copy.encrypted_key = Protect-LocalText $EnteredKey.Trim()
        $copy.key_url = $copy.base_url
    } elseif ($copy.encrypted_key -and $copy.key_url -ne $copy.base_url) {
        throw '接口地址已改变，请输入新接口对应的 Key；不会将旧 Key 发给新地址。'
    }
    return $copy
}

function Read-ProfileModels($Profile,[string]$EnteredKey = '') {
    $url = Normalize-Endpoint $Profile.base_url
    $key = Get-LocalKey $Profile $url $EnteredKey
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $response = Invoke-RestMethod -Method Get -Uri ($url + '/models') -Headers @{ Authorization = 'Bearer ' + $key } -TimeoutSec 12 -MaximumRedirection 0
        $ids = @($response.data | ForEach-Object { [string]$_.id } | Where-Object { $_ -and $_.Length -le 200 -and $_ -notmatch '[\r\n\x00-\x1f]' } | Sort-Object -Unique)
        if (-not $ids.Count) { throw 'empty' }
        return $ids
    } catch { throw '模型列表检查失败，请核对接口地址、Key 与网络。该检查不发送聊天内容。' }
    finally { $key = $null }
}

function Upgrade-SwitchKeys($State,[string]$CurrentManaged) {
    $known = $script:LegacyManagedKeys
    if ($State.PSObject.Properties['managed_keys']) { $known = @($State.managed_keys) }
    $newKeys = @($script:ManagedKeys | Where-Object { $_ -notin $known })
    if (-not $newKeys.Count) { return }
    $original = (Unprotect-LocalText $State.official_transport_encrypted).Substring(7)
    if ($original -and -not $original.EndsWith("`n")) { $original += "`r`n" }
    foreach ($key in $newKeys) {
        $entry = [regex]::Match($CurrentManaged,('(?m)^[ \t]*' + $key + '[ \t]*=[^\r\n]*(?:\r?\n|$)'))
        if ($entry.Success) { $original += $entry.Value }
    }
    $State.official_transport_encrypted = Protect-LocalText ('backup:' + $original)
    $State | Add-Member -NotePropertyName managed_keys -NotePropertyValue $script:ManagedKeys -Force
    Save-SwitchState $State
}

function Protect-LocalText([string]$Text) {
    return ConvertFrom-SecureString (ConvertTo-SecureString $Text -AsPlainText -Force)
}

function Unprotect-LocalText([string]$Cipher) {
    $pointer = [IntPtr]::Zero
    try {
        $secure = ConvertTo-SecureString $Cipher
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally { if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) } }
}

function Split-Transport([string]$Text) {
    # Restrict editing to scalar keys before the first TOML table. Keep all other text verbatim.
    $table = [regex]::Match($Text, '(?m)^\s*\[')
    $length = $Text.Length
    if ($table.Success) { $length = $table.Index }
    $root = $Text.Substring(0,$length)
    $rest = $Text.Substring($length)
    $keys = ($script:ManagedKeys | ForEach-Object { [regex]::Escape($_) }) -join '|'
    if ($root -match ('(?m)^\s*["''](?:' + $keys + ')["'']\s*=')) { throw '连接设置使用了特殊 TOML 写法；为避免误改，启动器已停止。' }
    $pattern = '(?m)^[ \t]*(?:' + $keys + ')[ \t]*=[^\r\n]*(?:\r?\n|$)'
    $matches = [regex]::Matches($root,$pattern)
    foreach ($entry in $matches) {
        if ($entry.Value -match '"""|\x27\x27\x27' -or $entry.Value -match '=\s*[\[\{]') { throw '连接设置包含复杂 TOML 值；启动器没有修改文件。' }
    }
    return [pscustomobject]@{ unmanaged = [regex]::Replace($root,$pattern,'') + $rest; managed = ($matches | ForEach-Object { $_.Value }) -join '' }
}

function Merge-Transport([string]$Text,[string]$Managed) {
    $parts = Split-Transport $Text
    # Generated transport must not leave an extra blank line in unmanaged TOML.
    if ($Managed) { $Managed=$Managed.TrimEnd("`r","`n")+"`r`n" }
    return $Managed + $parts.unmanaged
}

function Get-SwitchState {
    if (Test-Path -LiteralPath $script:SwitchFile) {
        $state = Get-Content -LiteralPath $script:SwitchFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.version -notin @(1,2)) { throw '切换备份版本无法识别，已停止修改。' }
        if ($state.home -ne $script:OfficialHome) {
            if($state.active){throw '切换备份与当前数据目录不匹配，请在环境设置中恢复原目录后再恢复官方。'}
            return $null
        }
        return $state
    }
    return $null
}

function Save-SwitchState($State) {
    if(Test-Path -LiteralPath $script:SwitchFile){
        $old=Get-Content -LiteralPath $script:SwitchFile -Raw -Encoding UTF8|ConvertFrom-Json
        if($old.home -ne $State.home){
            if($old.active){throw '另一个数据目录仍有未恢复的 API 切换，已停止写入。'}
            Write-Atomic (Join-Path $script:LauncherData ('recovery-archives\'+[Guid]::NewGuid().ToString('N')+'.json')) ([IO.File]::ReadAllText($script:SwitchFile))
        }
    }
    Write-Atomic $script:SwitchFile ($State | ConvertTo-Json -Depth 5)
}

# A separate, encrypted official snapshot survives a damaged switch journal.
function Save-OfficialRecoveryCopy($State) {
    $copy=$State|ConvertTo-Json -Depth 8|ConvertFrom-Json
    $copy.active=$true
    Write-Atomic (Join-Path $script:LauncherData 'official-recovery.json') ($copy|ConvertTo-Json -Depth 8)
}
function Resolve-OfficialRecoveryTarget {
    $candidate=$null
    foreach($path in @($script:SwitchFile,(Join-Path $script:LauncherData 'official-recovery.json'))){
        if(Test-Path -LiteralPath $path){try{$value=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json;if($value.version -in @(1,2) -and $path -eq $script:SwitchFile -and -not $value.active){return};if($value.active -and $value.home){$candidate=$value;break}}catch{}}
    }
    if($candidate){
        $homePath=Convert-LauncherPath ([string]$candidate.home) '官方备份数据目录'
        if(-not(Test-Path -LiteralPath $homePath -PathType Container)){throw '原数据目录不存在，请接回磁盘或恢复原目录；聊天不会被移到空目录。'}
        $script:OfficialHome=$homePath
        if($candidate.PSObject.Properties['ui'] -and $candidate.ui){$script:OfficialUi=Convert-LauncherPath ([string]$candidate.ui) '官方界面目录'}
    }
}
function Get-OfficialRestoreState([switch]$Force) {
    try{
        $state=Get-SwitchState
        if($state -and $state.active){
            $transport=Unprotect-LocalText $state.official_transport_encrypted
            $auth=Unprotect-LocalText $state.auth_encrypted
            if(-not $transport.StartsWith('backup:') -or -not $auth.StartsWith('backup:')){throw 'Invalid recovery values'}
            if($state.auth_present){$authObject=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($auth.Substring(7)))|ConvertFrom-Json);if($authObject.auth_mode -eq 'apikey' -or $authObject.OPENAI_API_KEY){throw '备份不是官方账号登录'}}
        }
        if($state -and $state.active){return $state}
        $authFile=Join-Path $script:OfficialHome 'auth.json'
        if(Test-Path -LiteralPath $authFile){$authKind=(Get-Content -LiteralPath $authFile -Raw -Encoding UTF8|ConvertFrom-Json).auth_mode;if($authKind -eq 'apikey'){throw 'API 登录缺少切换记录'}}
        $configFile=Join-Path $script:OfficialHome 'config.toml'
        if((Test-Path -LiteralPath $configFile) -and [IO.File]::ReadAllText($configFile) -match '(?m)^\s*forced_login_method\s*=\s*"apikey"'){throw 'API 连接缺少切换记录'}
        return $state
    }catch{
        if(-not $Force){throw}
        $path=Join-Path $script:LauncherData 'official-recovery.json'
        if(Test-Path -LiteralPath $path){
            try{
                $copy=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
                if($copy.version -notin @(1,2) -or $copy.home -ine $script:OfficialHome){throw 'Wrong recovery directory'}
                $backup=Unprotect-LocalText $copy.official_config_encrypted
                $auth=Unprotect-LocalText $copy.auth_encrypted
                $transport=Unprotect-LocalText $copy.official_transport_encrypted
                if(-not $backup.StartsWith('backup:') -or -not $auth.StartsWith('backup:') -or -not $transport.StartsWith('backup:')){throw 'Invalid recovery copy'}
                if($copy.auth_present){$authObject=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($auth.Substring(7)))|ConvertFrom-Json);if($authObject.auth_mode -eq 'apikey' -or $authObject.OPENAI_API_KEY){throw '独立副本不是官方账号登录'}}
                # Preserve the unreadable journal before repairing it; never hide it.
                if(Test-Path -LiteralPath $script:SwitchFile){Write-Atomic (Join-Path $script:LauncherData ('recovery-archives/'+[Guid]::NewGuid().ToString('N')+'.encrypted')) (Protect-LocalText ('backup:'+ [IO.File]::ReadAllText($script:SwitchFile)))}
                $copy.active=$true
                $copy|Add-Member -NotePropertyName recovery_from_copy -NotePropertyValue $true -Force
                Write-Atomic $script:SwitchFile ($copy|ConvertTo-Json -Depth 8)
                return $copy
            }catch{throw '官方恢复记录和独立副本均不可用。可选择“重置连接并重新登录官方”；原文件会先备份，聊天与项目保留。'}
        }
        throw '没有可用的官方登录备份。可选择“重置连接并重新登录官方”；原文件会先备份，聊天与项目保留。'
    }
}

function Get-OfficialTransportText {
    $state = Get-SwitchState
    if ($state -and $state.active) { return (Unprotect-LocalText $state.official_transport_encrypted).Substring(7) }
    $path = Join-Path $script:OfficialHome 'config.toml'
    if (Test-Path -LiteralPath $path) { return (Split-Transport ([IO.File]::ReadAllText($path))).managed }
    return ''
}

function Get-LocalAuthFingerprint {
    $path = Join-Path $script:OfficialHome 'auth.json'
    if (-not (Test-Path -LiteralPath $path)) { return 'missing' }
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($path)
        return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')
    } finally { if ($stream) { $stream.Dispose() }; $sha.Dispose() }
}

function Assert-ManagedConnection($State) {
    if (-not $State -or -not $State.active) { return }
    if ($State.PSObject.Properties['phase'] -and $State.phase -in @('switching','restoring')) { throw '上次切换或恢复未完成。请保持 Codex 关闭，使用“恢复官方配置”确认恢复后再启动。' }
    if($State.PSObject.Properties['image_mcp_block'] -and $State.image_mcp_block){$null=Remove-ManagedImageBlock ([IO.File]::ReadAllText((Join-Path $script:OfficialHome 'config.toml'))) $State}
    if (-not $State.PSObject.Properties['active_url']) { return }
    $path = Join-Path $script:OfficialHome 'config.toml'
    $text = ''
    if (Test-Path -LiteralPath $path) { $text = (Split-Transport ([IO.File]::ReadAllText($path))).managed }
    $urlMatch = [regex]::Match($text,'(?m)^\s*openai_base_url\s*=\s*("(?:[^"\\]|\\.)*")')
    $providerMatch = [regex]::Match($text,'(?m)^\s*model_provider\s*=\s*"openai"\s*(?:#.*)?$')
    $url = ''
    if ($urlMatch.Success) { $url = $urlMatch.Groups[1].Value | ConvertFrom-Json }
    if ($url -ne $State.active_url -or -not $providerMatch.Success -or
        (Get-LocalAuthFingerprint) -ne $State.active_auth_hash) {
        throw '登录或接口已被其他方式修改。为避免覆盖，普通切换已停止；请检查当前设置，或使用“恢复官方配置”明确恢复本启动器保存的官方备份。'
    }
}

function Save-ConfigBackup([string]$Text) {
    $dir = Join-Path $script:LauncherData 'config-backups'
    $name = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N') + '.toml'
    Write-Atomic (Join-Path $dir $name) $Text
}

function Set-SharedApi([string]$Url,[string]$Model,[string]$Key,[string]$CatalogPath = '',$Settings = $null) {
    $script:SwitchWriteStarted = $false
    $configPath = Join-Path $script:OfficialHome 'config.toml'
    $authPath = Join-Path $script:OfficialHome 'auth.json'
    $text = ''
    if (Test-Path -LiteralPath $configPath) { $text = [IO.File]::ReadAllText($configPath) }
    $authBefore = Get-LocalAuthFingerprint
    $state = Get-SwitchState
    Assert-ManagedConnection $state
    $previousImageBlock='';if($state -and $state.active -and $state.PSObject.Properties['image_mcp_block']){$previousImageBlock=[string]$state.image_mcp_block}
    $imagePlan=Get-OptionalImageIntegrationPlan $Settings
    $withoutImage=Remove-ManagedImageBlock $text $state -CheckCollision:([bool]$imagePlan.block)
    if($previousImageBlock -and $text -notmatch '(?m)^\s*\[[^\r\n]*codex_launcher_images[^\r\n]*\]' -and $imagePlan.block){
        $imagePlan.warning='检测到图片工具区段缺失，已按当前保存的图片设置重新建立。普通聊天配置保持有效。'
    }
    $parts = Split-Transport $withoutImage
    if ($state -and $state.active) { Upgrade-SwitchKeys $state $parts.managed }
    $officialTransport = $parts.managed
    if ($state -and $state.active) { $officialTransport = (Unprotect-LocalText $state.official_transport_encrypted).Substring(7) }
    $managed = New-ThirdPartyConfig $Url $Model $CatalogPath $Settings $officialTransport
    $nextConfig=Merge-Transport $withoutImage $managed
    # Own the separator too, so a user's unterminated final MCP line is restored exactly.
    if($imagePlan.block){if(-not $nextConfig.EndsWith("`n")){$imagePlan.block="`r`n"+$imagePlan.block};$nextConfig+=$imagePlan.block}
    if (-not $state -or -not $state.active) {
        $present = Test-Path -LiteralPath $authPath
        $auth = ''
        if ($present) { $auth = [Convert]::ToBase64String([IO.File]::ReadAllBytes($authPath)) }
        $state = [pscustomobject]@{
            version = 1; home = $script:OfficialHome; active = $true
            ui = $script:OfficialUi
            auth_present = $present; auth_encrypted = (Protect-LocalText ('backup:' + $auth))
            official_transport_encrypted = (Protect-LocalText ('backup:' + $parts.managed))
            official_config_encrypted = (Protect-LocalText ('backup:' + $text))
            managed_keys = $script:ManagedKeys
        }
        # Persist recoverable official credentials BEFORE changing either file.
        Save-OfficialRecoveryCopy $state
        Save-SwitchState $state
    }
    if($imagePlan.block -or $state.version -eq 2){$state.version=2}
    $state|Add-Member -NotePropertyName image_mcp_block -NotePropertyValue $imagePlan.block -Force
    $state|Add-Member -NotePropertyName image_runtime_path -NotePropertyValue $imagePlan.path -Force
    $state|Add-Member -NotePropertyName image_warning -NotePropertyValue $imagePlan.warning -Force
    $state|Add-Member -NotePropertyName image_previous_mcp_block -NotePropertyValue $previousImageBlock -Force
    $state | Add-Member -NotePropertyName phase -NotePropertyValue 'switching' -Force
    Save-SwitchState $state
    Save-ConfigBackup $text
    if ((Test-Path -LiteralPath $configPath) -and [IO.File]::ReadAllText($configPath) -ne $text) { throw '配置在切换期间发生变化，已停止写入。请保持其他配置工具关闭后再试。' }
    if ((Get-LocalAuthFingerprint) -ne $authBefore) { throw '登录在切换期间发生变化，已停止写入。请保持 Codex 关闭，检查登录后使用恢复入口。' }
    $script:SwitchWriteStarted = $true
    $nextAuth=@{ auth_mode = 'apikey'; OPENAI_API_KEY = $Key } | ConvertTo-Json
    Write-Atomic $authPath $nextAuth
    Write-Atomic $configPath $nextConfig
    # A successful write call is insufficient: keep the recoverable switching
    # checkpoint until both actual files match the intended transaction.
    if([IO.File]::ReadAllText($configPath) -cne $nextConfig -or [IO.File]::ReadAllText($authPath) -cne $nextAuth){
        throw '切换后的配置回读不一致，未标记完成。请保持 Codex 关闭并点击“恢复官方配置”；官方备份已保留。'
    }
    $state | Add-Member -NotePropertyName active_url -NotePropertyValue $Url -Force
    $state | Add-Member -NotePropertyName active_auth_hash -NotePropertyValue (Get-LocalAuthFingerprint) -Force
    $profileId = ''
    if ($Settings -and $Settings.PSObject.Properties['id']) { $profileId = $Settings.id }
    $state | Add-Member -NotePropertyName active_profile_id -NotePropertyValue $profileId -Force
    $state | Add-Member -NotePropertyName phase -NotePropertyValue 'ready' -Force
    $state.PSObject.Properties.Remove('image_previous_mcp_block')
    Save-SwitchState $state
}

function Restore-SharedOfficial([switch]$Force) {
    $script:RecoveryNotice='';$script:LastRecoveryDirectory='';$script:LastRecoveryPerformed=$false
    $state = Get-OfficialRestoreState -Force:$Force
    if (-not $state -or -not $state.active) { return }
    if (-not $Force) { Assert-ManagedConnection $state }
    $configPath = Join-Path $script:OfficialHome 'config.toml'
    $authPath = Join-Path $script:OfficialHome 'auth.json'
    $text = ''
    if (Test-Path -LiteralPath $configPath) { $text = [IO.File]::ReadAllText($configPath) }
    # Decode and validate every recovery value before the first write.
    $authBefore=Get-LocalAuthFingerprint
    $transportBackup=Unprotect-LocalText $state.official_transport_encrypted
    $authBackup=Unprotect-LocalText $state.auth_encrypted
    if(-not $transportBackup.StartsWith('backup:') -or -not $authBackup.StartsWith('backup:')){throw '官方恢复备份格式无效；当前文件未修改。'}
    $transport=$transportBackup.Substring(7);$auth=$authBackup.Substring(7)
    $authBytes=$null;if($state.auth_present){$authBytes=[Convert]::FromBase64String($auth);$null=([Text.Encoding]::UTF8.GetString($authBytes)|ConvertFrom-Json)}
    $script:RecoveryNotice=''
    try{
        if(-not(Test-Path -LiteralPath $configPath)){throw '当前配置文件缺失。'}
        if($state.PSObject.Properties['recovery_from_copy'] -and $state.recovery_from_copy){throw '切换记录已损坏，使用独立的完整官方快照。'}
        Upgrade-SwitchKeys $state (Split-Transport $text).managed
        $transport=(Unprotect-LocalText $state.official_transport_encrypted).Substring(7)
        $withoutImage=Remove-ManagedImageBlock $text $state
        $newConfig=Merge-Transport $withoutImage $transport
    }catch{
        if(-not $Force){throw}
        # Explicit emergency recovery: quarantine current files, then restore a
        # known official baseline rather than depending on the broken image guard.
        $baseline=Get-OfficialRecoveryBaseline $state
        if($null -eq $baseline){throw '未找到可验证的官方配置备份；原文件和登录备份均保留，不能编造官方配置。'}
        $newConfig=$baseline
        $script:RecoveryNotice='当前配置有冲突，已留存加密备份并恢复切换前的官方配置。其他工具后加的设置可从备份找回。'
    }
    $recoveryDirectory=Save-RecoveryCheckpoint $text $state
    Save-ConfigBackup $text
    if((Test-Path -LiteralPath $configPath) -and [IO.File]::ReadAllText($configPath) -cne $text){throw '恢复期间配置发生变化；备份已保留，请退出其他配置工具后再恢复。'}
    if((Get-LocalAuthFingerprint) -cne $authBefore){throw '恢复期间登录发生变化；备份已保留，请退出其他登录工具后再恢复。'}
    $state | Add-Member -NotePropertyName phase -NotePropertyValue 'restoring' -Force
    Save-SwitchState $state
    if ($state.auth_present) {
        # Auth JSON is restored byte-for-byte; encrypted backup stays available for recovery.
        $temporary = $authPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
        try {
            [IO.File]::WriteAllBytes($temporary,$authBytes)
            if (Test-Path -LiteralPath $authPath) {
                $previous = $temporary + '.previous'
                try { [IO.File]::Replace($temporary,$authPath,$previous,$true) }
                finally { if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous } }
            } else { [IO.File]::Move($temporary,$authPath) }
        } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
    } elseif (Test-Path -LiteralPath $authPath) { Remove-Item -LiteralPath $authPath }
    Write-Atomic $configPath $newConfig
    $authRestored=-not(Test-Path -LiteralPath $authPath)
    if($state.auth_present){$authRestored=(Test-Path -LiteralPath $authPath) -and ([Convert]::ToBase64String([IO.File]::ReadAllBytes($authPath)) -ceq $auth)}
    if([IO.File]::ReadAllText($configPath) -cne $newConfig -or -not $authRestored){
        throw '官方恢复后的文件回读不一致，未标记恢复成功。备份已保留；请保持 Codex 关闭后再次使用恢复入口。'
    }
    $state.active = $false
    $state.phase = 'ready'
    Save-SwitchState $state
    $script:LastRecoveryDirectory=$recoveryDirectory
    $script:LastRecoveryPerformed=$true
}

function Get-OfficialRecoveryBaseline($State) {
    if($State.PSObject.Properties['official_config_encrypted'] -and $State.official_config_encrypted){
        $value=Unprotect-LocalText $State.official_config_encrypted
        if(-not $value.StartsWith('backup:')){throw '官方配置备份格式无效。'}
        return $value.Substring(7)
    }
    # Legacy releases stored complete config checkpoints before every switch.
    # Accept only a checkpoint with the original transport and no assistant MCP.
    $transport=(Unprotect-LocalText $State.official_transport_encrypted).Substring(7).Replace("`r`n","`n")
    $directory=Join-Path $script:LauncherData 'config-backups'
    if(Test-Path -LiteralPath $directory){
        foreach($file in (Get-ChildItem -LiteralPath $directory -Filter '*.toml' -File|Sort-Object Name -Descending)){
            $candidate=[IO.File]::ReadAllText($file.FullName)
            try{$managed=(Split-Transport $candidate).managed.Replace("`r`n","`n")}catch{continue}
            if($managed -ceq $transport -and $candidate -notmatch '(?m)^\s*\[[^\r\n]*codex_launcher_images[^\r\n]*\]'){return $candidate}
        }
    }
    return $null
}

function Save-RecoveryCheckpoint([string]$Text,$State) {
    $directory=Join-Path $script:LauncherData ('recovery-checkpoints/'+[Guid]::NewGuid().ToString('N'))
    Write-Atomic (Join-Path $directory 'config.encrypted') (Protect-LocalText ('backup:'+$Text))
    Write-Atomic (Join-Path $directory 'state.json') ($State|ConvertTo-Json -Depth 8)
    $authPath=Join-Path $script:OfficialHome 'auth.json'
    if(Test-Path -LiteralPath $authPath){Write-Atomic (Join-Path $directory 'auth.encrypted') (Protect-LocalText ('backup:'+ [Convert]::ToBase64String([IO.File]::ReadAllBytes($authPath))))}
    return $directory
}

function New-LaunchInfo([string]$Exe, [string]$HomePath, [string]$UiPath = '') {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Exe
    $info.WorkingDirectory = Split-Path $Exe
    $info.UseShellExecute = $false
    # Changes apply only to this child process. No user or machine environment changes.
    foreach ($name in @('OPENAI_API_KEY','CODEX_API_KEY','OPENAI_BASE_URL','CODEX_ELECTRON_USER_DATA_PATH','CODEX_HOME')) {
        $info.EnvironmentVariables.Remove($name)
    }
    $info.EnvironmentVariables['CODEX_HOME'] = $HomePath
    if ($UiPath) { $info.EnvironmentVariables['CODEX_ELECTRON_USER_DATA_PATH'] = $UiPath }
    return $info
}

function Start-Desktop([string]$Exe, [string]$HomePath, [string]$UiPath = '') {
    $plan=Get-DesktopLaunchPlan $Exe $HomePath $UiPath
    if($plan.kind -eq 'registered'){
        if(-not ('CodexDesktopActivation' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'DesktopActivation.cs')}
        try{return [CodexDesktopActivation]::Activate($plan.app_id)}
        catch{throw 'Windows 官方应用入口启动失败。请从开始菜单正常打开 Codex；启动器保留恢复备份，不会重复启动另一实例。'}
    }
    $info = New-LaunchInfo $Exe $HomePath $UiPath
    $process = [Diagnostics.Process]::Start($info)
    if (-not $process) { throw '未能启动桌面程序。请使用“启动官方模式”恢复。' }
    return $process.Id
}

function Invoke-ExclusiveSwitch([scriptblock]$Action) {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex = [Threading.Mutex]::new($false,('Local\CodexLauncherSwitch-' + $sid))
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw '另一个启动器正在切换，请等它完成后再操作。' }
        return & $Action
    }
    finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

function Start-ThirdParty([string]$Url, [string]$Model, [string]$EnteredKey,$Profile = $null) {
    return Invoke-ExclusiveSwitch { Start-ThirdPartyInternal $Url $Model $EnteredKey $Profile }
}

function Start-ThirdPartyInternal([string]$Url, [string]$Model, [string]$EnteredKey,$Profile = $null) {
    Assert-ResolvedDataPaths -Api
    $exe = Get-DesktopExe
    Assert-DesktopClosed $exe
    Assert-ManagedConnection (Get-SwitchState)
    $url = Normalize-Endpoint $Url
    $model = $Model.Trim()
    $catalogPath = Join-Path $script:LauncherData 'native-models.json'
    $catalogEndpoint = Join-Path $script:LauncherData 'native-models-endpoint.txt'
    if ($Profile) {
        if ($Profile.id -notmatch '^[a-f0-9]{32}$') { throw '接口标识无效。' }
        $catalogPath = Join-Path $script:LauncherData ('catalogs\' + $Profile.id + '.json')
        $catalogEndpoint = Join-Path $script:LauncherData ('catalogs\' + $Profile.id + '-endpoint.txt')
    }
    $useCatalog = ''
    if ((Test-Path -LiteralPath $catalogPath) -and (Test-Path -LiteralPath $catalogEndpoint) -and [IO.File]::ReadAllText($catalogEndpoint).Trim() -eq $url) {
        $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (@($catalog.models).Count -and (-not $Profile -or @($Profile.models).Count)) { $useCatalog = $catalogPath }
    }
    $null = New-ThirdPartyConfig $url $model $useCatalog
    $credential = $Profile
    if (-not $Profile) { $credential = Get-Preferences }
    $key = Get-LocalKey $credential $url $EnteredKey
    $script:SwitchWriteStarted = $false
    $httpBridge=$null
    try {
        Assert-DesktopClosed $exe
        Save-Preferences $url $model $key
        # A retry from API mode cannot discover account-managed source plugins.
        # Restore the existing official baseline in the SAME home before querying.
        $priorSwitch=Get-SwitchState
        if($priorSwitch -and $priorSwitch.active){Restore-SharedOfficial -Force}
        $portablePlugins=@();$script:PluginSharingNotice='';$script:ConfirmedLocalPlugins=@();$script:UnconfirmedLocalPlugins=@();$script:PluginSourceStatus='unobserved';$script:PluginSourceMode='unknown';$script:PluginSourceInstalled=@();$script:PluginSourceCandidates=@()
        try{
            $inventory=Invoke-PluginInventory (Join-Path (Split-Path $exe) 'resources/codex.exe')
            $script:PluginSourceMode=$inventory.identity.mode
            $script:PluginSourceInstalled=@($inventory.plugins|Where-Object{$_.installed -and $_.enabled -and $_.name -match '^[a-z0-9][a-z0-9-]{0,79}$'}|ForEach-Object name)
            if($inventory.identity.native_auth_status -eq 'pass' -and $inventory.plugins_status -eq 'pass' -and $inventory.skills_status -eq 'pass'){
                $script:PluginSourceStatus='pass';$portablePlugins=@(Get-PortableSharedPlugins $inventory)
                $script:PluginSourceCandidates=@($portablePlugins|ForEach-Object name)
                Save-CompatibilityReport $inventory
                if(-not $portablePlugins.Count){$script:PluginSharingNotice='本次 '+$inventory.identity.mode+' 来源检查未找到可自动共享的纯技能插件；尚未进行安装。API 可启动，账号连接仍需单独核对。'}
            }else{$script:PluginSharingNotice='插件清单或技能发现未完成，尚未进行自动安装；API 可启动。请在启动摘要查看详情。'}
        }catch{$script:PluginSharingNotice=('尚未进行插件共享：'+(Get-CompatibilityFailureMessage $_))}
        $useCatalog=Get-HttpCompatibilityCatalog $useCatalog $model
        $httpBridge=Start-HttpCompatibility $url $key
        Set-SharedApi $httpBridge.url $model $httpBridge.token $useCatalog $Profile
        if($portablePlugins.Count){Install-PortableSharedPlugins $portablePlugins (Join-Path (Split-Path $exe) 'resources/codex.exe')}
        try{Save-PluginSharingResult}catch{$script:PluginSharingNotice+=' 本次检查记录未能保存，可重新检查。'}
        $desktopId=Start-Desktop $exe $script:OfficialHome $script:OfficialUi
        $httpBridge.process.StandardInput.WriteLine(([string]$desktopId))
        $httpBridge.process.StandardInput.Flush()
        $httpBridge.process.StandardInput.Close()
        $httpBridge.process.Dispose()
        $httpBridge=$null
        return $desktopId
    }
    catch {
        # Any interrupted/failed write has a durable recovery snapshot.
        if ($script:SwitchWriteStarted) {
            try { Restore-SharedOfficial -Force } catch { throw '启动失败，自动恢复也未完成。请保持 Codex 关闭，再点“恢复官方配置”恢复；加密备份仍保留。' }
        }
        throw
    }
    finally { $key = $null;if($httpBridge){Stop-HttpCompatibility $httpBridge} }
}

function Start-Official {
    return Invoke-ExclusiveSwitch { Start-OfficialInternal }
}

function Start-OfficialInternal {
    $script:CanResetOfficial=$false
    Assert-DesktopClosed $script:DesktopOverride
    Resolve-OfficialRecoveryTarget
    try{Restore-SharedOfficial -Force}catch{$script:CanResetOfficial=$true;throw}
    $exe = Get-OfficialDesktopExe
    return Start-Desktop $exe $script:OfficialHome $script:OfficialUi
}

function Restore-OfficialOnly([switch]$Force) {
    $script:CanResetOfficial=$false
    Invoke-ExclusiveSwitch {
        Assert-DesktopClosed $script:DesktopOverride
        Resolve-OfficialRecoveryTarget
        try{Restore-SharedOfficial -Force:$Force}catch{$script:CanResetOfficial=$true;throw}
    }
}

function Reset-OfficialConnection([switch]$Confirmed) {
    if(-not $Confirmed){throw '重置官方连接需要明确确认。'}
    Invoke-ExclusiveSwitch {
        Assert-DesktopClosed $script:DesktopOverride
        Resolve-OfficialRecoveryTarget
        if(-not(Test-Path -LiteralPath $script:OfficialHome -PathType Container)){throw '原聊天目录不存在，请接回磁盘后再试。'}
        $configPath=Join-Path $script:OfficialHome 'config.toml';$authPath=Join-Path $script:OfficialHome 'auth.json'
        $text='';if(Test-Path -LiteralPath $configPath){$text=[IO.File]::ReadAllText($configPath)}
        $authBefore=Get-LocalAuthFingerprint
        $directory=Save-RecoveryCheckpoint $text ([pscustomobject]@{version=1;home=$script:OfficialHome;action='reset-official-login'})
        if(Test-Path -LiteralPath $script:SwitchFile){Write-Atomic (Join-Path $directory 'switch.encrypted') (Protect-LocalText ('backup:'+ [IO.File]::ReadAllText($script:SwitchFile)))}
        if(((Test-Path -LiteralPath $configPath) -and [IO.File]::ReadAllText($configPath) -cne $text) -or (Get-LocalAuthFingerprint) -cne $authBefore){throw '文件正在被其他程序修改；备份已保留，请正常退出其他配置程序后重试。'}
        $official="model_provider = `"openai`"`nforced_login_method = `"chatgpt`"`ncli_auth_credentials_store = `"file`"`n"
        $state=[pscustomobject]@{version=2;home=$script:OfficialHome;ui=$script:OfficialUi;active=$true;phase='restoring';auth_present=$false;auth_encrypted=(Protect-LocalText 'backup:');official_transport_encrypted=(Protect-LocalText ('backup:'+$official));official_config_encrypted=(Protect-LocalText ('backup:'+$official));managed_keys=$script:ManagedKeys}
        Save-OfficialRecoveryCopy $state
        Write-Atomic $script:SwitchFile ($state|ConvertTo-Json -Depth 8)
        Write-Atomic $configPath $official
        if(Test-Path -LiteralPath $authPath){[IO.File]::Delete($authPath)}
        if([IO.File]::ReadAllText($configPath) -cne $official -or (Test-Path -LiteralPath $authPath)){throw '重置尚未完成；备份保留，请再次使用恢复入口。'}
        $state.active=$false;$state.phase='ready';Save-SwitchState $state
        $script:RecoveryNotice='连接已重置为官方，请在 Codex 中重新登录。原配置与登录已加密备份，聊天和项目未删除。'
        $script:LastRecoveryDirectory=$directory;$script:LastRecoveryPerformed=$true
    }
}

function Read-Models([string]$Url, [string]$EnteredKey) {
    $url = Normalize-Endpoint $Url
    $key = Get-LocalKey (Get-Preferences) $url $EnteredKey
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $response = Invoke-RestMethod -Method Get -Uri ($url + '/models') -Headers @{ Authorization = 'Bearer ' + $key } -TimeoutSec 12 -MaximumRedirection 0
        $ids = @($response.data | ForEach-Object { [string]$_.id } | Where-Object { $_ -and $_.Length -le 200 -and $_ -notmatch '[\r\n\x00-\x1f]' } | Sort-Object -Unique)
        if (-not $ids.Count) { throw 'empty' }
        return $ids
    }
    catch { throw '未能读取模型列表：请检查接口、Key 和网络。也可以手动填入服务商提供的模型名。' }
    finally { $key = $null }
}

. (Join-Path $PSScriptRoot 'Launcher.Images.ps1')

. (Join-Path $PSScriptRoot 'Launcher.Compatibility.ps1')
