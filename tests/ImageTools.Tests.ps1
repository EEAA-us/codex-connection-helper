$ErrorActionPreference='Stop'
$source=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $source 'Launcher.Core.ps1')
Initialize-ImageClient
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('CodexLauncher-Images-'+[Guid]::NewGuid().ToString('N'))
$script:LauncherData=Join-Path $fixture 'local';$script:OfficialHome=Join-Path $fixture '另一个盘 中文';$script:SwitchFile=Join-Path $script:LauncherData 'shared-switch.json'
New-Item -ItemType Directory -Path $script:OfficialHome -Force|Out-Null
Add-Type -ReferencedAssemblies System,System.Core,System.Web.Extensions -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
public class ImageFixture : IDisposable {
 readonly TcpListener listener;
 readonly Task worker;
 volatile bool stopping=false;
 public volatile int Posts=0;
 public readonly List<string> Paths=new List<string>();
 public string Body=""; public string LastAuth="";
 public volatile string Mode;
 public int Port { get{return ((IPEndPoint)listener.LocalEndpoint).Port;} }
 public ImageFixture(string initialMode) {
  Mode=initialMode;
  listener=new TcpListener(IPAddress.Loopback,0);listener.Start();
  worker=Task.Run(()=> { try {int polls=0;for(;;) {try{using(var c=listener.AcceptTcpClient())using(var s=c.GetStream()) {
   var h=new StringBuilder();int ch;while((ch=s.ReadByte())>=0){h.Append((char)ch);if(h.ToString().EndsWith("\r\n\r\n"))break;}
   if(!h.ToString().EndsWith("\r\n\r\n"))continue; // Cancellation may close a newly accepted socket before headers.
   var lines=h.ToString().Split('\n');string path=lines[0].Split(' ')[1];int len=0;bool expect=false;LastAuth="";
   foreach(var line in lines) {if(line.StartsWith("Content-Length:",StringComparison.OrdinalIgnoreCase))len=int.Parse(line.Substring(15).Trim());if(line.StartsWith("Authorization:",StringComparison.OrdinalIgnoreCase))LastAuth=line.Substring(14).Trim();if(line.StartsWith("Expect:",StringComparison.OrdinalIgnoreCase))expect=true;}
   if(expect){var interim=Encoding.ASCII.GetBytes("HTTP/1.1 100 Continue\r\n\r\n");s.Write(interim,0,interim.Length);s.Flush();}
   var bytes=new byte[len];int offset=0;while(offset<len){int n=s.Read(bytes,offset,len-offset);if(n==0)break;offset+=n;}if(offset<len)continue;Body=Encoding.UTF8.GetString(bytes);Paths.Add(path);
   string png="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZioAAAAASUVORK5CYII=";
   string text="{\"data\":[{\"b64_json\":\""+png+"\"}]}";int status=200;string type="application/json";byte[] output=null;
   string mode=Mode;bool post=lines[0].StartsWith("POST");if(post)Posts++;
   if(mode=="auth"){status=401;text="{\"error\":{\"message\":\"private-provider-body\"}}";}
   else if(mode=="badjson")text="private-provider-body";
   else if(mode=="responses")text="{\"status\":\"completed\",\"output\":[{\"type\":\"image_generation_call\",\"status\":\"completed\",\"result\":\""+png+"\"}]}";
   else if(mode=="responses_missing")text="{\"status\":\"completed\",\"output\":[{\"type\":\"message\"}]}";
   else if(mode=="responses_incomplete")text="{\"status\":\"incomplete\",\"output\":[]}";
   else if(mode=="unknown_task"){status=202;text="{\"id\":\"private-custom-task\",\"status\":\"queued\",\"poll_url\":\"https://foreign.invalid/tasks/id\"}";}
   else if(mode=="empty")text="{\"data\":[]}";
   else if(mode=="async" || mode=="pending" || mode=="failed") {
    if(post){status=202;text="{\"object\":\"image.task\",\"id\":\"provider-task-123\",\"status\":\"queued\"}";}
    else if(path.Contains("/files/")){type="image/png";output=Convert.FromBase64String(png);}
    else if(mode=="failed")text="{\"status\":\"failed\",\"error\":{\"message\":\"private-provider-body\"}}";
    else if(mode=="pending" || polls++==0)text="{\"status\":\"in_progress\"}";
    else text="{\"status\":\"completed\",\"result\":{\"data\":[{\"url\":\"http://127.0.0.1:"+Port+"/v1/images/tasks/provider-task-123/files/0\"}]}}";
   }else if(mode=="url" || mode=="url_external") {if(path.Contains("/file")){type="image/png";output=Convert.FromBase64String(png);}else text="{\"data\":[{\"url\":\"http://"+(mode=="url_external"?"localhost":"127.0.0.1")+":"+Port+"/file\"}]}";}
   if(output==null)output=Encoding.UTF8.GetBytes(text);
   var headers=Encoding.ASCII.GetBytes("HTTP/1.1 "+status+" Synthetic\r\nContent-Type: "+type+"\r\nContent-Length: "+output.Length+"\r\nConnection: close\r\n\r\n");s.Write(headers,0,headers.Length);s.Flush();if(mode=="slowbody")Thread.Sleep(2000);s.Write(output,0,output.Length);s.Flush();
  }}catch(IOException){/* A cancelled client must not stop the fixture listener. */}}}catch(SocketException){}catch(ObjectDisposedException){}catch(InvalidOperationException){if(!stopping)throw;} });
 }
 public void Dispose(){stopping=true;listener.Stop();worker.Wait(3000);}
}
'@
function Test-ExpectFailure([scriptblock]$Action){$bad=$false;try{& $Action|Out-Null}catch{$bad=$true};if(-not $bad){throw 'Expected rejected image configuration'}}
function New-FixtureClient($Server,[string]$Protocol='images_sync') {
    $settings=@{base_url=('http://127.0.0.1:'+$Server.Port+'/v1');model='synthetic-image-model';key='synthetic-image-key';protocol=$Protocol;output_dir=(Join-Path $fixture '图片 输出');jobs_dir=(Join-Path $fixture 'jobs');wait_seconds=60;network='direct'}
    return [CodexImageTools]::new(($settings|ConvertTo-Json -Compress),$false,$true)
}
$imageBytes=[Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZioAAAAASUVORK5CYII=')
$reference=Join-Path $fixture '参考.png';[IO.File]::WriteAllBytes($reference,$imageBytes)
foreach($mode in @('sync','url','url_external','async','auth','badjson','empty','failed')){
    $server=[ImageFixture]::new($mode);$protocol='images_sync';if($mode -in @('async','failed')){$protocol='cctq_async'};$client=New-FixtureClient $server $protocol
    try{
        $value=$client.ExecuteAsync('generate_image','{"prompt":"synthetic image only"}').GetAwaiter().GetResult()|ConvertFrom-Json
        if($mode -in @('sync','url','url_external','async')){
            if($value.status -ne 'completed' -or -not(Test-Path -LiteralPath $value.paths[0])){throw ('Image did not complete: '+$mode+' '+$value.message)}
            if((Get-FileHash -LiteralPath $value.paths[0]).Hash -ne (Get-FileHash -LiteralPath $reference).Hash){throw 'Image bytes changed'}
            if($mode -eq 'url_external' -and $server.LastAuth){throw 'Credential forwarded to a foreign image origin'}
            $again=$client.ExecuteAsync('resume_image_task',(@{job_id=$value.job_id}|ConvertTo-Json -Compress)).GetAwaiter().GetResult()|ConvertFrom-Json
            if($again.paths[0] -ne $value.paths[0] -or $server.Posts -ne 1){throw 'Completed resume submitted a new task'}
        }elseif(($mode -eq 'empty' -and $value.status -ne 'unknown') -or ($mode -ne 'empty' -and $value.status -ne 'failed') -or ($value|ConvertTo-Json -Depth 8) -match 'private-provider-body|synthetic-image-key'){throw 'Image failure was incorrect or exposed private data'}
    }finally{$client.Dispose();$server.Dispose()}
}
$server=[ImageFixture]::new('sync');$client=New-FixtureClient $server
try{
    $result=$client.ExecuteAsync('edit_image',(@{prompt='modify the reference';reference_image_paths=@($reference)}|ConvertTo-Json -Compress)).GetAwaiter().GetResult()|ConvertFrom-Json
    if($result.status -ne 'completed' -or $server.Paths[0] -ne '/v1/images/edits' -or $server.Body -notmatch 'image\[\]'){throw 'Edit multipart contract failed'}
    if((Get-FileHash -LiteralPath $reference).Hash -ne (Get-FileHash -LiteralPath $result.paths[0]).Hash){throw 'Edit overwrote reference'}
    $result=$client.ExecuteAsync('generate_image','{"prompt":"x","base_url":"https://other.invalid"}').GetAwaiter().GetResult()|ConvertFrom-Json
    if($result.status -ne 'failed' -or $server.Posts -ne 1){throw 'Tool arguments changed endpoint'}
}finally{$client.Dispose();$server.Dispose()}
$server=[ImageFixture]::new('slowbody');$client=New-FixtureClient $server
try{
    $waiting=$client.ExecuteAsync('generate_image','{"prompt":"x"}');Start-Sleep -Milliseconds 150
    $stopwatch=[Diagnostics.Stopwatch]::StartNew();$client.Cancel();$stopped=$waiting.GetAwaiter().GetResult()|ConvertFrom-Json
    if($stopped.status -ne 'cancelled' -or $stopwatch.ElapsedMilliseconds -gt 1000){throw 'Stalled image body ignored cancellation'}
}finally{$client.Dispose();$server.Dispose()}
$server=[ImageFixture]::new('pending');$client=New-FixtureClient $server 'cctq_async'
try{
    $pending=$client.ExecuteAsync('generate_image','{"prompt":"x"}')
    for($i=0;$i -lt 100 -and $client.Stage -ne 'in_progress';$i++){Start-Sleep -Milliseconds 30}
    $client.Cancel();$result=$pending.GetAwaiter().GetResult()|ConvertFrom-Json
    if(-not $result.can_resume -or $server.Posts -ne 1 -or $result.status -ne 'cancelled'){throw 'Cancelled asynchronous job cannot resume'}
    $plain=[IO.File]::ReadAllText((Join-Path $fixture ('jobs/'+$result.job_id+'.json')))
    if($plain -match 'synthetic-image-key|provider-task-123|127.0.0.1'){throw 'Task snapshot is not encrypted'}
    $server.Mode='async';$continuation=New-FixtureClient $server 'cctq_async'
    try{
        $resumed=$continuation.ExecuteAsync('resume_image_task',(@{job_id=$result.job_id}|ConvertTo-Json -Compress)).GetAwaiter().GetResult()|ConvertFrom-Json
        if($resumed.status -ne 'completed' -or $server.Posts -ne 1 -or -not(Test-Path -LiteralPath $resumed.paths[0])){throw ('Pending resume did not download the original task without resubmitting: '+$resumed.status+' / '+$resumed.message+' / POST '+$server.Posts)}
    }finally{$continuation.Dispose()}
}finally{$client.Dispose();$server.Dispose()}

foreach($test in @(@('sync','images_auto','completed'),@('async','images_auto','completed'),@('unknown_task','images_auto','unknown'),@('responses','responses_image','completed'),@('responses_missing','responses_image','failed'),@('responses_incomplete','responses_image','failed'),@('auth','responses_image','failed'),@('async','images_sync','pending'))){
    $server=[ImageFixture]::new($test[0]);$client=New-FixtureClient $server $test[1]
    try{
        $value=$client.ExecuteAsync('generate_image','{"prompt":"protocol test"}').GetAwaiter().GetResult()|ConvertFrom-Json
        if($value.status -ne $test[2] -or $server.Posts -ne 1){throw ('New image protocol failed: '+($test -join ',')+' '+$value.message)}
        if($test[1] -eq 'images_auto' -and $server.Body -match '"async"'){throw 'Automatic mode forced async submission'}
        if($test[0] -eq 'responses'){
            $body=$server.Body|ConvertFrom-Json
            if($server.Paths[0] -ne '/v1/responses' -or $body.model -ne 'synthetic-image-model' -or $body.store -ne $false -or $body.stream -ne $false -or $body.tools[0].type -ne 'image_generation'){throw 'Dialogue image request contract incorrect'}
            $edited=$client.ExecuteAsync('edit_image',(@{prompt='edit reference';reference_image_paths=@($reference)}|ConvertTo-Json -Compress)).GetAwaiter().GetResult()|ConvertFrom-Json
            $body=$server.Body|ConvertFrom-Json
            if($edited.status -ne 'completed' -or $body.tools[0].action -ne 'edit' -or $body.input[0].content[1].image_url -notmatch '^data:image/png;base64,'){throw 'Responses reference editing contract incorrect'}
        }
        if($test[0] -eq 'unknown_task'){
            if($value.can_resume -or $server.Paths.Count -ne 1){throw 'Unknown task queried a guessed URL'}
            $resumed=$client.ExecuteAsync('resume_image_task',(@{job_id=$value.job_id}|ConvertTo-Json -Compress)).GetAwaiter().GetResult()|ConvertFrom-Json
            if($resumed.status -ne 'unknown' -or $server.Posts -ne 1 -or $server.Paths.Count -ne 1){throw 'Unknown task was repeated or queried'}
        }
        if($test[2] -eq 'pending'){
            if(-not $value.can_resume){throw 'Forced sync discarded an accepted task'}
            $resumed=$client.ExecuteAsync('resume_image_task',(@{job_id=$value.job_id}|ConvertTo-Json -Compress)).GetAwaiter().GetResult()|ConvertFrom-Json
            if($resumed.status -ne 'completed' -or $server.Posts -ne 1){throw 'Accepted sync task cannot resume without a new POST'}
        }
    }finally{$client.Dispose();$server.Dispose()}
}
$one=New-ImageService;$two=New-ImageService @($one)
if($one.name -eq $two.name -or $one.protocol -ne 'images_auto'){throw 'New image defaults or unique names failed'}
$two.name=$one.name;Repair-ImageNames @($one,$two)
if($one.name -eq $two.name){throw 'Historical duplicate migration failed'}
$legacyService=$one|ConvertTo-Json -Depth 12|ConvertFrom-Json;$legacyService.PSObject.Properties.Remove('protocol')
Save-ImageStore ([pscustomobject]@{version=1;output_dir='';services=@($legacyService)})
$legacyRead=Get-ImageStore
if($legacyRead.services[0].protocol -ne 'images_sync' -or $legacyRead.services[0].id -ne $one.id){throw 'Missing legacy protocol changed default or identity'}
$dialog=New-ApiProfile;$dialog.base_url='https://dialogue.invalid/v1';$dialog.model='synthetic-dialogue-model';$dialog=Complete-ApiProfile $dialog 'synthetic-dialogue-key';$dialog.image_mode='current'
$runtime=New-DialogueImageSnapshot $dialog
if($runtime.model -ne $dialog.model -or $runtime.protocol -ne 'responses_image' -or $runtime.key -ne 'synthetic-dialogue-key'){throw 'Current dialogue snapshot changed model or credentials'}
$dialog.image_mode='';$dialog.image_service_id='legacy-service'
if((Get-ImageMode $dialog) -ne 'service'){throw 'Legacy service binding migration failed'}

$chat=New-ApiProfile;$chat.base_url='https://dialog.example.test/v1';$chat.model='gpt-6.1-sol';$chat.key_url=$chat.base_url;$chat.encrypted_key=Protect-LocalText 'synthetic-dialog-key'
$service=New-ImageService;$service.base_url='https://images.example.test/v1';$service.model='gpt-image-2';$service.key_mode='chat'
Test-ExpectFailure {Get-ImageCredential $service $chat}
$service.base_url=$chat.base_url
if((Get-ImageCredential $service $chat) -cne 'synthetic-dialog-key'){throw 'Same-origin explicit credential reference failed'}
$service.key_mode='own';$service.base_url='https://images.example.test/v1';$service=Complete-ImageService $service 'synthetic-separate-key'
if((Get-ImageCredential $service $chat) -cne 'synthetic-separate-key'){throw 'Independent image credential failed'}
Save-ImageStore ([pscustomobject]@{version=1;output_dir='';services=@($service)})
$chat.image_service_id=$service.id
$official="model = `"official-original`"`r`n[mcp_servers.existing]`r`ncommand = `"keep-existing`"`r`n"
$auth=Join-Path $script:OfficialHome 'auth.json';$config=Join-Path $script:OfficialHome 'config.toml';[IO.File]::WriteAllText($auth,'{"auth_mode":"chatgpt","marker":"synthetic-only"}');[IO.File]::WriteAllText($config,$official)
Set-SharedApi 'http://127.0.0.1:4321/v1' 'gpt-6.1-sol' 'synthetic-bridge-token' '' $chat
$applied=[IO.File]::ReadAllText($config);$state=Get-SwitchState
if($state.version -ne 2 -or $applied -notmatch '\[mcp_servers.codex_launcher_images\]' -or $applied -notmatch 'keep-existing' -or $applied -match 'synthetic-separate-key'){throw 'Image MCP apply/credential isolation failed'}
$runtime=Get-Content -LiteralPath $state.image_runtime_path -Raw|ConvertFrom-Json
$snapshot=(Unprotect-LocalText $runtime.encrypted_runtime)|ConvertFrom-Json
$guard=New-ImageClient $snapshot -ApiSession
[IO.File]::WriteAllText($config,($applied.Replace('tool_timeout_sec = 630','tool_timeout_sec = 631')))
Test-ExpectFailure {Assert-ManagedConnection (Get-SwitchState)}
[IO.File]::WriteAllText($config,$applied);Restore-SharedOfficial
if([IO.File]::ReadAllText($config) -ne $official){throw 'Official MCP/config restore is not exact'}
$unterminated=$official.TrimEnd("`r","`n");[IO.File]::WriteAllText($config,$unterminated)
Set-SharedApi 'http://127.0.0.1:4321/v1' 'gpt-6.1-sol' 'synthetic-bridge-token' '' $chat
Restore-SharedOfficial
if([IO.File]::ReadAllText($config) -cne $unterminated){throw 'Unterminated user MCP line changed during image restore'}
Set-SharedApi 'http://127.0.0.1:4321/v1' 'gpt-6.1-sol' 'synthetic-bridge-token' '' $chat
$disabled=$chat|ConvertTo-Json -Depth 12|ConvertFrom-Json;$disabled.image_service_id=''
Set-SharedApi 'http://127.0.0.1:4321/v1' 'gpt-6.1-sol' 'synthetic-bridge-token' '' $disabled
if([IO.File]::ReadAllText($config) -match '\[mcp_servers.codex_launcher_images\]'){throw 'Disabled binding left the previous image tools installed'}
Restore-SharedOfficial
if([IO.File]::ReadAllText($config) -cne $unterminated){throw 'Binding disable changed unrelated official config'}
$current=$chat|ConvertTo-Json -Depth 12|ConvertFrom-Json;$current.image_mode='current';$current.image_service_id=''
Set-SharedApi 'http://127.0.0.1:4321/v1' 'gpt-6.1-sol' 'synthetic-bridge-token' '' $current
$currentState=Get-SwitchState;$currentRuntime=Get-Content -LiteralPath $currentState.image_runtime_path -Raw -Encoding UTF8|ConvertFrom-Json
$currentSnapshot=Unprotect-LocalText $currentRuntime.encrypted_runtime|ConvertFrom-Json
if($currentSnapshot.protocol -ne 'responses_image' -or $currentSnapshot.base_url -ne $chat.base_url -or $currentSnapshot.model -ne $chat.model){throw 'Current dialogue MCP did not retain upstream identity'}
Restore-SharedOfficial
if([IO.File]::ReadAllText($config) -cne $unterminated){throw 'Dialogue image mode changed the official configuration'}
$foreign=$unterminated+"`r`n[mcp_servers.codex_launcher_images]`r`ncommand = `"user-owned`"`r`n"
[IO.File]::WriteAllText($config,$foreign);$authBefore=(Get-FileHash -LiteralPath $auth).Hash
Test-ExpectFailure {Set-SharedApi 'http://127.0.0.1:4321/v1' 'gpt-6.1-sol' 'synthetic-bridge-token' '' $chat}
if([IO.File]::ReadAllText($config) -cne $foreign -or (Get-FileHash -LiteralPath $auth).Hash -ne $authBefore){throw 'User-owned MCP name collision changed config/auth'}
[IO.File]::WriteAllText($config,$unterminated)
foreach($crashPoint in @('before-first-config-write','before-next-config-write','after-config-write')){
    Set-SharedApi 'http://127.0.0.1:4321/v1' 'gpt-6.1-sol' 'synthetic-bridge-token' '' $chat
    $interrupted=Get-SwitchState;$oldBlock=$interrupted.image_mcp_block;$interrupted.phase='switching'
    if($crashPoint -eq 'before-first-config-write'){
        [IO.File]::WriteAllText($config,$unterminated)
        $interrupted|Add-Member -NotePropertyName image_previous_mcp_block -NotePropertyValue '' -Force
    }elseif($crashPoint -eq 'before-next-config-write'){
        $interrupted|Add-Member -NotePropertyName image_previous_mcp_block -NotePropertyValue $oldBlock -Force
        $interrupted.image_mcp_block=$oldBlock.Replace('startup_timeout_sec = 30','startup_timeout_sec = 31')
    }
    Save-SwitchState $interrupted;Restore-SharedOfficial -Force
    if([IO.File]::ReadAllText($config) -cne $unterminated){throw ('Interrupted image switch cannot restore: '+$crashPoint)}
}
$blocked=$guard.ExecuteAsync('generate_image','{"prompt":"x"}').GetAwaiter().GetResult()|ConvertFrom-Json
if($blocked.status -ne 'failed' -or $blocked.message -notmatch 'inactive'){throw 'Image tool remains active after official restore'};$guard.Dispose()
$process=[Diagnostics.Process]::new();$process.StartInfo=[Diagnostics.ProcessStartInfo]::new()
$process.StartInfo.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$process.StartInfo.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $source 'ImageMcp.ps1')+'" -RuntimePath "'+$state.image_runtime_path+'"'
$process.StartInfo.UseShellExecute=$false;$process.StartInfo.CreateNoWindow=$true;$process.StartInfo.RedirectStandardInput=$true;$process.StartInfo.RedirectStandardOutput=$true;$process.StartInfo.RedirectStandardError=$true
try{
    if(-not $process.Start()){throw 'MCP did not start'}
    $read=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
    foreach($message in @(
        @{jsonrpc='2.0';id=1;method='initialize';params=@{protocolVersion='2025-06-18';capabilities=@{};clientInfo=@{name='isolated-test';version='1'}}},
        @{jsonrpc='2.0';method='notifications/initialized'},
        @{jsonrpc='2.0';id=2;method='tools/list'},
        @{jsonrpc='2.0';id=3;method='tools/call';params=@{name='generate_image';arguments=@{prompt='synthetic-only'}}}
    )){$process.StandardInput.WriteLine(($message|ConvertTo-Json -Depth 12 -Compress))}
    $process.StandardInput.Close()
    if(-not $process.WaitForExit(15000)){throw 'MCP process did not cleanly stop'}
    $output=$read.GetAwaiter().GetResult();$errorOutput=$errors.GetAwaiter().GetResult()
    if($process.ExitCode -ne 0 -or $errorOutput -or $output -match 'synthetic-separate-key'){throw ('MCP initialization failed: '+$errorOutput)}
    $messages=@($output -split '\r?\n'|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json})
    $init=@($messages|Where-Object{$_.id -eq 1})[0];$listing=@($messages|Where-Object{$_.id -eq 2})[0];$call=@($messages|Where-Object{$_.id -eq 3})[0]
    if($init.result.protocolVersion -ne '2025-06-18' -or @($listing.result.tools).Count -ne 3 -or -not $call.result.isError -or $call.result.structuredContent.status -ne 'failed'){throw 'Real MCP handshake/list/call contract failed'}
}finally{$process.Dispose()}
Write-Output 'PASS: sync/base64/URL, async queue/download, edits, cancellation, resume without resubmission, safe errors, encrypted task ownership, same/cross-origin credentials, MCP apply/conflict/exact restore, official-mode guard.'
