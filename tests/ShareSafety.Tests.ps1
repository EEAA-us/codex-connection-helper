$ErrorActionPreference='Stop'
$source=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('CodexLauncher-ShareTest-'+[Guid]::NewGuid().ToString('N'))
$seed=Join-Path $fixture 'source';$output=Join-Path $fixture 'public'
& (Join-Path $source 'Prepare-Share.ps1') -Destination $seed|Out-Null
$marker='synthetic-private-marker-do-not-publish'
foreach($name in @('auth.json','profiles.json','image-services.json','paths.json','preferences.json','shared-switch.json','official-recovery.json','sharing-status.json','.env')){[IO.File]::WriteAllText((Join-Path $seed $name),$marker)}
New-Item -ItemType Directory -Path (Join-Path $seed 'sessions'),(Join-Path $seed 'assets'),(Join-Path $seed 'image-runtime'),(Join-Path $seed 'image-jobs') -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $seed 'image-runtime/private.json'),$marker)
[IO.File]::WriteAllText((Join-Path $seed 'image-jobs/private.json'),$marker)
New-Item -ItemType Directory -Path (Join-Path $seed 'compatibility'),(Join-Path $seed 'plugin-repair-backups') -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $seed 'compatibility/official.json'),$marker)
[IO.File]::WriteAllText((Join-Path $seed 'plugin-repair-backups/private.json'),$marker)
New-Item -ItemType Directory -Path (Join-Path $seed 'portable-plugins'),(Join-Path $seed 'recovery-checkpoints') -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $seed 'portable-plugins/index.json'),$marker)
[IO.File]::WriteAllText((Join-Path $seed 'recovery-checkpoints/auth.encrypted'),$marker)
[IO.File]::WriteAllText((Join-Path $seed 'sessions\private.jsonl'),$marker)
[IO.File]::WriteAllText((Join-Path $seed 'assets\private.txt'),$marker)
& (Join-Path $seed 'Prepare-Share.ps1') -Destination $output|Out-Null
foreach($name in @('auth.json','profiles.json','image-services.json','paths.json','preferences.json','shared-switch.json','official-recovery.json','sharing-status.json','.env','sessions','assets','image-runtime','image-jobs','compatibility','plugin-repair-backups','portable-plugins','recovery-checkpoints')){
    if(Test-Path -LiteralPath (Join-Path $output $name)){throw 'Private data copied into public output'}
}
foreach($file in Get-ChildItem -LiteralPath $output -Recurse -Force -File){
    if($file.Extension -in @('.ps1','.cs','.xaml','.md','.html','.yml','.cmd','.vbs')){
        # The test code itself contains the marker definition; only private fixture files must be excluded.
        if($file.Name -ne 'ShareSafety.Tests.ps1' -and [IO.File]::ReadAllText($file.FullName).Contains($marker)){throw 'Private fixture marker leaked'}
    }
}
$before=(Get-FileHash -LiteralPath (Join-Path $output 'README.md')).Hash
$blocked=$false;try{& (Join-Path $seed 'Prepare-Share.ps1') -Destination $output|Out-Null}catch{$blocked=$true}
if(-not $blocked -or (Get-FileHash -LiteralPath (Join-Path $output 'README.md')).Hash -ne $before){throw 'Existing public directory was overwritten'}
$blocked=$false;try{& (Join-Path $seed 'Prepare-Share.ps1') -Destination (Join-Path $seed 'nested')|Out-Null}catch{$blocked=$true}
if(-not $blocked -or (Test-Path (Join-Path $seed 'nested'))){throw 'Nested public directory accepted'}
'PASS: public copy excludes account, profiles, path settings, sessions and local assets; existing and nested targets are rejected.'
