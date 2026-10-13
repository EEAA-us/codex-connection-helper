$script:CompatibilityRequest=$null;$script:CompatibilityReport=$null
$lastSharing=Get-LastPluginSharingSummary;if($lastSharing){$compatibilitySummary.Text=$lastSharing+"`r`n"+'当前模式尚未检查。'}
$lastSharingDetail=Get-LastPluginSharingDetail;if($lastSharingDetail){$compatibilityDetail.Text=$lastSharingDetail}
function Stop-CompatibilityRequest {
    $job=$script:CompatibilityRequest;if(-not $job){return};$script:CompatibilityRequest=$null;$job.Timer.Stop()
    try{$job.Probe.Cancel();$job.Worker.Stop()}finally{$job.Probe.Dispose();$job.Worker.Dispose();Set-Busy $false;$compatibilityCancel.Visibility='Collapsed';$compatibilityDetail.Text='检查已取消，保留上次结果。'}
}
function Finish-CompatibilityRequest {
    $job=$script:CompatibilityRequest;if(-not $job -or -not $job.Async.IsCompleted){return}
    $job.Timer.Stop()
    try{
        $raw=@($job.Worker.EndInvoke($job.Async));if($raw.Count -ne 1){throw '原生检查没有返回有效结果；请重试。安装、启用与共享状态尚未确认。'}
        $report=Convert-CompatibilityReport ($raw[0]|ConvertFrom-Json) $job.Identity
        $previous=Get-PreviousCompatibilityReport $report.identity;Save-CompatibilityReport $report;$script:CompatibilityReport=$report
        $compatibilityDetail.Text=Get-CompatibilityFindings $report $previous
        $compatibilitySummary.Text=Get-CompatibilitySummary $report $previous
        $lastSharing=Get-LastPluginSharingSummary;if($lastSharing){$compatibilitySummary.Text=$lastSharing+"`r`n"+$compatibilitySummary.Text}
        if($job.Repair){
            if($report.repair_failure_kind -eq 'native_api_catalog_auth'){
                $compatibilityRepairChoice.Items.Clear();$compatibilityRepairPanel.Visibility='Collapsed'
                throw '当前原生引擎不支持 API Key 登录安装官方远程市场插件。市场可搜索不代表能安装；助手不能复制官方账号授权。请在官方模式管理账号插件，本地 MCP 可使用自己的连接。'
            }
            $installed=@($report.plugins|Where-Object{$_.name -eq $job.PluginName -and $_.source_type -eq 'local' -and $_.installed -and $_.enabled})
            if($report.repair_status -eq 'pass' -and $report.plugins_status -eq 'pass' -and $installed.Count){$compatibilityDetail.Text='所选插件的本地安装与启用已在原生清单确认；原生页面显示、外部连接和实际调用仍需核对。'+"`r`n"+$compatibilityDetail.Text}
            else{throw '本次未确认所选插件安装成功；请查看原生插件市场或重新检查。未更改账号插件授权。'}
        }
        $compatibilityRepairChoice.Items.Clear()
        foreach($p in @(Get-LocalPluginRepairCandidates $report $previous)){$item=[Windows.Controls.ComboBoxItem]::new();$item.Tag=$p;$item.Content=$p.name;$compatibilityRepairChoice.Items.Add($item)|Out-Null}
        $compatibilityRepairPanel.Visibility='Collapsed';if($compatibilityRepairChoice.Items.Count){$compatibilityRepairPanel.Visibility='Visible';$compatibilityRepairChoice.SelectedIndex=0}
        if($report.plugins_status -ne 'pass' -or $report.skills_status -ne 'pass' -or $report.identity.native_auth_status -ne 'pass'){
            Show-ResultToast 'notice' '部分检查未完成' '已保留取得的结果；插件共享尚未确认，请查看明细。'
        }elseif($report.mcp_status -ne 'pass' -or $report.apps_status -ne 'pass'){
            Show-ResultToast 'notice' '插件清单已读取，部分连接未确认' '安装与技能结果已保留。账号连接检查未完成；无需因此修改环境位置，普通聊天可继续。'
        }else{Show-ResultToast 'notice' '插件清单已读取' '请查看安装、启用和技能发现结果；原生页面显示与实际调用仍需核对。'}
    }catch{$compatibilityDetail.Text=Get-CompatibilityFailureMessage $_;if($job.Probe.Stage){$compatibilityDetail.Text+=' 检查阶段：'+$job.Probe.Stage+'。'};$compatibilitySummary.Text='当前检查未完成；不能据此认定插件没有安装。展开明细查看原因。';$lastSharing=Get-LastPluginSharingSummary;if($lastSharing){$compatibilitySummary.Text=$lastSharing+"`r`n"+$compatibilitySummary.Text};Show-ResultToast 'error' '兼容检查未完成' $compatibilityDetail.Text}
    finally{$job.Probe.Dispose();$job.Worker.Dispose();$script:CompatibilityRequest=$null;$compatibilityCancel.Visibility='Collapsed';Set-Busy $false}
}
function Start-CompatibilityRequest([switch]$Repair) {
    if($script:Busy){return};$probe=$null;$worker=$null
    try{
        $cwd=$env:USERPROFILE;if($compatibilityCwd.Text.Trim()){$cwd=Convert-LauncherPath $compatibilityCwd.Text '项目目录';if(-not(Test-Path -LiteralPath $cwd -PathType Container)){throw '项目目录不存在。'}}
        Assert-PluginCheckPaths
        $identity=Get-CompatibilityIdentity $cwd;$repairJson=''
        if($Repair){
            $plugin=$compatibilityRepairChoice.SelectedItem.Tag
            $plan=New-LocalPluginRepairPlan $plugin $script:CompatibilityReport.identity.mode
            if(-not $script:CompatibilityReport -or $identity.home -ine $script:CompatibilityReport.identity.home -or $identity.ui -ine $script:CompatibilityReport.identity.ui -or $identity.cwd -ine $script:CompatibilityReport.identity.cwd -or $identity.mode -ne $script:CompatibilityReport.identity.mode){throw '登录、环境或项目范围已改变，请重新检查后修复。'}
            $eligible=@(Get-LocalPluginRepairCandidates $script:CompatibilityReport (Get-PreviousCompatibilityReport $script:CompatibilityReport.identity)|Where-Object id -eq $plugin.id)
            if($eligible.Count -ne 1){throw '插件来源或比较记录已改变，请重新检查后选择。'}
            Backup-LocalPluginRepair;$repairJson=$plan|ConvertTo-Json -Compress
        }
        $engine=Join-Path (Split-Path (Get-DesktopExe)) 'resources/codex.exe'
        $probe=New-CompatibilityProbe;$worker=[PowerShell]::Create()
        $null=$worker.AddScript('param($probe,$engine,$dataHome,$uiPath,$projectCwd,$repair) $ErrorActionPreference="Stop"; $probe.RunAsync($engine,$dataHome,$uiPath,$projectCwd,$repair).GetAwaiter().GetResult()').AddArgument($probe).AddArgument($engine).AddArgument($identity.home).AddArgument($identity.ui).AddArgument($cwd).AddArgument($repairJson)
        $async=$worker.BeginInvoke();$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(250);$timer.Add_Tick({Finish-CompatibilityRequest})
        $pluginName='';if($Repair){$pluginName=$plugin.name}
        $script:CompatibilityRequest=[pscustomobject]@{Probe=$probe;Worker=$worker;Async=$async;Timer=$timer;Identity=$identity;Repair=[bool]$Repair;PluginName=$pluginName}
        Set-Busy $true;$compatibilityCancel.Visibility='Visible';$compatibilityDetail.Text='正在向原生引擎查询插件与技能。不会读取聊天正文或自动安装插件。';$timer.Start()
    }catch{if($probe){$probe.Dispose()};if($worker){$worker.Dispose()};Set-Busy $false;$compatibilityDetail.Text=$_.Exception.Message;Show-ResultToast 'error' '暂时无法检查兼容性' $compatibilityDetail.Text}
}
$compatibilityCheck.Add_Click({Start-CompatibilityRequest});$compatibilityCancel.Add_Click({Stop-CompatibilityRequest})
$compatibilityRepair.Add_Click({Start-CompatibilityRequest -Repair})
$compatibilityRepairChoice.Add_SelectionChanged({if($compatibilityRepairChoice.SelectedItem){$p=$compatibilityRepairChoice.SelectedItem.Tag;$compatibilityRepairPreview.Text='将通过官方接口安装或登记 '+$p.name+' 的本地版本。来源：'+$p.marketplace_path+'。先正常退出 Codex；操作前加密备份配置。外部服务可能需要单独连接，完成后重新检查；不复制官方账号授权。'}})
$form.Add_Closed({Stop-CompatibilityRequest})
