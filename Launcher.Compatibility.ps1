# Safe projections of native inventory. No chat bodies or authentication tokens are retained.
function Get-CompatibilityFailureMessage($Failure) {
    $exception=$Failure.Exception
    while($exception.InnerException){$exception=$exception.InnerException}
    if($exception -is [TimeoutException]){return '原生插件检查超时；未取得有效结果，请稍后重试。不能据此判断插件没有共享。'}
    if($exception -is [IO.IOException]){return '检查用的原生引擎提前退出；插件状态尚未确认。普通聊天和官方恢复仍可使用。'}
    if($Failure.Exception -is [Management.Automation.MethodInvocationException]){return ('后台检查程序报错（'+$exception.GetType().Name+'）；插件状态尚未确认。普通聊天和官方恢复仍可使用。')}
    return $Failure.Exception.Message
}
function New-CompatibilityProbe {
    if(-not ('CodexNativeProbe' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'NativeProbe.cs') -ReferencedAssemblies 'System','System.Core','System.Web.Extensions'}
    return [CodexNativeProbe]::new()
}
function Get-CompatibilityIdentity([string]$Cwd) {
    $mode='official';$state=Get-SwitchState;if($state -and $state.active){$mode='api'};$configuredMode=$mode
    $authPath=Join-Path $script:OfficialHome 'auth.json'
    if(Test-Path -LiteralPath $authPath){try{$kind=(Get-Content -LiteralPath $authPath -Raw -Encoding UTF8|ConvertFrom-Json).auth_mode;if($kind -eq 'apikey'){$mode='api'}elseif($kind -match '^chatgpt'){$mode='official'}}catch{}}
    return [pscustomobject]@{mode=$mode;configured_mode=$configuredMode;home=$script:OfficialHome;ui=$script:OfficialUi;cwd=$Cwd;observed_at=[DateTime]::UtcNow.ToString('o')}
}
function Convert-CompatibilityReport($Raw,$Identity) {
    $Identity=$Identity|ConvertTo-Json|ConvertFrom-Json
    $nativeMode='unknown';switch(([string]$Raw.account.type).ToLowerInvariant()){'chatgpt'{$nativeMode='official'}'chatgptauthtokens'{$nativeMode='official'}'apikey'{$nativeMode='api'}}
    $configuredMode=$Identity.mode;if($Identity.PSObject.Properties['configured_mode']){$configuredMode=$Identity.configured_mode}
    $Identity|Add-Member -NotePropertyName configured_mode -NotePropertyValue $configuredMode -Force
    $Identity|Add-Member -NotePropertyName native_auth_status -NotePropertyValue $(if($nativeMode -eq 'unknown'){'unobserved'}else{'pass'}) -Force
    $Identity.mode=$nativeMode
    $plugins=@();foreach($market in @($Raw.plugins.marketplaces)){if(-not $market){continue};foreach($p in @($market.plugins)){
        $plugins+=@([pscustomobject]@{id=$p.id;name=$p.name;installed=[bool]$p.installed;enabled=[bool]$p.enabled;availability=$p.availability;disabled_reason=$p.disabledReason;source_type=$p.source.type;source_path=$p.source.path;marketplace_name=$market.name;marketplace_path=$market.path})
    }}
    $skills=@();foreach($entry in @($Raw.skills.data)){foreach($skill in @($entry.skills)){if($skill){$skills+=@([pscustomobject]@{name=$skill.name;path=$skill.path;scope=$skill.scope;enabled=[bool]$skill.enabled;plugin_id=$skill.pluginId})}}}
    $mcp=@();foreach($server in @($Raw.mcp.data)){if($server){$mcp+=@([pscustomobject]@{name=$server.name;plugin_id=$server.pluginId;auth_status=$server.authStatus;runtime_status=$server.runtimeStatus;tool_count=@($server.tools.PSObject.Properties).Count;call_status='unobserved'})}}
    $apps=@();foreach($app in @($Raw.apps.apps)){if($app){$apps+=@([pscustomobject]@{id=$app.id;name=$app.runtimeName;enabled=[bool]$app.enabled;model_visible=[bool]$app.callable;call_status='unobserved'})}}
    $marketErrors=@($Raw.plugins.marketplaceLoadErrors|Where-Object{$_}).Count
    $skillErrors=@($Raw.skills.data|ForEach-Object{$_.errors}|Where-Object{$_}).Count
    $repairStatus='unobserved';$failureKind=''
    if($Raw.PSObject.Properties['repair']){
        if($Raw.repair.query_status -in @('unobserved','blocked','fail')){$repairStatus=$Raw.repair.query_status}else{$repairStatus='pass'}
        if($Raw.repair.failure_kind -eq 'native_api_catalog_auth'){$failureKind='native_api_catalog_auth'}
    }
    return [pscustomobject]@{version=2;identity=$Identity;repair_status=$repairStatus;repair_failure_kind=$failureKind;plugins_status=$(if($Raw.plugins -and $Raw.plugins.PSObject.Properties['marketplaces'] -and -not $marketErrors){'pass'}else{'unobserved'});skills_status=$(if($Raw.skills -and $Raw.skills.PSObject.Properties['data'] -and -not $skillErrors){'pass'}else{'unobserved'});mcp_status=$(if($Raw.mcp -and $Raw.mcp.PSObject.Properties['data'] -and -not $Raw.mcp.nextCursor){'pass'}else{'unobserved'});apps_status=$(if($Raw.apps -and $Raw.apps.PSObject.Properties['apps']){'pass'}else{'unobserved'});plugins=$plugins;skills=$skills;mcp=$mcp;apps=$apps}
}
function Test-PluginPresent($Plugin,$Report) {
    if(@($Report.plugins|Where-Object{$_.installed -and $_.id -eq $Plugin.id}).Count){return $true}
    # A verified pure-skill local copy has a different native ID from its remote source.
    return ($Report.skills_status -eq 'pass' -and
        @($Report.plugins|Where-Object{$_.installed -and $_.enabled -and $_.name -eq $Plugin.name -and $_.source_type -eq 'local' -and $_.marketplace_name -eq ('codex-launcher-local-'+$Plugin.name)}).Count -gt 0 -and
        @($Report.skills|Where-Object{$_.enabled -and $_.name -like ($Plugin.name+':*')}).Count -gt 0)
}
function Get-CompatibilityFindings($Report,$Previous=$null) {
    $lines=@('本次：'+$Report.identity.mode+' · '+$Report.identity.observed_at,'数据目录：'+$Report.identity.home,'界面目录：'+$Report.identity.ui,'技能检查范围：'+$Report.identity.cwd)
    $lastDetail=Get-LastPluginSharingDetail;if($lastDetail){$lines+=$lastDetail}
    if($Report.identity.native_auth_status -ne 'pass'){$lines+='原生登录方式未确认；本次不能作为两种模式共享的证据。'}elseif($Report.identity.configured_mode -ne $Report.identity.mode){$lines+='切换记录与原生登录不一致；按原生登录方式归类，不把本次当作另一模式检查。'}
    if($Previous){
        if($Previous.identity.home -ine $Report.identity.home -or $Previous.identity.ui -ine $Report.identity.ui){$lines+='目录不一致：请在环境设置选择原来的目录，不复制聊天数据库。'}
        elseif($Previous.identity.cwd -ine $Report.identity.cwd){$lines+='两种模式项目范围不同：请选同一项目后重新检查。'}
        else{
            $lines+='两种模式使用相同本地目录；这不代表插件授权或调用成功。'
            if($Report.plugins_status -eq 'pass' -and $Previous.plugins_status -eq 'pass'){
                foreach($p in @($Previous.plugins|Where-Object installed)){if(-not(Test-PluginPresent $p $Report)){$lines+='安装记录缺失：'+$p.name+'；上一模式已安装。账号管理插件请在官方插件页核对，本地插件可检查登记。'}}
            }
        }
    }else{$lines+='另一模式尚未检查：正常切换后点同一检查按钮，才能比较两种模式。'}
    $lines+='';$lines+='原生安装清单：'+$Report.plugins_status+'；技能发现：'+$Report.skills_status+'；MCP 清单：'+$Report.mcp_status
    foreach($p in @($Report.plugins)){
        $state='未安装';if($p.installed){$state='已安装'};if($p.installed -and -not $p.enabled){$state+=' · 已停用'}elseif($p.installed){$state+=' · 已启用'}
        if($p.availability -and $p.availability -ne 'AVAILABLE'){$state+=' · 登录/服务能力限制（'+$p.availability+'）'}
        $lines+=($p.name+'（'+$p.source_type+'）'+ '：'+$state+'；调用未观察')
    }
    if($Report.plugins_status -ne 'pass'){$lines+='原生插件清单未取得，原因未确认；查询失败不代表插件没有安装。'}
    foreach($group in @($Report.plugins|Group-Object name)){
        if(@($group.Group|Where-Object{$_.installed -and $_.source_type -eq 'remote'}).Count -and @($group.Group|Where-Object{$_.source_type -eq 'local' -and -not $_.installed}).Count){$lines+=$group.Name+' 来源不同：账号管理版本已安装，本地市场版本尚未安装，是两份安装记录。市场可搜索不代表已安装；外部连接与实际调用仍需单独核对。'}
    }
    $lines+='';$lines+='技能：'+@($Report.skills).Count+' 个；已启用 '+@($Report.skills|Where-Object enabled).Count+' 个。'
    foreach($skill in @($Report.skills)){$lines+=($skill.name+' · '+$skill.scope+' · '+$(if($skill.enabled){'启用'}else{'停用'})+' · '+$skill.path)}
    foreach($server in @($Report.mcp)){$lines+=('MCP '+$server.name+'：认证 '+$server.auth_status+'；发现工具 '+$server.tool_count+'；实际调用未观察。')}
    $lines+='App 运行快照：'+$Report.apps_status+'（独立检查进程，不能代替当前桌面聊天的运行状态）。'
    foreach($app in @($Report.apps)){$lines+=('App '+$app.name+'：'+$(if($app.enabled){'启用'}else{'停用'})+'；'+$(if($app.model_visible){'工具可见'}else{'工具未就绪，需要连接或进一步核对'})+'；实际调用未观察。')}
    $dependencies=@(Get-PluginAppDependencies $Report)
    foreach($dependency in $dependencies){
        $visible=@($Report.apps|Where-Object{$_.id -eq $dependency.app_id -and $_.model_visible}).Count -gt 0
        $lines+=($dependency.plugin+' 依赖 App '+$dependency.app_id+'：'+$(if($visible){'本次工具可见，调用未观察'}else{'本次未就绪，请在官方插件页检查连接；不据此断定 API 登录被禁止'}))
    }
    if(@($dependencies|Where-Object{$dep=$_;-not @($Report.apps|Where-Object{$_.id -eq $dep.app_id -and $_.model_visible}).Count}).Count){$lines+='有插件连接尚未就绪，请在 Codex 插件页核对所需 App；市场可搜索不等于可调用。'}
    return $lines -join "`r`n"
}
function Get-PluginAppDependencies($Report) {
    $cache=[IO.Path]::Combine([string]$Report.identity.home,'plugins/cache');$result=@()
    if(-not(Test-Path -LiteralPath $cache -PathType Container)){return @()}
    foreach($market in @(Get-ChildItem -LiteralPath $cache -Directory -ErrorAction SilentlyContinue)){
        foreach($p in @($Report.plugins|Where-Object installed|Group-Object name|ForEach-Object{$_.Group[0]})){
            if($p.name -notmatch '^[A-Za-z0-9_-]{1,100}$'){continue}
            $pluginDir=Join-Path $market.FullName $p.name
            if(-not(Test-Path -LiteralPath $pluginDir -PathType Container)){continue}
            foreach($version in @(Get-ChildItem -LiteralPath $pluginDir -Directory -ErrorAction SilentlyContinue)){
                $manifest=Join-Path $version.FullName '.app.json';if(-not(Test-Path -LiteralPath $manifest -PathType Leaf)){continue}
                try{$apps=(Get-Content -LiteralPath $manifest -Raw -Encoding UTF8|ConvertFrom-Json).apps
                    foreach($property in @($apps.PSObject.Properties)){if($property.Value.id){$result+=@([pscustomobject]@{plugin=$p.name;app_id=$property.Value.id;required=[bool]$property.Value.required})}}
                }catch{}
            }
        }
    }
    return @($result|Sort-Object plugin,app_id -Unique)
}
function Get-CompatibilitySummary($Report,$Previous=$null) {
    $queryLabel='未完成';if($Report.plugins_status -eq 'pass'){$queryLabel='已查询'}
    $skillLabel='未完成';if($Report.skills_status -eq 'pass'){$skillLabel=([string]@($Report.skills).Count)+' 个'}
    $lines=@('插件清单：'+$queryLabel+' · 技能发现：'+$skillLabel+' · 实际调用：未观察')
    if($Report.plugins_status -eq 'pass'){$lines+='已安装 '+@($Report.plugins|Where-Object installed).Count+' 个来源记录；已启用 '+@($Report.plugins|Where-Object{$_.installed -and $_.enabled}).Count+' 个。'}
    if($Report.identity.native_auth_status -ne 'pass'){$lines+='登录方式未确认：尚不能判断官方与 API 的共享情况。'}elseif($Report.identity.configured_mode -ne $Report.identity.mode){$lines+='切换记录与实际登录不同；本次按原生登录归类。'}
    if(-not $Previous){$lines+='另一模式还没有有效检查，正常切换后再点一次即可比较。'}
    elseif($Report.identity.home -ine $Previous.identity.home -or $Report.identity.ui -ine $Previous.identity.ui){$lines+='目录不一致，请在环境设置选择同一份数据。'}
    elseif($Report.identity.cwd -ine $Previous.identity.cwd){$lines+='项目范围不同，请选择同一项目再检查。'}
    elseif($Report.plugins_status -eq 'pass' -and $Previous.plugins_status -eq 'pass'){
        $missing=@($Previous.plugins|Where-Object{$_.installed -and -not(Test-PluginPresent $_ $Report)})
        $lines+='本地目录一致；'+$missing.Count+' 个已安装插件未出现在本次安装清单。'
    }else{$lines+='部分查询未观察，暂不能判断两种模式的安装差异。'}
    $differentSources=@($Report.plugins|Group-Object name|Where-Object{@($_.Group|Where-Object{$_.installed -and $_.source_type -eq 'remote'}).Count -and @($_.Group|Where-Object{$_.source_type -eq 'local' -and -not $_.installed}).Count})
    if($differentSources.Count){$lines+='有 '+$differentSources.Count+' 个插件存在账号版本与本地版本两份安装记录；具体来源见明细。'}
    if(@(Get-LocalPluginRepairCandidates $Report $Previous).Count){$lines+='可为下方所选插件登记本地版本；安装后仍需核对连接和调用。'}
    $shared=@($Report.plugins|Where-Object{$_.installed -and $_.enabled -and $_.source_type -eq 'local' -and $_.marketplace_name -eq ('codex-launcher-local-'+$_.name)}|ForEach-Object name)
    if($shared.Count){$lines+='助手本地版本：'+$shared.Count+' 个已安装并启用；完整名单见明细，页面显示与实际调用仍需核对。'}
    return $lines -join "`r`n"
}
function Save-CompatibilityReport($Report) {
    if($Report.identity.native_auth_status -ne 'pass'){return}
    $dir=Join-Path $script:LauncherData 'compatibility';$path=Join-Path $dir ($Report.identity.mode+'.json')
    Write-Atomic $path ($Report|ConvertTo-Json -Depth 14)
}
function Get-PreviousCompatibilityReport($Identity) {
    if($Identity.native_auth_status -ne 'pass'){return $null}
    $other='api';if($Identity.mode -eq 'api'){$other='official'}
    $path=Join-Path $script:LauncherData ('compatibility/'+$other+'.json')
    if(Test-Path -LiteralPath $path){try{$report=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json;if($report.version -eq 2 -and $report.identity.native_auth_status -eq 'pass' -and $report.identity.mode -eq $other -and $report.identity.home -and $report.identity.ui -and $report.identity.cwd){return $report}}catch{}}
    return $null
}
function Get-LocalPluginRepairCandidates($Report,$Previous) {
    if($Report.repair_failure_kind -eq 'native_api_catalog_auth'){return @()}
    if(-not $Previous -or $Report.identity.native_auth_status -ne 'pass' -or $Previous.identity.native_auth_status -ne 'pass' -or $Report.identity.mode -eq $Previous.identity.mode -or $Report.plugins_status -ne 'pass' -or $Previous.plugins_status -ne 'pass' -or $Report.identity.home -ine $Previous.identity.home -or $Report.identity.ui -ine $Previous.identity.ui -or $Report.identity.cwd -ine $Previous.identity.cwd){return @()}
    $candidates=@($Previous.plugins|Where-Object{$_.installed -and $_.enabled -and $_.source_type -eq 'local' -and $_.marketplace_path -and (Test-Path -LiteralPath $_.marketplace_path -PathType Leaf) -and $_.id -notin @($Report.plugins|Where-Object installed|ForEach-Object id)})
    if($Report.identity.mode -eq 'api' -and $Previous.identity.mode -eq 'official'){
        # Account installation cannot be copied. Offer the current API catalog's
        # explicit local entry for the same plugin, only after verified comparison.
        $accountNames=@($Previous.plugins|Where-Object{$_.installed -and $_.enabled -and $_.source_type -eq 'remote'}|ForEach-Object name)
        $installedNames=@($Report.plugins|Where-Object installed|ForEach-Object name)
        $candidates+=@($Report.plugins|Where-Object{$_.name -in $accountNames -and $_.name -notin $installedNames -and -not $_.installed -and $_.source_type -eq 'local' -and $_.availability -eq 'AVAILABLE' -and $_.marketplace_path -and (Test-Path -LiteralPath $_.marketplace_path -PathType Leaf)})
    }
    return @($candidates|Sort-Object id -Unique)
}
function New-LocalPluginRepairPlan($Plugin,[string]$ExpectedMode) {
    if($Plugin.source_type -ne 'local' -or -not $Plugin.marketplace_path -or -not(Test-Path -LiteralPath $Plugin.marketplace_path -PathType Leaf)){throw '只支持有明确本地市场来源的登记修复；账号管理插件请在官方页面连接。'}
    if($ExpectedMode -notin @('official','api')){throw '安装前必须确认原生登录方式，请重新检查。'}
    $marketName=[string]$Plugin.marketplace_name
    if(-not $marketName){try{$marketName=[string](Get-Content -LiteralPath $Plugin.marketplace_path -Raw -Encoding UTF8|ConvertFrom-Json).name}catch{throw '市场来源无法读取，请重新检查后操作。'}}
    $plan=[pscustomobject]@{pluginName=$Plugin.name;marketplacePath=$Plugin.marketplace_path;installAttemptId=[Guid]::NewGuid().ToString('N');launcherExpectedMode=$ExpectedMode}
    # The native catalog exposes a cached path for curated plugins, but that
    # reserved marketplace must be installed through its official remote route.
    if($marketName -eq 'openai-curated'){$plan.marketplacePath=$null;$plan|Add-Member -NotePropertyName remoteMarketplaceName -NotePropertyValue $marketName}
    return $plan
}

