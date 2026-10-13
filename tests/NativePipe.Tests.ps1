param([string]$ReportPath)
$ErrorActionPreference='Stop'
$source=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('CodexLauncher-原生 UTF8-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture|Out-Null
$engine=Join-Path $fixture 'native-fixture.exe'
$code=@'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Web.Script.Serialization;
public static class Utf8NativeFixture {
 public static int Main() {
  var json=new JavaScriptSerializer();
  using(var reader=new StreamReader(Console.OpenStandardInput(),new UTF8Encoding(false,true),false))
  using(var writer=new StreamWriter(Console.OpenStandardOutput(),new UTF8Encoding(false)){AutoFlush=true}) {
   try {
    string line;
    while((line=reader.ReadLine())!=null) {
     var request=json.DeserializeObject(line) as Dictionary<string,object>;
     if(!request.ContainsKey("id"))continue;
     var method=Convert.ToString(request["method"]);var args=request["params"] as Dictionary<string,object>;object result=new{};
     if(method=="account/read")result=new{account=new{type="apiKey"}};
     if(method=="plugin/install")result=new{observedCatalog=Convert.ToString(args["marketplacePath"])};
     if(method=="plugin/installed")result=new{marketplaces=new object[0],observedCwd=Convert.ToString(((object[])args["cwds"])[0])};
     if(method=="skills/list")result=new{data=new object[0],observedCwd=Convert.ToString(((object[])args["cwds"])[0])};
     if(method=="mcpServerStatus/list" || method=="app/installed") {
      if(File.Exists("plugins-only.flag"))return 3;
      result=method=="app/installed" ? (object)new{apps=new object[0]} : new{data=new object[0]};
     }
     writer.WriteLine(json.Serialize(new{id=request["id"],result=result}));
    }
    return 0;
   }catch(DecoderFallbackException){return 2;}
  }
 }
}
'@
Add-Type -TypeDefinition $code -ReferencedAssemblies 'System','System.Core','System.Web.Extensions' -OutputAssembly $engine -OutputType ConsoleApplication
# This fixture contains no credentials. Capture bounded stderr only in the test
# assembly so CI startup failures are diagnosable without logging production RPCs.
$probeCode=[IO.File]::ReadAllText((Join-Path $source 'NativeProbe.cs'))
$probeCode=$probeCode.Replace('process.ErrorDataReceived+=(s,e)=>{};', 'process.ErrorDataReceived+=(s,e)=>{if(e.Data!=null)Console.Error.WriteLine("Synthetic fixture stderr: "+e.Data.Substring(0,Math.Min(500,e.Data.Length)));};')
Add-Type -TypeDefinition $probeCode -ReferencedAssemblies 'System','System.Core','System.Web.Extensions'
$project=Join-Path $fixture '项目 中文 空格';New-Item -ItemType Directory -Path $project|Out-Null
$catalog=Join-Path $fixture '图片与设计/市场.json'
$repair=@{pluginName='design-partner';marketplacePath=$catalog;launcherExpectedMode='api'}|ConvertTo-Json -Compress
foreach($plan in @('',$repair)){
    $probe=[CodexNativeProbe]::new()
    try{$raw=$probe.RunAsync($engine,$fixture,$fixture,$project,$plan).GetAwaiter().GetResult()|ConvertFrom-Json}catch{throw ('Native fixture failed at '+$probe.Stage+': '+$_.Exception.GetBaseException().Message)}finally{$probe.Dispose()}
    if($raw.plugins.observedCwd -cne $project -or $raw.skills.observedCwd -cne $project){throw 'Unicode project path changed in native pipe'}
    if($plan -and $raw.repair.observedCatalog -cne $catalog){throw 'Unicode marketplace path changed in native pipe'}
}
[IO.File]::WriteAllText((Join-Path $project 'plugins-only.flag'),'synthetic')
$probe=[CodexNativeProbe]::new()
try{$raw=$probe.RunPluginsAsync($engine,$fixture,$fixture,$project,'').GetAwaiter().GetResult()|ConvertFrom-Json}finally{$probe.Dispose()}
if($raw.plugins.observedCwd -cne $project -or $raw.skills.observedCwd -cne $project -or $raw.PSObject.Properties['mcp'] -or $raw.PSObject.Properties['apps']){throw 'Plugin source query depended on optional connections'}
$result=[ordered]@{status='pass';powershell=$PSVersionTable.PSVersion.ToString();fixture=$fixture;strictUtf8Decoder='pass';unicodeCwd='pass';unicodeMarketplace='pass';queryAndInstall='pass';realNativeDesktop='unobserved'}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
'PASS: UTF-8 native stdin; exact Chinese/space cwd and marketplace roundtrip, query and install.'
