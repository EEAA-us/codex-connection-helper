param([string]$PreviewDirectory)
$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run with Windows PowerShell -STA.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
$source=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $source 'Launcher.Dialogs.ps1')
$form=New-ThemedWindow ([IO.File]::ReadAllText((Join-Path $source 'UI.xaml')))
function Control([string]$Name){return $form.FindName($Name)}
function Pump {$form.UpdateLayout();$form.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)}
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Check-EdgePixels($Control) {
    $dpi=[Windows.Media.VisualTreeHelper]::GetDpi($Control);$scale=$dpi.DpiScaleX
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int][Math]::Round($Control.ActualWidth*$scale),[int][Math]::Round($Control.ActualHeight*$scale),96*$scale,96*$scale,[Windows.Media.PixelFormats]::Pbgra32)
    $drawing=[Windows.Media.DrawingVisual]::new();$dc=$drawing.RenderOpen();$dc.DrawRectangle([Windows.Media.VisualBrush]::new($Control),$null,[Windows.Rect]::new(0,0,$Control.ActualWidth,$Control.ActualHeight));$dc.Close();$bitmap.Render($drawing)
    $row=New-Object byte[] ($bitmap.PixelWidth*4);$bitmap.CopyPixels([Windows.Int32Rect]::new(0,[int]($bitmap.PixelHeight/2),$bitmap.PixelWidth,1),$row,$row.Length,0)
    $left=0;$right=0
    for($i=0;$i -lt 6;$i++){foreach($side in @('left','right')){$x=$i;if($side -eq 'right'){$x=$bitmap.PixelWidth-1-$i};$offset=$x*4;if($row[$offset+3] -gt 200 -and $row[$offset+2] -lt 235 -and $row[$offset+1] -lt 235 -and $row[$offset] -lt 245){if($side -eq 'left'){$left++}else{$right++}}}}
    Check ($left -gt 0 -and $left -eq $right) ('Unequal or missing rendered side edges: '+$Control.Name+' '+$left+'/'+$right)
}
function Render($Visual,[string]$Name,[double]$Scale=1.5) {
    if(-not $PreviewDirectory){return}
    $Visual.UpdateLayout()
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int][Math]::Ceiling($Visual.ActualWidth*$Scale),[int][Math]::Ceiling($Visual.ActualHeight*$Scale),96*$Scale,96*$Scale,[Windows.Media.PixelFormats]::Pbgra32)
    $drawing=[Windows.Media.DrawingVisual]::new();$dc=$drawing.RenderOpen();$rect=[Windows.Rect]::new(0,0,$Visual.ActualWidth,$Visual.ActualHeight)
    try{
        $owner=[Windows.Window]::GetWindow($Visual);if($owner){$dc.DrawRectangle($owner.Background,$null,$rect)}
        $brush=[Windows.Media.VisualBrush]::new($Visual);$brush.ViewboxUnits=[Windows.Media.BrushMappingMode]::Absolute;$brush.Viewbox=$rect;$brush.Stretch=[Windows.Media.Stretch]::Fill;$dc.DrawRectangle($brush,$null,$rect)
    }finally{$dc.Close()}
    $bitmap.Render($drawing);$png=[Windows.Media.Imaging.PngBitmapEncoder]::new();$png.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create((Join-Path $PreviewDirectory $Name));try{$png.Save($stream)}finally{$stream.Dispose()}
}
if($PreviewDirectory){New-Item -ItemType Directory -Path $PreviewDirectory -Force|Out-Null}
$form.Show();Pump
try{
    $glyph=[Windows.Media.GlyphTypeface]::new([Uri]::new((Join-Path $source 'fonts/ChillRoundM.ttf'),[UriKind]::Absolute))
    Check ($glyph.FamilyNames.Values -contains 'ChillRoundM') 'Bundled font family mismatch.'
    foreach($letter in '连接助手保存配置图片服务取消修改接口凭据'.ToCharArray()){Check ($glyph.CharacterToGlyphMap.ContainsKey([int]$letter)) ('Missing UI glyph: '+$letter)}
    $uiFont=$form.FindResource('UiFont')
    Check ($uiFont.FamilyMaps[0].Target -match 'ChillRoundM') 'Main interface did not select the local rounded face.'
    $descender=$glyph.GetGlyphOutline($glyph.CharacterToGlyphMap[103],1,1).Bounds.Bottom
    Check ($uiFont.LineSpacing-$uiFont.Baseline -ge $descender) 'Font line metrics truncate lowercase descenders.'
    $resolvedTypeface=[Windows.Media.Typeface]::new([Windows.Media.FontFamily]::new($uiFont.FamilyMaps[0].Target),'Normal','Normal','Normal')
    $resolvedGlyph=$null
    Check ($resolvedTypeface.TryGetGlyphTypeface([ref]$resolvedGlyph) -and $resolvedGlyph.FamilyNames.Values -contains 'ChillRoundM') 'Composite font falls back instead of loading the bundled face.'
    foreach($name in @('urlBox','imageUrlBox','modelBox','imageModelBox','compatibilityCwd')){
        $fieldFont=(Control $name).FontFamily
        Check ($fieldFont.FamilyMaps[0].Target -ceq $uiFont.FamilyMaps[0].Target -and $fieldFont.LineSpacing -eq $uiFont.LineSpacing -and $fieldFont.Baseline -eq $uiFont.Baseline) ('Field face or metrics differ: '+$name)
    }
    Check ((Control 'homeDiagnostics').Visibility -eq 'Collapsed') 'Connection checks remain visible on the home page.'
    Check ((Control 'keyBox') -is [Windows.Controls.TextBox] -and (Control 'imageKeyBox') -is [Windows.Controls.TextBox]) 'Keys are still password-only fields.'
    Check ($null -eq (Control 'showKey') -and $null -eq (Control 'imageUseChatKey')) 'Retired key toggles remain.'
    Check ((Control 'connectionDiagnostics') -is [Windows.Controls.StackPanel]) 'Connection checks still require expanding.'
    foreach($name in @('pageConnection','pageAdvanced','pagePlan','pageHome','pageImages')){(Control $name).Visibility='Collapsed'}
    (Control 'pageConnection').Visibility='Visible';(Control 'pageTitle').Text='接口配置';(Control 'pageSubtitle').Text='设置接口地址、密钥和默认模型。'
    (Control 'selectedProfileName').Text='日常开发';(Control 'nameBox').Text='日常开发';(Control 'urlBox').Text='https://api.example.test/v1';(Control 'keyHint').Text='密钥保存在本机；留空沿用已保存的 Key。'
    (Control 'modelBox').Items.Add('gpt-6.1-sol')|Out-Null;(Control 'modelBox').SelectedIndex=0
    foreach($i in 1..25){(Control 'modelBox').Items.Add(('example-model-'+$i+'-long-name-for-menu-layout'))|Out-Null}
    foreach($label in @('不启用','使用对话接口生图','独立服务 · 图片服务 1')){(Control 'imageBindingBox').Items.Add($label)|Out-Null}
    (Control 'imageBindingBox').SelectedIndex=0;(Control 'navConnection').IsChecked=$true
    (Control 'imageCurrentTestButton').Visibility='Collapsed';(Control 'imageConfigureButton').Visibility='Collapsed'
    (Control 'imageBindingHint').Text='按接口能力选择图片功能。';(Control 'status').Text='配置已保存。下次启动时应用。';Pump
    foreach($size in @(@(1280,940),@(1080,760))){
        $form.Width=$size[0];$form.Height=$size[1];Pump
        foreach($name in @('nameBox','urlBox','keyBox','modelBox','imageBindingBox')){
            $input=Control $name;$input.ApplyTemplate()|Out-Null;$border=$input.Template.FindName('Input',$input)
            Check ($border -and $border.BorderThickness.Left -ge 1 -and $border.BorderThickness.Right -ge 1 -and $border.BorderThickness.Top -ge 1 -and $border.BorderThickness.Bottom -ge 1) ('Missing field edge: '+$name)
            Check ($input.ActualWidth -ge 180 -and $input.ActualHeight -ge 39) ('Field content area too small: '+$name)
            Check-EdgePixels $input
        }
        $modelField=Control 'modelBox';$editable=$modelField.Template.FindName('PART_EditableTextBox',$modelField)
        $firstGlyph=$editable.GetRectFromCharacterIndex(0)
        $modelOrigin=$editable.TranslatePoint([Windows.Point]::new($firstGlyph.X,$firstGlyph.Y),$form)
        $urlField=Control 'urlBox';$urlGlyph=$urlField.GetRectFromCharacterIndex(0)
        $urlOrigin=$urlField.TranslatePoint([Windows.Point]::new($urlGlyph.X,$urlGlyph.Y),$form)
        Check ([Math]::Abs($modelOrigin.X-$urlOrigin.X) -le 1.5) 'Model first character does not align with adjacent fields.'
        Check ($firstGlyph.X -ge 1 -and $firstGlyph.Bottom -le $editable.ActualHeight) 'Editable model clips its first glyph or descender.'
        $input=Control 'modelBox';$input.IsDropDownOpen=$true;Pump
        $popup=$input.Template.FindName('PART_Popup',$input);$edge=$input.Template.FindName('DropDownBorder',$input)
        Check ($popup.IsOpen -and $edge.ActualWidth -ge $input.ActualWidth-1) 'Model menu width does not cover the input.'
        Check ($edge.Padding.Left -ge 4 -and $edge.Padding.Right -ge 4 -and $edge.Padding.Top -ge 4 -and $edge.Padding.Bottom -ge 4) 'Menu items can paint over outer menu edges.'
        Render $popup.Child ('menu-'+$size[0]+'.png');$input.IsDropDownOpen=$false;Pump
        foreach($scale in @(1.0,1.5,2.0)){Render $form.Content ('connection-'+$size[0]+'-'+[int]($scale*100)+'.png') $scale}
    }
    $form.Width=1280;$form.Height=940;Pump
    (Control 'pageConnection').Visibility='Collapsed';(Control 'pageAdvanced').Visibility='Visible';Pump
    foreach($name in @('reasoningBox','verbosityBox','searchBox','windowBox','compactBox','toolBox')){Check-EdgePixels (Control $name)}
    Render $form.Content 'parameters.png'
    (Control 'pageAdvanced').Visibility='Collapsed';(Control 'pageConnection').Visibility='Visible';Pump
    # Exercise actual modal result routes with a short timer after ContentRendered.
    foreach($case in @(@('save','save','dialogConfirm'),@('save','discard','dialogDiscard'),@('save','cancel','dialogCancel'),@('save','cancel','dialogClose'),@('remove','cancel','dialogCancel'),@('remove','confirm','dialogConfirm'),@('recover','cancel','dialogCancel'),@('reset-login','cancel','dialogCancel'),@('reset-login','confirm','dialogConfirm'),@('reset-login','cancel','enter'),@('save','save','enter'),@('remove','cancel','enter'),@('notice','confirm','enter'),@('error','confirm','dialogConfirm'))){
        $dialog=New-AssistantDialog $form $case[0] '保存这次修改？' '修改还没有保存。可以保存后继续，或返回编辑。' '日常开发'
        $ctx=$dialog.Tag;$ctx.TestTarget=$case[2];$ctx.ExpectedFocus=if($case[0] -in @('save','notice','error')){'dialogConfirm'}else{'dialogCancel'}
        $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(120);$ctx.Timer=$timer;$ctx.Failure=''
        $timer.Add_Tick({
            $timer.Stop()
            try{
                Check ($ctx[$ctx.ExpectedFocus].IsKeyboardFocused) 'Modal default focus is wrong.'
                Check (-not $ctx.Window.ShowInTaskbar -and $ctx.Window.Owner -eq $form) 'Dialog owner/taskbar contract changed.'
                $bounds=$ctx.dialogFrame.TransformToAncestor($ctx.Window.Content).TransformBounds([Windows.Rect]::new(0,0,$ctx.dialogFrame.ActualWidth,$ctx.dialogFrame.ActualHeight))
                Check ($bounds.Left -ge 7 -and $bounds.Top -ge 7 -and $bounds.Right -le $ctx.Window.Content.ActualWidth-7 -and $bounds.Bottom -le $ctx.Window.Content.ActualHeight-7) 'Dialog frame extends outside the drawable window.'
                Render $ctx.Window.Content ('dialog-'+$ctx.Kind+'-'+$ctx.TestTarget+'.png')
                if($ctx.TestTarget -eq 'enter'){
                    $event=[Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,[Windows.PresentationSource]::FromVisual($ctx.Window),0,[Windows.Input.Key]::Enter);$event.RoutedEvent=[Windows.Input.Keyboard]::PreviewKeyDownEvent;$ctx.Window.RaiseEvent($event)
                }else{$ctx[$ctx.TestTarget].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
            }catch{$ctx.Failure=$_.Exception.Message;$ctx.Window.Close()}
        }.GetNewClosure())
        $timer.Start();$null=$dialog.ShowDialog();$timer.Stop()
        Check (-not $ctx.Failure) $ctx.Failure;Check ($ctx.Choice -eq $case[1]) 'Dialog result did not match explicit button.'
    }
    foreach($kind in @('save','remove')){
        $dialog=New-AssistantDialog $form $kind '很长的提示' ('这是需要保持完整的说明。'*90) ('长配置名称 '*12)
        $ctx=$dialog.Tag;$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(120)
        $timer.Add_Tick({$timer.Stop();$event=[Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,[Windows.PresentationSource]::FromVisual($ctx.Window),0,[Windows.Input.Key]::Escape);$event.RoutedEvent=[Windows.Input.Keyboard]::PreviewKeyDownEvent;$ctx.Window.RaiseEvent($event)}.GetNewClosure())
        $timer.Start();$null=$dialog.ShowDialog();Check ($ctx.Choice -eq 'cancel') 'Escape did not cancel.'
    }
    . (Join-Path $source 'Environment.ps1')
    function Get-PathPreferences {return [pscustomobject]@{desktop_exe='';codex_home='';ui_data_path=''}}
    function Get-DesktopExe {return 'D:\示例 安装\app\ChatGPT.exe'}
    $script:OfficialHome='D:\示例 聊天';$script:OfficialUi='D:\示例 界面';$script:HomePathSource='示例';$script:UiPathSource='示例'
    $settings=New-EnvironmentWindow;$settings.Owner=$form;$settings.Show();Pump
    try{
        Check ($settings.FindResource('UiFont').FamilyMaps[0].Target -match 'ChillRoundM') 'Environment dialog uses a separate type system.'
        Check ($settings.FindName('savePaths').Style -eq $settings.FindResource('Primary')) 'Environment primary action does not share the theme.'
        Render $settings.Content 'environment.png'
        Check-EdgePixels ($settings.FindName('cancelPaths'))
        $settings.FindName('cancelPaths').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Check (-not $settings.Tag.Saved) 'Cancelling environment settings writes paths.'
    }finally{if($settings.IsVisible){$settings.Close()}}
    # Exercise real production notification functions against the actual WPF controls.
    $tokens=$null;$errors=$null
    $launcherAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'Launcher.ps1'),[ref]$tokens,[ref]$errors)
    foreach($functionName in @('Show-ResultToast','Show-ResultToastDetail','Hide-ResultToast','Add-ProfileItem','Open-SettingsHelp','Open-PluginSharingHelp','Show-Page')){
        $node=$launcherAst.FindAll({param($item)$item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $functionName},$true)[0]
        . ([scriptblock]::Create($node.Extent.Text))
    }
    $coreAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'Launcher.Core.ps1'),[ref]$tokens,[ref]$errors)
    foreach($functionName in @('Get-UniqueApiName','Get-ApiDisplayName')){
        $node=$coreAst.FindAll({param($item)$item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $functionName},$true)[0]
        . ([scriptblock]::Create($node.Extent.Text))
    }
    function Color([string]$Hex){return [Windows.Media.BrushConverter]::new().ConvertFromString($Hex)}
    foreach($name in @('settingsHelpPopup','settingsHelpTitle','settingsHelpDetail','helpCloseButton')){Set-Variable -Name $name -Value (Control $name)}
    foreach($name in @('profileManager','pageConnection','pageAdvanced','pagePlan','pageHome','pageImages','navConnection','navAdvanced','navPlan','navHome','navImages','pageTitle','pageSubtitle','footerActions','footerDivider','saveButton','contentScroll')){Set-Variable -Name $name -Value (Control $name)}
    # Only the external status/data refresh is stubbed; navigation is the actual production function.
    function Refresh-Environment {(Control 'appliedConnection').Text='官方账号';(Control 'runtimeStatus').Text='合成检查：Codex 已退出，可以选择连接。'}
    function Update-Plan {}
    $script:ChangingPage=$false
    foreach($prefix in @('$form.FindName(''homeSharingInfoButton'').Add_Click','$form.FindName(''sharingInfoButton'').Add_Click','$helpCloseButton.Add_Click','$settingsHelpPopup.Child.Add_PreviewKeyDown')){
        $hook=@($launcherAst.EndBlock.Statements|Where-Object{$_.Extent.Text.StartsWith($prefix)})[0]
        Check ($null -ne $hook) ('Missing actual help event binding: '+$prefix)
        . ([scriptblock]::Create($hook.Extent.Text))
    }
    $header=(Control 'pageTitle').Parent.Parent
    Check (@($header.Children|Where-Object{$_ -is [Windows.Controls.Border] -and $_.Width -eq 8 -and $_.Height -eq 8}).Count -eq 0) 'Unexplained pink header dot remains.'
    foreach($size in @(@(1280,940),@(1080,760))){
        $form.Width=$size[0];$form.Height=$size[1]
        foreach($case in @(@('pageHome','homeSharingInfoButton'),@('pagePlan','sharingInfoButton'))){
            $pageIndex=2;if($case[0] -eq 'pageHome'){$pageIndex=3}
            Show-Page $pageIndex;(Control 'contentScroll').ScrollToEnd();Pump
            $button=Control $case[1];$button.Focus()|Out-Null;Pump
            Check ($button.IsKeyboardFocused -and $button.ActualWidth -ge 24 -and [Windows.Automation.AutomationProperties]::GetName($button) -eq '插件共享范围说明') 'Sharing explanation is not a named keyboard reachable button.'
            $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));Pump
            Check ($settingsHelpPopup.IsOpen -and $settingsHelpPopup.PlacementTarget -eq $button -and $helpCloseButton.IsKeyboardFocused) 'Actual sharing help click does not open/focus the matching popup.'
            Check ($settingsHelpDetail.Text -match 'MIT' -and $settingsHelpDetail.Text -match '本地共享' -and $settingsHelpDetail.Text -match 'Figma' -and $settingsHelpDetail.Text -match '复制文件不能转移账号授权' -and $settingsHelpDetail.Text -match '清单读取成功不等于') 'Sharing rules omit a material capability boundary.'
            Check (-not $settingsHelpPopup.StaysOpen) 'Help popup cannot dismiss on outside interaction.'
            $helpScroll=Control 'settingsHelpScroll';Check ($helpScroll.ActualHeight -le $helpScroll.MaxHeight) 'Help text exceeds its bounded reading area.'
            Render $form.Content ('sharing-page-'+$case[0]+'-'+$size[0]+'.png')
            Render $settingsHelpPopup.Child ('sharing-help-'+$case[1]+'-'+$size[0]+'.png')
            $event=[Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,[Windows.PresentationSource]::FromVisual($settingsHelpPopup.Child),0,[Windows.Input.Key]::Escape);$event.RoutedEvent=[Windows.Input.Keyboard]::PreviewKeyDownEvent;$settingsHelpPopup.Child.RaiseEvent($event);Pump
            Check (-not $settingsHelpPopup.IsOpen -and $event.Handled -and $button.IsKeyboardFocused) 'Escape does not close sharing rules and restore the trigger focus.'
            $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));Pump
            $helpCloseButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));Pump
            Check (-not $settingsHelpPopup.IsOpen -and $button.IsKeyboardFocused) 'Help close action does not restore focus.'
            $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));Pump
            Show-Page 0;Pump;Check (-not $settingsHelpPopup.IsOpen) 'Page navigation leaves an unrelated help popup open.'
        }
    }
    Show-Page 0;Pump
    # Existing parameter explanations continue to use the same tested popup.
    Show-Page 1;Pump
    foreach($infoName in @('reasoningInfoButton','contextInfoButton','compactInfoButton')){
        Set-Variable -Name $infoName -Value (Control $infoName)
        $prefix='$'+$infoName+'.Add_Click'
        $hook=@($launcherAst.EndBlock.Statements|Where-Object{$_.Extent.Text.StartsWith($prefix)})[0]
        . ([scriptblock]::Create($hook.Extent.Text))
        (Control $infoName).RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));Pump
        Check ($settingsHelpPopup.IsOpen -and $settingsHelpPopup.PlacementTarget -eq (Control $infoName) -and $settingsHelpDetail.Text.Length -gt 40) ('Existing parameter explanation regressed: '+$infoName)
        $helpCloseButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));Pump
    }
    Open-SettingsHelp (Control 'reasoningInfoButton') '长说明测试' ('很长的说明内容，仍然可以完整查看。'*150);Pump
    Check ((Control 'settingsHelpScroll').ScrollableHeight -gt 0 -and (Control 'settingsHelpScroll').ActualHeight -le (Control 'settingsHelpScroll').MaxHeight) 'Long explanation cannot be read through bounded scrolling.'
    (Control 'settingsHelpScroll').ScrollToEnd();Pump;Check ((Control 'settingsHelpScroll').VerticalOffset -gt 0) 'End of long explanation is inaccessible.'
    $helpCloseButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));Show-Page 0;Pump
    foreach($name in @('resultToast','resultToastTitle','resultToastDetail','resultToastIcon','profilesList')){Set-Variable -Name $name -Value (Control $name)}
    $script:ResultToastTimer=[Windows.Threading.DispatcherTimer]::new();$script:ResultToastTimer.Interval=[TimeSpan]::FromSeconds(8)
    foreach($state in @('notice','info','success','error','cancelled')){
        Show-ResultToast $state '测试状态' '这是简短的合成结果。';Pump
        $expected='i';if($state -eq 'success'){$expected='✓'}elseif($state -eq 'error'){$expected='!'}elseif($state -eq 'cancelled'){$expected='−'}
        Check ($resultToastIcon.Text -ceq $expected) ('Result icon misrepresents state: '+$state)
        Check ((Control 'resultToastMore').Visibility -eq 'Collapsed') 'Short feedback unnecessarily expands details.'
    }
    $longText=("合成错误说明：这是完整内容，长路径 D:\示例 目录\文件。`n"*60)
    $moreHook=@($launcherAst.EndBlock.Statements|Where-Object{$_.Extent.Text.StartsWith('$form.FindName(''resultToastMore'').Add_Click')})[0]
    . ([scriptblock]::Create($moreHook.Extent.Text))
    foreach($size in @(@(1280,940),@(1080,760))){
        $form.Width=$size[0];$form.Height=$size[1];Show-ResultToast 'error' '长错误测试' $longText;Pump
        Check ($resultToastDetail.Text.Length -le 181 -and (Control 'resultToastMore').Visibility -eq 'Visible') 'Long result has no bounded excerpt/detail action.'
        Check ($resultToast.ActualHeight -lt 300) 'Feedback covers the work surface.'
        $button=Control 'resultToastMore';$button.Focus()|Out-Null;Pump
        Check ($button.IsKeyboardFocused) 'Full result action is not keyboard reachable.'
        $bounds=$resultToast.TransformToAncestor($form.Content).TransformBounds([Windows.Rect]::new(0,0,$resultToast.ActualWidth,$resultToast.ActualHeight))
        Check ($bounds.Right -le $form.Content.ActualWidth -and $bounds.Bottom -le $form.Content.ActualHeight) 'Feedback extends past window boundaries.'
        Render $form.Content ('feedback-long-'+$size[0]+'.png')
    }
    $script:FeedbackDialogFailure='';$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(150)
    $timer.Add_Tick({
        $timer.Stop();$detailDialog=@($form.OwnedWindows|Where-Object IsVisible)[0]
        try{
            Check ($detailDialog -and $detailDialog.Tag.dialogMessage.Text -ceq $longText) 'Full feedback is missing from the themed dialog.'
            Check ($detailDialog.Tag.Kind -eq 'error' -and $detailDialog.Tag.dialogConfirm.IsKeyboardFocused) 'Full feedback dialog state/focus mismatch.'
            Render $detailDialog.Content 'feedback-full-details.png'
            $event=[Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,[Windows.PresentationSource]::FromVisual($detailDialog),0,[Windows.Input.Key]::Escape);$event.RoutedEvent=[Windows.Input.Keyboard]::PreviewKeyDownEvent;$detailDialog.RaiseEvent($event)
        }catch{$script:FeedbackDialogFailure=$_.Exception.Message;if($detailDialog){$detailDialog.Close()}}
    }.GetNewClosure())
    $timer.Start();(Control 'resultToastMore').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));$timer.Stop()
    Check (-not $script:FeedbackDialogFailure) $script:FeedbackDialogFailure
    Check ((Control 'resultToastMore').IsKeyboardFocused) 'Closing full result did not restore focus.'
    Hide-ResultToast
    $profiles=@([pscustomobject]@{id='first';name='重复名称';base_url='https://example.test/v1'},[pscustomobject]@{id='second';name='重复名称';base_url='https://example.test/v1'})
    $script:Store=[pscustomobject]@{profiles=$profiles};$profilesList.Items.Clear();foreach($profile in $profiles){Add-ProfileItem $profile}
    Check ($profilesList.Items[0].name -cne $profilesList.Items[1].name -and $profilesList.Items[0].id -eq 'first' -and $profiles[0].name -eq '重复名称') 'Duplicate display names remain indistinguishable or original data changed.'
    foreach($profile in $profiles){$profile.name='长'*60}
    Check ((Get-ApiDisplayName $profiles[0] $profiles).StartsWith('1 · ') -and (Get-ApiDisplayName $profiles[1] $profiles).StartsWith('2 · ')) 'Long duplicate names hide their distinguishing number at the clipped end.'
    $existing=@([pscustomobject]@{name='新 API 接口 1'},[pscustomobject]@{name='新 API 接口 3'})
    Check ((Get-UniqueApiName '新 API 接口' $existing) -eq '新 API 接口 2') 'Adding after deletion reused an occupied name.'
    $copyBase=('长'*50)+' · 副本';$firstCopy=Get-UniqueApiName $copyBase @();$secondCopy=Get-UniqueApiName $copyBase @([pscustomobject]@{name=$firstCopy})
    Check ($firstCopy.Length -le 60 -and $secondCopy.Length -le 60 -and $firstCopy -cne $secondCopy) 'Repeated copies are not uniquely named within the name limit.'
    foreach($name in @('pageConnection','pageAdvanced','pageHome','pageImages')){(Control $name).Visibility='Collapsed'}
    (Control 'pagePlan').Visibility='Visible';(Control 'navPlan').IsChecked=$true;(Control 'pageTitle').Text='启动摘要';(Control 'pageSubtitle').Text='查看本次配置与插件检查结果。';(Control 'compatibilityDetails').IsExpanded=$true
    (Control 'compatibilityDetail').Text=("示例插件与完整路径 D:\项目 目录\技能\SKILL.md`n"*300);Pump
    $detailScroll=Control 'compatibilityDetailScroll'
    Check ($detailScroll.ActualHeight -le 280 -and $detailScroll.ScrollableHeight -gt 0) 'Large inventory stretches the page instead of the local details area.'
    $detailScroll.ScrollToEnd();Pump;Check ($detailScroll.VerticalOffset -gt 0) 'End of the complete inventory is inaccessible.'
    (Control 'contentScroll').ScrollToEnd();Pump
    Render $form.Content 'feedback-many-plugins.png'
    (Control 'compatibilityDetails').IsExpanded=$false;(Control 'pagePlan').Visibility='Collapsed';(Control 'pageConnection').Visibility='Visible';(Control 'navConnection').IsChecked=$true;(Control 'contentScroll').ScrollToHome();Pump
    # Long feedback stays bounded even if a consumer directly fills the text control.
    (Control 'resultToast').Visibility='Visible';(Control 'resultToastTitle').Text='连接检查未完成';(Control 'resultToastDetail').Text=('这是很长的错误说明。'*80);Pump
    Check ((Control 'resultToast').ActualHeight -lt 300) 'Long toast covers the work surface.'
    Render $form.Content 'long-error-toast.png';(Control 'resultToast').Visibility='Collapsed'
    # Focus stays visibly inside a complete border and causes no size change.
    $input=Control 'nameBox';$before=$input.ActualWidth;$input.Focus()|Out-Null;Pump
    Check ($input.ActualWidth -eq $before) 'Focus ring resized the field.'
    Render $form.Content 'connection-focused.png'
    'PASS: bundled font/glyphs; form and menu edges; 1280/1080 layouts; 100/150/200 percent raster rendering; modal save/discard/cancel/remove/recover routes, initial focus, owner, Enter/Escape, themed environment cancellation, bounded long toast and unchanged field bounds.'
}finally{if($script:ResultToastTimer){$script:ResultToastTimer.Stop()};$form.Close()}