function Get-PortableSharedPlugins($Report) {
    if($Report.identity.native_auth_status -ne 'pass' -or $Report.plugins_status -ne 'pass' -or $Report.skills_status -ne 'pass'){return @()}
    $installed=@($Report.plugins|Where-Object{$_.installed -and $_.enabled}|ForEach-Object name)
    $roots=@()
    $cache=[IO.Path]::GetFullPath((Join-Path $Report.identity.home 'plugins/cache')).TrimEnd('\')+'\'
    foreach($skill in @($Report.skills|Where-Object enabled)){
        if(-not $skill.path){continue}
        if($skill.plugin_id -like '*@codex-launcher-local-*'){continue}
        try{
            $path=[IO.Path]::GetFullPath([string]$skill.path)
            if(-not $path.StartsWith($cache,[StringComparison]::OrdinalIgnoreCase)){continue}
            $directory=Get-Item -LiteralPath $path -ErrorAction Stop
            if(-not $directory.PSIsContainer){$directory=$directory.Directory}
            while($directory -and $directory.FullName.StartsWith($cache,[StringComparison]::OrdinalIgnoreCase)){
                $manifestPath=Join-Path $directory.FullName '.codex-plugin/plugin.json'
                if(Test-Path -LiteralPath $manifestPath){
                    $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
                    if($manifest.name -in $installed -and $manifest.name -match '^[a-z0-9][a-z0-9-]{0,79}$' -and $manifest.license -eq 'MIT' -and $manifest.skills -eq './skills/' -and -not $manifest.apps -and -not $manifest.mcpServers -and -not $manifest.hooks -and (Test-Path -LiteralPath (Join-Path $directory.FullName 'LICENSE')) -and -not(Test-Path -LiteralPath (Join-Path $directory.FullName '.app.json')) -and -not(Test-Path -LiteralPath (Join-Path $directory.FullName '.mcp.json')) -and -not(Test-Path -LiteralPath (Join-Path $directory.FullName 'mcp.json'))){
                        $roots+=@([pscustomobject]@{name=$manifest.name;version=$manifest.version;source_path=$directory.FullName})
                    }
                    break
                }
                $directory=$directory.Parent
            }
        }catch{continue}
    }
    return @($roots|Sort-Object name,source_path -Unique|Group-Object name|Where-Object Count -eq 1|ForEach-Object{$_.Group[0]})
}

function Get-PortableManifestContent($Manifest) {
    $local=$Manifest|ConvertTo-Json -Depth 32|ConvertFrom-Json
    $label=[string]$local.interface.displayName;if(-not $label.Trim()){$label=[string]$local.name}
    if(-not $local.interface){$local|Add-Member -NotePropertyName interface -NotePropertyValue ([pscustomobject]@{}) -Force}
    $local.interface|Add-Member -NotePropertyName displayName -NotePropertyValue ($label+' · 本地共享') -Force
    return ($local|ConvertTo-Json -Depth 32)
}
function Test-PortablePackageFiles($Files,[string]$Origin,[string]$Package,[string]$ManifestContent) {
    if(-not(Test-Path -LiteralPath $Package -PathType Container)){return $false}
    $parent=Get-Item -LiteralPath $Package
    while($parent){if($parent.Attributes -band [IO.FileAttributes]::ReparsePoint){return $false};$parent=$parent.Parent}
    $copies=@(Get-ChildItem -LiteralPath $Package -File -Recurse -Force)
    if($copies.Count -ne @($Files).Count -or @($copies|Where-Object{$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){return $false}
    foreach($file in $Files){
        $relative=$file.FullName.Substring($Origin.Length+1);$destination=Join-Path $Package $relative
        if(-not(Test-Path -LiteralPath $destination -PathType Leaf)){return $false}
        foreach($candidate in @($file,(Get-Item -LiteralPath $destination))){
            if($candidate.Attributes -band [IO.FileAttributes]::ReparsePoint){return $false}
            $parent=$candidate.Directory;while($parent){if($parent.Attributes -band [IO.FileAttributes]::ReparsePoint){return $false};$parent=$parent.Parent}
        }
        if($relative -eq '.codex-plugin\plugin.json' -and [IO.File]::ReadAllText($destination) -ceq $ManifestContent){continue}
        if((Get-FileHash -LiteralPath $destination).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash){return $false}
    }
    return $true
}
function Set-PortablePackageLabel([string]$Package,[string]$ManifestContent) {
    $path=Join-Path $Package '.codex-plugin/plugin.json'
    if([IO.File]::ReadAllText($path) -ceq $ManifestContent){return 0}
    $backup=Join-Path $script:LauncherData ('portable-plugin-label-backups/'+[Guid]::NewGuid().ToString('N')+'.json')
    New-Item -ItemType Directory -Path (Split-Path $backup) -Force|Out-Null
    Copy-Item -LiteralPath $path -Destination $backup
    if((Get-FileHash -LiteralPath $backup).Hash -ne (Get-FileHash -LiteralPath $path).Hash){throw '本地插件名称备份未能完成；原名称保留。'}
    Write-Atomic $path $ManifestContent
    if([IO.File]::ReadAllText($path) -cne $ManifestContent){throw '本地插件显示名称未能保存；连接仍可使用。'}
    return 1
}
function Update-PortablePluginLabels {
    $indexPath=Join-Path $script:LauncherData 'portable-plugins/index.json'
    if(-not(Test-Path -LiteralPath $indexPath)){return 0}
    $changed=0;$index=@(Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8|ConvertFrom-Json)
    $ownedRoot=[IO.Path]::GetFullPath((Join-Path $script:LauncherData 'portable-plugins')).TrimEnd('\')+'\'
    $sourceRoot=[IO.Path]::GetFullPath((Join-Path $script:OfficialHome 'plugins/cache')).TrimEnd('\')+'\'
    foreach($entry in $index){
        if($entry.name -notmatch '^[a-z0-9][a-z0-9-]{0,79}$'){continue}
        $root=[IO.Path]::GetFullPath([string]$entry.root);$origin=[IO.Path]::GetFullPath([string]$entry.source).TrimEnd('\')
        if(-not $root.StartsWith($ownedRoot,[StringComparison]::OrdinalIgnoreCase) -or -not $origin.StartsWith($sourceRoot,[StringComparison]::OrdinalIgnoreCase)){continue}
        $provenance=Get-Content -LiteralPath (Join-Path $root 'provenance.json') -Raw -Encoding UTF8|ConvertFrom-Json
        if($provenance.kind -ne 'local-skills-copy' -or $provenance.name -cne $entry.name -or $provenance.source -ine $origin){continue}
        $manifest=Get-Content -LiteralPath (Join-Path $origin '.codex-plugin/plugin.json') -Raw -Encoding UTF8|ConvertFrom-Json
        if($manifest.name -cne $entry.name -or $manifest.license -ne 'MIT' -or $manifest.skills -ne './skills/' -or $manifest.apps -or $manifest.mcpServers -or $manifest.hooks){continue}
        $content=Get-PortableManifestContent $manifest
        $files=@(Get-ChildItem -LiteralPath $origin -File -Recurse -Force|Where-Object{$relative=$_.FullName.Substring($origin.Length+1);$relative -match '^(skills\\|assets\\|\.codex-plugin\\)' -or $relative -in @('LICENSE','PRIVACY.md','TERMS.md','PROVENANCE.md')})
        $package=Join-Path $root ('plugins/'+$entry.name)
        if(-not(Test-PortablePackageFiles $files $origin $package $content)){continue}
        $changed+=Set-PortablePackageLabel $package $content
        $cache=Join-Path $script:OfficialHome ('plugins/cache/codex-launcher-local-'+$entry.name+'/'+$entry.name)
        if(Test-Path -LiteralPath $cache -PathType Container){foreach($version in @(Get-ChildItem -LiteralPath $cache -Directory)){
            if(Test-PortablePackageFiles $files $origin $version.FullName $content){$changed+=Set-PortablePackageLabel $version.FullName $content}
        }}
    }
    return $changed
}
function New-PortableLocalPluginPlan($Plugin,[string]$ExpectedMode) {
    if($ExpectedMode -notin @('official','api')){throw '本地共享前需确认登录方式。'}
    $marketName='codex-launcher-local-'+$Plugin.name
    $origin=[IO.Path]::GetFullPath([string]$Plugin.source_path).TrimEnd('\')
    $manifest=Get-Content -LiteralPath (Join-Path $origin '.codex-plugin/plugin.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if($manifest.name -cne $Plugin.name -or $manifest.name -notmatch '^[a-z0-9][a-z0-9-]{0,79}$' -or $manifest.license -ne 'MIT' -or $manifest.skills -ne './skills/' -or $manifest.apps -or $manifest.mcpServers -or $manifest.hooks -or -not(Test-Path -LiteralPath (Join-Path $origin 'LICENSE'))){throw '该包不是已确认的纯技能本地版本。'}
    $files=@(Get-ChildItem -LiteralPath $origin -File -Recurse -Force)
    foreach($file in $files){
        $relative=$file.FullName.Substring($origin.Length+1)
        if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw '插件来源含链接，请手动核对。'}
        $parent=$file.Directory
        while($parent -and $parent.FullName.Length -ge $origin.Length){if($parent.Attributes -band [IO.FileAttributes]::ReparsePoint){throw '插件来源含链接，请手动核对。'};$parent=$parent.Parent}
        if($relative -match '(^|\\)(\.env(?:\..*)?|auth\.json|credentials.*|.*token.*\.json)$' -or $relative -in @('.app.json','.mcp.json','mcp.json')){throw '插件包含连接配置，不自动共享。'}
    }
    $indexPath=Join-Path $script:LauncherData 'portable-plugins/index.json'
    $index=@();if(Test-Path -LiteralPath $indexPath){try{$index=@(Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8|ConvertFrom-Json)}catch{}}
    $copyFiles=@($files|Where-Object{$relative=$_.FullName.Substring($origin.Length+1);$relative -match '^(skills\\|assets\\|\.codex-plugin\\)' -or $relative -in @('LICENSE','PRIVACY.md','TERMS.md','PROVENANCE.md')})
    $manifestContent=Get-PortableManifestContent $manifest
    foreach($entry in @($index|Where-Object{$_.name -eq $Plugin.name -and $_.source -ieq $origin})){
        try{
            $managedRoot=[IO.Path]::GetFullPath([string]$entry.root)
            if(-not $managedRoot.StartsWith([IO.Path]::GetFullPath((Join-Path $script:LauncherData 'portable-plugins')).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){continue}
            $cachedPackage=Join-Path $managedRoot ('plugins/'+$Plugin.name)
            $same=Test-PortablePackageFiles $copyFiles $origin $cachedPackage $manifestContent
            $catalog=Join-Path $managedRoot '.agents/plugins/marketplace.json'
            $market=Get-Content -LiteralPath $catalog -Raw -Encoding UTF8|ConvertFrom-Json
            if($same -and $market.name -eq $marketName -and @($market.plugins).Count -eq 1 -and $market.plugins[0].name -ceq $Plugin.name -and $market.plugins[0].source.path -ceq ('./plugins/'+$Plugin.name)){
                $null=Set-PortablePackageLabel $cachedPackage $manifestContent
                return New-LocalPluginRepairPlan ([pscustomobject]@{name=$Plugin.name;source_type='local';marketplace_path=$catalog;marketplace_name=$marketName}) $ExpectedMode
            }
        }catch{continue}
    }
    $root=Join-Path $script:LauncherData ('portable-plugins/'+[Guid]::NewGuid().ToString('N'))
    $package=Join-Path $root ('plugins/'+$Plugin.name)
    foreach($file in $files){
        $relative=$file.FullName.Substring($origin.Length+1)
        if($relative -notmatch '^(skills\\|assets\\|\.codex-plugin\\)' -and $relative -notin @('LICENSE','PRIVACY.md','TERMS.md','PROVENANCE.md')){continue}
        $destination=Join-Path $package $relative
        New-Item -ItemType Directory -Path (Split-Path $destination) -Force|Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination
        if((Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $destination).Hash){throw '插件副本校验失败。'}
    }
    Write-Atomic (Join-Path $package '.codex-plugin/plugin.json') $manifestContent
    $catalog=Join-Path $root '.agents/plugins/marketplace.json'
    Write-Atomic $catalog (@{name=$marketName;interface=@{displayName=('本地共享 · '+$Plugin.name)};plugins=@(@{name=$Plugin.name;source=@{source='local';path=('./plugins/'+$Plugin.name)};policy=@{installation='AVAILABLE';authentication='ON_INSTALL'};category='Productivity'})}|ConvertTo-Json -Depth 8)
    Write-Atomic (Join-Path $root 'provenance.json') (@{name=$Plugin.name;version=$manifest.version;source=$origin;license='MIT';kind='local-skills-copy';account_authorization_copied=$false}|ConvertTo-Json)
    $index=@($index|Where-Object name -ne $Plugin.name)+@([pscustomobject]@{name=$Plugin.name;source=$origin;root=$root})
    Write-Atomic $indexPath (ConvertTo-Json -InputObject $index -Depth 6)
    return New-LocalPluginRepairPlan ([pscustomobject]@{name=$Plugin.name;source_type='local';marketplace_path=$catalog;marketplace_name=$marketName}) $ExpectedMode
}

function Register-PortablePluginMarketplace([string]$Engine,[string]$Catalog) {
    $root=Split-Path (Split-Path (Split-Path $Catalog))
    $info=New-LaunchInfo $Engine $script:OfficialHome $script:OfficialUi
    $info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.Arguments='plugin marketplace add "'+$root+'"'
    $process=[Diagnostics.Process]::Start($info)
    try{
        $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(10000)){$process.Kill();throw '本地市场登记超时。'}
        if($process.ExitCode -ne 0){throw '原生引擎未确认本地市场登记。'}
        # Do not persist native stdout/stderr; they can contain local account details.
    }finally{$process.Dispose()}
}

function Invoke-PluginInventory([string]$Engine,[string]$Repair='') {
    $probe=New-CompatibilityProbe
    try{
        $task=$probe.RunPluginsAsync($Engine,$script:OfficialHome,$script:OfficialUi,$PSScriptRoot,$Repair)
        if(-not $task.Wait(45000)){$probe.Cancel();throw '插件检查超时；普通连接继续使用。'}
        return Convert-CompatibilityReport ($task.GetAwaiter().GetResult()|ConvertFrom-Json) (Get-CompatibilityIdentity $PSScriptRoot)
    }finally{$probe.Dispose()}
}

function Get-PluginSharingNotice($Confirmed,$Unconfirmed) {
    $parts=@()
    $confirmedCount=@($Confirmed|Where-Object{$_}).Count;$pendingCount=@($Unconfirmed|Where-Object{$_}).Count
    if($confirmedCount){$parts+='已确认 '+$confirmedCount+' 个本地插件的安装和技能发现。'}
    if($pendingCount){$parts+=''+$pendingCount+' 个插件尚未确认。'}
    if($parts.Count){$parts+='完整名单见启动摘要明细；原生页面显示、聊天调用和账号连接仍需核对。'}
    return $parts -join ' '
}
function Install-PortableSharedPlugins($Plugins,[string]$Engine) {
    $confirmed=@();$unconfirmed=@()
    foreach($plugin in @($Plugins)){
        try{
            $plan=New-PortableLocalPluginPlan $plugin 'api'
            Register-PortablePluginMarketplace $Engine $plan.marketplacePath
            $report=Invoke-PluginInventory $Engine ($plan|ConvertTo-Json -Compress)
            if($report.repair_status -eq 'pass' -and $report.plugins_status -eq 'pass' -and @($report.plugins|Where-Object{$_.name -eq $plugin.name -and $_.installed -and $_.enabled -and $_.marketplace_name -eq ('codex-launcher-local-'+$plugin.name)}).Count -and @($report.skills|Where-Object{$_.enabled -and $_.name -like ($plugin.name+':*')}).Count){$confirmed+=$plugin.name}
            else{$unconfirmed+=$plugin.name}
        }catch{$unconfirmed+=$plugin.name}
    }
    $script:ConfirmedLocalPlugins=$confirmed;$script:UnconfirmedLocalPlugins=$unconfirmed
    $message=Get-PluginSharingNotice $confirmed $unconfirmed
    if($message){$script:PluginSharingNotice=($script:PluginSharingNotice+' '+$message).Trim()}
}
function Save-PluginSharingResult {
    $result=[pscustomobject]@{version=1;observed_at=[DateTime]::UtcNow.ToString('o');home=$script:OfficialHome;ui=$script:OfficialUi;source_query=$script:PluginSourceStatus;source_mode=$script:PluginSourceMode;source_installed=@($script:PluginSourceInstalled);source_candidates=@($script:PluginSourceCandidates);local_installed_skills=@($script:ConfirmedLocalPlugins);local_unconfirmed=@($script:UnconfirmedLocalPlugins);notice=$script:PluginSharingNotice;desktop_display='unobserved';actual_call='unobserved'}
    Write-Atomic (Join-Path $script:LauncherData 'sharing-status.json') ($result|ConvertTo-Json -Depth 6)
}
function Get-LastPluginSharingSummary {
    $path=Join-Path $script:LauncherData 'sharing-status.json'
    if(-not(Test-Path -LiteralPath $path)){return ''}
    try{
        $result=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
        if($result.version -ne 1 -or $result.home -ine $script:OfficialHome -or $result.ui -ine $script:OfficialUi){return ''}
        $names=@($result.local_installed_skills|Where-Object{$_ -match '^[a-z0-9][a-z0-9-]{0,79}$'})
        $pending=@($result.local_unconfirmed|Where-Object{$_ -match '^[a-z0-9][a-z0-9-]{0,79}$'})
        if($names.Count -or $pending.Count){return ('上次 API 启动：'+(Get-PluginSharingNotice $names $pending))}
        if($result.source_query -eq 'pass'){return '上次 API 启动：没有确认本地插件安装；请检查下面的原生清单。'}
        return '上次 API 启动：插件源检查未完成，没有确认共享。'
    }catch{return '上次插件检查记录无法读取；请重新检查当前模式。'}
}
function Get-LastPluginSharingDetail {
    $path=Join-Path $script:LauncherData 'sharing-status.json'
    if(-not(Test-Path -LiteralPath $path)){return ''}
    try{
        $result=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
        if($result.version -ne 1 -or $result.home -ine $script:OfficialHome -or $result.ui -ine $script:OfficialUi){return ''}
        $lines=@()
        $names=@($result.local_installed_skills|Where-Object{$_ -match '^[a-z0-9][a-z0-9-]{0,79}$'})
        $pending=@($result.local_unconfirmed|Where-Object{$_ -match '^[a-z0-9][a-z0-9-]{0,79}$'})
        if($names.Count){$lines+='上次 API 启动已确认本地安装与技能发现：'+($names -join '、')+'。'}
        if($pending.Count){$lines+='上次 API 启动尚未确认：'+($pending -join '、')+'。'}
        return $lines -join "`r`n"
    }catch{return ''}
}
function Backup-LocalPluginRepair {
    Assert-DesktopClosed (Get-DesktopExe)
    $config=Join-Path $script:OfficialHome 'config.toml'
    if(Test-Path -LiteralPath $config){Write-Atomic (Join-Path $script:LauncherData ('plugin-repair-backups/'+[Guid]::NewGuid().ToString('N')+'.json')) (@{version=1;encrypted_config=(Protect-LocalText ([IO.File]::ReadAllText($config)))}|ConvertTo-Json -Compress)}
}
