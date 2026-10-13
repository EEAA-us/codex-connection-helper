param([Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
$target=[IO.Path]::GetFullPath($Destination)
$origin=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
if($target.Equals($origin,[StringComparison]::OrdinalIgnoreCase) -or $target.StartsWith($origin+'\',[StringComparison]::OrdinalIgnoreCase)){
    throw '分享目录必须在源码文件夹之外。'
}
if(Test-Path -LiteralPath $target){throw '目标已经存在。请选择新的空目录，避免混入本机数据；脚本不会覆盖或删除旧目录。'}
. (Join-Path $PSScriptRoot 'Distribution.ps1')
$allowed=@(Get-DistributionFiles)
foreach($relative in $allowed){
    $path=Join-Path $origin $relative
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw ('发行文件缺失：'+$relative)}
    $item=Get-Item -LiteralPath $path -Force
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw '分享文件不能是链接。'}
    $parent=$item.Directory
    while($parent -and $parent.FullName.Length -ge $origin.Length){
        if($parent.Attributes -band [IO.FileAttributes]::ReparsePoint){throw '分享文件的父目录不能是链接。'}
        $parent=$parent.Parent
    }
}
New-Item -ItemType Directory -Path $target|Out-Null
foreach($relative in $allowed){
    $destinationFile=Join-Path $target $relative
    New-Item -ItemType Directory -Path (Split-Path $destinationFile) -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $origin $relative) -Destination $destinationFile
    if((Get-FileHash -LiteralPath (Join-Path $origin $relative)).Hash -ne (Get-FileHash -LiteralPath $destinationFile).Hash){throw '分享文件校验失败。'}
}
Write-Output ('已创建干净分享目录，共 '+$allowed.Count+' 个文件：'+$target)
