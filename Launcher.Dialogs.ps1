$script:AssistantThemeRoot=$PSScriptRoot
$script:AssistantDialogActive=$false
function Set-ThemedControlStroke([Windows.Window]$Window) {
    $dpi=[Windows.Media.VisualTreeHelper]::GetDpi($Window)
    $x=[Math]::Ceiling($dpi.DpiScaleX)/$dpi.DpiScaleX
    $y=[Math]::Ceiling($dpi.DpiScaleY)/$dpi.DpiScaleY
    $Window.Resources['ControlStroke']=[Windows.Thickness]::new($x,$y,$x,$y)
}
function New-ThemedWindow([string]$Layout) {
    $context=[Windows.Markup.ParserContext]::new()
    $context.BaseUri=[Uri]::new(($script:AssistantThemeRoot.TrimEnd('\')+'\'),[UriKind]::Absolute)
    $stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($Layout))
    try{
        $window=[Windows.Markup.XamlReader]::Load($stream,$context)
        # Composite font maps do not inherit ParserContext.BaseUri for their targets.
        $fontUri=[Uri]::new((Join-Path $script:AssistantThemeRoot 'fonts')+'\',[UriKind]::Absolute)
        foreach($key in @('UiFont','DataFont')){
            foreach($map in $window.FindResource($key).FamilyMaps){$map.Target=$fontUri.AbsoluteUri+'#ChillRoundM, Segoe UI, Microsoft YaHei UI'}
        }
        $window.SnapsToDevicePixels=$true
        Set-ThemedControlStroke $window
        $window.Add_SourceInitialized({param($sender,$eventArgs) Set-ThemedControlStroke $sender})
        $window.Add_DpiChanged({param($sender,$eventArgs) Set-ThemedControlStroke $sender})
        return $window
    }finally{$stream.Dispose()}
}
function New-AssistantDialog([Windows.Window]$Owner,[string]$Kind,[string]$Title,[string]$Message,[string]$Subject='') {
    $layout=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="570" SizeToContent="Height" WindowStartupLocation="CenterOwner" WindowStyle="None" ResizeMode="NoResize" ShowInTaskbar="False" AllowsTransparency="True" Background="Transparent" FontFamily="{DynamicResource UiFont}" FontSize="14" Foreground="{DynamicResource Ink}" UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Ideal">
 <Window.Resources><ResourceDictionary><ResourceDictionary.MergedDictionaries><ResourceDictionary Source="Theme.xaml"/></ResourceDictionary.MergedDictionaries></ResourceDictionary></Window.Resources>
 <Grid><Border x:Name="dialogFrame" Background="{StaticResource Surface}" BorderBrush="{StaticResource InputBorder}" BorderThickness="{DynamicResource ControlStroke}" CornerRadius="16" Margin="8" Padding="26">
  <Border.Effect><DropShadowEffect BlurRadius="12" ShadowDepth="2" Opacity="0.12" Color="#243647"/></Border.Effect>
  <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
   <Grid x:Name="dialogHeader" Background="Transparent" Margin="0,0,0,18"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="32"/></Grid.ColumnDefinitions><StackPanel Orientation="Horizontal" VerticalAlignment="Center"><TextBlock Text="连接助手" FontSize="13" Foreground="{StaticResource MutedInk}"/></StackPanel><Button x:Name="dialogClose" Grid.Column="1" Content="×" Style="{StaticResource Quiet}" Width="32" Height="32" MinHeight="32" Padding="0" FontSize="20" AutomationProperties.Name="返回并关闭提示"/></Grid>
   <ScrollViewer x:Name="dialogScroll" Grid.Row="1" Style="{StaticResource CompactScroll}" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" MaxHeight="440" Focusable="False" Padding="0,0,4,0"><StackPanel><TextBlock x:Name="dialogTitle" Style="{StaticResource DialogTitle}"/><Border x:Name="dialogSubjectFrame" Background="{StaticResource InsetSurface}" CornerRadius="8" Padding="12,10" Margin="0,14,0,0"><TextBlock x:Name="dialogSubject" FontSize="14" Foreground="{StaticResource SecondaryInk}"/></Border><TextBlock x:Name="dialogMessage" FontSize="14" LineHeight="24" Foreground="{StaticResource MutedInk}" Margin="0,14,0,0"/></StackPanel></ScrollViewer>
   <WrapPanel x:Name="dialogActions" Grid.Row="2" HorizontalAlignment="Right" Margin="0,24,0,0" KeyboardNavigation.TabNavigation="Cycle"><Button x:Name="dialogCancel" Content="返回编辑" Margin="0,4,8,4" Padding="13,8"/><Button x:Name="dialogDiscard" Content="不保存" Margin="0,4,8,4" Padding="13,8"/><Button x:Name="dialogConfirm" Content="保存并继续" Style="{StaticResource Primary}" Margin="0,4,0,4" Padding="13,8"/></WrapPanel>
  </Grid>
 </Border></Grid>
</Window>
'@
    $window=New-ThemedWindow $layout
    $window.Title=$Title
    $ctx=@{Window=$window;Choice='cancel';Kind=$Kind;PreviousFocus=[Windows.Input.Keyboard]::FocusedElement}
    foreach($name in @('dialogFrame','dialogTitle','dialogSubjectFrame','dialogSubject','dialogMessage','dialogHeader','dialogClose','dialogCancel','dialogDiscard','dialogConfirm','dialogScroll')){$ctx[$name]=$window.FindName($name)}
    $window.Tag=$ctx
    if($Owner){$window.Owner=$Owner;$window.Icon=$Owner.Icon}
    $ctx.dialogTitle.Text=$Title;$ctx.dialogMessage.Text=$Message;$ctx.dialogSubject.Text=$Subject
    if(-not $Subject){$ctx.dialogSubjectFrame.Visibility='Collapsed'}
    $ctx.dialogCancel.Tag='cancel';$ctx.dialogClose.Tag='cancel';$ctx.dialogDiscard.Tag='discard'
    $ctx.dialogConfirm.Tag='save'
    if($Kind -ne 'save'){
        $ctx.dialogDiscard.Visibility='Collapsed';$ctx.dialogCancel.Content='取消';$ctx.dialogConfirm.Tag='confirm'
        $ctx.dialogConfirm.Content='移除配置';if($Kind -eq 'recover'){$ctx.dialogConfirm.Content='恢复官方备份'}
        if($Kind -eq 'reset-login'){$ctx.dialogConfirm.Content='重置并重新登录'}
        if($Kind -eq 'replace-profile'){$ctx.dialogConfirm.Content='备份并保存'}
        $ctx.dialogConfirm.Style=$window.FindResource('Danger')
    }
    if($Kind -in @('notice','error')){
        $ctx.dialogCancel.Visibility='Collapsed';$ctx.dialogConfirm.Content='知道了'
        $ctx.dialogConfirm.Style=$window.FindResource('Primary')
    }
    foreach($button in @($ctx.dialogCancel,$ctx.dialogClose,$ctx.dialogDiscard,$ctx.dialogConfirm)){
        $button.Add_Click({param($sender,$eventArgs)$state=([Windows.Window]::GetWindow($sender)).Tag;$state.Choice=[string]$sender.Tag;$state.Window.Close()})
    }
    $ctx.dialogHeader.Add_MouseLeftButtonDown({param($sender,$eventArgs)
        $target=$eventArgs.OriginalSource
        while($target -and $target -ne $sender){
            if($target -is [Windows.Controls.Primitives.ButtonBase]){return}
            if($target -is [Windows.Media.Visual]){$target=[Windows.Media.VisualTreeHelper]::GetParent($target)}else{return}
        }
        try{([Windows.Window]::GetWindow($sender)).DragMove()}catch{}
    })
    $window.Add_PreviewKeyDown({param($sender,$eventArgs)
        if($eventArgs.Key -eq [Windows.Input.Key]::Escape){$sender.Tag.Choice='cancel';$sender.Close();$eventArgs.Handled=$true}
        elseif($eventArgs.Key -eq [Windows.Input.Key]::Enter -and [Windows.Input.Keyboard]::FocusedElement -is [Windows.Controls.Button]){
            $target=[Windows.Input.Keyboard]::FocusedElement;$target.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));$eventArgs.Handled=$true
        }
    })
    $window.Add_ContentRendered({param($sender,$eventArgs)$state=$sender.Tag;if($state.Kind -in @('save','notice','error')){$state.dialogConfirm.Focus()|Out-Null}else{$state.dialogCancel.Focus()|Out-Null}})
    $window.Add_Closed({param($sender,$eventArgs)$previous=$sender.Tag.PreviousFocus;if($previous -and $previous -is [Windows.UIElement] -and $previous.IsVisible -and $previous.IsEnabled){$previous.Focus()|Out-Null}})
    [Windows.Input.KeyboardNavigation]::SetTabNavigation($window.Content,[Windows.Input.KeyboardNavigationMode]::Cycle)
    $area=[Windows.SystemParameters]::WorkArea;$window.Width=[Math]::Min(570,$area.Width-24);$window.MaxHeight=[Math]::Max(200,$area.Height-24)
    $ctx.dialogScroll.MaxHeight=[Math]::Max(100,[Math]::Min(440,$area.Height-230))
    return $window
}
function Show-AssistantDialog([string]$Kind,[string]$Title,[string]$Message,[string]$Subject='') {
    if($script:AssistantDialogActive){return 'cancel'}
    $script:AssistantDialogActive=$true
    try{
        $dialog=New-AssistantDialog $form $Kind $Title $Message $Subject
        $null=$dialog.ShowDialog()
        return [string]$dialog.Tag.Choice
    }finally{$script:AssistantDialogActive=$false}
}
