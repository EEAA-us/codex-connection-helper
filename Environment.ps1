function New-EnvironmentWindow {
    $layout=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="环境设置 · Codex 连接助手" Width="780" Height="720" MinWidth="620" MinHeight="520" WindowStartupLocation="CenterOwner" Background="{DynamicResource Canvas}" FontFamily="{DynamicResource UiFont}" FontSize="14" Foreground="{DynamicResource Ink}" UseLayoutRounding="True">
 <Window.Resources><ResourceDictionary><ResourceDictionary.MergedDictionaries><ResourceDictionary Source="Theme.xaml"/></ResourceDictionary.MergedDictionaries></ResourceDictionary></Window.Resources>
 <Border Padding="25"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <StackPanel Margin="0,0,0,20"><TextBlock Text="找到你的 Codex" FontSize="25" FontWeight="SemiBold"/><TextBlock Text="通常无需填写。留空使用自动识别结果；只有找不到或位置不对时才选择。" Foreground="{StaticResource MutedInk}" Margin="0,8,0,0" FontSize="13" TextWrapping="Wrap"/></StackPanel>
  <ScrollViewer Grid.Row="1" Style="{StaticResource CompactScroll}" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><StackPanel Margin="0,0,10,12">
   <Border Background="White" BorderBrush="{StaticResource Divider}" BorderThickness="{DynamicResource ControlStroke}" CornerRadius="12" Padding="18"><StackPanel>
    <TextBlock Text="桌面程序" FontWeight="SemiBold"/><TextBlock Text="留空自动识别商店、Windows 登记或正在运行的完整安装。" FontSize="13" Foreground="{StaticResource MutedInk}" Margin="0,5,0,9"/>
    <DockPanel><Button x:Name="chooseDesktop" DockPanel.Dock="Right" Content="选择…" Margin="9,0,0,0" Tag="desktop"/><TextBox x:Name="desktopPath" FontFamily="{StaticResource DataFont}" AutomationProperties.Name="桌面程序路径"/></DockPanel>
    <TextBlock Text="聊天与插件数据" FontWeight="SemiBold" Margin="0,20,0,0"/><TextBlock Text="留空自动使用 CODEX_HOME 或当前用户的 .codex，不移动聊天。" FontSize="13" Foreground="{StaticResource MutedInk}" Margin="0,5,0,9"/>
    <DockPanel><Button x:Name="chooseHome" DockPanel.Dock="Right" Content="选择…" Margin="9,0,0,0" Tag="home"/><TextBox x:Name="homePath" FontFamily="{StaticResource DataFont}" AutomationProperties.Name="聊天数据目录"/></DockPanel>
    <TextBlock Text="桌面界面数据" FontWeight="SemiBold" Margin="0,20,0,0"/><TextBlock Text="通常保持自动；使用过自定义界面目录时选择原位置。" FontSize="13" Foreground="{StaticResource MutedInk}" Margin="0,5,0,9"/>
    <DockPanel><Button x:Name="chooseUi" DockPanel.Dock="Right" Content="选择…" Margin="9,0,0,0" Tag="ui"/><TextBox x:Name="uiPath" FontFamily="{StaticResource DataFont}" AutomationProperties.Name="界面数据目录"/></DockPanel>
   </StackPanel></Border>
   <Border Background="{StaticResource InsetSurface}" CornerRadius="12" Padding="16,13" Margin="0,14,0,0"><StackPanel><TextBlock Text="当前实际使用的位置" Foreground="{StaticResource ActionInk}" FontWeight="SemiBold"/><TextBlock x:Name="resolvedPaths" FontSize="13" Foreground="{StaticResource MutedInk}" Margin="0,8,0,0" LineHeight="20" TextWrapping="Wrap"/></StackPanel></Border>
  </StackPanel></ScrollViewer>
  <StackPanel Grid.Row="2"><TextBlock x:Name="pathError" Foreground="{StaticResource DangerInk}" FontSize="13" TextWrapping="Wrap" Margin="0,9,0,12"/><DockPanel><Button x:Name="savePaths" DockPanel.Dock="Right" Content="保存位置" Style="{StaticResource Primary}" IsDefault="True"/><Button x:Name="cancelPaths" DockPanel.Dock="Right" Content="取消" Margin="0,0,9,0" IsCancel="True"/><Button x:Name="autoPaths" Content="自动识别并应用" HorizontalAlignment="Left"/></DockPanel></StackPanel>
 </Grid></Border>
</Window>
'@
    $window=New-ThemedWindow $layout
    $context=@{Saved=$false;Window=$window}
    foreach($name in @('desktopPath','homePath','uiPath','resolvedPaths','pathError','savePaths','cancelPaths','autoPaths','chooseDesktop','chooseHome','chooseUi')){$context[$name]=$window.FindName($name)}
    $window.Tag=$context
    try{
        $prefs=Get-PathPreferences
        $context.desktopPath.Text=$prefs.desktop_exe;$context.homePath.Text=$prefs.codex_home;$context.uiPath.Text=$prefs.ui_data_path
    }catch{$context.pathError.Text=$_.Exception.Message}
    Update-EnvironmentPathsView $context
    if($env:CODEX_HOME){$context.homePath.IsEnabled=$false;$context.chooseHome.IsEnabled=$false}
    if($env:CODEX_ELECTRON_USER_DATA_PATH){$context.uiPath.IsEnabled=$false;$context.chooseUi.IsEnabled=$false}
    foreach($button in @($context.chooseDesktop,$context.chooseHome,$context.chooseUi)){
        $button.Add_Click({param($sender,$eventArgs)
            $ctx=([Windows.Window]::GetWindow($sender)).Tag
            if($sender.Tag -eq 'desktop'){
                $dialog=[Windows.Forms.OpenFileDialog]::new();$dialog.Filter='Codex 桌面程序 (*.exe)|*.exe';$dialog.CheckFileExists=$true
                try{if($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK){$ctx.desktopPath.Text=$dialog.FileName}}finally{$dialog.Dispose()}
            }else{
                $dialog=[Windows.Forms.FolderBrowserDialog]::new();$dialog.ShowNewFolderButton=$false;$dialog.Description='选择原有的 Codex 数据目录'
                try{if($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK){if($sender.Tag -eq 'home'){$ctx.homePath.Text=$dialog.SelectedPath}else{$ctx.uiPath.Text=$dialog.SelectedPath}}}finally{$dialog.Dispose()}
            }
        })
    }
    $context.autoPaths.Add_Click({param($sender,$eventArgs)
        $ctx=([Windows.Window]::GetWindow($sender)).Tag
        try{
            Invoke-ExclusiveSwitch {Use-AutomaticLauncherPaths}
            $prefs=Get-PathPreferences;$ctx.desktopPath.Text=$prefs.desktop_exe;$ctx.homePath.Text=$prefs.codex_home;$ctx.uiPath.Text=$prefs.ui_data_path
            $ctx.Saved=$true;Update-EnvironmentPathsView $ctx
            $ctx.cancelPaths.Content='关闭'
            $ctx.pathError.Foreground=$ctx.Window.FindResource('SuccessInk')
            $ctx.pathError.Text='已应用，无需再点保存。保留正在使用的聊天与界面目录；环境变量仍优先。'
            if(-not(Test-CodexHome $script:OfficialHome)){$ctx.pathError.Foreground=$ctx.Window.FindResource('MutedInk');$ctx.pathError.Text+=' 原聊天目录暂未找到；位置已保留，请接回磁盘或先打开官方 Codex。'}
        }catch{$ctx.pathError.Foreground=$ctx.Window.FindResource('DangerInk');$ctx.pathError.Text=$_.Exception.Message}
    })
    $context.cancelPaths.Add_Click({param($sender,$eventArgs)([Windows.Window]::GetWindow($sender)).Close()})
    $context.savePaths.Add_Click({param($sender,$eventArgs)
        $ctx=([Windows.Window]::GetWindow($sender)).Tag
        try{
            Invoke-ExclusiveSwitch {Save-PathPreferences $ctx.desktopPath.Text $ctx.homePath.Text $ctx.uiPath.Text}
            $ctx.Saved=$true;$ctx.Window.Close()
        }catch{$ctx.pathError.Foreground=$ctx.Window.FindResource('DangerInk');$ctx.pathError.Text=$_.Exception.Message}
    })
    $area=[Windows.SystemParameters]::WorkArea
    $window.Width=[Math]::Min($window.Width,$area.Width-32);$window.Height=[Math]::Min($window.Height,$area.Height-32)
    $window.MinWidth=[Math]::Min($window.MinWidth,$window.Width);$window.MinHeight=[Math]::Min($window.MinHeight,$window.Height)
    return $window
}

function Update-EnvironmentPathsView($Context) {
    $desktop='未找到，请选择桌面程序';try{$desktop=Get-DesktopExe}catch{$desktop=$_.Exception.Message}
    $Context.resolvedPaths.Text="程序：$desktop`n聊天：$script:OfficialHome（$script:HomePathSource）`n界面：$script:OfficialUi（$script:UiPathSource）`n自动识别不会移动或重建聊天；更换聊天目录请手动选择。"
}
