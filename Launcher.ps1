param([switch]$ValidateOnly, [string]$PreviewPath)
$ErrorActionPreference = 'Stop'
trap {
    if ($ValidateOnly) { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
    try { Add-Type -AssemblyName System.Windows.Forms; [Windows.Forms.MessageBox]::Show($_.Exception.Message,'启动器未能打开') | Out-Null } catch { }
    exit 1
}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml,System.Windows.Forms
. (Join-Path $PSScriptRoot 'Launcher.Core.ps1')
. (Join-Path $PSScriptRoot 'Launcher.Dialogs.ps1')
. (Join-Path $PSScriptRoot 'Environment.ps1')
# Give this WPF window its own taskbar identity instead of grouping under PowerShell.
if(-not ('CodexLauncherTaskbar' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexLauncherTaskbar {
    [DllImport("shell32.dll", CharSet=CharSet.Unicode)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
}
'@
}
$null=[CodexLauncherTaskbar]::SetCurrentProcessExplicitAppUserModelID('CodexLauncher.ConnectionAssistant')

$script:ProfileStoreError=''
try{$script:Store = Get-ProfileStore}catch{
    $script:ProfileStoreError=$_.Exception.Message
    $emptyProfile=New-ApiProfile '待重新配置的 API'
    $script:Store=[pscustomobject]@{version=2;selected_id=$emptyProfile.id;profiles=@($emptyProfile)}
}
$script:ModelMetadata=@()
try{$metadataFile=Join-Path $script:OfficialHome 'models_cache.json';if(Test-Path $metadataFile){$script:ModelMetadata=@((Get-Content $metadataFile -Raw -Encoding UTF8|ConvertFrom-Json).models)}}catch{}
$script:Loading=$true;$script:Busy=$false;$script:CurrentId=$script:Store.selected_id;$script:Baseline='';$script:ChangingPage=$false
$script:DesktopClosed=$false;$script:ModelRequest=$null;$script:FinishingModelRequest=$false;$script:CheckState='idle';$script:ProfileQuery='';$script:LaunchRequest=$null
$script:ReasoningModel=$null
$script:ReasoningLabels=@{inherit='继承原设置';none='关闭 / none';minimal='极低 / minimal';low='低 / low';medium='中 / medium';high='高 / high';xhigh='很高 / xhigh';max='最大 / max';ultra='Ultra / ultra'}
$form=New-ThemedWindow ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'UI.xaml')))
$names=@('addButton','profilesList','copyButton','deleteButton','helpButton','recoveryButton','modeBadge','navConnection','navAdvanced','navPlan','editBadge','pageConnection','pageAdvanced','pagePlan','nameBox','urlBox','keyBox','keyHint','modelBox','modelsButton','testButton','windowBox','windowHint','compactBox','searchBox','verbosityBox','toolBox','defaultsButton','planText','apiButton','saveButton','status','inlineError','contentScroll','pageTitle','pageSubtitle','profileCount','planKeyStatus','planPreferences','navHome','pageHome','profileFilter','clearFilterButton','emptyProfiles','checkTitle','checkDetail','footerDivider','footerActions','discardButton','appliedConnection','runtimeStatus','refreshStateButton','homeOfficialButton','homeApiButton','homeEditButton','homeCheckButton','readinessBadge','profileManager','selectedProfileName','homeDiagnostics','connectionDiagnostics','reasoningBox','reasoningHint','reasoningInfoButton','contextInfoButton','compactInfoButton','settingsHelpPopup','settingsHelpTitle','settingsHelpDetail','helpCloseButton','environmentButton','homeProbeButton','replyTestButton','cancelCheckButton','resultToast','resultToastTitle','resultToastIcon','resultToastDetail','resultToastClose','compatibilityCwd','compatibilityCheck','compatibilityCancel','compatibilitySummary','compatibilityDetail','compatibilityRepairPanel','compatibilityRepairChoice','compatibilityRepairPreview','compatibilityRepair','imageCurrentTestButton','imageModelsButton','imageProtocolHint','imageAdvanced','imageBindingBox','imageBindingHint','imageConfigureButton','navImages','pageImages','imageNameBox','imageProtocolBox','imageUrlBox','imageModelBox','imageKeyBox','imageServiceList','imageAddButton','imageCopyButton','imageDeleteButton','imageEditor','imageKeyHint','imageSizeBox','imageQualityBox','imageFormatBox','imageBackgroundBox','imageWaitBox','imageNetworkBox','imageOutputBox','imageFolderButton','imageOutputHint','imageSaveButton','imageDiscardButton','imageEditBadge','imageEmptyHint','imageTestButton','imageCancelButton','imageOpenButton','imageCheckStatus','imageTestPreview')
foreach($name in $names){$control=$form.FindName($name);if(-not $control){throw ('界面缺少控件：'+$name)};Set-Variable -Name $name -Value $control -Scope Script}
# Remove only the retired bundled icon, when no old window is holding it.
$legacyIcon=Join-Path $PSScriptRoot 'codex-launcher.ico'
try{if((Test-Path -LiteralPath $legacyIcon) -and (Get-FileHash -LiteralPath $legacyIcon).Hash -eq '3BF851A1CBC7644BB2241A3668C38E8A0A82720E295555E21A5D900BAB64AFFB'){Remove-Item -LiteralPath $legacyIcon -ErrorAction Stop}}catch{}
try{$iconStream=[IO.File]::OpenRead((Join-Path $PSScriptRoot 'codex-star.ico'));try{$form.Icon=[Windows.Media.Imaging.BitmapFrame]::Create($iconStream,[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad);$form.Icon.Freeze()}finally{$iconStream.Dispose()}}catch{}
$area=[Windows.SystemParameters]::WorkArea
$form.Width=[Math]::Min($form.Width,$area.Width-32);$form.Height=[Math]::Min($form.Height,$area.Height-32)
$form.MinWidth=[Math]::Min($form.MinWidth,$form.Width);$form.MinHeight=[Math]::Min($form.MinHeight,$form.Height)
function Color([string]$Hex){return [Windows.Media.BrushConverter]::new().ConvertFromString($Hex)}
function Update-View {$form.UpdateLayout();$form.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)}
function Invoke-Button($Button){$Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
function Get-KeyText {return $keyBox.Text}
function Set-KeyText([string]$Value){$keyBox.Text=$Value}
function Get-EnteredKey {if($script:KeyEdited){return Get-KeyText};return ''}
function Test-KeyDirty {return (Get-KeyText) -cne ([string]$script:KeyBaseline)}
function Add-ProfileItem($Profile){
    $hostText='尚未设置地址';try{if($Profile.base_url){$hostText=([Uri]$Profile.base_url).Host}}catch{}
    $profilesList.Items.Add([PSCustomObject]@{id=$Profile.id;name=(Get-ApiDisplayName $Profile @($script:Store.profiles));display_host=$hostText})|Out-Null
}
function Save-Preview([string]$Path,$Visual=$null){
    Update-View
    if(-not $Visual){$Visual=$form.Content};$dpi=[Windows.Media.VisualTreeHelper]::GetDpi($Visual)
    $image=[Windows.Media.Imaging.RenderTargetBitmap]::new([int][Math]::Ceiling($visual.ActualWidth*$dpi.DpiScaleX),[int][Math]::Ceiling($visual.ActualHeight*$dpi.DpiScaleY),$dpi.PixelsPerInchX,$dpi.PixelsPerInchY,[Windows.Media.PixelFormats]::Pbgra32)
    $drawing=[Windows.Media.DrawingVisual]::new();$context=$drawing.RenderOpen()
    $rect=[Windows.Rect]::new(0,0,$visual.ActualWidth,$visual.ActualHeight)
    try{$context.DrawRectangle($form.Background,$null,$rect);$brush=[Windows.Media.VisualBrush]::new($visual);$brush.ViewboxUnits=[Windows.Media.BrushMappingMode]::Absolute;$brush.Viewbox=$rect;$brush.Stretch=[Windows.Media.Stretch]::Fill;$context.DrawRectangle($brush,$null,$rect)}finally{$context.Close()}
    $image.Render($drawing);$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($image))
    $file=[IO.File]::Create($Path);try{$encoder.Save($file)}finally{$file.Dispose()}
}
foreach($value in @('继承原设置','128K','200K','256K','400K','1M')){$windowBox.Items.Add($value)|Out-Null}
foreach($value in @('继承原设置','64K','100K','160K','200K','800K')){$compactBox.Items.Add($value)|Out-Null}
foreach($value in @('继承原设置','4K','8K','16K','32K')){$toolBox.Items.Add($value)|Out-Null}
foreach($value in @('继承原设置','关闭','缓存搜索','实时搜索')){$searchBox.Items.Add($value)|Out-Null}
foreach($value in @('继承原设置','简洁 / low','适中 / medium','详细 / high')){$verbosityBox.Items.Add($value)|Out-Null}
$windowBox.ToolTip='单位是 token。200K 表示 200,000；留空继承原值，填写须符合服务商能力。'
$compactBox.ToolTip='达到此预算时 Codex 尝试压缩上下文；自定义时应小于有效窗口。'
$saveButton.ToolTip='Ctrl+S 保存；不会立即切换当前 Codex 连接。'
function Set-Status([string]$Message,[switch]$ErrorState) {
    if($ErrorState){Show-ResultToast 'error' '请检查当前操作' $Message;$Message='操作未完成，请查看上方提示。'}
    $status.Foreground=Color '#56697B'
    $status.Text=$Message;if(-not $script:FinishingModelRequest){Update-View}
}
function Show-Failure([string]$Message){
    $inlineError.Visibility='Collapsed'
    Set-Status '操作未完成，请查看上方提示。'
    Show-ResultToast 'error' '操作未完成' $Message
    $target=$null;$page=0
    if($Message -match '推理强度'){$target=$reasoningBox;$page=1}elseif($Message -match '名称'){$target=$nameBox}elseif($Message -match 'HTTPS|接口地址已改变'){$target=$urlBox}elseif($Message -match 'Key|密钥'){$target=$keyBox}elseif($Message -match '模型名|请填写.*模型'){$target=$modelBox}elseif($Message -match '压缩|compact_limit'){$target=$compactBox;$page=1}elseif($Message -match 'context_window'){$target=$windowBox;$page=1}elseif($Message -match 'tool_output_limit'){$target=$toolBox;$page=1}
    if($target){Show-Page $page;$target.Focus()|Out-Null}
}
function Set-Busy([bool]$Value,[switch]$AllowEditing){
    $script:Busy=$Value
    if(-not $Value){$cancelCheckButton.Visibility='Collapsed'}
    foreach($item in @($compatibilityCwd,$compatibilityCheck,$compatibilityRepair,$compatibilityRepairChoice,$profilesList,$addButton,$copyButton,$deleteButton,$nameBox,$urlBox,$modelBox,$keyBox,$windowBox,$compactBox,$searchBox,$verbosityBox,$toolBox,$reasoningBox,$modelsButton,$testButton,$apiButton,$saveButton,$recoveryButton,$defaultsButton,$profileFilter,$clearFilterButton,$discardButton,$homeOfficialButton,$homeApiButton,$homeCheckButton,$refreshStateButton,$homeProbeButton,$replyTestButton,$environmentButton,$imageBindingBox,$imageCurrentTestButton,$imageEditor,$imageServiceList,$imageAddButton,$imageCopyButton,$imageDeleteButton,$imageTestButton)){$item.IsEnabled=-not $Value}
    if($Value -and $AllowEditing){
        foreach($item in @($nameBox,$urlBox,$modelBox,$keyBox,$windowBox,$compactBox,$searchBox,$verbosityBox,$toolBox,$reasoningBox,$defaultsButton,$imageBindingBox)){$item.IsEnabled=$true}
    }
    $form.Cursor=[Windows.Input.Cursors]::Arrow;$form.ForceCursor=$Value -and -not $AllowEditing
    $discardButton.IsEnabled=-not $Value -and ((Ui-Fingerprint) -cne $script:Baseline -or (Test-KeyDirty))
    Update-Readiness
}
# Nonmodal feedback stays inside this window and never takes keyboard focus.
$script:ResultToastTimer=[Windows.Threading.DispatcherTimer]::new()
$script:ResultToastTimer.Interval=[TimeSpan]::FromSeconds(8)
function Hide-ResultToast {$script:ResultToastTimer.Stop();$resultToast.Visibility='Collapsed'}
function Show-ResultToast([string]$State,[string]$Title,[string]$Detail){
    $script:ResultToastTimer.Stop()
    $script:ResultToastFullDetail=$Detail;$script:ResultToastState=$State
    $resultToastTitle.Text=$Title;$resultToastDetail.Text=$Detail
    $more=$form.FindName('resultToastMore');$more.Visibility='Collapsed'
    if($Detail.Length -gt 180 -or @($Detail -split '\r?\n').Count -gt 4){
        $excerpt=($Detail -replace '\s+',' ').Trim();$limit=[Math]::Min(180,$excerpt.Length)
        if($limit -gt 0 -and [char]::IsHighSurrogate($excerpt[$limit-1])){$limit--}
        $resultToastDetail.Text=$excerpt.Substring(0,$limit)+'…';$more.Visibility='Visible'
    }
    $resultToastIcon.Text='i';$resultToastIcon.Foreground=$form.FindResource('ActionInk')
    $resultToastTitle.Foreground=Color '#375EBB';$resultToast.Background=Color '#EFF5FA';$resultToast.BorderBrush=Color '#DCE5ED'
    if($State -eq 'success'){$resultToastIcon.Text='✓';$resultToastIcon.Foreground=$form.FindResource('SuccessInk');$resultToastTitle.Foreground=Color '#27675A';$resultToast.Background=Color '#F0F8F5';$resultToast.BorderBrush=Color '#B7D5CA'}
    if($State -eq 'error'){$resultToastIcon.Text='!';$resultToastIcon.Foreground=$form.FindResource('DangerInk');$resultToastTitle.Foreground=Color '#AF3749';$resultToast.Background=Color '#FFF3F5';$resultToast.BorderBrush=Color '#E4BDCA'}
    elseif($State -eq 'cancelled'){$resultToastIcon.Text='−';$resultToastIcon.Foreground=$form.FindResource('ActionInk');$resultToastTitle.Foreground=Color '#375EBB';$resultToast.Background=Color '#EFF5FA';$resultToast.BorderBrush=Color '#DCE5ED'}
    $resultToast.Visibility='Visible'
    # Errors remain until dismissed; hover/focus pauses automatic dismissal.
    if($State -ne 'error'){$script:ResultToastTimer.Start()}
}
$script:ResultToastTimer.Add_Tick({if(-not $resultToast.IsMouseOver -and -not $resultToast.IsKeyboardFocusWithin){Hide-ResultToast}})
$resultToastClose.Add_Click({Hide-ResultToast})
function Show-ResultToastDetail {
    $kind='notice';if($script:ResultToastState -eq 'error'){$kind='error'}
    $null=Show-AssistantDialog $kind $resultToastTitle.Text $script:ResultToastFullDetail
}
$form.FindName('resultToastMore').Add_Click({Show-ResultToastDetail})
$form.Add_PreviewKeyDown({param($Sender,$EventArgs)if($EventArgs.Key -eq 'Escape' -and $resultToast.Visibility -eq 'Visible'){Hide-ResultToast;$EventArgs.Handled=$true}})
function Set-CheckState([string]$State,[string]$Title='', [string]$Detail=''){
    $script:CheckState=$State
    if($State -eq 'idle'){$Title='尚未检查接口';$Detail='可检查地址，或发送固定短提示测试回复。'}
    if($State -eq 'stale'){$Title='配置已变更，请重新检查';$Detail='之前的结果不适用于当前输入。'}
    $checkTitle.Text=$Title;$checkDetail.Text=$Detail
    $checkTitle.Foreground=Color '#375EBB'
    if($State -eq 'success'){$checkTitle.Foreground=Color '#27675A'}
    if($State -eq 'error'){$checkTitle.Foreground=Color '#AF3749'}
    if($State -eq 'checking'){$checkTitle.Foreground=Color '#375EBB'}
}
function Invalidate-Check {
    if($script:CheckState -in @('success','error')){Hide-ResultToast;Set-CheckState 'stale'}
}
function Update-Readiness {
    $reason='基础信息已齐全';$ready=$true;$url=''
    if([string]::IsNullOrWhiteSpace($nameBox.Text)){$reason='待填写接口名称';$ready=$false}
    else{try{$url=Normalize-Endpoint $urlBox.Text}catch{$reason='待填写有效的 HTTPS 地址';$ready=$false}}
    if($ready){
        $profile=Current-Profile
        if([string]::IsNullOrWhiteSpace((Get-KeyText)) -or ($profile.key_url -ne $url -and -not $script:KeyEdited)){$reason='待填写这个地址对应的 API Key';$ready=$false}
        elseif($modelBox.Text -match '^gpt-image(?:-|$)'){$reason='请选对话模型；图片模型在图片服务中设置';$ready=$false}
        elseif([string]::IsNullOrWhiteSpace($modelBox.Text)){$reason='待选择默认模型';$ready=$false}
        elseif($script:ReasoningOptions.known -and (Get-ReasoningSelection) -ne 'inherit' -and (Get-ReasoningSelection) -notin $script:ReasoningOptions.levels){$reason='待选择当前模型支持的推理强度';$ready=$false}
    }
    $readinessBadge.Text=$reason;$readinessBadge.Foreground=Color '#56697B'
    if(-not $ready){$readinessBadge.Foreground=Color '#85541E'}
    $canSwitch=$script:DesktopClosed -and -not $script:Busy
    $homeApiButton.IsEnabled=$canSwitch -and $ready
    $homeOfficialButton.IsEnabled=$canSwitch
    $apiButton.IsEnabled=$canSwitch -and $ready
    
    $hint='完全退出 Codex 后，点击“刷新状态”再切换。'
    if($canSwitch){$hint='启动时会保存接口配置，并继续使用原来的本地目录。'}
    foreach($button in @($homeApiButton,$homeOfficialButton,$apiButton)){$button.ToolTip=$hint}
}
function Refresh-Environment {
    $script:DesktopClosed=$false
    try{Assert-DesktopClosed $script:DesktopOverride;$script:DesktopClosed=$true;$runtimeStatus.Text='Codex 已退出，可以切换连接；官方入口独立检查安装位置';$runtimeStatus.Foreground=Color '#27675A'}
    catch{$runtimeStatus.Text=$_.Exception.Message;$runtimeStatus.Foreground=Color '#85541E'}
    Update-ModeBadge
    $appliedConnection.Text=$modeBadge.Text.Replace('当前配置：','')
    try{
        $state=Get-SwitchState
        if($state -and $state.active){$active=@($script:Store.profiles|Where-Object{$_.id -eq $state.active_profile_id})[0];if($active){$appliedConnection.Text='API / '+$active.name}}
    }catch{}
    Update-Readiness
}
function Filter-Profiles {
    if($script:Loading){return}
    $wasLoading=$script:Loading;$script:Loading=$true
    try{
        $script:ProfileQuery=$profileFilter.Text.Trim().ToLowerInvariant()
        $clearFilterButton.Visibility='Collapsed';if($script:ProfileQuery){$clearFilterButton.Visibility='Visible'}
        $profilesList.Items.Filter=$null
        if($script:ProfileQuery){$profilesList.Items.Filter=[Predicate[object]]{param($item) return (($item.name+' '+$item.display_host).ToLowerInvariant().Contains($script:ProfileQuery))}}
        $profilesList.SelectedIndex=-1
        foreach($item in $profilesList.Items){if($item.id -eq $script:CurrentId){$profilesList.SelectedItem=$item;break}}
        $profileCount.Text=[string]$script:Store.profiles.Count
        if($script:ProfileQuery){$profileCount.Text=([string]$profilesList.Items.Count)+' / '+$script:Store.profiles.Count}
        $emptyProfiles.Visibility='Collapsed';if($profilesList.Items.Count -eq 0){$emptyProfiles.Visibility='Visible'}
    }finally{$script:Loading=$wasLoading}
}
function Get-ModelWorkerScript {
    return @'
param([string]$CorePath,[string]$ProfileJson)
$ErrorActionPreference='Stop'
. $CorePath
$watch=[Diagnostics.Stopwatch]::StartNew()
$ids=@(Read-ProfileModels ($ProfileJson|ConvertFrom-Json))
$watch.Stop()
[pscustomobject]@{Models=$ids;ElapsedMs=$watch.ElapsedMilliseconds}
'@
}
function Get-ReplyWorkerScript {
    return @'
param([string]$CorePath,[string]$ProfileJson,$Probe)
$ErrorActionPreference='Stop'
. $CorePath
Test-ProfileConnection ($ProfileJson|ConvertFrom-Json) $Probe
'@
}
function Get-ConnectionCheckError([string]$Code,[int]$HttpStatus) {
    if($Code -eq 'http_error'){
        switch($HttpStatus){
            401 {return '密钥被拒绝（401），请核对 API Key。'}
            403 {return '服务商拒绝访问（403），请核对权限或网络拦截。'}
            404 {return 'Responses 地址或所选模型不可用（404），请核对服务商支持。'}
            429 {return '额度不足或请求限流（429），请检查余额并稍后重试。'}
            400 {return '测试参数被拒绝（400），请核对模型与 Responses 兼容性。'}
            default {return ('服务商返回 HTTP '+$HttpStatus+'，请稍后重试。')}
        }
    }
    switch($Code){
        'timeout' {return '45 秒内未收到完整回复，可能是网络或模型响应较慢。'}
        'cancelled' {return '测试已取消，未确认连接成功。'}
        'unsupported_protocol' {return '返回格式不是 Responses 流，可能是登录网页或不兼容的接口。'}
        'missing_completion' {return '连接已结束，但缺少完整完成事件，不能确认 Codex 可正常结束回复。'}
        'incomplete' {return '服务商返回未完成状态，可能达到测试预算或模型限制。'}
        'provider_error' {return '服务商返回生成失败事件，尚未确认回复能力。'}
        'empty_or_invalid_completion' {return '收到完成事件，但缺少有效的完整文本回复。'}
        'invalid_response' {return '服务商返回了损坏或不兼容的事件数据。'}
        'response_too_large' {return '测试流超过 1 MiB，已停止检查。'}
        default {return '连接测试未完成，请检查网络和本机兼容模块。'}
    }
}
function Stop-ModelRequest {
    $job=$script:ModelRequest
    if(-not $job){return}
    $script:ModelRequest=$null;$job.Timer.Stop()
    try{if($job.Probe){$job.Probe.Cancel()};$job.PowerShell.Stop()}finally{if($job.Probe){$job.Probe.Dispose()};$job.PowerShell.Dispose();Set-Busy $false;Set-CheckState 'cancelled' '检查已取消' '可以重新检查当前接口。';Set-Status '已取消接口检查。';if($job.Kind -eq 'reply'){Show-ResultToast 'cancelled' '回复测试已取消' '未确认连接成功，可以重新测试。'}}
}
function Finish-ModelRequest {
    $job=$script:ModelRequest
    if(-not $job){return}
    if(-not $job.Async.IsCompleted){
        if($job.Kind -eq 'reply' -and $job.Probe){
            $seconds=[int][Math]::Floor($job.Watch.Elapsed.TotalSeconds)
            if($seconds -ne $job.LastSecond){
                $job.LastSecond=$seconds
                $phase=switch($job.Probe.Stage){
                    'starting_bridge' {'正在启动本机兼容模块'}
                    'waiting_headers' {'正在等待服务商响应'}
                    'waiting_reply' {'已收到响应，等待生成'}
                    'generating' {'服务商正在生成回复'}
                    'receiving_text' {'已收到文字，等待完整结束事件'}
                    default {'正在收尾并释放检查资源'}
                }
                Set-CheckState 'checking' ($phase+' · '+$seconds+' 秒') '可以取消；服务商耗时与正式聊天可能不同，只有完整结束后才确认成功。'
            }
        }
        return
    }
    $job.Timer.Stop();$script:FinishingModelRequest=$true
    try{
        $result=@($job.PowerShell.EndInvoke($job.Async))
        if($job.PowerShell.HadErrors -or $result.Count -ne 1){throw '检查未完成，请核对接口、密钥与网络。'}
        if($job.Fingerprint -cne (Ui-Fingerprint) -or $job.KeyText -cne (Get-KeyText)){
            Set-CheckState 'stale' '测试已结束 · 配置已修改' '本次检查使用开始时的配置；修改已保留，请按当前配置重新检查。'
            Show-ResultToast 'info' '检查已结束' '你在等待期间修改了配置。修改已保留，本次结果不用于确认当前配置。'
            return
        }
        if($job.Kind -eq 'reply'){
            $response=$result[0]
            if(-not $response.Success){
                $detail=Get-ConnectionCheckError $response.Code $response.HttpStatus
                Set-CheckState 'error' '真实回复未通过' $detail;Set-Status $detail -ErrorState;Show-ResultToast 'error' '回复测试失败' $detail
                return
            }
            $time=[DateTime]::Now.ToString('HH:mm:ss')
            Set-CheckState 'success' '连接成功 · 真实回复已完成' ($time+' · HTTP '+$response.HttpStatus+' · 请求 '+$response.ElapsedMs+' ms；已验证短回复与完整结束事件。')
            Set-Status '真实短回复通过；工具调用、长上下文和桌面通知仍需实际使用验证。'
            Show-ResultToast 'success' '回复测试成功' ('HTTP '+$response.HttpStatus+' · 请求 '+[Math]::Round($response.ElapsedMs/1000.0,2)+' 秒；已收到完整结束事件。')
            return
        }
        $ids=@($result[0].Models)
        if(-not $ids.Count){throw '模型列表为空，请核对接口地址与服务商配置。'}
        if($job.SaveModels){
            $job.Draft.models=$ids;$list=@($script:Store.profiles)
            for($i=0;$i -lt $list.Count;$i++){if($list[$i].id -eq $job.Draft.id){$list[$i]=$job.Draft}}
            $script:Store.profiles=$list;Save-ProfileStore $script:Store;Refresh-Profiles $job.Draft.id
            try{$catalog=Sync-NativeCatalog $job.Draft.base_url $ids $job.Draft.id;Set-Status ('模型列表已保存；'+$catalog.count+' 个兼容模型将在重开 API 模式后进入菜单。')}
            catch{Set-Status ('模型列表已保存，原生菜单尚未生成：'+$_.Exception.Message) -ErrorState}
        }else{Set-Status ('模型列表已响应，返回 '+$ids.Count+' 个模型。生成与工具能力仍需实际验证。')}
        $time=[DateTime]::Now.ToString('HH:mm:ss')
        Set-CheckState 'success' ('模型列表已响应 · '+$ids.Count+' 个模型') ($time+' 检查，耗时 '+$result[0].ElapsedMs+' ms；生成与工具调用尚未验证。')
    }catch{Set-CheckState 'error' '接口检查失败' '请核对 HTTPS 地址、密钥与网络，再重新检查。';if($job.Kind -eq 'reply'){Show-ResultToast 'error' '回复测试未完成' $checkDetail.Text};Show-Failure $_.Exception.Message}
    finally{if($job.Probe){$job.Probe.Dispose()};$job.PowerShell.Dispose();$script:ModelRequest=$null;Set-Busy $false;$script:FinishingModelRequest=$false}
}
function Start-ModelRequest([switch]$SaveModels,[switch]$TestReply){
    if($script:Busy){return}
    $worker=$null;$probe=$null;Hide-ResultToast;Set-Busy $true -AllowEditing
    try{
        $draft=Complete-ApiProfile (Ui-Draft) (Get-EnteredKey)
        $kind='models';$workerSource=Get-ModelWorkerScript
        if($TestReply){
            $null=New-ThirdPartyConfig $draft.base_url $draft.model
            $kind='reply';$workerSource=Get-ReplyWorkerScript;$probe=New-ApiConnectionProbe
            Set-CheckState 'checking' '正在测试真实回复…' '兼容模块启动最长 15 秒，请求最长 45 秒；仅发送固定短提示，可取消。'
        }else{Set-CheckState 'checking' '正在检查模型列表…' '最长约 12 秒。页面仍可切换，不发送聊天内容。'}
        Set-Status '正在检查开始时的配置；可以继续调整参数，修改会保留。'
        $worker=[PowerShell]::Create()
        $null=$worker.AddScript($workerSource).AddArgument((Join-Path $PSScriptRoot 'Launcher.Core.ps1')).AddArgument(($draft|ConvertTo-Json -Depth 12))
        if($TestReply){$null=$worker.AddArgument($probe)}
        $async=$worker.BeginInvoke()
        $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(120)
        $timer.Add_Tick({Finish-ModelRequest})
        $script:ModelRequest=[pscustomobject]@{PowerShell=$worker;Async=$async;Timer=$timer;Draft=$draft;SaveModels=[bool]$SaveModels;Kind=$kind;Probe=$probe;Fingerprint=(Ui-Fingerprint);KeyText=(Get-KeyText);Watch=[Diagnostics.Stopwatch]::StartNew();LastSecond=-1}
        $cancelCheckButton.Visibility='Visible';$timer.Start()
    }catch{if($probe){$probe.Dispose()};if($worker){$worker.Dispose()};Set-Busy $false;Set-CheckState 'error' '配置需要补充' '请按照页面提示补充或修正，再检查接口。';if($TestReply){Show-ResultToast 'error' '暂时无法测试回复' $checkDetail.Text};Show-Failure $_.Exception.Message}
}
function Current-Profile { return @($script:Store.profiles | Where-Object{$_.id -eq $script:CurrentId})[0] }
function Get-ReasoningSelection {if($reasoningBox.SelectedItem){return [string]$reasoningBox.SelectedItem.Tag};return 'inherit'}
function Update-ReasoningChoices([string]$Value='', [switch]$Force) {
    if(-not $Force -and $script:ReasoningModel -ceq $modelBox.Text){Update-ReasoningHint;return}
    if(-not $Value){$Value=Get-ReasoningSelection};if(-not $Value){$Value='inherit'}
    $wasLoading=$script:Loading;$script:Loading=$true
    try{
        $script:ReasoningModel=$modelBox.Text;$options=Get-ModelReasoningOptions $modelBox.Text;$script:ReasoningOptions=$options
        $reasoningBox.Items.Clear()
        foreach($level in @('inherit')+@($options.levels)){$item=[Windows.Controls.ComboBoxItem]::new();$item.Tag=$level;$item.Content=$script:ReasoningLabels[$level];$reasoningBox.Items.Add($item)|Out-Null}
        if($Value -ne 'inherit' -and $Value -notin $options.levels){
            $label=$script:ReasoningLabels[$Value];if(-not $label){$label=$Value}
            $item=[Windows.Controls.ComboBoxItem]::new();$item.Tag=$Value;$item.Content=$label+'（需调整）';$reasoningBox.Items.Add($item)|Out-Null
        }
        $reasoningBox.SelectedValue=$Value
        Update-ReasoningHint
    }finally{$script:Loading=$wasLoading}
}
function Update-ReasoningHint {
    $reasoningHint.Text='保存后，在下次 API 启动时作为默认值。'
    if(-not $script:ReasoningOptions.known){$reasoningHint.Text='未知模型：请向服务商确认支持的档位。'}
    if($script:ReasoningOptions.known -and (Get-ReasoningSelection) -ne 'inherit' -and (Get-ReasoningSelection) -notin $script:ReasoningOptions.levels){$reasoningHint.Text='当前模型未声明支持此档位，请重新选择。'}
}
function Ui-Fingerprint {
    return (@($nameBox.Text,$urlBox.Text,$modelBox.Text,$windowBox.Text,$compactBox.Text,$searchBox.SelectedIndex,$verbosityBox.SelectedIndex,$toolBox.Text,(Get-ReasoningSelection),[string]$imageBindingBox.SelectedValue) | ConvertTo-Json -Compress)
}
function Ui-Draft {
    $draft=(Current-Profile) | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $draft.name=$nameBox.Text;$draft.base_url=$urlBox.Text;$draft.model=$modelBox.Text
    $draft.context_window=$windowBox.Text;$draft.compact_limit=$compactBox.Text;$draft.tool_output_limit=$toolBox.Text
    $draft.web_search=@('inherit','disabled','cached','live')[$searchBox.SelectedIndex]
    $draft.verbosity=@('inherit','low','medium','high')[$verbosityBox.SelectedIndex]
    $draft.reasoning_effort=Get-ReasoningSelection
    $draft.image_service_id=[string]$imageBindingBox.SelectedValue
    $draft.image_mode='service';if(-not $draft.image_service_id){$draft.image_mode='off'}elseif($draft.image_service_id -eq '__current__'){$draft.image_mode='current';$draft.image_service_id=''}
    return $draft
}
function Update-Plan {
    Update-ReasoningChoices
    $dirty=((Ui-Fingerprint) -ne $script:Baseline -or (Test-KeyDirty))
    $editBadge.Text='已保存';$editBadge.Foreground=Color '#667085';if($dirty){$editBadge.Text='有未保存修改';$editBadge.Foreground=Color '#A06524'}
    $discardButton.Visibility='Visible';$discardButton.IsEnabled=$dirty -and -not $script:Busy
    $keyStatus='待输入 Key';if((Get-KeyText)){$keyStatus='Key 已保存';if(Test-KeyDirty){$keyStatus='Key 已修改，待保存'}}
    $planKeyStatus.Text=$keyStatus
    $planPreferences.Text="推理：$($reasoningBox.SelectedItem.Content)；工具输出：$($toolBox.Text)；联网：$($searchBox.Text)；回答：$($verbosityBox.Text)"
    $model=$modelBox.Text;if(-not $model){$model='待选择'}
    $window=$windowBox.Text;if(-not $window){$window='继承原设置'}
    $compact=$compactBox.Text;if(-not $compact){$compact='继承原设置'}
    $imageSummary='关闭';if($imageBindingBox.SelectedValue){$imageSummary=[string]$imageBindingBox.SelectedItem.Content}
    $planText.Text="接口：$($nameBox.Text)`r`n地址：$($urlBox.Text)`r`n模型：$model`r`n图片服务：$imageSummary`r`n上下文：$window   ·   压缩阈值：$compact`r`n联网：$($searchBox.Text)   ·   回答：$($verbosityBox.Text)`r`n凭据：$keyStatus`r`n记录：原聊天、项目与插件目录共用；官方登录先加密备份。"
    try{
        $official=Get-OfficialTransportText
        $windowMatch=[regex]::Match($official,'(?m)^\s*model_context_window\s*=\s*([\d_]+)')
        $inherited='模型默认'
        if($windowMatch.Success){$inherited=$windowMatch.Groups[1].Value.Replace('_','')+' Tokens'}else{
            $entry=@($script:ModelMetadata|Where-Object{$_.slug -ceq $modelBox.Text})[0];if($entry -and $entry.context_window){$inherited=([string]$entry.context_window)+' Tokens（本机模型元数据）'}
        }
        $windowHint.Text='继承值：'+$inherited+'。'
    }catch{$windowHint.Text='继承原设置；服务商实际支持的长度需自行确认。'}
    Update-ImageBindingHint
    Update-Readiness
}
function Update-ModeBadge {
    $modeBadge.Text='当前配置：原有连接';$modeBadge.Foreground=Color '#375EBB'
    try{
        $state=Get-SwitchState
        if($state -and $state.active){Assert-ManagedConnection $state;$modeBadge.Text='当前配置：API 模式'}else{
            $authPath=Join-Path $script:OfficialHome 'auth.json'
            if(Test-Path $authPath){$authMode=(Get-Content $authPath -Raw -Encoding UTF8|ConvertFrom-Json).auth_mode;if($authMode -match 'chatgpt'){$modeBadge.Text='当前配置：官方账号'}}
        }
    }catch{$modeBadge.Text='当前连接需要检查';$modeBadge.Foreground=Color '#A06524'}
}
function Set-TokenBox($Box,[string]$Value){
    $display='继承原设置'
    if($Value){
        $display=$Value
        if($Value -match '^\d+$'){
            $amount=[long]$Value
            if($amount -ge 1000000 -and $amount%1000000 -eq 0){$display=([string]($amount/1000000))+'M'}elseif($amount -ge 1000 -and $amount%1000 -eq 0){$display=([string]($amount/1000))+'K'}
        }
    }
    if(-not $Box.Items.Contains($display)){$Box.Items.Add($display)|Out-Null}
    $Box.SelectedIndex=-1
    $Box.SelectedItem=$display
    $Box.Text=$display
}
function Load-Profile($Profile){
    Hide-ResultToast
    Set-CheckState 'idle'
    $script:Loading=$true;$script:CurrentId=$Profile.id;$script:Store.selected_id=$Profile.id
    $selectedProfileName.Text=Get-ApiDisplayName $Profile @($script:Store.profiles);$nameBox.Text=$Profile.name;$urlBox.Text=$Profile.base_url;Set-KeyText ''
    $keyHint.Text='填写这个接口的 API Key；保存后会自动显示。'
    if($Profile.encrypted_key){try{Set-KeyText (Get-LocalKey $Profile $Profile.base_url);$keyHint.Text='已保存；可直接查看和修改 Key。'}catch{$keyHint.Text='已保存的 Key 无法读取，请重新填写。'}}
    $script:KeyBaseline=Get-KeyText;$script:KeyEdited=$false
    Refresh-ImageBindings;$imageBindingBox.SelectedValue=[string]$Profile.image_service_id;if((Get-ImageMode $Profile) -eq 'current'){$imageBindingBox.SelectedValue='__current__'}elseif((Get-ImageMode $Profile) -eq 'off'){$imageBindingBox.SelectedValue=''}
    $modelBox.Items.Clear();foreach($id in @($Profile.models)){if($id){$modelBox.Items.Add($id)|Out-Null}};$modelBox.Text=$Profile.model
    Update-ReasoningChoices $Profile.reasoning_effort -Force
    Set-TokenBox $windowBox $Profile.context_window
    Set-TokenBox $compactBox $Profile.compact_limit
    Set-TokenBox $toolBox $Profile.tool_output_limit
    $searchBox.SelectedIndex=[Array]::IndexOf(@('inherit','disabled','cached','live'),[string]$Profile.web_search)
    $verbosityBox.SelectedIndex=[Array]::IndexOf(@('inherit','low','medium','high'),[string]$Profile.verbosity)
    if($searchBox.SelectedIndex -lt 0){$searchBox.SelectedIndex=0};if($verbosityBox.SelectedIndex -lt 0){$verbosityBox.SelectedIndex=0}
    $script:Baseline=Ui-Fingerprint;$script:Loading=$false;Update-Plan
}
function Refresh-Profiles([string]$Id){
    $script:Loading=$true;$profileFilter.Text='';$script:ProfileQuery='';$clearFilterButton.Visibility='Collapsed';$profilesList.Items.Filter=$null;$emptyProfiles.Visibility='Collapsed';$profilesList.Items.Clear();$index=0;$selected=0
    foreach($profile in @($script:Store.profiles)){Add-ProfileItem $profile;if($profile.id -eq $Id){$selected=$index};$index++}
    $profileCount.Text=[string]$profilesList.Items.Count
    $profilesList.SelectedIndex=$selected;$script:CurrentId=$profilesList.Items[$selected].id;$script:Loading=$false;Load-Profile (Current-Profile)
}
function Save-Current {
    if($script:ProfileStoreError){
        $answer=Show-AssistantDialog 'replace-profile' '重新保存 API 配置？' '旧 API 配置无法读取。确认后先备份原文件，再保存当前填写的配置；取消不改文件，仍可使用官方模式。'
        if($answer -ne 'confirm'){throw '已取消保存；旧文件保留，官方入口仍可使用。'}
    }
    $profile=Complete-ApiProfile (Ui-Draft) (Get-EnteredKey)
    $list=@($script:Store.profiles)
    for($i=0;$i -lt $list.Count;$i++){if($list[$i].id -eq $profile.id){$list[$i]=$profile}}
    $script:Store.profiles=$list;$script:Store.selected_id=$profile.id;Save-ProfileStore $script:Store
    $script:ProfileStoreError=''
    Refresh-Profiles $profile.id
    return $profile
}
function Confirm-Leave {
    if($script:Loading -or ((Ui-Fingerprint) -eq $script:Baseline -and -not (Test-KeyDirty))){return $true}
    $choice=Show-AssistantDialog 'save' '保存这次修改？' '这项接口配置还没有保存。选择保存后继续，或保留原来的配置。' (Current-Profile).name
    if($choice -eq 'cancel'){return $false}
    if($choice -eq 'save'){try{$null=Save-Current}catch{Show-Failure $_.Exception.Message;return $false}}
    return $true
}
function Show-Page([int]$Index){
    if($script:ChangingPage){return}
    $script:ChangingPage=$true
    $profileManager.IsExpanded=$false;$settingsHelpPopup.IsOpen=$false
    try{
        $pages=@($pageConnection,$pageAdvanced,$pagePlan,$pageHome,$pageImages);$buttons=@($navConnection,$navAdvanced,$navPlan,$navHome,$navImages)
        for($i=0;$i -lt $pages.Count;$i++){$pages[$i].Visibility='Collapsed';$buttons[$i].IsChecked=($i -eq $Index)}
        $pages[$Index].Visibility='Visible'
        $pageTitle.Text=@('接口配置','API 参数','启动摘要','切换连接','图片服务')[$Index]
        $pageSubtitle.Text=@('设置接口地址、密钥和默认模型。','设置 API 默认参数，返回官方恢复原值。','确认连接设置，接着之前的工作。','退出 Codex 后，选择连接并继续工作。','配置生成和修改图片的接口，继续使用原来的对话模型。')[$Index]
        $footerActions.Visibility='Visible';$footerDivider.Visibility='Visible';$saveButton.IsDefault=$true
        if($Index -eq 3){$footerActions.Visibility='Collapsed';$footerDivider.Visibility='Collapsed';$saveButton.IsDefault=$false;Refresh-Environment}
        if($Index -eq 4){$footerActions.Visibility='Collapsed';$footerDivider.Visibility='Collapsed';$saveButton.IsDefault=$false}
        $contentScroll.ScrollToTop();Update-Plan
    }finally{$script:ChangingPage=$false}
}
$profilesList.Add_SelectionChanged({
    if($script:Loading -or $profilesList.SelectedIndex -lt 0){return}
    $desired=$profilesList.SelectedItem.id
    if($desired -eq $script:CurrentId){return}
    if(-not (Confirm-Leave)){
        $script:Loading=$true
        for($i=0;$i -lt $profilesList.Items.Count;$i++){if($profilesList.Items[$i].id -eq $script:CurrentId){$profilesList.SelectedIndex=$i;break}}
        $script:Loading=$false;return
    }
    Refresh-Profiles $desired;Save-ProfileStore $script:Store;$profileManager.IsExpanded=$false;Set-Status '已选中接口。点击启动后才会应用到 Codex。'
})
$addButton.Add_Click({
    if(-not (Confirm-Leave)){return}
    try{$profile=New-ApiProfile (Get-UniqueApiName '新 API 接口' @($script:Store.profiles));$script:Store.profiles=@($script:Store.profiles)+@($profile);$script:Store.selected_id=$profile.id;Save-ProfileStore $script:Store;Refresh-Profiles $profile.id;$profileManager.IsExpanded=$false;Show-Page 0;Set-Status '已添加接口。填写名称、地址和自己的 Key，再保存。'}catch{Show-Failure $_.Exception.Message}
})
$copyButton.Add_Click({
    if(-not (Confirm-Leave)){return}
    try{$profile=(Current-Profile)|ConvertTo-Json -Depth 12|ConvertFrom-Json;$profile.id=[Guid]::NewGuid().ToString('N');$profile.name=Get-UniqueApiName ($profile.name.Substring(0,[Math]::Min(50,$profile.name.Length))+' · 副本') @($script:Store.profiles);$script:Store.profiles=@($script:Store.profiles)+@($profile);$script:Store.selected_id=$profile.id;Save-ProfileStore $script:Store;Refresh-Profiles $profile.id;Set-Status '已复制配置。同地址可沿用 Key；更换地址时重新输入。'}catch{Show-Failure $_.Exception.Message}
})
$deleteButton.Add_Click({
    if(@($script:Store.profiles).Count -le 1){Show-Failure '至少保留一个接口。可以先添加新接口，再移除这一项。';return}
    if(-not (Confirm-Leave)){return}
    $choice=Show-AssistantDialog 'remove' '移除这项配置？' '它将从 API 配置列表中移除。加密备份会保留，聊天和项目不会删除。' (Current-Profile).name
    if($choice -ne 'confirm'){return}
    try{$script:Store.profiles=@($script:Store.profiles|Where-Object{$_.id -ne $script:CurrentId});$script:Store.selected_id=$script:Store.profiles[0].id;Save-ProfileStore $script:Store;Refresh-Profiles $script:Store.selected_id;Set-Status '已从配置列表移除；聊天和项目仍保留。'}catch{Show-Failure $_.Exception.Message}
})
$saveButton.Add_Click({try{$null=Save-Current;Set-Status '配置已保存。正在运行的 Codex 不会立即改变接口。'}catch{Show-Failure $_.Exception.Message}})
$modelsButton.Add_Click({Start-ModelRequest -SaveModels})
$testButton.Add_Click({Start-ModelRequest})
function Finish-ApiLaunch {
    $job=$script:LaunchRequest;if(-not $job -or -not $job.Async.IsCompleted){return}
    $job.Timer.Stop()
    try{
        $raw=@($job.Worker.EndInvoke($job.Async))
        if($raw.Count -ne 1 -or -not $raw[0].PSObject.Properties['error']){throw '后台启动没有返回有效结果，请重试；如需官方登录，可使用恢复官方入口。'}
        $result=$raw[0]
        if($result.error){throw $result.error}
        if(-not $result.pid -or $result.pid -le 0){throw '后台未确认应用启动，请刷新状态后重试。'}
        $script:DesktopClosed=$false;$runtimeStatus.Text='已请求启动 Codex；再次切换前，请退出并刷新状态。';$appliedConnection.Text='API / '+$job.ProfileName
        Update-ModeBadge;Set-Status ('已请求启动 '+$job.ProfileName+'。进入原聊天后检查模型与插件。')
        if($result.image_warning){
            Set-Status '已请求启动 API；图片功能需要核对，详情见上方提示。'
            $detail=$result.image_warning;if($result.sharing){$detail=$result.sharing+"`r`n`r`n"+$detail}
            Show-ResultToast 'notice' '启动检查有提示' $detail
        }elseif($result.sharing){Show-ResultToast 'notice' '插件共享检查' $result.sharing}
    }catch{Show-Failure $_.Exception.Message}
    finally{$job.Worker.Dispose();$script:LaunchRequest=$null;Set-Busy $false}
}
$apiButton.Add_Click({
    Set-Busy $true
    try{
        Assert-DesktopClosed (Get-DesktopExe);$profile=Save-Current
        if(@($profile.models).Count){try{$null=Sync-NativeCatalog $profile.base_url @($profile.models) $profile.id}catch{}}
        Set-Status '正在备份官方连接并应用选中的 API 配置……'
        $worker=[PowerShell]::Create()
        $null=$worker.AddScript('param($root,$data,$dataHome,$ui,$profileJson) . (Join-Path $root "Launcher.Core.ps1");$script:LauncherData=$data;$script:OfficialHome=$dataHome;$script:OfficialUi=$ui;$script:SwitchFile=Join-Path $data "shared-switch.json"; try{$profile=$profileJson|ConvertFrom-Json;$id=Start-ThirdParty $profile.base_url $profile.model "" $profile;$state=Get-SwitchState;[pscustomobject]@{pid=$id;sharing=$script:PluginSharingNotice;image_warning=$state.image_warning;error=""}}catch{[pscustomobject]@{error=$_.Exception.Message}}').AddArgument($PSScriptRoot).AddArgument($script:LauncherData).AddArgument($script:OfficialHome).AddArgument($script:OfficialUi).AddArgument(($profile|ConvertTo-Json -Depth 12))
        $async=$worker.BeginInvoke();$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(250);$timer.Add_Tick({Finish-ApiLaunch})
        $script:LaunchRequest=[pscustomobject]@{Worker=$worker;Async=$async;Timer=$timer;ProfileName=$profile.name};$timer.Start()
    }catch{if($worker){$worker.Dispose()};Show-Failure $_.Exception.Message;Set-Busy $false}
})
function Confirm-OfficialReset([string]$Reason,[switch]$Launch) {
    if(-not $script:CanResetOfficial){return $false}
    $choice=Show-AssistantDialog 'reset-login' '重置连接并重新登录官方？' ($Reason+"`n`n确认后先加密备份当前配置与登录，再清除 API 连接。聊天和项目保留；其他参数可从备份找回。需要重新登录官方账号。")
    if($choice -ne 'confirm'){return $false}
    Reset-OfficialConnection -Confirmed
    if($Launch){$null=Start-Official}
    Update-ModeBadge;Set-Status '已重置官方连接，请重新登录；聊天和项目保留。'
    Show-ResultToast 'success' '请重新登录官方' $script:RecoveryNotice
    return $true
}
function Open-Official {Set-Busy $true;try{Set-Status '正在恢复官方连接与原参数……';$null=Start-Official;$script:DesktopClosed=$false;$runtimeStatus.Text='已请求启动 Codex；再次切换前，请退出并刷新状态。';$appliedConnection.Text='官方账号';Update-ModeBadge;Set-Status '已恢复官方连接并请求启动；记录使用同一份本机数据。';if($script:RecoveryNotice){Show-ResultToast 'success' '已恢复官方' $script:RecoveryNotice}}catch{try{if(-not(Confirm-OfficialReset $_.Exception.Message -Launch)){Show-Failure $_.Exception.Message}}catch{Show-Failure $_.Exception.Message}}finally{Set-Busy $false}}

