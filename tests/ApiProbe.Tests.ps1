$ErrorActionPreference='Stop'
$source=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $source 'Launcher.Core.ps1')
$script:OfficialHome=Join-Path ([IO.Path]::GetTempPath()) ('CodexLauncher-ProbeTest-'+[Guid]::NewGuid().ToString('N'))
$warmup=New-ApiConnectionProbe;$warmup.Dispose()
Add-Type -ReferencedAssemblies 'System','System.Core' -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public sealed class ProbeFixture : IDisposable {
 readonly TcpListener listener;
 readonly Task worker;
 public string RequestBody;
 public int Port { get { return ((IPEndPoint)listener.LocalEndpoint).Port; } }
 public ProbeFixture(int status,string type,string text,int holdMs,bool gzip) {
  listener=new TcpListener(IPAddress.Loopback,0);listener.Start();
  worker=Task.Run(()=>{
   try { using(var client=listener.AcceptTcpClient()) using(var stream=client.GetStream()) {
    var header=new StringBuilder();int current;
    while((current=stream.ReadByte())>=0){header.Append((char)current);if(header.ToString().EndsWith("\r\n\r\n"))break;if(header.Length>65536)throw new Exception();}
    int size=0;foreach(var line in header.ToString().Split('\n'))if(line.StartsWith("Content-Length:",StringComparison.OrdinalIgnoreCase))size=Int32.Parse(line.Substring(15).Trim());
    var body=new byte[size];int read=0;while(read<size){int n=stream.Read(body,read,size-read);if(n<=0)break;read+=n;}RequestBody=Encoding.UTF8.GetString(body);
    var output=Encoding.UTF8.GetBytes(text);
    if(gzip){using(var compressed=new MemoryStream()){using(var zip=new GZipStream(compressed,CompressionMode.Compress,true))zip.Write(output,0,output.Length);output=compressed.ToArray();}}
    var headers=Encoding.ASCII.GetBytes("HTTP/1.1 "+status+" Synthetic\r\nContent-Type: "+type+"\r\n"+(gzip?"Content-Encoding: gzip\r\n":"")+"Connection: close\r\n\r\n");
    stream.Write(headers,0,headers.Length);stream.Write(output,0,output.Length);stream.Flush();
    if(holdMs>0)Thread.Sleep(holdMs);
   }}catch(IOException){}catch(SocketException){}catch(ObjectDisposedException){}
  });
 }
 public void Dispose(){listener.Stop();worker.Wait(6000);}
}
'@
function Run-Case([string]$Body,[string]$Expected,[int]$Status=200,[string]$Type='text/event-stream',[int]$HoldMs=0,[switch]$Cancel,[switch]$Gzip){
    $server=[ProbeFixture]::new($Status,$Type,$Body,$HoldMs,[bool]$Gzip);$probe=New-ApiConnectionProbe
    try{
        $task=$probe.RunAsync(('http://127.0.0.1:'+$server.Port+'/v1/responses'),'synthetic-token','{"model":"synthetic-model","stream":true,"store":false,"input":"Reply exactly OK. Do not use tools.","tools":[],"max_output_tokens":512}',1)
        if($Cancel){$probe.Cancel()}
        $result=$task.GetAwaiter().GetResult()
        if($result.Code -ne $Expected -or $result.Success -ne ($Expected -eq 'ok')){throw ('Unexpected probe result: '+$result.Code+' vs '+$Expected)}
        if($probe.Stage -ne 'finished'){throw 'Probe progress did not reach a terminal state'}
        if($Expected -eq 'ok' -and ($result.HeadersMs -lt 0 -or $result.FirstTextMs -lt $result.HeadersMs -or $result.FirstTextMs -gt $result.ElapsedMs)){throw 'Probe timing phases do not follow the response lifecycle'}
        if($Expected -in @('cancelled','timeout') -and $result.ElapsedMs -gt 1500){throw 'Probe cancellation/timeout did not stop promptly'}
        $safe=$result|ConvertTo-Json
        if($safe -match 'private-marker|synthetic-token|fixture-response-id'){throw 'Probe returned private response data'}
        if($server.RequestBody -notmatch 'Reply exactly OK' -or $server.RequestBody -match 'history|project'){if(-not $Cancel){throw 'Unexpected probe request'}}
    }finally{$probe.Dispose();$server.Dispose()}
}
$completed='data: {"type":"response.completed","response":{"id":"fixture-response-id","object":"response","status":"completed","output":[{"id":"message-id","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"完整回复 private-marker"}]}]}}'+"`r`n`r`n"
Run-Case $completed 'ok';Run-Case $completed 'ok' -Gzip
Run-Case ($completed.Replace('完整回复 private-marker',('中文😀'*5000))) 'ok'
Run-Case ($completed.Replace('"status":"completed","content"','"status":"in_progress","content"')) 'empty_or_invalid_completion'
Run-Case ($completed.Replace('完整回复 private-marker','')) 'empty_or_invalid_completion'
Run-Case ('data: {"type":"response.output_text.delta","delta":"already visible"}'+"`n`n") 'missing_completion'
Run-Case ('data: [DONE]'+"`n`n") 'missing_completion'
Run-Case ('data: {"type":"response.failed","response":{"error":{"message":"private-marker"}}}'+"`n`n") 'provider_error'
Run-Case ('data: {"type":"response.incomplete"}'+"`n`n") 'incomplete'
Run-Case ('data: invalid-json'+"`n`n") 'invalid_response'
Run-Case '<html>private-marker</html>' 'unsupported_protocol' -Type 'text/html'
foreach($status in @(401,403,404,429,500)){Run-Case 'private-marker' 'http_error' -Status $status -Type 'application/json'}
Run-Case (':'+'x'*1048577) 'response_too_large'
Run-Case ': waiting' 'timeout' -HoldMs 1600
Run-Case ': waiting' 'cancelled' -HoldMs 300 -Cancel
# Verify production helper initialization/cleanup and synthetic request isolation.
$server=[ProbeFixture]::new(200,'text/event-stream',$completed,0,$false)
$script:Stopped=$false;$script:Port=$server.Port
function Start-HttpCompatibility {param($Url,$Key,$Cancellation)
    if($Url -ne 'https://provider.example.invalid/v1' -or $Key -ne 'synthetic-key'){throw 'Unexpected upstream credential'}
    [pscustomobject]@{url=('http://127.0.0.1:'+$script:Port+'/v1');token='synthetic-token';process=[pscustomobject]@{StandardInput=[IO.StringWriter]::new()}}
}
function Stop-HttpCompatibility {param($Bridge) $script:Stopped=$true}
try{
    $profile=New-ApiProfile 'synthetic';$profile.base_url='https://provider.example.invalid/v1';$profile.model='synthetic-model';$profile.key_url=$profile.base_url;$profile.encrypted_key=Protect-LocalText 'synthetic-key'
    $result=Test-ProfileConnection $profile
    if(-not $result.Success -or -not $script:Stopped){throw 'Production helper did not complete or clean up'}
}finally{$server.Dispose()}
'PASS: complete SSE, compression, incomplete/error/EOF handling, bounded response, timeout/cancellation, private-data suppression and helper cleanup.'
