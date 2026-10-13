$script:ImageLoading=$true;$script:ImageRequest=$null;$script:ImageCurrentId='';$script:ImageBaseline='';$script:ImageStoreError=''
try{$script:ImageStore=Get-ImageStore}catch{$script:ImageStoreError=$_.Exception.Message;$script:ImageStore=[pscustomobject]@{version=1;output_dir='';services=@()};$imageCheckStatus.Text=$script:ImageStoreError}
foreach($choice in @(@('images_auto','自动识别（推荐）'),@('images_sync','Images · 同步返回'),@('cctq_async','Images · 异步任务（轮询）'))){$item=[Windows.Controls.ComboBoxItem]::new();$item.Tag=$choice[0];$item.Content=$choice[1];$imageProtocolBox.Items.Add($item)|Out-Null}
foreach($choice in @(@('system','跟随系统'),@('direct','直连'))){$item=[Windows.Controls.ComboBoxItem]::new();$item.Tag=$choice[0];$item.Content=$choice[1];$imageNetworkBox.Items.Add($item)|Out-Null}
function Current-ImageService {return @($script:ImageStore.services|Where-Object{$_.id -eq $script:ImageCurrentId})[0]}
function New-ImageChoice([string]$Id,[string]$Name) {
    $item=[Windows.Controls.ComboBoxItem]::new();$item.Tag=$Id;$item.Content=$Name
    return $item
}
function New-ImageServiceChoice($Service,$Services) {
    $name=Get-ImageDisplayName $Service $Services;$item=New-ImageChoice $Service.id $name;$item.Uid=$name
    $hostText='未设置地址';try{if($Service.base_url){$hostText=([Uri]$Service.base_url).Host}}catch{}
    $stack=[Windows.Controls.StackPanel]::new()
    $title=[Windows.Controls.TextBlock]::new();$title.Text=$name;$title.FontSize=14;$title.TextTrimming='CharacterEllipsis'
    $detail=[Windows.Controls.TextBlock]::new();$detail.Text=$hostText+'  /  '+$Service.model;$detail.FontSize=12;$detail.Foreground=Color '#667085';$detail.TextTrimming='CharacterEllipsis'
    $stack.Children.Add($title)|Out-Null;$stack.Children.Add($detail)|Out-Null;$item.Content=$stack;$item.ToolTip=$name+' · '+$detail.Text
    # SelectionBoxItem clones this visual before the closed dropdown has measured it.
    $stack.Measure([Windows.Size]::new(600,[double]::PositiveInfinity))
    $stack.Arrange([Windows.Rect]::new($stack.DesiredSize))
    [Windows.Automation.AutomationProperties]::SetName($item,$item.ToolTip)
    return $item
}
function Get-EnteredImageKey {
    $original=Current-ImageService
    if($script:ImageKeyEdited -or ($original.key_mode -eq 'chat' -and $imageUrlBox.Text.TrimEnd('/') -ceq $original.base_url.TrimEnd('/'))){return $imageKeyBox.Text}
    return ''
}
function Image-UiDraft {
    $original=Current-ImageService;if(-not $original){return $null}
    $draft=$original|ConvertTo-Json -Depth 12|ConvertFrom-Json
    $draft.name=$imageNameBox.Text;$draft.base_url=$imageUrlBox.Text;$draft.model=$imageModelBox.Text;$draft.protocol=[string]$imageProtocolBox.SelectedValue
    $draft.key_mode='own'
    $draft.size=$imageSizeBox.Text;$draft.quality=$imageQualityBox.Text;$draft.output_format=$imageFormatBox.Text;$draft.background=$imageBackgroundBox.Text;$draft.wait_seconds=$imageWaitBox.Text;$draft.network=[string]$imageNetworkBox.SelectedValue
    return $draft
}
function Image-UiFingerprint {return (@((Image-UiDraft),$imageOutputBox.Text)|ConvertTo-Json -Depth 12 -Compress)}
function Test-ImageDirty {return (Current-ImageService) -and ((Image-UiFingerprint) -cne $script:ImageBaseline -or $imageKeyBox.Text -cne ([string]$script:ImageKeyBaseline))}
function Update-ImageEditing {
    if($script:ImageLoading){return}
    $dirty=Test-ImageDirty;$imageEditBadge.Text='已保存';if($dirty){$imageEditBadge.Text='有未保存修改'}
    $imageKeyBox.IsEnabled=-not $script:Busy
    $imageProtocolHint.Text='保持一次请求，生成完成后返回图片。同一服务可能同时支持同步和异步，按文档选择。'
    if($imageProtocolBox.SelectedValue -eq 'cctq_async'){$imageProtocolHint.Text='先返回任务编号，助手自动查询并下载。此模式要求 async=true 与 /images/tasks/{id} 任务接口；其他异步格式需适配。'}
    if($imageProtocolBox.SelectedValue -eq 'images_auto'){$imageProtocolHint.Text='先按普通 Images 请求提交一次，再识别图片或已支持的任务格式。未知格式不重试提交。'}
    $imageKeyHint.Text='保存后 Key 会自动显示，可直接修改。'
    $imageOutputHint.Text='默认：'+(Get-ImageOutputDirectory)+ '；留空跟随当前 Codex 数据目录。'
}
function Update-ImageBindingHint {
    $imageConfigureButton.Visibility='Collapsed';$imageCurrentTestButton.Visibility='Collapsed'
    if($imageBindingBox.SelectedValue -eq '__current__'){
        $imageBindingHint.Text='复用此对话配置的地址和 Key，实际模型：'+$modelBox.Text+'。要求接口支持 Responses 图片工具；不跟随右下角临时切换。'
        $imageCurrentTestButton.Visibility='Visible'
    }elseif($imageBindingBox.SelectedValue){$imageConfigureButton.Visibility='Visible';$imageBindingHint.Text='在同一条聊天中调用独立图片服务，不切换对话模型。保存后下次 API 启动生效。'}
    else{$imageBindingHint.Text='默认关闭。可选择复用对话接口，或使用独立图片服务。'}
}
function Refresh-ImageBindings {
    $loadingBefore=$script:Loading;$script:Loading=$true
    try{
        $selected=[string]$imageBindingBox.SelectedValue;$imageBindingBox.Items.Clear()
        $imageBindingBox.Items.Add((New-ImageChoice '' '不启用'))|Out-Null
        $imageBindingBox.Items.Add((New-ImageChoice '__current__' '使用对话接口生图'))|Out-Null
        foreach($service in @($script:ImageStore.services)){$imageBindingBox.Items.Add((New-ImageChoice $service.id ('独立服务 · '+(Get-ImageDisplayName $service $script:ImageStore.services))))|Out-Null}
        if($selected -and $selected -ne '__current__' -and $selected -notin @($script:ImageStore.services.id)){$imageBindingBox.Items.Add((New-ImageChoice $selected '服务已缺失，请重新选择'))|Out-Null}
        $imageBindingBox.SelectedValue=$selected
    }finally{$script:Loading=$loadingBefore}
}
function Load-ImageService($Service) {
    $script:ImageLoading=$true
    try{
        $imageEditor.Visibility='Collapsed';$imageEmptyHint.Visibility='Visible';$imageTestButton.IsEnabled=$false;$imageCopyButton.IsEnabled=$false;$imageDeleteButton.IsEnabled=$false
        if(-not $Service){$script:ImageCurrentId='';return}
        $script:ImageCurrentId=$Service.id;$imageEditor.Visibility='Visible';$imageEmptyHint.Visibility='Collapsed';$imageTestButton.IsEnabled=-not $script:Busy;$imageCopyButton.IsEnabled=-not $script:Busy;$imageDeleteButton.IsEnabled=-not $script:Busy
        $imageNameBox.Text=$Service.name;$imageUrlBox.Text=$Service.base_url;$imageModelBox.Items.Clear();foreach($model in @($Service.models)){$imageModelBox.Items.Add([string]$model)|Out-Null};$imageModelBox.Text=$Service.model
        $imageProtocolBox.SelectedValue=$Service.protocol;$imageNetworkBox.SelectedValue=$Service.network;$imageKeyBox.Text='';try{if($Service.key_mode -eq 'chat'){$imageKeyBox.Text=Get-ImageCredential $Service (Current-Profile)}elseif($Service.encrypted_key){$imageKeyBox.Text=Get-LocalKey $Service $Service.base_url}}catch{Show-ResultToast 'error' '请填写图片 Key' '已保存的 Key 无法读取或不适用于当前地址，请重新填写。'};$script:ImageKeyBaseline=$imageKeyBox.Text;$script:ImageKeyEdited=$false
        $imageSizeBox.Text=$Service.size;$imageQualityBox.Text=$Service.quality;$imageFormatBox.Text=$Service.output_format;$imageBackgroundBox.Text=$Service.background;$imageWaitBox.Text=[string]$Service.wait_seconds;$imageOutputBox.Text=$script:ImageStore.output_dir
        $script:ImageBaseline=Image-UiFingerprint
    }finally{$script:ImageLoading=$false;Update-ImageEditing}
}
function Refresh-ImageServices([string]$Selected='') {
    $script:ImageLoading=$true
    try{$imageServiceList.Items.Clear();foreach($service in @($script:ImageStore.services)){$imageServiceList.Items.Add((New-ImageServiceChoice $service $script:ImageStore.services))|Out-Null};$imageServiceList.SelectedValue=$Selected;if($imageServiceList.SelectedIndex -lt 0 -and $imageServiceList.Items.Count){$imageServiceList.SelectedIndex=0}}
    finally{$script:ImageLoading=$false}
    Load-ImageService (@($script:ImageStore.services|Where-Object{$_.id -eq $imageServiceList.SelectedValue})[0]);Refresh-ImageBindings
}
function Save-CurrentImageService {
    if($script:ImageStoreError){throw $script:ImageStoreError}
    $draft=Complete-ImageService (Image-UiDraft) (Get-EnteredImageKey)
    $duplicates=@($script:ImageStore.services|Where-Object{$_.id -ne $draft.id -and ([string]$_.name).Trim() -ieq $draft.name})
    if($duplicates.Count -and $draft.name -ine ([string](Current-ImageService).name).Trim()){throw '图片服务名称重复，请使用不同名称。'}
    if($draft.key_mode -eq 'chat'){$null=Get-ImageCredential $draft (Complete-ApiProfile (Ui-Draft) (Get-EnteredKey))}
    if($imageOutputBox.Text){$null=Get-ImageOutputDirectory $imageOutputBox.Text}
    $list=@($script:ImageStore.services);for($i=0;$i -lt $list.Count;$i++){if($list[$i].id -eq $draft.id){$list[$i]=$draft}}
    $script:ImageStore.services=$list;$script:ImageStore.output_dir=$imageOutputBox.Text.Trim();Save-ImageStore $script:ImageStore
    Refresh-ImageServices $draft.id
    $imageCheckStatus.Text='图片服务已保存。请在“连接与模型”选择此服务并保存对话配置；下次 API 启动生效。'
    return $draft
}
function Confirm-ImageLeave {
    if(-not(Test-ImageDirty)){return $true}
    $answer=Show-AssistantDialog 'save' '保存图片服务修改？' '这项图片服务还没有保存。选择保存后继续，或保留原来的配置。' (Current-ImageService).name
    if($answer -eq 'cancel'){return $false}
    if($answer -eq 'save'){try{$null=Save-CurrentImageService}catch{$imageCheckStatus.Text=$_.Exception.Message;return $false}}
    else{Load-ImageService (Current-ImageService)}
    return $true
}
$script:DialogueConfirmLeave=(Get-Item Function:\Confirm-Leave).ScriptBlock
function Confirm-Leave {if(-not(Confirm-ImageLeave)){return $false};return (& $script:DialogueConfirmLeave)}
function Set-ImageBusy([bool]$Busy) {
    Set-Busy $Busy
    foreach($item in @($imageServiceList,$imageAddButton,$imageCopyButton,$imageDeleteButton,$imageEditor,$imageModelsButton,$imageTestButton,$imageBindingBox,$imageCurrentTestButton)){$item.IsEnabled=-not $Busy}
    $imageCancelButton.Visibility='Collapsed';if($Busy){$imageCancelButton.Visibility='Visible'}
    Update-ImageEditing
}
function Stop-ImageRequest {
    $job=$script:ImageRequest;if(-not $job){return};$script:ImageRequest=$null;$job.Timer.Stop()
    try{if($job.Client){$job.Client.Cancel()};$job.Worker.Stop()}
    finally{if($job.Client){$job.Client.Dispose()};$job.Worker.Dispose();Set-ImageBusy $false;$imageCheckStatus.Text='已停止本地等待；服务商可能仍在生成，未重复提交。';if($job.Client -and $job.Client.ActiveJobId){$imageCheckStatus.Text+='任务：'+$job.Client.ActiveJobId};Show-ResultToast 'cancelled' '图片检查已停止等待' $imageCheckStatus.Text}
}
function Finish-ImageRequest {
    $job=$script:ImageRequest;if(-not $job){return}
    if(-not $job.Async.IsCompleted){
        $seconds=[int]$job.Watch.Elapsed.TotalSeconds
        if($seconds -ne $job.LastSecond){$job.LastSecond=$seconds;$phase='读取模型列表';if($job.Client){$phase=switch($job.Client.Stage){'submitting' {'提交图片请求'};'queued' {'服务商排队中'};'in_progress' {'服务商生成中'};'downloading' {'下载图片'};default {'等待服务商'}}};$imageCheckStatus.Text=$phase+' · '+$seconds+' 秒'}
        return
    }
    $job.Timer.Stop()
    try{
        $results=@($job.Worker.EndInvoke($job.Async));if($job.Worker.HadErrors -or $results.Count -ne 1){throw '图片检查未完成，请核对接口、Key 与网络。'}
        if($job.Kind -eq 'models'){
            $ids=@($results[0].Models);$imageModelBox.Items.Clear();foreach($id in $ids){$imageModelBox.Items.Add([string]$id)|Out-Null};$imageModelBox.Text=$job.Service.model
            $selected=Current-ImageService;$selected.models=$ids;$imageCheckStatus.Text='已读取 '+$ids.Count+' 个模型，仍需按服务商文档选择图片模型；可手动填写，列表响应不表示生图已通过。';Update-ImageEditing
            return
        }
        $result=([string]$results[0])|ConvertFrom-Json
        if($result.status -eq 'completed'){
            $imageCheckStatus.Text='图片已生成并保存：'+[string]$result.paths[0]
            try{$stream=[IO.File]::OpenRead([string]$result.paths[0]);try{$imageTestPreview.Source=[Windows.Media.Imaging.BitmapFrame]::Create($stream,[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad);$imageTestPreview.Visibility='Visible'}finally{$stream.Dispose()}}catch{$imageTestPreview.Visibility='Collapsed'}
            Show-ResultToast 'success' '图片测试成功' '结果已保存，可在图片服务页面查看。'
        }else{$imageCheckStatus.Text='图片检查状态：'+$result.status+' · '+$result.message;if($result.job_id){$imageCheckStatus.Text+=' · 本地任务 '+$result.job_id};Show-ResultToast 'error' '图片检查未完成' $imageCheckStatus.Text}
    }catch{$imageCheckStatus.Text=$_.Exception.Message;Show-ResultToast 'error' '图片检查失败' $imageCheckStatus.Text}
    finally{if($job.Client){$job.Client.Dispose()};$job.Worker.Dispose();$script:ImageRequest=$null;Set-ImageBusy $false}
}
function Get-ImageWorkerScript {
    return @'
param($CorePath,$ServiceJson,$ChatJson,$Kind,$Client)
$ErrorActionPreference='Stop'
. $CorePath
if($Kind -eq 'models'){
    $service=$ServiceJson|ConvertFrom-Json;$chat=$ChatJson|ConvertFrom-Json;$key=Get-ImageCredential $service $chat
    try{[pscustomobject]@{Models=@(Read-ProfileModels $service $key)}}finally{$key=$null}
}else{$Client.ExecuteAsync('generate_image','{"prompt":"Create a simple blue square on a plain white background. No text."}').GetAwaiter().GetResult()}
'@
}
function Start-ImageRequest([string]$Kind) {
    if($script:Busy -or ($Kind -ne 'current' -and -not(Current-ImageService))){return}
    $worker=$null;$client=$null;Hide-ResultToast;Set-ImageBusy $true
    try{
        if($Kind -eq 'current'){
            $chat=Complete-ApiProfile (Ui-Draft) (Get-EnteredKey);$service=$null
            $snapshot=New-DialogueImageSnapshot $chat $script:ImageStore.output_dir;$client=New-ImageClient $snapshot;$snapshot.key=$null
        }else{
        $imageDraft=Image-UiDraft;$modelBefore=$imageDraft.model
        if($Kind -eq 'models' -and -not $imageDraft.model){$imageDraft.model='__models_only__'}
        $service=Complete-ImageService $imageDraft (Get-EnteredImageKey)
        if($Kind -eq 'models'){$service.model=$modelBefore}
        $chat=Ui-Draft;if($service.key_mode -eq 'chat'){$chat=Complete-ApiProfile $chat (Get-EnteredKey)}
        if($Kind -eq 'generate'){$snapshot=New-ImageSnapshot $service $chat $imageOutputBox.Text;$client=New-ImageClient $snapshot;$snapshot.key=$null}
        }
        $worker=[PowerShell]::Create()
        $code=Get-ImageWorkerScript
        $null=$worker.AddScript($code).AddArgument((Join-Path $script:ImageSourceRoot 'Launcher.Core.ps1')).AddArgument(($service|ConvertTo-Json -Depth 12)).AddArgument(($chat|ConvertTo-Json -Depth 12)).AddArgument($Kind).AddArgument($client)
        $async=$worker.BeginInvoke();$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(200);$timer.Add_Tick({Finish-ImageRequest})
        $script:ImageRequest=[pscustomobject]@{Worker=$worker;Client=$client;Async=$async;Timer=$timer;Kind=$Kind;Service=$service;Watch=[Diagnostics.Stopwatch]::StartNew();LastSecond=-1};$timer.Start()
        $imageTestPreview.Visibility='Collapsed';$imageCheckStatus.Text='检查已开始，可停止等待；本次不会保存接口草稿。'
    }catch{if($client){$client.Dispose()};if($worker){$worker.Dispose()};Set-ImageBusy $false;$imageCheckStatus.Text=$_.Exception.Message;Show-ResultToast 'error' '暂时无法检查图片服务' $imageCheckStatus.Text}
}
$navImages.Add_Checked({Show-Page 4});$imageConfigureButton.Add_Click({Show-Page 4})
$imageBindingBox.Add_SelectionChanged({if(-not $script:Loading){$null=$imageBindingBox.Dispatcher.BeginInvoke([Action]{if(-not $script:Loading){Invalidate-Check;Update-Plan;Update-ImageBindingHint}})}})
$imageServiceList.Add_SelectionChanged({if($script:ImageLoading){return};$desired=$imageServiceList.SelectedValue;if($desired -eq $script:ImageCurrentId){return};if(-not(Confirm-ImageLeave)){$script:ImageLoading=$true;$imageServiceList.SelectedValue=$script:ImageCurrentId;$script:ImageLoading=$false;return};Load-ImageService (@($script:ImageStore.services|Where-Object{$_.id -eq $desired})[0])})
$imageAddButton.Add_Click({if($script:Busy -or -not(Confirm-ImageLeave)){return};try{if($script:ImageStoreError){throw $script:ImageStoreError};$service=New-ImageService @($script:ImageStore.services);$script:ImageStore.services=@($script:ImageStore.services)+@($service);Save-ImageStore $script:ImageStore;Refresh-ImageServices $service.id}catch{$imageCheckStatus.Text=$_.Exception.Message}})
$imageCopyButton.Add_Click({if($script:Busy -or -not(Current-ImageService) -or -not(Confirm-ImageLeave)){return};try{$service=(Current-ImageService)|ConvertTo-Json -Depth 12|ConvertFrom-Json;$service.id=[Guid]::NewGuid().ToString('N');$service.name=Get-UniqueImageName ($service.name.Substring(0,[Math]::Min(50,$service.name.Length))+' · 副本') @($script:ImageStore.services);$script:ImageStore.services=@($script:ImageStore.services)+@($service);Save-ImageStore $script:ImageStore;Refresh-ImageServices $service.id}catch{$imageCheckStatus.Text=$_.Exception.Message}})
$imageDeleteButton.Add_Click({if($script:Busy -or -not(Current-ImageService) -or -not(Confirm-ImageLeave)){return};try{if(@($script:Store.profiles|Where-Object{$_.image_service_id -eq $script:ImageCurrentId}).Count -or $imageBindingBox.SelectedValue -eq $script:ImageCurrentId){throw '此图片服务已绑定对话配置。请先取消绑定并保存，再移除。'};$script:ImageStore.services=@($script:ImageStore.services|Where-Object{$_.id -ne $script:ImageCurrentId});Save-ImageStore $script:ImageStore;Refresh-ImageServices}catch{$imageCheckStatus.Text=$_.Exception.Message}})
$imageSaveButton.Add_Click({try{$null=Save-CurrentImageService;Show-ResultToast 'success' '图片服务已保存' '在对话配置中选择此服务，保存后在下次 API 启动使用。'}catch{$imageCheckStatus.Text=$_.Exception.Message;Show-ResultToast 'error' '图片服务未保存' $imageCheckStatus.Text}})
$imageDiscardButton.Add_Click({Load-ImageService (Current-ImageService)})
foreach($control in @($imageNameBox,$imageUrlBox,$imageModelBox,$imageSizeBox,$imageQualityBox,$imageFormatBox,$imageBackgroundBox,$imageWaitBox,$imageOutputBox)){$control.AddHandler([Windows.Controls.TextBox]::TextChangedEvent,[Windows.Controls.TextChangedEventHandler]{Update-ImageEditing})}
foreach($control in @($imageProtocolBox,$imageNetworkBox)){$control.Add_SelectionChanged({Update-ImageEditing})}
$imageKeyBox.Add_TextChanged({if(-not $script:ImageLoading){$script:ImageKeyEdited=$true;Update-ImageEditing}})
$imageCurrentTestButton.Add_Click({Start-ImageRequest 'current'})
$imageModelsButton.Add_Click({Start-ImageRequest 'models'});$imageTestButton.Add_Click({Start-ImageRequest 'generate'});$imageCancelButton.Add_Click({Stop-ImageRequest})
$imageFolderButton.Add_Click({$dialog=[Windows.Forms.FolderBrowserDialog]::new();try{if($dialog.ShowDialog() -eq 'OK'){$imageOutputBox.Text=$dialog.SelectedPath}}finally{$dialog.Dispose()}})
$imageOpenButton.Add_Click({try{$dir=Get-ImageOutputDirectory $imageOutputBox.Text;if(-not(Test-Path -LiteralPath $dir -PathType Container)){throw '还没有结果目录，请先生成图片。'};Start-Process -FilePath explorer.exe -ArgumentList ('"'+$dir+'"')|Out-Null}catch{$imageCheckStatus.Text=$_.Exception.Message}})
Refresh-ImageServices
$script:ImageLoading=$false
