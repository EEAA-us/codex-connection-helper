# Image settings are independent from dialogue credentials and chat history.
$script:ImageSourceRoot=$PSScriptRoot
$script:ImageMcpName='codex_launcher_images'
function Get-UniqueImageName([string]$Base='图片服务',$Services=@()) {
    $names=@($Services|ForEach-Object{([string]$_.name).Trim()})
    for($n=1;;$n++){$suffix=' '+$n;$candidate=$Base.Substring(0,[Math]::Min($Base.Length,60-$suffix.Length))+$suffix;if($candidate -notin $names){return $candidate}}
}
function Get-ImageDisplayName($Service,$Services) {
    $same=@($Services|Where-Object{([string]$_.name).Trim() -ieq ([string]$Service.name).Trim()})
    if($same.Count -gt 1){return $Service.name+' · '+(1+[Array]::IndexOf(@($same.id),$Service.id))}
    return $Service.name
}
function Repair-ImageNames($Services) {
    $used=@();foreach($service in @($Services)){
        $service.name=([string]$service.name).Trim();if(-not $service.name){$service.name='图片服务'}
        if($service.name -in @($used.name)){$service.name=Get-UniqueImageName $service.name @($used+$Services)}
        $used+=@($service)
    }
}
function Get-ImageMode($Chat) {
    if($Chat -and $Chat.PSObject.Properties['image_mode'] -and $Chat.image_mode){return [string]$Chat.image_mode}
    if($Chat -and $Chat.image_service_id){return 'service'};return 'off'
}
function New-ImageService($Services=@()) {
    return [pscustomobject]@{id=[Guid]::NewGuid().ToString('N');name=(Get-UniqueImageName '图片服务' $Services);protocol='images_auto';base_url='';model='';models=@();key_mode='own';key_url='';encrypted_key='';size='';quality='';output_format='';background='';wait_seconds=600;network='system'}
}
function Get-ImageStore {
    $path=Join-Path $script:LauncherData 'image-services.json'
    if(-not(Test-Path -LiteralPath $path)){return [pscustomobject]@{version=1;output_dir='';services=@()}}
    try{
        $store=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
        if($store.version -ne 1 -or -not $store.PSObject.Properties['services'] -or -not $store.PSObject.Properties['output_dir']){throw 'schema'}
        foreach($service in @($store.services)){
            if($service.id -notmatch '^[a-f0-9]{32}$'){throw 'id'}
            if(-not $service.PSObject.Properties['protocol']){$service|Add-Member -NotePropertyName protocol -NotePropertyValue 'images_sync'}
            foreach($property in (New-ImageService).PSObject.Properties){if(-not $service.PSObject.Properties[$property.Name]){$service|Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value}}
        }
        if(@($store.services.id|Sort-Object -Unique).Count -ne @($store.services).Count){throw 'duplicate'}
        return $store
    }catch{throw '图片服务配置无法读取；原文件未改动，请检查 image-services.json。'}
}
function Save-ImageStore($Store) {
    $path=Join-Path $script:LauncherData 'image-services.json'
    if(Test-Path -LiteralPath $path){Write-Atomic (Join-Path $script:LauncherData ('image-service-backups/'+[Guid]::NewGuid().ToString('N')+'.json')) ([IO.File]::ReadAllText($path))}
    Repair-ImageNames @($Store.services)
    Write-Atomic $path ($Store|ConvertTo-Json -Depth 12)
}
function Complete-ImageService($Service,[string]$EnteredKey='') {
    $copy=$Service|ConvertTo-Json -Depth 12|ConvertFrom-Json
    if($copy.id -notmatch '^[a-f0-9]{32}$'){throw '图片服务标识无效。'}
    $copy.name=$copy.name.Trim();if(-not $copy.name -or $copy.name.Length -gt 60){throw '图片服务名称须为 1–60 字。'}
    $copy.base_url=Normalize-Endpoint $copy.base_url
    if($copy.protocol -notin @('images_auto','images_sync','cctq_async')){throw '请选择自动识别、同步返回或异步任务（轮询）。'}
    $copy.model=$copy.model.Trim();if(-not $copy.model -or $copy.model.Length -gt 200 -or $copy.model -match '[\x00-\x1f]'){throw '请填写准确的图片模型名。'}
    if($copy.key_mode -notin @('own','chat')){throw '图片凭据模式无效。'}
    if($copy.key_mode -eq 'own'){
        if($EnteredKey.Trim()){$copy.encrypted_key=Protect-LocalText $EnteredKey.Trim();$copy.key_url=$copy.base_url}
        $null=Get-LocalKey $copy $copy.base_url
    }else{$copy.encrypted_key='';$copy.key_url=''}
    if($copy.network -notin @('system','direct')){throw '图片网络模式无效。'}
    $seconds=0;if(-not [int]::TryParse([string]$copy.wait_seconds,[ref]$seconds) -or $seconds -lt 60 -or $seconds -gt 1800){throw '图片等待时长须为 60–1800 秒。'};$copy.wait_seconds=$seconds
    foreach($field in @('size','quality','output_format','background')){if(([string]$copy.$field).Length -gt 80 -or ([string]$copy.$field) -match '[\x00-\x1f]'){throw '图片参数无效。'}}
    return $copy
}
function Get-ImageOutputDirectory([string]$Custom='') {
    if($Custom){return Convert-LauncherPath $Custom '图片保存目录'}
    return Join-Path $script:OfficialHome 'generated_images\launcher'
}
function Get-ImageCredential($Service,$Chat) {
    $url=Normalize-Endpoint $Service.base_url
    if($Service.key_mode -eq 'chat'){
        $chatUrl=Normalize-Endpoint $Chat.base_url;$a=[Uri]$url;$b=[Uri]$chatUrl
        if($a.Scheme -ne $b.Scheme -or $a.IdnHost -ne $b.IdnHost -or $a.Port -ne $b.Port){throw '图片服务与对话接口不同源，请为图片服务设置独立 Key。'}
        return Get-LocalKey $Chat $chatUrl
    }
    return Get-LocalKey $Service $url
}
function New-ImageSnapshot($Service,$Chat,[string]$OutputDirectory='') {
    $copy=Complete-ImageService $Service
    $key=Get-ImageCredential $copy $Chat
    try{
        $output=Get-ImageOutputDirectory $OutputDirectory
        return [pscustomobject]@{service_id=$copy.id;protocol=$copy.protocol;base_url=$copy.base_url;model=$copy.model;key=$key;output_dir=$output;jobs_dir=(Join-Path $script:LauncherData 'image-jobs');size=$copy.size;quality=$copy.quality;output_format=$copy.output_format;background=$copy.background;wait_seconds=$copy.wait_seconds;network=$copy.network;switch_file=$script:SwitchFile;auth_file=(Join-Path $script:OfficialHome 'auth.json');runtime_path=''}
    }finally{$key=$null}
}
function New-DialogueImageSnapshot($Chat,[string]$OutputDirectory='') {
    $chatCopy=Complete-ApiProfile $Chat
    $key=Get-LocalKey $chatCopy $chatCopy.base_url
    try{return [pscustomobject]@{service_id=('dialogue-'+$chatCopy.id);protocol='responses_image';base_url=$chatCopy.base_url;model=$chatCopy.model;key=$key;output_dir=(Get-ImageOutputDirectory $OutputDirectory);jobs_dir=(Join-Path $script:LauncherData 'image-jobs');wait_seconds=600;network='system';switch_file=$script:SwitchFile;auth_file=(Join-Path $script:OfficialHome 'auth.json');runtime_path=''}}finally{$key=$null}
}
function Initialize-ImageClient {
    if(-not ('CodexImageTools' -as [type])){
        Add-Type -AssemblyName System.Net.Http
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        Add-Type -Path (Join-Path $script:ImageSourceRoot 'ImageTools.cs') -ReferencedAssemblies 'System','System.Core','System.Net.Http','System.Web.Extensions','System.Security'
    }
}
function New-ImageClient($Snapshot,[switch]$ApiSession) {
    Initialize-ImageClient
    return [CodexImageTools]::new(($Snapshot|ConvertTo-Json -Depth 12 -Compress),[bool]$ApiSession,$false)
}
function New-ImageIntegrationPlan($Chat) {
    $mode=Get-ImageMode $Chat
    if($mode -eq 'off'){return [pscustomobject]@{block='';path=''}}
    $store=Get-ImageStore
    if($mode -eq 'current'){$snapshot=New-DialogueImageSnapshot $Chat $store.output_dir}
    elseif($mode -eq 'service'){
        $service=@($store.services|Where-Object{$_.id -eq $Chat.image_service_id})[0]
        if(-not $service){throw '选中的图片服务已不存在；请关闭图片服务或重新选择。'}
        $snapshot=New-ImageSnapshot $service $Chat $store.output_dir
    }else{throw '图片使用方式无效。'}
    $path=Join-Path $script:LauncherData ('image-runtime/'+[Guid]::NewGuid().ToString('N')+'.json')
    $snapshot.runtime_path=$path
    Write-Atomic $path (@{version=1;encrypted_runtime=(Protect-LocalText ($snapshot|ConvertTo-Json -Depth 12 -Compress))}|ConvertTo-Json -Compress)
    $command=ConvertTo-Json (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Compress
    $arguments=ConvertTo-Json @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $script:ImageSourceRoot 'ImageMcp.ps1'),'-RuntimePath',$path) -Compress
    $block="[mcp_servers.$($script:ImageMcpName)]`r`ncommand = $command`r`nargs = $arguments`r`nstartup_timeout_sec = 30`r`ntool_timeout_sec = $($snapshot.wait_seconds+30)`r`nrequired = false`r`n"
    $snapshot.key=$null
    return [pscustomobject]@{block=$block;path=$path}
}
function Get-OptionalImageIntegrationPlan($Chat) {
    try{$plan=New-ImageIntegrationPlan $Chat;$plan|Add-Member -NotePropertyName warning -NotePropertyValue '';return $plan}
    catch{return [pscustomobject]@{block='';path='';warning='图片工具配置未就绪，普通聊天仍可用。请检查图片服务的地址、Key、绑定和保存目录。'}}
}
function Get-ImageBlockValues([string]$Block,$ParsedEnd=$null) {
    # Deliberately parse only our generated TOML subset. Unknown syntax is a
    # conflict, never a reason to guess or discard a user's additional setting.
    $string='"(?:[^"\\\r\n]|\\["\\/bfnrt]|\\u[0-9a-fA-F]{4})*"|''[^''\r\n]*'''
    $clean=[regex]::Replace($Block,('(?:'+$string+')|#[^\r\n]*'),[Text.RegularExpressions.MatchEvaluator]{param($m) if($m.Value.StartsWith('#')){return (' '*$m.Length)};return $m.Value})
    $header=[regex]::Match($clean,'\A\s*\[\s*mcp_servers\.codex_launcher_images\s*\][ \t]*(?:\r?\n|$)')
    if(-not $header.Success){return $null}
    $body=$clean.Substring($header.Length);$values=@{};$position=0
    $array='\[\s*(?:(?:'+$string+')\s*(?:,\s*(?:'+$string+')\s*)*,?\s*)?\]'
    $entryPattern='\G\s*(command|args|startup_timeout_sec|tool_timeout_sec|required)[ \t]*=[ \t]*(?<value>(?:'+$array+')|(?:'+$string+')|[0-9][0-9_]*|true|false)[ \t]*(?:\r?\n|$)'
    while($position -lt $body.Length){
        if([string]::IsNullOrWhiteSpace($body.Substring($position))){break}
        # Match at a supplied offset so \G cannot silently skip unknown fields.
        $entry=([regex]::new($entryPattern,[Text.RegularExpressions.RegexOptions]::None,[TimeSpan]::FromSeconds(1))).Match($body,$position)
        if(-not $entry.Success -or $entry.Index -ne $position){return $null}
        $key=$entry.Groups[1].Value;$value=$entry.Groups['value'].Value
        if($values.ContainsKey($key)){return $null}
        if($key -in @('command','args')){
            if(($key -eq 'args') -ne $value.StartsWith('[')){return $null}
            if($key -eq 'command' -and $value[0] -notin @('"',"'")){return $null}
            $tokens=@([regex]::Matches($value,$string)|ForEach-Object{
                if($_.Value.StartsWith("'")){$_.Value.Substring(1,$_.Value.Length-2)}else{$_.Value|ConvertFrom-Json}
            })
            $values[$key]=ConvertTo-Json -InputObject $tokens -Compress
        }elseif($key -eq 'required'){
            if($value -notin @('true','false')){return $null};$values[$key]=$value
        }else{
            if($value -notmatch '^[0-9]+(?:_[0-9]+)*$'){return $null}
            $number=0L;if(-not [long]::TryParse($value.Replace('_',''),[ref]$number)){return $null};$values[$key]=[string]$number
        }
        $position=$entry.Index+$entry.Length
    }
    if($values.Count -ne 5){return $null}
    if($null -ne $ParsedEnd){$ParsedEnd.Value=$header.Length+$position}
    return $values
}
function Find-EquivalentImageBlock([string]$Text,[string]$Expected) {
    $headers=@([regex]::Matches($Text,'(?m)^[ \t]*\[[^\r\n]*codex_launcher_images[^\r\n]*\][^\r\n]*(?:\r?\n|$)'))
    if($headers.Count -ne 1){return $null}
    $start=$headers[0].Index;$afterHeader=$start+$headers[0].Length
    $next=[regex]::Match($Text.Substring($afterHeader),'(?m)^[ \t]*\[')
    $end=$Text.Length;if($next.Success){$end=$afterHeader+$next.Index}
    $actual=$Text.Substring($start,$end-$start)
    $last=0
    try{$a=Get-ImageBlockValues $actual ([ref]$last);$b=Get-ImageBlockValues $Expected}catch{return $null}
    if(-not $a -or -not $b){return $null}
    foreach($key in $b.Keys){if($a[$key] -cne $b[$key]){return $null}}
    # Leave trailing blank lines and comments outside the owned entries intact.
    if(-not $last){return $null}
    if($Expected.StartsWith("`n") -or $Expected.StartsWith("`r`n")){
        if($start -gt 0 -and $Text[$start-1] -eq "`n"){$start--;if($start -gt 0 -and $Text[$start-1] -eq "`r"){$start--}}
    }
    return [pscustomobject]@{Index=$start;Length=($headers[0].Index+$last-$start)}
}
function Remove-ManagedImageBlock([string]$Text,$State,[switch]$CheckCollision) {
    $namespacePattern='(?m)^\s*\[[^\r\n]*codex_launcher_images[^\r\n]*\]'
    if($State -and $State.active){
        $blocks=@();$switching=$State.PSObject.Properties['phase'] -and $State.phase -eq 'switching'
        if($State.PSObject.Properties['image_mcp_block'] -and $State.image_mcp_block){$blocks+=([string]$State.image_mcp_block)}
        if($switching -and $State.PSObject.Properties['image_previous_mcp_block'] -and $State.image_previous_mcp_block){$blocks+=([string]$State.image_previous_mcp_block)}
        if($blocks.Count){
            # Compare the whole section, not a matching prefix: additional fields
            # must not be orphaned into a neighboring user's MCP section.
            $found=@(foreach($block in ($blocks|Select-Object -Unique)){
                $equivalent=Find-EquivalentImageBlock $Text $block;if($equivalent){$equivalent}
            })
            $found=@($found|Sort-Object Index,Length -Unique)
            if($found.Count -eq 1){
                $Text=$Text.Remove($found[0].Index,$found[0].Length)
                if($Text -match $namespacePattern){throw '图片工具配置存在重复区段，普通切换已停止，原文件未改动。请正常退出 Codex 后点击“恢复官方配置”，助手会先备份再恢复；恢复后可重新启动 API。'}
            }elseif(-not($found.Count -eq 0 -and $Text -notmatch $namespacePattern)){
                throw '无法确认图片工具配置与保存记录一致：可能存在参数变化、重复区段或不支持的写法。普通切换已停止，原文件未改动。请正常退出 Codex 后点击“恢复官方配置”，助手会先备份再恢复；恢复后可重新启动 API。'
            }
        }
    }
    if($CheckCollision -and ($Text -match $namespacePattern -or $Text -match '(?m)^\s*mcp_servers\s*=')){throw '已存在同名或内联 MCP 配置，启动器不会覆盖；请更名或改用标准独立区段。'}
    return $Text
}
