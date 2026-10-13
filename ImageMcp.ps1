param([Parameter(Mandatory=$true)][string]$RuntimePath)
$ErrorActionPreference='Stop'
$client=$null
try{
    . (Join-Path $PSScriptRoot 'Launcher.Core.ps1')
    $runtime=Get-Content -LiteralPath $RuntimePath -Raw -Encoding UTF8|ConvertFrom-Json
    if($runtime.version -ne 1){throw 'Unsupported runtime'}
    $snapshot=(Unprotect-LocalText $runtime.encrypted_runtime)|ConvertFrom-Json
    if($snapshot.runtime_path -cne $RuntimePath){throw 'Runtime mismatch'}
    $client=New-ImageClient $snapshot -ApiSession
    $snapshot.key=$null;$snapshot=$null;$runtime=$null
    $client.RunStdio()
}catch{[Console]::Error.WriteLine('Image tool could not initialize. Check the image service settings and restore state.');exit 1}
finally{if($client){$client.Dispose()}}