$recoveryButton.Add_Click({
    Set-Busy $true
    try{
        Restore-OfficialOnly -Force;Update-ModeBadge;Set-Status '官方登录和连接参数已恢复，可以正常打开 Codex。'
        $detail='已恢复保存的官方连接与登录。';if($script:RecoveryNotice){$detail=$script:RecoveryNotice}
        $title='已恢复官方'
        if(-not $script:LastRecoveryPerformed){$title='无需恢复';$detail='没有助手的待恢复切换。可以从开始菜单打开官方 Codex；账号已退出时仍需正常登录。';Set-Status '没有待恢复的助手切换。'}
        Show-ResultToast 'success' $title $detail
    }catch{try{if(-not(Confirm-OfficialReset $_.Exception.Message)){Show-Failure $_.Exception.Message}}catch{Show-Failure $_.Exception.Message}}finally{Set-Busy $false}
})
$defaultsButton.Add_Click({$windowBox.Text='继承原设置';$compactBox.Text='继承原设置';$toolBox.Text='继承原设置';$searchBox.SelectedIndex=0;$verbosityBox.SelectedIndex=0;$reasoningBox.SelectedValue='inherit';Set-Status '参数已设为继承官方值；保存后在下次 API 启动应用。'})
function Open-SettingsHelp($Target,[string]$Title,[string]$Detail){
    $settingsHelpPopup.PlacementTarget=$Target;$settingsHelpTitle.Text=$Title;$settingsHelpDetail.Text=$Detail
    $form.FindName('settingsHelpScroll').MaxHeight=[Math]::Max(100,[Math]::Min(400,[Windows.SystemParameters]::WorkArea.Height-150))
    $form.FindName('settingsHelpScroll').ScrollToTop();$settingsHelpPopup.IsOpen=$true
    $helpCloseButton.Focus()|Out-Null
}
function Open-PluginSharingHelp($Target){
    Open-SettingsHelp $Target '插件共享范围' "聊天和项目继续使用同一份本地数据。`n`n助手目前只自动共享：已安装并启用、只包含本地技能且允许复制（MIT 许可）的插件。副本显示为「原名称 · 本地共享」，官方模式可能同时显示原版和副本。`n`nFigma 等含账号服务连接的插件需单独核对安装与连接；复制文件不能转移账号授权。没有本地副本，不代表 API 模式一定不可用。`n`n官方账号与 API 登录的插件市场可见范围可能不同，账号服务插件不保证显示完整；这不表示本地插件或聊天被删除，也不是靠重设环境位置就能补全。`n`n安装、启用、技能发现和实际调用分别确认；清单读取成功不等于所有插件都能调用。"
}
$form.FindName('homeSharingInfoButton').Add_Click({Open-PluginSharingHelp $form.FindName('homeSharingInfoButton')})
$form.FindName('sharingInfoButton').Add_Click({Open-PluginSharingHelp $form.FindName('sharingInfoButton')})
$reasoningInfoButton.Add_Click({Open-SettingsHelp $reasoningInfoButton '推理强度与原生调节' "这里设置下次 API 启动的默认推理强度，按接口保存。进入 Codex 后，仍可在右下角调整。`n`n已有聊天可能保留自己的选择，启动默认值不会强制覆盖它。档位根据本机模型元数据列出，第三方是否支持仍需确认。返回官方会恢复原来的推理配置。"})
$contextInfoButton.Add_Click({Open-SettingsHelp $contextInfoButton '上下文长度' "单位为 token。200K = 200,000，1M = 1,000,000。选择继承时沿用官方原值或模型默认。`n`n填写更大的数字不会增加服务商的真实窗口。此处显示的是本机元数据或原设置，第三方实际能力仍需确认。"})
$compactInfoButton.Add_Click({Open-SettingsHelp $compactInfoButton '自动压缩阈值' "达到预算时 Codex 尝试压缩上下文。自定义阈值应小于有效上下文长度；压缩能力也取决于服务商。`n`n选择继承可保持原设置，已有长聊天仍按 Codex 的上下文机制处理。"})
$helpCloseButton.Add_Click({$settingsHelpPopup.IsOpen=$false;$settingsHelpPopup.PlacementTarget.Focus()|Out-Null})
$settingsHelpPopup.Child.Add_PreviewKeyDown({param($Sender,$EventArgs)if($EventArgs.Key -eq 'Escape'){$settingsHelpPopup.IsOpen=$false;$settingsHelpPopup.PlacementTarget.Focus()|Out-Null;$EventArgs.Handled=$true}})
$form.Add_PreviewKeyDown({param($Sender,$EventArgs)if($EventArgs.Key -eq 'Escape' -and $settingsHelpPopup.IsOpen){$settingsHelpPopup.IsOpen=$false;$EventArgs.Handled=$true}})
$environmentButton.Add_Click({
    if($script:Busy){return}
    $dialog=New-EnvironmentWindow;$dialog.Owner=$form;$dialog.Icon=$form.Icon
    $null=$dialog.ShowDialog()
    if($dialog.Tag.Saved){
        $script:ModelMetadata=@()
        try{$metadataFile=Join-Path $script:OfficialHome 'models_cache.json';if(Test-Path -LiteralPath $metadataFile){$script:ModelMetadata=@((Get-Content -LiteralPath $metadataFile -Raw -Encoding UTF8|ConvertFrom-Json).models)}}catch{}
        Update-ReasoningChoices (Get-ReasoningSelection) -Force;Refresh-Environment;Update-Plan
        Set-Status '环境位置已保存；下次启动使用显示的目录，不移动原聊天。'
    }
})
$helpButton.Add_Click({try{Start-Process -FilePath (Join-Path $PSScriptRoot '使用说明.html')|Out-Null}catch{Show-Failure '请打开文件夹中的 使用说明.html。'}})
$keyBox.Add_TextChanged({if(-not $script:Loading){$script:KeyEdited=$true;$inlineError.Visibility='Collapsed';Invalidate-Check;Update-Plan}})
$navHome.Add_Checked({Show-Page 3});$navConnection.Add_Checked({Show-Page 0});$navAdvanced.Add_Checked({Show-Page 1});$navPlan.Add_Checked({Show-Page 2})
foreach($control in @($nameBox,$urlBox,$modelBox,$windowBox,$compactBox,$toolBox)){
    $control.AddHandler([Windows.Controls.TextBox]::TextChangedEvent,[Windows.Controls.TextChangedEventHandler]{if(-not $script:Loading){$inlineError.Visibility='Collapsed';Invalidate-Check;Update-Plan}})
}
foreach($control in @($searchBox,$verbosityBox,$reasoningBox)){$control.Add_SelectionChanged({if(-not $script:Loading){Invalidate-Check;Update-Plan}})}
$homeOfficialButton.Add_Click({Open-Official})
$homeApiButton.Add_Click({Invoke-Button $apiButton})
$homeEditButton.Add_Click({Show-Page 0;$nameBox.Focus()|Out-Null})
$homeCheckButton.Add_Click({Start-ModelRequest})
$homeProbeButton.Add_Click({Start-ModelRequest -TestReply})
$replyTestButton.Add_Click({Start-ModelRequest -TestReply})
$cancelCheckButton.Add_Click({Stop-ModelRequest})
$refreshStateButton.Add_Click({Refresh-Environment})
$profileFilter.Add_TextChanged({Filter-Profiles})
$profileManager.Add_Collapsed({if($script:ProfileQuery){$profileFilter.Text=''}})
$form.Add_PreviewKeyDown({param($Sender,$EventArgs)if($EventArgs.Key -eq 'Escape' -and $profileManager.IsExpanded){$profileManager.IsExpanded=$false;$profileManager.Template.FindName('DisclosureHeader',$profileManager).Focus()|Out-Null;$EventArgs.Handled=$true}})
$clearFilterButton.Add_Click({$profileFilter.Text='';$profileFilter.Focus()|Out-Null})
$discardButton.Add_Click({Load-Profile (Current-Profile);$inlineError.Visibility='Collapsed';Set-Status '已恢复当前接口最后保存的配置。';Show-ResultToast 'success' '已撤销修改' '参数、模型和密钥已恢复到当前接口最后一次保存的值。'})
$form.Add_Closed({$script:ResultToastTimer.Stop();if($script:ImageRequest){Stop-ImageRequest}})
$form.Add_Closing({param($Sender,$EventArgs)if($script:ImageRequest){Stop-ImageRequest};if($script:ModelRequest){Stop-ModelRequest};if($script:CompatibilityRequest){Stop-CompatibilityRequest};if($script:Busy){$EventArgs.Cancel=$true;return};if(-not $ValidateOnly -and -not (Confirm-Leave)){$EventArgs.Cancel=$true}})
$saveButton.IsDefault=$true
$form.Add_PreviewKeyDown({param($Sender,$EventArgs)if(([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) -and $EventArgs.Key -eq 'S' -and -not $script:Busy){if($pageImages.Visibility -eq 'Visible'){Invoke-Button $imageSaveButton}else{Invoke-Button $saveButton};$EventArgs.Handled=$true}})
. (Join-Path $PSScriptRoot 'Launcher.ImageUI.ps1')
. (Join-Path $PSScriptRoot 'Launcher.CompatibilityUI.ps1')
Refresh-Profiles $script:Store.selected_id;Show-Page 3;Update-ModeBadge
try{$null=Update-PortablePluginLabels}catch{Show-ResultToast 'notice' '本地插件名称尚未更新' '连接与官方恢复仍可使用；稍后重新打开助手可再次更新显示名称。'}
if($script:ProfileStoreError){Show-ResultToast 'error' 'API 配置需要重新保存' '原文件保留。官方启动和恢复仍可使用；保存新 API 配置时会先确认并备份。'}
if($ValidateOnly){
    $form.Show();Update-View
    if($PreviewPath){Save-Preview $PreviewPath}
    $form.Close();Write-Output 'WPF interface initialized successfully.';return
}
$null=$form.ShowDialog()
