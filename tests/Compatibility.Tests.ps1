$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Launcher.Core.ps1')
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('CodexLauncher-Compatibility-'+[Guid]::NewGuid().ToString('N'))
$script:LauncherData=$fixture;New-Item -ItemType Directory -Path $fixture|Out-Null
$identity=[pscustomobject]@{mode='official';home='D:\Codex 数据';ui='D:\Codex 界面';cwd='D:\项目';observed_at=[DateTime]::UtcNow.ToString('o')}
$raw=@{account=@{type='chatgpt'};plugins=@{marketplaces=@(@{name='synthetic';plugins=@(@{id='figma@local';name='figma';installed=$true;enabled=$true;source=@{type='local';path='D:\plugin'}})})};skills=@{data=@(@{skills=@(@{name='figma-use';path='D:\plugin\skills\SKILL.md';scope='user';enabled=$true;pluginId='figma@local';description='private description'})})};mcp=@{data=@(@{name='synthetic';tools=@{read=@{description='private tool description'}};authStatus='notLoggedIn'})};secret='synthetic-private-token'}|ConvertTo-Json -Depth 20|ConvertFrom-Json
$official=Convert-CompatibilityReport $raw $identity
if($official.plugins_status -ne 'pass' -or $official.plugins.Count -ne 1 -or -not $official.plugins[0].installed){throw 'Native plugin installation state lost'}
$serialized=$official|ConvertTo-Json -Depth 20
if($serialized -match 'synthetic-private-token|private description|private tool description'){throw 'Private native payload retained'}
Save-CompatibilityReport $official
$apiIdentity=$identity|ConvertTo-Json|ConvertFrom-Json;$apiIdentity.mode='api'
$empty=@{account=@{type='apiKey'};plugins=@{marketplaces=@()};skills=@{data=@()};mcp=@{data=@()}}|ConvertTo-Json|ConvertFrom-Json
$api=Convert-CompatibilityReport $empty $apiIdentity
$previous=Get-PreviousCompatibilityReport $api.identity
$findings=Get-CompatibilityFindings $api $previous
if($findings -notmatch '安装记录缺失|figma' -or $findings -notmatch '实际调用未观察|调用未观察|调用成功'){throw 'Mode comparison lost missing registration or honesty boundary'}
$api.identity.home='E:\另一份';if((Get-CompatibilityFindings $api $official) -notmatch '目录不一致'){throw 'Wrong home was not detected'}
$api.identity.home=$official.identity.home
$localManifest=Join-Path $fixture 'marketplace.json';[IO.File]::WriteAllText($localManifest,'{}')
$official.plugins[0].marketplace_path=$localManifest
$candidates=@(Get-LocalPluginRepairCandidates $api $official)
if($candidates.Count -ne 1){throw 'Exact local repair candidate not discovered'}
$plan=New-LocalPluginRepairPlan $candidates[0] 'api'
if($plan.pluginName -ne 'figma' -or $plan.marketplacePath -ne $localManifest){throw 'Targeted native repair contract incorrect'}
$curated=$official.plugins[0]|ConvertTo-Json|ConvertFrom-Json;$curated|Add-Member -NotePropertyName marketplace_name -NotePropertyValue 'openai-curated' -Force
$curatedPlan=New-LocalPluginRepairPlan $curated 'api'
if($curatedPlan.marketplacePath -or $curatedPlan.remoteMarketplaceName -ne 'openai-curated'){throw 'Reserved curated cache was submitted as an ordinary local marketplace'}
$official.plugins[0].source_type='remote'
if(@(Get-LocalPluginRepairCandidates $api $official).Count){throw 'Cloud plugin selected for local registration repair'}
$api.plugins=@([pscustomobject]@{id='figma@api-market';name='figma';installed=$false;enabled=$false;source_type='local';marketplace_path=$localManifest;availability='AVAILABLE'})
$localCandidates=@(Get-LocalPluginRepairCandidates $api $official)
if($localCandidates.Count -ne 1 -or $localCandidates[0].id -ne 'figma@api-market'){throw 'Available API local alternative for account plugin not offered'}
if((New-LocalPluginRepairPlan $localCandidates[0] 'api').pluginName -ne 'figma'){throw 'API local alternative install plan wrong'}
$api.plugins[0].availability='REQUIRES_AUTH';if(@(Get-LocalPluginRepairCandidates $api $official).Count){throw 'Unavailable API alternative offered'}
$api.plugins[0].availability='AVAILABLE';$api.plugins[0].installed=$true
if(@(Get-LocalPluginRepairCandidates $api $official).Count){throw 'Already installed alternative offered again'}
$api.plugins[0].installed=$false;$api.identity.cwd='E:\other'
if(@(Get-LocalPluginRepairCandidates $api $official).Count){throw 'Different project offered API local installation'}
$api.identity.cwd=$official.identity.cwd
$official.plugins+=@([pscustomobject]@{id='figma@local';name='figma';installed=$false;enabled=$false;source_type='local';marketplace_path=$localManifest;availability='AVAILABLE'})
if((Get-CompatibilitySummary $official) -notmatch '两份安装记录'){throw 'Account/local distinction missing from summary'}
$generic=$official|ConvertTo-Json -Depth 12|ConvertFrom-Json
foreach($p in $generic.plugins){$p.name='unrelated-plugin'}
if((Get-CompatibilitySummary $generic) -match 'Figma|design-partner' -or (Get-CompatibilityFindings $generic) -notmatch 'unrelated-plugin 来源不同'){throw 'Plugin diagnostics still hardcoded one vendor instead of actual source names'}
$emptyRaw=@{account=@{type='apiKey'};plugins=@{marketplaces=@()};skills=@{data=@()};mcp=@{data=@()};apps=@{apps=@()}}|ConvertTo-Json -Depth 8|ConvertFrom-Json
$emptyReport=Convert-CompatibilityReport $emptyRaw $identity
if((Get-CompatibilitySummary $emptyReport) -match 'Figma|design-partner' -or (Get-CompatibilityFindings $emptyReport) -match '需要连接|所需 App'){throw 'Empty inventory invented a plugin or asked for an unnecessary connection'}
$unknown=@{plugins=@{query_status='unobserved'};skills=@{query_status='unobserved'};mcp=@{query_status='unobserved'}}|ConvertTo-Json|ConvertFrom-Json
$report=Convert-CompatibilityReport $unknown $identity
if($report.plugins_status -ne 'unobserved' -or (Get-CompatibilityFindings $report $null) -notmatch '原因未确认'){throw 'Unavailable inventory treated as installed or prohibited'}
$mismatched=$identity|ConvertTo-Json|ConvertFrom-Json;$mismatched.mode='api'
$actualOfficial=Convert-CompatibilityReport $raw $mismatched
if($actualOfficial.identity.mode -ne 'official' -or $actualOfficial.identity.configured_mode -ne 'api' -or (Get-CompatibilitySummary $actualOfficial) -notmatch '实际登录不同'){throw 'Stale switching state mislabels native account'}
$unverified=Convert-CompatibilityReport $unknown $identity
if($unverified.identity.native_auth_status -ne 'unobserved' -or @(Get-LocalPluginRepairCandidates $unverified $official).Count){throw 'Unverified login offers cross-mode repair'}
$serialized=$actualOfficial|ConvertTo-Json -Depth 20
if($serialized -match 'synthetic-private-token|private description'){throw 'Account projection leaked raw payload'}
$fakeEngine=Join-Path $fixture 'FakeNative.exe'
Add-Type -OutputAssembly $fakeEngine -OutputType ConsoleApplication -ReferencedAssemblies 'System','System.Core','System.Web.Extensions' -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Web.Script.Serialization;
public static class FakeNativePluginHost {
 public static void Main() {
  var json=new JavaScriptSerializer(); string line;
  while((line=Console.ReadLine())!=null) {
   var input=json.DeserializeObject(line) as Dictionary<string,object>;
   if(!input.ContainsKey("id"))continue;
   var method=Convert.ToString(input["method"]); object result=new {};
   if(method=="account/read")result=new {account=new {type=File.ReadAllText("account-type.txt")}};
   if(method=="plugin/install" && File.Exists("unsupported.flag")) {
    Console.WriteLine(json.Serialize(new {id=input["id"],error=new {code=-32600,message="chatgpt authentication required for remote plugin catalog; api key auth is not supported synthetic-private-token"}}));continue;
   }
   if(method=="plugin/install") {File.WriteAllText("install-request.json",json.Serialize(input["params"]));}
   if(method=="plugin/installed")result=new {marketplaces=new object[0]};
   if(method=="skills/list" || method=="mcpServerStatus/list")result=new {data=new object[0]};
   if(method=="app/installed")result=new {apps=new object[0]};
   Console.WriteLine(json.Serialize(new {id=input["id"],result=result}));
  }
 }
}
'@
$accountFile=Join-Path $fixture 'account-type.txt';$installRequest=Join-Path $fixture 'install-request.json'
[IO.File]::WriteAllText($accountFile,'chatgpt')
$probe=New-CompatibilityProbe
try{
    $rejected=$false;try{$null=$probe.RunAsync($fakeEngine,$fixture,$fixture,$fixture,($plan|ConvertTo-Json -Compress)).GetAwaiter().GetResult()}catch{$rejected=$true}
    if(-not $rejected -or (Test-Path -LiteralPath $installRequest)){throw 'Native identity drift submitted installation'}
}finally{$probe.Dispose()}
[IO.File]::WriteAllText($accountFile,'apiKey');$probe=New-CompatibilityProbe
try{$null=$probe.RunAsync($fakeEngine,$fixture,$fixture,$fixture,($plan|ConvertTo-Json -Compress)).GetAwaiter().GetResult()}finally{$probe.Dispose()}
if(-not(Test-Path -LiteralPath $installRequest)){throw 'Matching native API identity could not install selected local entry'}
$submitted=Get-Content -LiteralPath $installRequest -Raw|ConvertFrom-Json
if($submitted.pluginName -ne 'figma' -or $submitted.PSObject.Properties['launcherExpectedMode']){throw 'Helper metadata leaked into official installation request'}
[IO.File]::WriteAllText((Join-Path $fixture 'unsupported.flag'),'synthetic-only');[IO.File]::Delete($installRequest);$probe=New-CompatibilityProbe
try{$blockedRaw=$probe.RunAsync($fakeEngine,$fixture,$fixture,$fixture,($plan|ConvertTo-Json -Compress)).GetAwaiter().GetResult()}finally{$probe.Dispose()}
$blocked=Convert-CompatibilityReport ($blockedRaw|ConvertFrom-Json) $apiIdentity
if($blocked.repair_status -ne 'blocked' -or $blocked.repair_failure_kind -ne 'native_api_catalog_auth' -or $blockedRaw -match 'synthetic-private-token' -or (Test-Path -LiteralPath $installRequest)){throw 'Native API catalog restriction lost or raw message leaked'}
if(@(Get-LocalPluginRepairCandidates $blocked $official).Count){throw 'Blocked native catalog operation offered again'}
# Portable local packages require actual enabled skill discovery and an installed plugin.
$portableHome=Join-Path $fixture 'portable-home'
$package=Join-Path $portableHome 'plugins/cache/synthetic/designer/1.0'
$manifestPath=Join-Path $package '.codex-plugin/plugin.json'
$skillPath=Join-Path $package 'skills/design/SKILL.md'
New-Item -ItemType Directory -Path (Split-Path $manifestPath),(Split-Path $skillPath) -Force|Out-Null
$manifest=@{name='designer';version='1.0';license='MIT';skills='./skills/';interface=@{displayName='Designer';capabilities=@('Read','Write')}}
Write-Atomic $manifestPath ($manifest|ConvertTo-Json)
Write-Atomic $skillPath "---`nname: design`ndescription: synthetic`n---`nSynthetic instructions."
Write-Atomic (Join-Path $package 'LICENSE') 'MIT synthetic license fixture'
$portableReport=[pscustomobject]@{identity=[pscustomobject]@{home=$portableHome;native_auth_status='pass'};plugins_status='pass';skills_status='pass';plugins=@([pscustomobject]@{name='designer';installed=$true;enabled=$true});skills=@([pscustomobject]@{name='designer:design';path=$skillPath;enabled=$true})}
$candidates=@(Get-PortableSharedPlugins $portableReport)
if($candidates.Count -ne 1){throw 'Installed enabled portable plugin not discovered'}
$sharedCache=Join-Path $portableHome 'plugins/cache/codex-launcher-local-designer/designer/1.0'
New-Item -ItemType Directory -Path (Split-Path $sharedCache) -Force|Out-Null
Copy-Item -LiteralPath $package -Destination $sharedCache -Recurse
$originalSkills=$portableReport.skills
$portableReport.skills+=@([pscustomobject]@{name='designer:design';path=(Join-Path $sharedCache 'skills/design/SKILL.md');enabled=$true;plugin_id='designer@codex-launcher-local-designer'})
if(@(Get-PortableSharedPlugins $portableReport).Count -ne 1){throw 'Previously shared copy hid the original source on the next launch'}
$portableReport.skills=$originalSkills
$local=New-PortableLocalPluginPlan $candidates[0] 'api'
$second=New-PortableLocalPluginPlan $candidates[0] 'api'
if($local.marketplacePath -cne $second.marketplacePath -or $local.PSObject.Properties['remoteMarketplaceName']){throw 'Portable local package not reused or incorrectly sent to remote catalog'}
$copiedPackage=Join-Path (Split-Path (Split-Path (Split-Path $local.marketplacePath))) 'plugins/designer'
if((Get-FileHash -LiteralPath (Join-Path $copiedPackage 'LICENSE')).Hash -ne (Get-FileHash -LiteralPath (Join-Path $package 'LICENSE')).Hash){throw 'Portable package lost license'}
$localManifest=Get-Content -LiteralPath (Join-Path $copiedPackage '.codex-plugin/plugin.json') -Raw -Encoding UTF8|ConvertFrom-Json
if($localManifest.interface.displayName -cne 'Designer · 本地共享' -or $localManifest.name -cne $manifest.name -or $localManifest.version -cne $manifest.version -or ($localManifest.interface.capabilities -join ',') -cne 'Read,Write'){throw 'Local display label missing or plugin identity/metadata changed'}
$originalHash=(Get-FileHash -LiteralPath $manifestPath).Hash
$payloadHash=(Get-FileHash -LiteralPath $skillPath).Hash
$firstManifestHash=(Get-FileHash -LiteralPath (Join-Path $copiedPackage '.codex-plugin/plugin.json')).Hash
$third=New-PortableLocalPluginPlan $candidates[0] 'api'
if($third.marketplacePath -cne $local.marketplacePath -or (Get-FileHash -LiteralPath (Join-Path $copiedPackage '.codex-plugin/plugin.json')).Hash -cne $firstManifestHash){throw 'Labeled plugin no longer reused on the next plan'}
# Migrate only exact owned legacy copies, including the installed native cache.
Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $copiedPackage '.codex-plugin/plugin.json')
$oldHome=$script:OfficialHome;$script:OfficialHome=$portableHome
try{
    if((Update-PortablePluginLabels) -ne 2){throw 'Owned legacy source and installed cache labels were not both migrated'}
    if((Update-PortablePluginLabels) -ne 0){throw 'Label migration is not idempotent'}
    if((Get-FileHash -LiteralPath $manifestPath).Hash -cne $originalHash -or (Get-FileHash -LiteralPath $skillPath).Hash -cne $payloadHash){throw 'Label migration changed the official source or skill payload'}
    $cacheManifest=Join-Path $sharedCache '.codex-plugin/plugin.json'
    if((Get-Content -LiteralPath $cacheManifest -Raw -Encoding UTF8|ConvertFrom-Json).interface.displayName -cne 'Designer · 本地共享'){throw 'Installed cache retained ambiguous display name'}
    $backupRoot=Join-Path $script:LauncherData 'portable-plugin-label-backups'
    if(@(Get-ChildItem -LiteralPath $backupRoot -File).Count -ne 2){throw 'Legacy metadata was not backed up before migration'}
    Copy-Item -LiteralPath $manifestPath -Destination $cacheManifest
    $cacheSkill=Join-Path $sharedCache 'skills/design/SKILL.md';$cacheSkillText=[IO.File]::ReadAllText($cacheSkill)
    Write-Atomic $cacheSkill 'Synthetic user modification'
    if((Update-PortablePluginLabels) -ne 0 -or (Get-FileHash -LiteralPath $cacheManifest).Hash -cne $originalHash){throw 'A modified installed copy was overwritten by label migration'}
    Write-Atomic $cacheSkill $cacheSkillText
    $null=Update-PortablePluginLabels
}finally{$script:OfficialHome=$oldHome}
$fourth=New-PortableLocalPluginPlan $candidates[0] 'api'
if($fourth.marketplacePath -cne $local.marketplacePath){throw 'Legacy migration generated a second marketplace'}
if((Get-PortableManifestContent ([pscustomobject]@{name='another-plugin';version='1.0'})|ConvertFrom-Json).interface.displayName -cne 'another-plugin · 本地共享'){throw 'Display label was hardcoded to one plugin'}
$portableReport.plugins[0].enabled=$false
if(@(Get-PortableSharedPlugins $portableReport).Count){throw 'Disabled plugin was shared'}
$portableReport.plugins[0].enabled=$true;$portableReport.skills[0].enabled=$false
if(@(Get-PortableSharedPlugins $portableReport).Count){throw 'Disabled skill was shared'}
$portableReport.skills[0].enabled=$true
Write-Atomic (Join-Path $package '.app.json') '{"apps":{}}'
if(@(Get-PortableSharedPlugins $portableReport).Count){throw 'Account-connected package was automatically shared'}
$rejected=$false;try{$null=New-PortableLocalPluginPlan $candidates[0] 'api'}catch{$rejected=$true}
if(-not $rejected){throw 'Connected package was copied by direct plan construction'}
[IO.File]::Delete((Join-Path $package '.app.json'))
$manifest.license='proprietary';Write-Atomic $manifestPath ($manifest|ConvertTo-Json)
if(@(Get-PortableSharedPlugins $portableReport).Count){throw 'Unknown-license package was shared'}
$manifest.license='MIT';Write-Atomic $manifestPath ($manifest|ConvertTo-Json)
Write-Atomic (Join-Path $package '.app.json') '{"apps":{"example":{"id":"synthetic-app"}}}'
$portableReport.plugins[0].installed=$false
if(@(Get-PluginAppDependencies $portableReport).Count){throw 'Uninstalled cached plugin created a spurious connection requirement'}
$portableReport.plugins[0].installed=$true
if(@(Get-PluginAppDependencies $portableReport).Count -ne 1){throw 'Installed plugin dependency discovery was lost'}
[IO.File]::Delete((Join-Path $package '.app.json'))
Write-Atomic (Join-Path $package 'skills/design/auth.json') 'synthetic-private-marker'
$rejected=$false;try{$null=New-PortableLocalPluginPlan $candidates[0] 'api'}catch{$rejected=$true}
if(-not $rejected){throw 'Credential file was copied as a skill resource'}
$sourcePlugin=[pscustomobject]@{id='designer@remote';name='designer';installed=$true;enabled=$true}
$sharedReport=[pscustomobject]@{skills_status='pass';plugins=@([pscustomobject]@{id='designer@codex-launcher-local-designer';name='designer';installed=$true;enabled=$true;source_type='local';marketplace_name='codex-launcher-local-designer'});skills=@([pscustomobject]@{name='designer:design';enabled=$true})}
if(-not(Test-PluginPresent $sourcePlugin $sharedReport)){throw 'Confirmed local skill copy reported as missing because of different native ID'}
$sharedReport.skills[0].enabled=$false
if(Test-PluginPresent $sourcePlugin $sharedReport){throw 'A local copy without enabled skill discovery was treated as shared'}
$sharedReport.skills[0].enabled=$true;$sharedReport.plugins[0].marketplace_name='unrelated-market'
if(Test-PluginPresent $sourcePlugin $sharedReport){throw 'Unrelated same-name plugin hid a missing source'}
'PASS: projection, native identity gate, local plugin discovery, license preservation, repeat-plan reuse and local source comparison; disabled, connected and credential-bearing packages excluded; real plugin/account state unchanged.'
