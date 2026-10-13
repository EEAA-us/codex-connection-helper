param([switch]$TestOnly)
$ErrorActionPreference='Stop'
try {
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    Add-Type -Path (Join-Path $PSScriptRoot 'HttpBridge.cs') -ReferencedAssemblies 'System.Net.Http','System','System.Core','System.Web.Extensions'
    $init=[Console]::In.ReadLine()|ConvertFrom-Json
    $bridge=[CodexHttpBridge]::new([string]$init.url,[string]$init.key,[string]$init.token)
    $diagnosticDir=Join-Path $env:LOCALAPPDATA 'CodexLauncherSafe'
    New-Item -ItemType Directory -Path $diagnosticDir -Force|Out-Null
    $bridge.DiagnosticPath=Join-Path $diagnosticDir 'http-diagnostics.jsonl'
    $init=$null
    $bridge.Start()
    [Console]::Out.WriteLine(($bridge.Port).ToString())
    $owner=[Console]::In.ReadLine()
    if ($owner -eq 'test') { for(;;){$command=[Console]::In.ReadLine();if($null -eq $command -or $command -eq 'stop'){break}} }
    else {
        $ownedProcess=[Diagnostics.Process]::GetProcessById([int]$owner)
        $ownedProcess.WaitForExit()
    }
} catch { [Console]::Error.WriteLine('HTTP compatibility bridge could not run.');exit 1 }
finally {if($bridge){$bridge.Dispose()}}
