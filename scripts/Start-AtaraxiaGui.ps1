[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$NoSplash
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    $hostPath = (Get-Process -Id $PID).Path
    $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',('"' + $PSCommandPath + '"')) -join ' '
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $arguments += ' -ConfigPath "' + $ConfigPath.Replace('"','\"') + '"' }
    if($NoSplash){$arguments+= ' -NoSplash'}
    Start-Process -FilePath $hostPath -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $PSScriptRoot) | Out-Null
    exit 0
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $projectRoot 'configs/config.json' }
. (Join-Path $PSScriptRoot 'Localization.ps1')
. (Join-Path $PSScriptRoot 'ConversationStore.ps1')
. (Join-Path $PSScriptRoot 'GuiConversationModel.ps1')
. (Join-Path $PSScriptRoot 'ProjectStore.ps1')
. (Join-Path $PSScriptRoot 'RoleContracts.ps1')
. (Join-Path $PSScriptRoot 'AgentCore.ps1')
. (Join-Path $PSScriptRoot 'SessionStore.ps1')
. (Join-Path $PSScriptRoot 'GuiTheme.ps1')
. (Join-Path $PSScriptRoot 'GuiModelParameters.ps1')
. (Join-Path $PSScriptRoot 'CommonPrompts.ps1')
. (Join-Path $PSScriptRoot 'KoboldCppSettings.ps1')
$script:queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:process = $null
$script:koboldProcess=$null
$script:koboldSetupProcess=$null
$script:koboldSetupStdoutPath=''
$script:koboldSetupStderrPath=''
$script:lastKoboldPoll=[DateTime]::MinValue
$script:mode = ''
$script:taskPath = ''
$script:editing = $false
$script:lastQuery = [DateTime]::MinValue
$script:loadingSession=$false
$script:pendingSessionProject=''
$script:projectTreeExpanded=@{}
$script:recentSessionsExpanded=$false
$script:smoothExpanderIds=[System.Collections.Generic.HashSet[int]]::new()
$script:currentRole=''
$script:themeMode='system'
$script:effectiveTheme=''
$script:updatingTheme=$false

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="" Width="1000" Height="820" MinWidth="760" MinHeight="640" WindowStartupLocation="CenterScreen" Background="{DynamicResource AppBackgroundBrush}" Foreground="{DynamicResource PrimaryTextBrush}" FontFamily="Segoe UI">
 <Window.Resources>
 <DataTemplate x:Key="ThemeOptionTemplate"><TextBlock Text="{Binding label}" VerticalAlignment="Center"/></DataTemplate><SolidColorBrush x:Key="AppBackgroundBrush" Color="#FAFAFA"/><SolidColorBrush x:Key="SurfaceBrush" Color="#FFFFFF"/><SolidColorBrush x:Key="PanelBrush" Color="#F0F0F0"/><SolidColorBrush x:Key="DrawerBrush" Color="#F7F7F7"/><SolidColorBrush x:Key="PrimaryTextBrush" Color="#141414"/><SolidColorBrush x:Key="SecondaryTextBrush" Color="#414141"/><SolidColorBrush x:Key="BorderBrush" Color="#C8C8C8"/><SolidColorBrush x:Key="AccentBrush" Color="#2C2C2C"/><SolidColorBrush x:Key="AccentTextBrush" Color="#FFFFFF"/><SolidColorBrush x:Key="IconBrush" Color="#2C2C2C"/>
 <Style x:Key="IconButtonHover" TargetType="{x:Type Button}"><Setter Property="Foreground" Value="{DynamicResource PrimaryTextBrush}"/><Setter Property="Background" Value="Transparent"/><Setter Property="BorderBrush" Value="Transparent"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="7,5"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type Button}"><Grid SnapsToDevicePixels="True"><Border x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5"/><Border x:Name="HoverTint" Background="{TemplateBinding Foreground}" Opacity="0" CornerRadius="5" IsHitTestVisible="False"/><ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" Margin="{TemplateBinding Padding}" RecognizesAccessKey="True"/></Grid><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="HoverTint" Property="Opacity" Value="0.12"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="HoverTint" Property="Opacity" Value="0.2"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter TargetName="Chrome" Property="Opacity" Value="0.42"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
 <Style TargetType="{x:Type Button}" BasedOn="{StaticResource IconButtonHover}"/>
 <Style TargetType="{x:Type ToggleButton}"><Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type ToggleButton}"><Border x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="Transparent" BorderThickness="1" CornerRadius="4"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Chrome" Property="Background" Value="{DynamicResource PanelBrush}"/></Trigger><Trigger Property="IsChecked" Value="True"><Setter TargetName="Chrome" Property="Background" Value="{DynamicResource PanelBrush}"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
 <Style TargetType="{x:Type TextBox}"><Setter Property="Foreground" Value="{DynamicResource PrimaryTextBrush}"/><Setter Property="Background" Value="{DynamicResource SurfaceBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="7,5"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type TextBox}"><Border x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" SnapsToDevicePixels="True"><ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" Focusable="False" HorizontalScrollBarVisibility="{TemplateBinding HorizontalScrollBarVisibility}" VerticalScrollBarVisibility="{TemplateBinding VerticalScrollBarVisibility}"/></Border><ControlTemplate.Triggers><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter TargetName="Chrome" Property="Opacity" Value="0.5"/></Trigger><Trigger Property="IsReadOnly" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="Transparent"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
 <Style TargetType="{x:Type ComboBox}"><Setter Property="Foreground" Value="{DynamicResource PrimaryTextBrush}"/><Setter Property="Background" Value="{DynamicResource SurfaceBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="7,4"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type ComboBox}"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="28"/></Grid.ColumnDefinitions><Border Grid.ColumnSpan="2" x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5"/><ContentPresenter Margin="{TemplateBinding Padding}" VerticalAlignment="Center" HorizontalAlignment="Left" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}" IsHitTestVisible="False"/><ToggleButton Grid.ColumnSpan="2" HorizontalAlignment="Stretch" Background="Transparent" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}" ClickMode="Press" ToolTip="Open list"><ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Grid Background="{TemplateBinding Background}"><Path Data="M4,6 L10,12 L16,6" Width="12" Height="8" Stretch="Fill" HorizontalAlignment="Right" Margin="0,0,9,0" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/></Grid></ControlTemplate></ToggleButton.Template></ToggleButton><Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Slide"><Border Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="5" Padding="3"><ScrollViewer CanContentScroll="True" MaxHeight="280"><ItemsPresenter/></ScrollViewer></Border></Popup></Grid><ControlTemplate.Triggers><Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter TargetName="Chrome" Property="Opacity" Value="0.5"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
 <Style TargetType="{x:Type Expander}"><Setter Property="Foreground" Value="{DynamicResource PrimaryTextBrush}"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type Expander}"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><DockPanel Grid.Row="0" LastChildFill="True"><ToggleButton x:Name="ExpandToggle" DockPanel.Dock="Left" Width="24" Height="24" Padding="0" IsChecked="{Binding IsExpanded, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}" ToolTip="Expand or collapse"><Path x:Name="Chevron" Data="{DynamicResource ExpanderChevronRightGeometry}" Width="12" Height="12" Stretch="Uniform" Fill="Transparent" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/></ToggleButton><ContentPresenter x:Name="HeaderSite" ContentSource="Header" RecognizesAccessKey="True" VerticalAlignment="Center" Margin="3,0,0,0"/></DockPanel><Border x:Name="ExpandClip" Grid.Row="1" Height="0" Opacity="0" Visibility="Collapsed" ClipToBounds="True"><ContentPresenter x:Name="ExpandSite" ContentSource="Content" Margin="0,5,0,0"/></Border></Grid><ControlTemplate.Triggers><Trigger Property="IsExpanded" Value="True"><Setter TargetName="Chevron" Property="Data" Value="{DynamicResource ExpanderChevronDownGeometry}"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
 <Style TargetType="{x:Type ScrollBar}"><Setter Property="Width" Value="10"/><Setter Property="Height" Value="Auto"/><Setter Property="MinWidth" Value="8"/><Setter Property="MinHeight" Value="0"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type ScrollBar}"><Track x:Name="PART_Track" IsDirectionReversed="True" Orientation="{TemplateBinding Orientation}"><Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="{x:Type Thumb}"><Border x:Name="ThumbShape" Background="{DynamicResource BorderBrush}" CornerRadius="4" Margin="2"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb></Track><ControlTemplate.Triggers><Trigger Property="Orientation" Value="Horizontal"><Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/><Setter Property="Width" Value="Auto"/><Setter Property="Height" Value="10"/><Setter Property="MinWidth" Value="0"/><Setter Property="MinHeight" Value="8"/></Trigger><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="PART_Track" Property="Opacity" Value="0.75"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
 <Style TargetType="{x:Type ProgressBar}"><Setter Property="Foreground" Value="{DynamicResource AccentBrush}"/><Setter Property="Background" Value="{DynamicResource PanelBrush}"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type ProgressBar}"><Border Background="{TemplateBinding Background}" CornerRadius="3" ClipToBounds="True"><Grid><Rectangle x:Name="PART_Track" Fill="{TemplateBinding Background}"/><Border x:Name="PART_Indicator" HorizontalAlignment="Left" Background="{TemplateBinding Foreground}" CornerRadius="3"/></Grid></Border></ControlTemplate></Setter.Value></Setter></Style>
 <Style TargetType="{x:Type ComboBoxItem}"><Setter Property="Foreground" Value="{DynamicResource PrimaryTextBrush}"/><Setter Property="Background" Value="Transparent"/><Setter Property="Padding" Value="8,6"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type ComboBoxItem}"><Border x:Name="ItemChrome" Background="{TemplateBinding Background}" CornerRadius="3"><ContentPresenter Margin="{TemplateBinding Padding}"/></Border><ControlTemplate.Triggers><Trigger Property="IsHighlighted" Value="True"><Setter TargetName="ItemChrome" Property="Background" Value="{DynamicResource PanelBrush}"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter TargetName="ItemChrome" Property="Background" Value="{DynamicResource PanelBrush}"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter TargetName="ItemChrome" Property="Opacity" Value="0.5"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
 <Style TargetType="{x:Type Slider}"><Setter Property="Foreground" Value="{DynamicResource AccentBrush}"/><Setter Property="Background" Value="{DynamicResource BorderBrush}"/><Setter Property="MinHeight" Value="24"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type Slider}"><Grid><Border Height="3" Background="{TemplateBinding Background}" CornerRadius="2" VerticalAlignment="Center"/><Track x:Name="PART_Track" Orientation="Horizontal" Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}" Value="{TemplateBinding Value}" IsDirectionReversed="False"><Track.DecreaseRepeatButton><RepeatButton Command="{x:Static Slider.DecreaseLarge}" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton><Track.IncreaseRepeatButton><RepeatButton Command="{x:Static Slider.IncreaseLarge}" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton><Track.Thumb><Thumb Width="14" Height="14" Focusable="False"><Thumb.Template><ControlTemplate TargetType="{x:Type Thumb}"><Ellipse x:Name="ThumbDot" Fill="{DynamicResource SurfaceBrush}" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.5"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb></Track></Grid></ControlTemplate></Setter.Value></Setter></Style>
 <Style TargetType="{x:Type ContextMenu}"><Setter Property="Background" Value="{DynamicResource SurfaceBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type ContextMenu}"><Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="5" Padding="4"><ItemsPresenter/></Border></ControlTemplate></Setter.Value></Setter></Style>
 <Style TargetType="{x:Type MenuItem}"><Setter Property="Foreground" Value="{DynamicResource PrimaryTextBrush}"/><Setter Property="Padding" Value="8,6"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type MenuItem}"><Border x:Name="MenuChrome" Background="Transparent" CornerRadius="3"><ContentPresenter ContentSource="Header" Margin="{TemplateBinding Padding}"/></Border><ControlTemplate.Triggers><Trigger Property="IsHighlighted" Value="True"><Setter TargetName="MenuChrome" Property="Background" Value="{DynamicResource PanelBrush}"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style></Window.Resources><Grid><Grid.ColumnDefinitions><ColumnDefinition x:Name="DrawerColumn" Width="260"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Border x:Name="ProjectDrawer" Grid.Column="0" Background="{DynamicResource DrawerBrush}" Padding="14">
    <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel>
     <DockPanel Margin="0,8,0,14" LastChildFill="False"><StackPanel Orientation="Horizontal"><Button x:Name="NewProject" Width="34" Height="32" Padding="7" Margin="0,0,6,0" ToolTip="New project"><Path Data="M2,5 H8 L10,7 H18 V17 H2 Z M10,12 H16 M13,9 V15" Width="18" Height="18" Stretch="Uniform" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Button><Button x:Name="RenameProject" Width="34" Height="32" Padding="7" Margin="0,0,6,0" ToolTip="Rename project"><Path Data="M3,15 L13,5 L16,8 L6,18 H3 Z M11,7 L14,10 M3,18 H17" Width="18" Height="18" Stretch="Uniform" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Button><Button x:Name="ProjectPromptButton" Width="34" Height="32" Padding="7" ToolTip="Project prompt"><Path Data="M2,3 H18 V15 H10 L5,19 V15 H2 Z M6,7 H15 M6,11 H13" Width="18" Height="18" Stretch="Uniform" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Button></StackPanel></DockPanel>
     <Expander x:Name="ProjectGroupExpander" IsExpanded="True" Margin="0,0,0,6"><Expander.Header><TextBlock Text="Projects" Foreground="{DynamicResource PrimaryTextBrush}" FontWeight="SemiBold"/></Expander.Header><ScrollViewer x:Name="ProjectTreeScroll" MaxHeight="400" VerticalScrollBarVisibility="Auto" Margin="0,0,0,6"><StackPanel x:Name="ProjectTreePanel"/></ScrollViewer></Expander>
     <Expander x:Name="RecentSessionsExpander" IsExpanded="False" Margin="0,6,0,0"><Expander.Header><TextBlock Text="Recent sessions" Foreground="{DynamicResource PrimaryTextBrush}" FontWeight="SemiBold"/></Expander.Header><ScrollViewer MaxHeight="220" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="RecentSessionsPanel" Margin="16,0,0,2"/></ScrollViewer></Expander>
    </StackPanel></ScrollViewer>
  </Border>
  <Grid x:Name="MainContent" Grid.Column="1" Margin="18"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="2*"/><RowDefinition Height="130"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <DockPanel Grid.Row="0" Margin="0,0,0,12" LastChildFill="False"><StackPanel DockPanel.Dock="Right" Orientation="Horizontal"><ComboBox x:Name="SessionSelector" Width="220" Height="34" Margin="0,0,8,0" VerticalContentAlignment="Center" DisplayMemberPath="title"/><Button x:Name="RenameSession" Width="34" Height="34" Padding="7" Margin="0,0,6,0" ToolTip="Rename session"><Path Data="M3,15 L13,5 L16,8 L6,18 H3 Z M11,7 L14,10 M3,18 H17" Width="18" Height="18" Stretch="Uniform" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Button><Button x:Name="SessionPromptButton" Width="34" Height="34" Padding="7" Margin="0,0,6,0" ToolTip="Session prompt"><Path Data="M2,3 H18 V15 H10 L5,19 V15 H2 Z M6,7 H15 M6,11 H13" Width="18" Height="18" Stretch="Uniform" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Button><Button x:Name="NewSession" Width="38" Height="34" Padding="0" Margin="0,0,8,0" Background="{DynamicResource AccentBrush}" Foreground="{DynamicResource AccentTextBrush}" ToolTip="New session"><Path Data="M4,1 H12 L16,5 V16 H4 Z M12,1 V5 H16 M10,8 V14 M7,11 H13" Width="18" Height="18" Stretch="Uniform" Stroke="{DynamicResource AccentTextBrush}" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Button><Button x:Name="OtherSession" Width="36" Height="34" FontSize="20" Padding="0" ToolTip="More"><Button.ContextMenu><ContextMenu><MenuItem Header="Copy session ID"/></ContextMenu></Button.ContextMenu></Button></StackPanel></DockPanel>
  <Expander x:Name="TaskSettingsExpander" Grid.Row="1" Header="Settings" IsExpanded="False" Margin="0,0,0,8"><StackPanel><Grid Grid.Row="1" Margin="0,0,0,8"><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock x:Name="ConfigLabel" Grid.Column="0" Text="Runtime config" VerticalAlignment="Center" Margin="0,0,10,0"/><TextBox x:Name="RuntimeConfig" Grid.Column="1" Height="30" Padding="6"/><Button x:Name="BrowseConfig" Grid.Column="2" Width="34" Height="30" Padding="7" Margin="6,0,8,0" ToolTip="Browse"><Path Data="M2,5 H8 L10,7 H18 V17 H2 Z M7,11 H15" Width="18" Height="18" Stretch="Uniform" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Button><TextBlock x:Name="ThemeLabel" Grid.Column="3" Text="Theme" VerticalAlignment="Center" Margin="0,0,6,0"/><ComboBox x:Name="ThemeSelector" Grid.Column="4" Width="110" Height="30" Padding="4" Margin="0,0,10,0"/><StackPanel Grid.Column="5" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,8,0"><Ellipse x:Name="KoboldStatusDot" Width="12" Height="12" Fill="#C62828" Margin="0,0,6,0"/><TextBlock x:Name="KoboldStatusText" Text="Disconnected" VerticalAlignment="Center"/></StackPanel><Button x:Name="KoboldToggle" Grid.Column="6" Width="34" Height="30" Padding="7" Margin="0,0,5,0" ToolTip="Start KoboldCpp"><Path Data="M5,3 L16,10 L5,17 Z" Width="18" Height="18" Stretch="Uniform" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Button><Button x:Name="KoboldRestart" Grid.Column="7" Width="34" Height="30" Padding="7" ToolTip="Restart"><Path Data="M16,7 A6,6 0 1 0 17,12 M16,3 V7 H12" Width="18" Height="18" Stretch="Uniform" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Button></Grid>
  <Grid Grid.Row="2" Margin="0,0,0,8"><Grid.ColumnDefinitions><ColumnDefinition Width="2*"/><ColumnDefinition Width="3*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel Grid.Column="0" Margin="0,0,8,0"><TextBlock x:Name="TaskNameLabel" Text="Task name"/><TextBox x:Name="TaskName" Height="30" Padding="6"/></StackPanel><StackPanel Grid.Column="1" Margin="0,0,8,0"><TextBlock x:Name="WorkspaceLabel" Text="Working directory"/><TextBox x:Name="Workspace" Height="30" Padding="6"/></StackPanel><Button x:Name="BrowseTask" Grid.Column="2" Width="34" Height="30" Padding="7" Margin="0,18,6,0" ToolTip="Open task"><Path Data="M4,2 H12 L16,6 V18 H4 Z M12,2 V6 H16 M7,10 H13 M7,13 H13" Width="18" Height="18" Stretch="Uniform" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Button><Button x:Name="BrowseWorkspace" Grid.Column="3" Width="34" Height="30" Padding="7" Margin="0,18,0,0" ToolTip="Browse folder"><Path Data="M2,5 H8 L10,7 H18 V17 H2 Z" Width="18" Height="18" Stretch="Uniform" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Button></Grid>
  <Expander x:Name="ParametersExpander" Grid.Row="3" IsExpanded="False" Margin="0,2,0,2"><ScrollViewer MaxHeight="260" VerticalScrollBarVisibility="Auto"><StackPanel Margin="6"><Grid Margin="0,3,0,8"><Grid.ColumnDefinitions><ColumnDefinition Width="145"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock x:Name="ModelFileLabel" Text="Model file" VerticalAlignment="Center" Margin="0,0,8,0"/><ComboBox x:Name="ModelFileSelector" Grid.Column="1" Height="30" Padding="4" IsEditable="False"/><Button x:Name="RefreshModels" Grid.Column="2" Width="34" Height="30" Padding="7" Margin="8,0,0,0" ToolTip="Refresh"><Path Data="M16,7 A6,6 0 1 0 17,12 M16,3 V7 H12" Width="18" Height="18" Stretch="Uniform" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Button></Grid><StackPanel x:Name="ParameterPanel"/></StackPanel></ScrollViewer></Expander></StackPanel></Expander>
  <Grid Grid.Row="4" Margin="0,5,0,0"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><TextBlock x:Name="ConversationLabel" Grid.Row="0" Text="Conversation" FontSize="15" FontWeight="SemiBold" Foreground="{DynamicResource PrimaryTextBrush}" Margin="0,0,0,5"/><ScrollViewer x:Name="ConversationScrollViewer" Grid.Row="1" Background="{DynamicResource AppBackgroundBrush}" VerticalScrollBarVisibility="Auto" Padding="10"><ItemsControl x:Name="Conversation"><ItemsControl.ItemTemplate><DataTemplate><Border x:Name="ConversationBubble" MaxWidth="680" CornerRadius="7" BorderThickness="0" Padding="11" Margin="4,4"><Border.Style><Style TargetType="Border"><Setter Property="HorizontalAlignment" Value="Left"/><Setter Property="Background" Value="Transparent"/><Style.Triggers><DataTrigger Binding="{Binding kind}" Value="user"><Setter Property="HorizontalAlignment" Value="Right"/><Setter Property="Background" Value="{DynamicResource PanelBrush}"/></DataTrigger></Style.Triggers></Style></Border.Style><Expander IsExpanded="{Binding is_expanded, Mode=TwoWay}" Padding="0" BorderThickness="0" Background="Transparent" Foreground="{DynamicResource PrimaryTextBrush}"><Expander.Header><StackPanel Orientation="Horizontal"><Path Data="{Binding icon_geometry}" Width="18" Height="18" Stretch="Uniform" Stroke="{DynamicResource IconBrush}" Fill="Transparent" StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Margin="0,0,8,0"/><TextBox x:Name="ConversationHeading" Text="{Binding heading}" IsReadOnly="True" IsTabStop="False" BorderThickness="0" Background="Transparent" Padding="0" VerticalContentAlignment="Center" TextWrapping="Wrap"/></StackPanel></Expander.Header><TextBox x:Name="ConversationBody" Text="{Binding body}" IsReadOnly="True" IsTabStop="False" BorderThickness="0" Background="Transparent" Padding="0" TextWrapping="Wrap" VerticalScrollBarVisibility="Disabled" HorizontalScrollBarVisibility="Disabled" Margin="8,6,8,8" Foreground="{DynamicResource PrimaryTextBrush}" Tag="{Binding RelativeSource={RelativeSource AncestorType=Window}, Path=Tag}"><TextBox.ContextMenu><ContextMenu><MenuItem Header="{Binding PlacementTarget.Tag, RelativeSource={RelativeSource AncestorType=ContextMenu}}"/></ContextMenu></TextBox.ContextMenu></TextBox></Expander></Border></DataTemplate></ItemsControl.ItemTemplate></ItemsControl></ScrollViewer></Grid>
  <Grid Grid.Row="5" Margin="0,10,0,0"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><TextBlock x:Name="GoalLabel" Grid.Row="0" Text="Your request" Margin="0,0,0,4"/><Button x:Name="ScrollToLatest" Grid.Row="1" Width="32" Height="26" Padding="5" HorizontalAlignment="Center" Margin="0,0,0,4" Visibility="Collapsed" ToolTip="Scroll to latest"><Path Data="M4,8 L10,14 L16,8 M10,3 V14" Width="18" Height="18" Stretch="Uniform" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Button><TextBox x:Name="Goal" Grid.Row="2" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Padding="10" Background="{DynamicResource SurfaceBrush}"/></Grid>
  <DockPanel Grid.Row="6" Margin="0,10,0,0" LastChildFill="False"><StackPanel Orientation="Horizontal" DockPanel.Dock="Left"><Button x:Name="CreateTask" Width="36" Height="34" Padding="7" Margin="0,0,6,0" ToolTip="New task"><Path Data="M4,2 H12 L16,6 V18 H4 Z M12,2 V6 H16 M10,9 V15 M7,12 H13" Width="18" Height="18" Stretch="Uniform" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Button><Button x:Name="EditLast" Width="36" Height="34" Padding="7" Margin="0,0,6,0" ToolTip="Edit last request"><Path Data="M3,15 L13,5 L16,8 L6,18 H3 Z M11,7 L14,10 M3,18 H17" Width="18" Height="18" Stretch="Uniform" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Button><Button x:Name="RunTask" Width="40" Height="34" Padding="8" Margin="0,0,8,0" Background="{DynamicResource AccentBrush}" Foreground="{DynamicResource AccentTextBrush}" ToolTip="Send / Run"><Path Data="M2,9 L18,2 L12,18 L9,11 Z M9,11 L18,2" Width="18" Height="18" Stretch="Uniform" Stroke="{DynamicResource AccentTextBrush}" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Button></StackPanel><StackPanel DockPanel.Dock="Right" Orientation="Horizontal"><TextBlock x:Name="Status" Text="Ready" VerticalAlignment="Center" Foreground="{DynamicResource SecondaryTextBrush}" Margin="0,0,10,0"/><ProgressBar x:Name="Progress" Width="120" Height="14" VerticalAlignment="Center" IsIndeterminate="False"/></StackPanel></DockPanel>
 </Grid></Grid>
</Window>
'@
$window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))
$windowIconPath=Join-Path $projectRoot 'assets/branding/ataraxia-app-icon.ico';if(Test-Path -LiteralPath $windowIconPath -PathType Leaf){$window.Icon=[Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new([IO.Path]::GetFullPath($windowIconPath)))}
foreach ($name in @('ProjectDrawer','ProjectGroupExpander','ProjectTreePanel','ProjectTreeScroll','RecentSessionsExpander','RecentSessionsPanel','NewProject','RenameProject','ProjectPromptButton','SessionPromptButton','TaskSettingsExpander','SessionSelector','RenameSession','NewSession','OtherSession','ConfigLabel','RuntimeConfig','BrowseConfig','ThemeLabel','ThemeSelector','KoboldStatusDot','KoboldStatusText','KoboldToggle','KoboldRestart','TaskNameLabel','TaskName','WorkspaceLabel','Workspace','BrowseTask','BrowseWorkspace','ParametersExpander','ModelFileLabel','ModelFileSelector','RefreshModels','ParameterPanel','ConversationLabel','ConversationScrollViewer','Conversation','GoalLabel','Goal','ScrollToLatest','CreateTask','EditLast','RunTask','Status','Progress')) { Set-Variable -Name $name -Value $window.FindName($name) -Scope Script }
function Get-AtaraxiaUiIconGeometry([string]$IconName){$iconPath=Join-Path (Join-Path $projectRoot 'assets/ui-icons') ($IconName+'.svg');$data=Get-AtaraxiaSvgPathGeometry $iconPath;if([string]::IsNullOrWhiteSpace($data)){throw "Ataraxia SVG icon is missing or empty: $iconPath"};return [Windows.Media.Geometry]::Parse($data)}
function Set-AtaraxiaPathIcon([Windows.Shapes.Path]$Icon,[string]$IconName){$Icon.Data=Get-AtaraxiaUiIconGeometry $IconName;$Icon.Width=16;$Icon.Height=16;$Icon.Fill=[Windows.Media.Brushes]::Transparent}
$window.Resources['ExpanderChevronRightGeometry']=Get-AtaraxiaUiIconGeometry 'chevron-right';$window.Resources['ExpanderChevronDownGeometry']=Get-AtaraxiaUiIconGeometry 'chevron-down'
function Enable-AtaraxiaSmoothExpander([Windows.Controls.Expander]$Expander) {
    if ($null -eq $Expander) { return }
    $Expander.ApplyTemplate()
    $clip = $Expander.Template.FindName('ExpandClip', $Expander)
    $content = $Expander.Template.FindName('ExpandSite', $Expander)
    if ($null -eq $clip -or $null -eq $content) { return }
    # Keep wiring state separate so project and session identifiers remain intact.
    $id = [Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Expander)
    if (-not $script:smoothExpanderIds.Add($id)) { return }
    if ($Expander.IsExpanded) { $clip.Visibility = [Windows.Visibility]::Visible; $clip.Height = [double]::NaN; $clip.Opacity = 1 }
    $Expander.Add_Expanded({
        $clipPart = $this.Template.FindName('ExpandClip', $this)
        $contentPart = $this.Template.FindName('ExpandSite', $this)
        if ($null -eq $clipPart -or $null -eq $contentPart) { return }
        $startHeight = if ($clipPart.Visibility -eq [Windows.Visibility]::Visible) { [Math]::Max(0, $clipPart.ActualHeight) } else { 0 }
        $startOpacity = if ($clipPart.Visibility -eq [Windows.Visibility]::Visible) { $clipPart.Opacity } else { 0 }
        $clipPart.BeginAnimation([Windows.FrameworkElement]::HeightProperty, $null)
        $clipPart.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
        $clipPart.Visibility = [Windows.Visibility]::Visible
        $clipPart.Height = $startHeight
        $clipPart.Opacity = $startOpacity
        $owner = $this
        $null = $owner.Dispatcher.BeginInvoke([Action]{
            $availableWidth = [Math]::Max(1, $owner.ActualWidth)
            $clipPart.Height = [double]::NaN
            $clipPart.Measure([Windows.Size]::new($availableWidth, [double]::PositiveInfinity))
            $targetHeight = $contentPart.DesiredSize.Height
            if ($targetHeight -le 0) { $targetHeight = $contentPart.ActualHeight }
            if ($targetHeight -le 0) { $clipPart.Height = [double]::NaN; $clipPart.Opacity = 1; return }
            $clipPart.Height = $startHeight
            $duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(190))
            $ease = [Windows.Media.Animation.CubicEase]::new(); $ease.EasingMode = [Windows.Media.Animation.EasingMode]::EaseOut
            $heightAnimation = [Windows.Media.Animation.DoubleAnimation]::new($startHeight, $targetHeight, $duration); $heightAnimation.EasingFunction = $ease
            $opacityAnimation = [Windows.Media.Animation.DoubleAnimation]::new($startOpacity, 1, $duration); $opacityAnimation.EasingFunction = $ease
            $clipPart.BeginAnimation([Windows.FrameworkElement]::HeightProperty, $heightAnimation)
            $clipPart.BeginAnimation([Windows.UIElement]::OpacityProperty, $opacityAnimation)
        }.GetNewClosure())
    }.GetNewClosure())
    $Expander.Add_Collapsed({
        $clipPart = $this.Template.FindName('ExpandClip', $this)
        if ($null -eq $clipPart -or $clipPart.Visibility -ne [Windows.Visibility]::Visible) { return }
        $startHeight = [Math]::Max(0, $clipPart.ActualHeight)
        $startOpacity = $clipPart.Opacity
        $clipPart.BeginAnimation([Windows.FrameworkElement]::HeightProperty, $null)
        $clipPart.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
        $clipPart.Height = $startHeight
        $clipPart.Visibility = [Windows.Visibility]::Visible
        $duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(160))
        $ease = [Windows.Media.Animation.CubicEase]::new(); $ease.EasingMode = [Windows.Media.Animation.EasingMode]::EaseIn
        $heightAnimation = [Windows.Media.Animation.DoubleAnimation]::new($startHeight, 0, $duration); $heightAnimation.EasingFunction = $ease
        $expanderForCompletion = $this
        $heightAnimation.Add_Completed({
            $clipTarget = $expanderForCompletion.Template.FindName('ExpandClip', $expanderForCompletion)
            if ($null -ne $clipTarget -and -not $expanderForCompletion.IsExpanded) { $clipTarget.Visibility = [Windows.Visibility]::Collapsed; $clipTarget.Height = 0; $clipTarget.Opacity = 0 }
        }.GetNewClosure())
        $opacityAnimation = [Windows.Media.Animation.DoubleAnimation]::new($startOpacity, 0, $duration); $opacityAnimation.EasingFunction = $ease
        $clipPart.BeginAnimation([Windows.FrameworkElement]::HeightProperty, $heightAnimation)
        $clipPart.BeginAnimation([Windows.UIElement]::OpacityProperty, $opacityAnimation)
    }.GetNewClosure())
}
function Register-AtaraxiaSmoothExpanders([Windows.DependencyObject]$Root) {
    if ($null -eq $Root) { return }
    $pending = [System.Collections.Generic.Stack[Windows.DependencyObject]]::new(); $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $node = $pending.Pop()
        if ($node -is [Windows.Controls.Expander]) { Enable-AtaraxiaSmoothExpander $node }
        try { $count = [Windows.Media.VisualTreeHelper]::GetChildrenCount($node) } catch { continue }
        for ($i = 0; $i -lt $count; $i++) { $child = [Windows.Media.VisualTreeHelper]::GetChild($node, $i); if ($null -ne $child) { $pending.Push($child) } }
    }
}
foreach($iconButton in @(@('NewProject','new-project'),@('RenameProject','rename-project'),@('ProjectPromptButton','project-prompt-button'),@('RenameSession','rename-session'),@('SessionPromptButton','session-prompt-button'),@('NewSession','new-session'),@('BrowseConfig','browse-config'),@('KoboldRestart','kobold-restart'),@('BrowseTask','browse-task'),@('BrowseWorkspace','browse-workspace'),@('RefreshModels','refresh-models'),@('ScrollToLatest','scroll-to-latest'),@('CreateTask','create-task'),@('EditLast','edit-last'),@('RunTask','send'))){$iconControl=$window.FindName($iconButton[0]);Set-AtaraxiaPathIcon $iconControl.Content $iconButton[1];$iconControl.Padding=[Windows.Thickness]::new(3)}
$OtherSession.Content=[Windows.Shapes.Path]::new();Set-AtaraxiaPathIcon $OtherSession.Content 'more';$OtherSession.Content.Width=18;$OtherSession.Content.Height=18;$OtherSession.Content.Stretch='Uniform';$OtherSession.Content.SetResourceReference([Windows.Shapes.Shape]::StrokeProperty,'IconBrush');$OtherSession.Content.SetResourceReference([Windows.Shapes.Shape]::FillProperty,'IconBrush');$OtherSession.Content.StrokeThickness=1.8
$script:CopySessionIdMenuItem=$OtherSession.ContextMenu.Items[0]
. (Join-Path $PSScriptRoot 'GuiDialogs.ps1')
$script:themeOptions=@() 
$RuntimeConfig.Text = [IO.Path]::GetFullPath($ConfigPath)
function Set-AtaraxiaLanguage([string]$Language) {
    Set-AppLanguage $Language
    $window.Title='';$TaskSettingsExpander.Header=Get-AppText 'gui_task_settings'; $ConfigLabel.Text=Get-AppText 'gui_runtime_config';$BrowseConfig.ToolTip=Get-AppText 'gui_browse';$NewSession.ToolTip=Get-AppText 'gui_new_session';$RenameSession.ToolTip=Get-AppText 'gui_rename_session_button';$OtherSession.ToolTip=Get-AppText 'gui_session_more';$script:CopySessionIdMenuItem.Header=Get-AppText 'gui_copy_session_id'; $ThemeLabel.Text=Get-AppText 'gui_theme'; $script:themeOptions=@([pscustomobject]@{key='system';label=(Get-AppText 'gui_theme_system')},[pscustomobject]@{key='light';label=(Get-AppText 'gui_theme_light')},[pscustomobject]@{key='dark';label=(Get-AppText 'gui_theme_dark')}); $script:updatingTheme=$true; $ThemeSelector.ItemsSource=$script:themeOptions; $ThemeSelector.ItemTemplate=$window.Resources['ThemeOptionTemplate']; $ThemeSelector.SelectedValuePath='key'; $ThemeSelector.SelectedValue=$script:themeMode; $script:updatingTheme=$false
    $ProjectPromptButton.ToolTip=Get-AppText 'gui_project_prompt';$SessionPromptButton.ToolTip=Get-AppText 'gui_session_prompt';$ProjectGroupExpander.Header=Get-AppText 'gui_projects';$RecentSessionsExpander.Header=Get-AppText 'gui_recent_sessions';$NewProject.ToolTip=Get-AppText 'gui_new_project';$RenameProject.ToolTip=Get-AppText 'gui_rename_project'
    $TaskNameLabel.Text=Get-AppText 'gui_task_name'; $WorkspaceLabel.Text=Get-AppText 'gui_working_directory'; $BrowseTask.ToolTip=Get-AppText 'gui_open_task'; $BrowseWorkspace.ToolTip=Get-AppText 'gui_browse_folder'
    $window.Tag=Get-AppText 'gui_copy_request';$KoboldRestart.ToolTip=Get-AppText 'gui_kobold_restart';$ModelFileLabel.Text=Get-AppText 'gui_model_file';$RefreshModels.ToolTip=Get-AppText 'gui_refresh_models';$ConversationLabel.Text=Get-AppText 'gui_conversation'; $GoalLabel.Text=Get-AppText 'gui_request';$ScrollToLatest.ToolTip=Get-AppText 'gui_scroll_to_latest'; $CreateTask.ToolTip=Get-AppText 'gui_new_task'; $EditLast.ToolTip=Get-AppText 'gui_edit_last_query'; $RunTask.ToolTip=Get-AppText 'gui_send_run';$Status.Text=Get-AppText 'gui_ready'
    Set-KoboldToggleIcon;Set-RunTaskIcon $false
}
function Apply-AtaraxiaTheme([string]$Mode) {
    $palette=Get-AtaraxiaThemePalette $Mode
    $keys=@{app_background='AppBackgroundBrush';surface='SurfaceBrush';panel='PanelBrush';drawer='DrawerBrush';primary_text='PrimaryTextBrush';secondary_text='SecondaryTextBrush';border='BorderBrush';accent='AccentBrush';accent_text='AccentTextBrush';icon='IconBrush'}
    foreach($name in $keys.Keys){$color=[Windows.Media.ColorConverter]::ConvertFromString([string]$palette.($name));$window.Resources[$keys[$name]]=[Windows.Media.SolidColorBrush]::new($color)}
    $script:effectiveTheme=$Mode
}
function Load-AtaraxiaThemePreference {
    try{$settings=Get-AtaraxiaConfig;$mode=[string]$settings.gui_theme;if($mode -notin @('system','light','dark')){$mode='system'}}catch{$mode='system'}
    $script:themeMode=$mode;$script:updatingTheme=$true;$ThemeSelector.SelectedValue=$mode;$script:updatingTheme=$false
    $effective=Resolve-AtaraxiaThemeMode $mode (Get-AtaraxiaSystemTheme);if($script:effectiveTheme -ne $effective){Apply-AtaraxiaTheme $effective}
}
function Save-AtaraxiaThemePreference([string]$Mode) {
    if($Mode -notin @('system','light','dark')){return};$configPath=[IO.Path]::GetFullPath($RuntimeConfig.Text);$settings=Get-AtaraxiaConfig;$settings|Add-Member -NotePropertyName gui_theme -NotePropertyValue $Mode -Force;$json=$settings|ConvertTo-Json -Depth 100;$temp=$configPath+'.tmp';[IO.File]::WriteAllText($temp,$json,[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temp -Destination $configPath -Force;$script:themeMode=$Mode;Load-AtaraxiaThemePreference
}
function Get-AtaraxiaRoleLabel([string]$RoleId) {
    $key='gui_role_'+(($RoleId -replace '[^A-Za-z0-9_]','_').ToLowerInvariant())
    try{return Get-AppText $key}catch{return $RoleId}
}
function Convert-AtaraxiaRunOutput([string]$Line) {
    $match=[regex]::Match($Line,'^\s*Run:\s*(?<role>\S.*?)\s*$')
    if(-not $match.Success){return $null}
    return [pscustomobject]@{kind='role';role=$match.Groups['role'].Value.Trim()}
}
function Set-KoboldConnectionIndicator([ValidateSet('connected','disconnected','starting')][string]$State) {
    switch($State){
        'connected'{$KoboldStatusDot.Fill=[Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#2E7D32'));$KoboldStatusText.Text=Get-AppText 'gui_kobold_connected'}
        'starting'{$KoboldStatusDot.Fill=[Windows.Media.Brushes]::DarkOrange;$KoboldStatusText.Text=Get-AppText 'gui_kobold_starting'}
        default{$KoboldStatusDot.Fill=[Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString('#C62828'));$KoboldStatusText.Text=Get-AppText 'gui_kobold_disconnected'}
    }
    Set-KoboldToggleIcon
    $KoboldRestart.IsEnabled=($null -ne $script:koboldProcess -and -not $script:koboldProcess.HasExited)
}
function Set-KoboldToggleIcon {
    $managed=($null -ne $script:koboldProcess -and -not $script:koboldProcess.HasExited)
    $KoboldToggle.ToolTip=if($managed){Get-AppText 'gui_kobold_stop'}else{Get-AppText 'gui_kobold_start'}
    $KoboldToggle.Padding=[Windows.Thickness]::new(3)
    $icon=[Windows.Shapes.Path]$KoboldToggle.Content
    Set-AtaraxiaPathIcon $icon $(if($managed){'kobold-stop'}else{'kobold-start'})
}
function Set-RunTaskIcon([bool]$Stop) {
    $RunTask.ToolTip=if($Stop){Get-AppText 'gui_stop'}else{Get-AppText 'gui_send_run'}
    $icon=[Windows.Shapes.Path]$RunTask.Content
    Set-AtaraxiaPathIcon $icon $(if($Stop){'stop'}else{'send'})
}
function Test-KoboldCppConnection {
    $client=$null;$waitHandle=$null
    try{$config=Get-AtaraxiaConfig;$null=Import-KoboldCppSettings $config $RuntimeConfig.Text;$uri=[uri][string]$config.api_server;$client=[Net.Sockets.TcpClient]::new();$pending=$client.BeginConnect($uri.Host,$uri.Port,$null,$null);$waitHandle=$pending.AsyncWaitHandle;if(-not $waitHandle.WaitOne(250,$false)){return $false};$client.EndConnect($pending);return $true}catch{return $false}finally{if($null -ne $waitHandle){$waitHandle.Close()};if($null -ne $client){$client.Dispose()}}
}
function Update-KoboldConnectionIndicator {
    if($null -ne $script:koboldProcess){$script:koboldProcess.Refresh();if($script:koboldProcess.HasExited){$script:koboldProcess.Dispose();$script:koboldProcess=$null}}
    if($null -ne $script:koboldSetupProcess){$script:koboldSetupProcess.Refresh();if(-not $script:koboldSetupProcess.HasExited){Set-KoboldConnectionIndicator 'starting';return}}
    if(Test-KoboldCppConnection){Set-KoboldConnectionIndicator 'connected'}elseif($null -ne $script:koboldProcess){Set-KoboldConnectionIndicator 'starting'}else{Set-KoboldConnectionIndicator 'disconnected'}
}
function Start-KoboldCppFromGui {
    if(Test-KoboldCppConnection){Set-KoboldConnectionIndicator 'connected';$Status.Text=Get-AppText 'gui_kobold_already_running';return}
    $config=Get-AtaraxiaConfig;$settings=Import-KoboldCppSettings $config $RuntimeConfig.Text;$paths=$settings.paths
    $installDirectory=if([IO.Path]::IsPathRooted([string]$paths.install_directory)){[IO.Path]::GetFullPath([string]$paths.install_directory)}else{[IO.Path]::GetFullPath((Join-Path $projectRoot ([string]$paths.install_directory)))}
    $executable=if([IO.Path]::IsPathRooted([string]$paths.executable)){[IO.Path]::GetFullPath([string]$paths.executable)}else{[IO.Path]::GetFullPath((Join-Path $projectRoot ([string]$paths.executable)))}
    if(-not(Test-Path -LiteralPath $executable -PathType Leaf)){throw (Get-AppText 'gui_kobold_missing_executable')}
    $modelFile=[string]$paths.model_file;if([string]::IsNullOrWhiteSpace($modelFile)){throw (Get-AppText 'gui_kobold_model_required')}
    $modelDirectory=if([IO.Path]::IsPathRooted([string]$paths.model_directory)){[IO.Path]::GetFullPath([string]$paths.model_directory)}else{[IO.Path]::GetFullPath((Join-Path $projectRoot ([string]$paths.model_directory)))}
    $modelPath=if([IO.Path]::IsPathRooted($modelFile)){[IO.Path]::GetFullPath($modelFile)}else{[IO.Path]::GetFullPath((Join-Path $modelDirectory $modelFile))};if(-not(Test-Path -LiteralPath $modelPath -PathType Leaf)){throw (Get-AppText 'gui_kobold_model_missing' @($modelPath))}
    $effective=Get-KoboldCppModelSettings $settings $modelPath;$arguments=@(Get-KoboldCppLaunchArguments $effective $modelPath) -join ' '
    $process=Start-Process -FilePath $executable -ArgumentList $arguments -WorkingDirectory $installDirectory -WindowStyle Hidden -PassThru
    $script:koboldProcess=$process;$script:lastKoboldPoll=[DateTime]::MinValue;Set-KoboldConnectionIndicator 'starting';$Status.Text=Get-AppText 'gui_kobold_starting'
}
function Stop-KoboldCppFromGui {
    $process=$script:koboldProcess;if($null -eq $process){Set-KoboldConnectionIndicator 'disconnected';return}
    try{if(-not $process.HasExited){$process.Kill();$process.WaitForExit(5000)}}finally{$process.Dispose();$script:koboldProcess=$null}
    Set-KoboldConnectionIndicator 'disconnected';$Status.Text=Get-AppText 'gui_kobold_stopped'
}
function Toggle-KoboldCppFromGui {
    try{if($null -ne $script:koboldProcess -and -not $script:koboldProcess.HasExited){Stop-KoboldCppFromGui}else{Start-KoboldCppFromGui}}catch{$Status.Text=$_.Exception.Message;Update-KoboldConnectionIndicator}
}
function Restart-KoboldCppFromGui {
    if($null -eq $script:koboldProcess -or $script:koboldProcess.HasExited){$Status.Text=Get-AppText 'gui_kobold_restart_requires_managed';return}
    try{
        if($ParametersExpander.IsExpanded -and $script:modelParameterControls.Count -gt 0){Save-AtaraxiaModelParameters}
        Stop-KoboldCppFromGui
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        while((Test-KoboldCppConnection) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 250}
        if(Test-KoboldCppConnection){throw (Get-AppText 'gui_kobold_restart_port_busy')}
        Start-KoboldCppFromGui
    }catch{$Status.Text=$_.Exception.Message;Update-KoboldConnectionIndicator}
}
function Start-KoboldCppAcquisitionIfMissing {
    $config=Get-AtaraxiaConfig;$settings=Import-KoboldCppSettings $config $RuntimeConfig.Text
    $configuredExecutable=[string]$settings.paths.executable
    $executable=if([IO.Path]::IsPathRooted($configuredExecutable)){[IO.Path]::GetFullPath($configuredExecutable)}else{[IO.Path]::GetFullPath((Join-Path $projectRoot $configuredExecutable))}
    if(Test-Path -LiteralPath $executable -PathType Leaf){return}
    $initializer=Join-Path $PSScriptRoot 'Initialize-KoboldCpp.ps1'
    if(-not(Test-Path -LiteralPath $initializer -PathType Leaf)){throw "KoboldCpp initializer was not found: $initializer"}
    $hostPath=(Get-Process -Id $PID).Path
    $configPath=[IO.Path]::GetFullPath($RuntimeConfig.Text)
    $script:koboldSetupStdoutPath=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-kobold-setup-'+[Guid]::NewGuid().ToString('N')+'.out')
    $script:koboldSetupStderrPath=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-kobold-setup-'+[Guid]::NewGuid().ToString('N')+'.err')
    $arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $initializer.Replace('"','\"'),$configPath.Replace('"','\"')
    $script:koboldSetupProcess=Start-Process -FilePath $hostPath -ArgumentList $arguments -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $script:koboldSetupStdoutPath -RedirectStandardError $script:koboldSetupStderrPath
    $KoboldToggle.IsEnabled=$false;$KoboldRestart.IsEnabled=$false
    Set-KoboldConnectionIndicator 'starting';$Status.Text=Get-AppText 'gui_kobold_downloading'
}
function Complete-KoboldCppAcquisitionIfFinished {
    if($null -eq $script:koboldSetupProcess){return}
    $script:koboldSetupProcess.Refresh();if(-not $script:koboldSetupProcess.HasExited){return}
    $exitCode=$script:koboldSetupProcess.ExitCode;$details=''
    if(Test-Path -LiteralPath $script:koboldSetupStderrPath){$details=(Get-Content -LiteralPath $script:koboldSetupStderrPath -Raw -ErrorAction SilentlyContinue).Trim()}
    if($exitCode -eq 0){$Status.Text=Get-AppText 'gui_kobold_downloaded'}else{$Status.Text=Get-AppText 'gui_kobold_download_failed';if(-not [string]::IsNullOrWhiteSpace($details)){$Status.Text+=': '+$details}}
    $script:koboldSetupProcess.Dispose();$script:koboldSetupProcess=$null
    foreach($path in @($script:koboldSetupStdoutPath,$script:koboldSetupStderrPath)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}}
    $script:koboldSetupStdoutPath='';$script:koboldSetupStderrPath='';$KoboldToggle.IsEnabled=$true;$KoboldRestart.IsEnabled=$true
    Update-KoboldConnectionIndicator
}
function Show-AtaraxiaStartupSplash {
    [xml]$splashXaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="560" Height="315" WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="NoResize" ShowInTaskbar="False" Topmost="True" Background="#101010"><Image x:Name="SplashImage" Stretch="UniformToFill"/></Window>
'@
    $splash=[Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($splashXaml))
    $coverPath=Join-Path $projectRoot 'assets/splash/ataraxia-project-cover.png'
    if(-not (Test-Path -LiteralPath $coverPath -PathType Leaf)){throw "Splash cover image is missing: $coverPath"}
    $coverImage=[Windows.Media.Imaging.BitmapImage]::new([Uri]::new([IO.Path]::GetFullPath($coverPath)))
    $splash.FindName('SplashImage').Source=$coverImage
    $splash.Show();$script:splashShownAt=[Diagnostics.Stopwatch]::StartNew();return $splash
}
try { $languagePath=if(Test-Path -LiteralPath $RuntimeConfig.Text){$RuntimeConfig.Text}else{Join-Path $projectRoot 'configs/config.example.json'}; $languageConfig=Read-AgentJsonFile $languagePath; Set-AtaraxiaLanguage ([string]$languageConfig.interface_language) } catch { Set-AtaraxiaLanguage 'English' }; Load-AtaraxiaThemePreference
$script:splashWindow=$null
if(-not $NoSplash){$script:splashWindow=Show-AtaraxiaStartupSplash}
Update-KoboldConnectionIndicator

$ThemeSelector.Add_SelectionChanged({if(-not $script:updatingTheme -and $null -ne $ThemeSelector.SelectedValue){Save-AtaraxiaThemePreference ([string]$ThemeSelector.SelectedValue)}})
$script:modelParametersDirty=$false
$script:modelParameterControls=@{}
$script:loadingModelSelector=$false
function Initialize-AtaraxiaModelParameterEditor {try{Build-AtaraxiaModelParameterControls}catch{$Status.Text=$_.Exception.Message}}
function Get-AtaraxiaConfig { Read-AgentJsonFile $RuntimeConfig.Text }
function Get-AtaraxiaSelectedModelPath {
    $config=Get-AtaraxiaConfig;$null=Import-KoboldCppSettings $config $RuntimeConfig.Text;$settings=$config.koboldcpp_base_settings;$modelFile=[string]$settings.paths.model_file
    if([string]::IsNullOrWhiteSpace($modelFile)){return ''}
    if([IO.Path]::IsPathRooted($modelFile)){return [IO.Path]::GetFullPath($modelFile)}
    $modelDirectory=[string]$settings.paths.model_directory
    if(-not [IO.Path]::IsPathRooted($modelDirectory)){$modelDirectory=Join-Path (Split-Path -Parent $PSScriptRoot) $modelDirectory}
    return [IO.Path]::GetFullPath((Join-Path $modelDirectory $modelFile))
}
function Get-AtaraxiaAvailableModels {
    $config=Get-AtaraxiaConfig;$null=Import-KoboldCppSettings $config $RuntimeConfig.Text;$directory=[string]$config.koboldcpp_base_settings.paths.model_directory
    if(-not [IO.Path]::IsPathRooted($directory)){$directory=Join-Path (Split-Path -Parent $PSScriptRoot) $directory}
    if(-not (Test-Path -LiteralPath $directory -PathType Container)){return @()}
    return @(Get-ChildItem -LiteralPath $directory -File -Filter '*.gguf' -Recurse|Sort-Object FullName|ForEach-Object{$relative=$_.FullName.Substring($directory.TrimEnd([IO.Path]::DirectorySeparatorChar).Length).TrimStart([IO.Path]::DirectorySeparatorChar);[pscustomobject]@{name=$relative;path=$_.FullName}})
}
function Refresh-AtaraxiaModelSelector {
    $selectedPath=Get-AtaraxiaSelectedModelPath;$models=@(Get-AtaraxiaAvailableModels);$ModelFileSelector.ItemsSource=$null;$ModelFileSelector.ItemsSource=$models;$ModelFileSelector.DisplayMemberPath='name';$ModelFileSelector.SelectedValuePath='path'
    $selected=@($models|Where-Object{$_.path -ieq $selectedPath}|Select-Object -First 1)
    if($selected.Count -gt 0){$ModelFileSelector.SelectedItem=$selected[0]}elseif(-not [string]::IsNullOrWhiteSpace($selectedPath)){$ModelFileSelector.Items.Add([pscustomobject]@{name=[IO.Path]::GetFileName($selectedPath);path=$selectedPath})|Out-Null;$ModelFileSelector.SelectedIndex=$ModelFileSelector.Items.Count-1}
}
function Save-AtaraxiaSelectedModel {
    $selected=$ModelFileSelector.SelectedItem;if($null -eq $selected){return}
    $settingsPath=Get-KoboldCppSettingsPath (Get-AtaraxiaConfig) $RuntimeConfig.Text;$config=Get-AtaraxiaConfig;$null=Import-KoboldCppSettings $config $RuntimeConfig.Text;$settings=$config.koboldcpp_base_settings
    $modelDirectory=[string]$settings.paths.model_directory;if(-not [IO.Path]::IsPathRooted($modelDirectory)){$modelDirectory=Join-Path (Split-Path -Parent $PSScriptRoot) $modelDirectory};$modelDirectory=[IO.Path]::GetFullPath($modelDirectory)
    $modelPath=[IO.Path]::GetFullPath([string]$selected.path)
    if(-not $modelPath.StartsWith($modelDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'The selected model must be inside the configured model directory.'}
    $settings.paths.model_file=[IO.Path]::GetRelativePath($modelDirectory,$modelPath)
    Save-KoboldCppSettings $settingsPath $settings
    $script:modelParametersDirty=$true
    if($ParametersExpander.IsExpanded){Build-AtaraxiaModelParameterControls}
}
$ModelFileSelector.Add_SelectionChanged({if(-not $script:loadingModelSelector -and $null -ne $ModelFileSelector.SelectedItem){try{Save-AtaraxiaSelectedModel}catch{$Status.Text=$_.Exception.Message}}})
$RefreshModels.Add_Click({try{$script:loadingModelSelector=$true;Refresh-AtaraxiaModelSelector}finally{$script:loadingModelSelector=$false}})
$ParametersExpander.Add_Expanded({$ParametersExpander.Header=Get-AppText 'gui_parameters';$script:loadingModelSelector=$true;try{Refresh-AtaraxiaModelSelector}finally{$script:loadingModelSelector=$false};Initialize-AtaraxiaModelParameterEditor})
$script:loadingModelSelector=$true;try{Refresh-AtaraxiaModelSelector}catch{$Status.Text=$_.Exception.Message}finally{$script:loadingModelSelector=$false}
function Save-AtaraxiaModelParameters {
    $settingsPath=Get-KoboldCppSettingsPath (Get-AtaraxiaConfig) $RuntimeConfig.Text
    $config=Get-AtaraxiaConfig;$null=Import-KoboldCppSettings $config $RuntimeConfig.Text;$settings=$config.koboldcpp_base_settings
    $values=[ordered]@{}
    foreach($definition in Get-AtaraxiaModelParameterDefinitions){$control=$script:modelParameterControls[$definition.key];if($definition.kind -eq 'string'){$raw=[string]$control.Text;if($definition.key -eq 'stop'){if([string]::IsNullOrWhiteSpace($raw)){$values[$definition.key]=@()}else{$values[$definition.key]=@($raw -split "`r?`n"|Where-Object{$_ -ne ''})}}else{$values[$definition.key]=$raw}}else{$parsed=0.0;if(-not [double]::TryParse($control.Text,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$parsed)){throw "Enter a valid number for $($definition.key)."};$values[$definition.key]=Assert-AtaraxiaModelParameterValue $definition.key $parsed}}
    $modelPath=Get-AtaraxiaSelectedModelPath;$effective=Get-KoboldCppModelSettings $settings $modelPath
    foreach($key in @($effective.request_parameters.PSObject.Properties.Name)){if($null -eq $settings.request_parameters.PSObject.Properties[$key]){$settings.request_parameters|Add-Member -NotePropertyName $key -NotePropertyValue $effective.request_parameters.$key -Force}}
    $settings=Set-AtaraxiaModelParameterValues $settings $values
    Save-KoboldCppSettings $settingsPath $settings
    $config|Add-Member -NotePropertyName koboldcpp_base_settings -NotePropertyValue $settings -Force
    $config|Add-Member -NotePropertyName override -NotePropertyValue $settings.request_parameters -Force
    $script:modelParameterValues=$values
}
function Build-AtaraxiaModelParameterControls {
    $ParameterPanel.Children.Clear();$script:modelParameterControls=@{};$config=Get-AtaraxiaConfig;$null=Import-KoboldCppSettings $config $RuntimeConfig.Text;$settings=$config.koboldcpp_base_settings;$modelPath=Get-AtaraxiaSelectedModelPath;$effective=Get-KoboldCppModelSettings $settings $modelPath;$values=Get-AtaraxiaModelParameterValues $effective
    foreach($definition in Get-AtaraxiaModelParameterDefinitions){
        $row=[Windows.Controls.Grid]::new();$row.Margin=[Windows.Thickness]::new(0,3,0,3);$row.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$row.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$row.ColumnDefinitions[0].Width=[Windows.GridLength]::new(145);$row.ColumnDefinitions[1].Width=[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)
        $label=[Windows.Controls.TextBlock]::new();$label.Text=Get-AppText $definition.label_key;$label.VerticalAlignment='Center';$label.Margin=[Windows.Thickness]::new(0,0,8,0);[Windows.Controls.Grid]::SetColumn($label,0);$row.Children.Add($label)|Out-Null
        $value=if($null -ne $values.PSObject.Properties[$definition.key]){$values.($definition.key)}elseif($definition.kind -eq 'string'){''}elseif($definition.key -eq 'max_tokens'){1024}else{0}
        if($definition.kind -eq 'number'){
            $controlHost=[Windows.Controls.Grid]::new();$controlHost.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$controlHost.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$controlHost.ColumnDefinitions[0].Width=[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star);$controlHost.ColumnDefinitions[1].Width=[Windows.GridLength]::new(82)
            $slider=[Windows.Controls.Slider]::new();$slider.Minimum=$definition.min;$slider.Maximum=$definition.max;$slider.SmallChange=$definition.step;$slider.LargeChange=[Math]::Max($definition.step,($definition.max-$definition.min)/20);$slider.TickFrequency=$definition.step;$slider.IsSnapToTick=($definition.step -eq 1.0);$slider.Value=[Math]::Max($definition.min,[Math]::Min($definition.max,[double]$value));$slider.VerticalAlignment='Center';[Windows.Controls.Grid]::SetColumn($slider,0);$controlHost.Children.Add($slider)|Out-Null
            $number=[Windows.Controls.TextBox]::new();$number.Text=([double]$slider.Value).ToString([string]$definition.format,[Globalization.CultureInfo]::InvariantCulture);$number.VerticalContentAlignment='Center';$number.Margin=[Windows.Thickness]::new(8,0,0,0);[Windows.Controls.Grid]::SetColumn($number,1);$controlHost.Children.Add($number)|Out-Null
            $slider.Tag=$number;$number.TagData=$definition;$slider.Add_ValueChanged({$textBox=$this.Tag;$d=$textBox.TagData;$textBox.Text=([double]$this.Value).ToString([string]$d.format,[Globalization.CultureInfo]::InvariantCulture)}.GetNewClosure());$number.Add_TextChanged({$n=0.0;if([double]::TryParse($this.Text,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$n)-and $n -ge $this.TagData.min -and $n -le $this.TagData.max -and ($this.TagData.step -ne 1.0 -or [Math]::Truncate($n) -eq $n)){$this.BorderBrush=[Windows.Media.Brushes]::Gray;$script:modelParametersDirty=$true;$slider=$this.Tag;if([Math]::Abs($slider.Value-$n) -gt [double]::Epsilon){$slider.Value=$n}}else{$this.BorderBrush=[Windows.Media.Brushes]::Red}}.GetNewClosure());$number.Tag=$slider;$number.Add_LostFocus({if($script:modelParametersDirty){try{Save-AtaraxiaModelParameters;$script:modelParametersDirty=$false}catch{$Status.Text=$_.Exception.Message}}}.GetNewClosure())
            $script:modelParameterControls[$definition.key]=$number
            $panelControl=$controlHost
        }else{
            $number=[Windows.Controls.TextBox]::new();$number.Text=if($definition.key -eq 'stop'){@($value) -join "`r`n"}else{[string]$value};$number.AcceptsReturn=$true;$number.TextWrapping='Wrap';$number.VerticalScrollBarVisibility='Auto';$number.MinHeight=48;$number.MaxHeight=90;$number.Background=$window.Resources['SurfaceBrush'];$number.Foreground=$window.Resources['PrimaryTextBrush'];$number.BorderBrush=$window.Resources['BorderBrush'];$number.Add_TextChanged({$script:modelParametersDirty=$true}.GetNewClosure());$number.Add_LostFocus({if($script:modelParametersDirty){try{Save-AtaraxiaModelParameters;$script:modelParametersDirty=$false}catch{$Status.Text=$_.Exception.Message}}}.GetNewClosure());$script:modelParameterControls[$definition.key]=$number;$panelControl=$number
        }
        [Windows.Controls.Grid]::SetColumn($panelControl,1);$row.Children.Add($panelControl)|Out-Null;$ParameterPanel.Children.Add($row)|Out-Null
    }
}
function Get-ProjectsRoot { Join-Path $projectRoot 'projects' }
function Get-TaskDirectory { $settings=Get-AtaraxiaConfig; Join-Path (Get-ProjectsRoot) ([string]$settings.project_name) }
function Get-ActiveProjectPath { Join-Path (Get-ProjectsRoot) ([string](Get-AtaraxiaConfig).project_name) }
function Reset-LoadedTask {
    $script:taskPath='';$script:editing=$false;$script:pendingSessionProject='';$TaskName.Text='';$Workspace.Text='';$Goal.Text='';$Conversation.ItemsSource=@()
    $ConversationScrollViewer.ScrollToTop();Update-AtaraxiaScrollToLatestButton
}
function Assert-ProjectManagerIdle {
    if($null -ne $script:process){throw (Get-AppText 'gui_project_busy')}
}
function Show-ProjectNameDialog([string]$Title,[string]$InitialValue='') {
    $value=Show-AtaraxiaProjectNameDialog $Title $InitialValue
    if($null -eq $value){return ''};return ([string]$value).Trim()
}
function Show-CommonPromptDialog([string]$Title,[string]$InitialValue) { return Show-AtaraxiaCommonPromptDialog $Title $InitialValue }
function Get-AtaraxiaTaskPath([object]$Session) {
    if($null -eq $Session){return ''}
    $metadataPath=Join-Path ([string]$Session.path) 'session.json'
    if(-not(Test-Path -LiteralPath $metadataPath -PathType Leaf)){throw "Session metadata was not found: $metadataPath"}
    $metadata=Read-AgentJsonFile $metadataPath
    $taskFile=[string]$metadata.task_file
    if([string]::IsNullOrWhiteSpace($taskFile) -or [IO.Path]::GetFileName($taskFile) -cne $taskFile){throw 'Session task file name is invalid.'}
    return Join-Path ([string]$Session.path) $taskFile
}

function Load-AtaraxiaTask([string]$Path) {
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "Task file was not found: $Path"}
    $task=Read-AgentJsonFile $Path
    if($null -eq $task.PSObject.Properties['workflow'] -or $null -eq $task.PSObject.Properties['roles']){throw 'The selected file is not an Ataraxia task.'}
    $script:taskPath=[IO.Path]::GetFullPath($Path);$script:editing=$false;$script:pendingSessionProject=''
    $TaskName.Text=[string]$task.name;$Workspace.Text=[string]$task.working_directory;$Goal.Text=[string]$task.goal
    $SessionSelector.SelectedItem=$null
    $sessionPath=Split-Path -Parent $script:taskPath;$sessionMeta=Join-Path $sessionPath 'session.json'
    if(Test-Path -LiteralPath $sessionMeta -PathType Leaf){$metadata=Read-AgentJsonFile $sessionMeta;$match=@($SessionSelector.Items|Where-Object{$_.id -ceq [string]$metadata.id}|Select-Object -First 1);if($match.Count -gt 0){$script:loadingSession=$true;try{$SessionSelector.SelectedItem=$match[0]}finally{$script:loadingSession=$false}}}
    Refresh-AtaraxiaConversation
    $RunTask.IsEnabled=$true;$EditLast.IsEnabled=$true;$RenameSession.IsEnabled=(Test-Path -LiteralPath $sessionMeta -PathType Leaf);$SessionPromptButton.IsEnabled=(Test-Path -LiteralPath $sessionMeta -PathType Leaf)
    $Status.Text=Get-AppText 'gui_ready'
}

function Save-AtaraxiaTask {
    if([string]::IsNullOrWhiteSpace($script:taskPath)){throw 'No session task is loaded.'}
    $task=Read-AgentJsonFile $script:taskPath
    $task.goal=[string]$Goal.Text;$task.working_directory=[string]$Workspace.Text
    $json=$task|ConvertTo-Json -Depth 100;$temporaryPath=$script:taskPath+'.tmp'
    [IO.File]::WriteAllText($temporaryPath,$json,[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temporaryPath -Destination $script:taskPath -Force
}

function Refresh-AtaraxiaConversation {
    if([string]::IsNullOrWhiteSpace($script:taskPath)){$Conversation.ItemsSource=@();Update-AtaraxiaScrollToLatestButton;return}
    $taskDirectory=Split-Path -Parent $script:taskPath;$conversationPath=Join-Path $taskDirectory 'conversation.json';$statePath=Join-Path $taskDirectory 'state.json'
    $conversation=Get-AtaraxiaConversation $conversationPath
    $state=if(Test-Path -LiteralPath $statePath -PathType Leaf){Read-AgentJsonFile $statePath 2097152}else{[pscustomobject]@{history=@()}}
    if($null -eq $state.PSObject.Properties['history']){$state|Add-Member -NotePropertyName history -NotePropertyValue @() -Force}
    $view=ConvertTo-AtaraxiaConversationView $conversation $state
    Wire-AtaraxiaRequestCopyMenus
    $Conversation.ItemsSource=$view
    $window.Dispatcher.BeginInvoke([Action]{ Register-AtaraxiaSmoothExpanders $Conversation; $ConversationScrollViewer.ScrollToEnd();Update-AtaraxiaScrollToLatestButton })|Out-Null
}

function Update-AtaraxiaScrollToLatestButton {
    if($null -eq $ConversationScrollViewer -or $null -eq $ScrollToLatest){return}
    $ScrollToLatest.Visibility=if($ConversationScrollViewer.ScrollableHeight -gt 8 -and ($ConversationScrollViewer.VerticalOffset -lt ($ConversationScrollViewer.ScrollableHeight-8))){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}
}

function Wire-AtaraxiaRequestCopyMenus {
    $script:requestCopyMenuHeader=Get-AppText 'gui_copy_request'
    $window.Dispatcher.BeginInvoke([Action]{
        foreach($item in $Conversation.Items){
            if($item.kind -ne 'user'){continue}
            $container=$Conversation.ItemContainerGenerator.ContainerFromItem($item);if($null -eq $container){continue}
            $pending=[System.Collections.Generic.Stack[Windows.DependencyObject]]::new();$pending.Push($container)
            while($pending.Count -gt 0){$parent=$pending.Pop();if($parent -is [Windows.Controls.TextBox] -and $null -ne $parent.ContextMenu){$menuItem=$parent.ContextMenu.Items[0];$menuItem.Header=Get-AppText 'gui_copy_request';if($null -eq $menuItem.Tag){$menuItem.Tag='AtaraxiaRequestCopy';$menuItem.Add_Click({$menu=$this.Parent;if($menu -is [Windows.Controls.ContextMenu]){$target=$menu.PlacementTarget;if($target -is [Windows.Controls.TextBox]){[Windows.Clipboard]::SetText($target.Text)}}}.GetNewClosure())};continue};$childCount=[Windows.Media.VisualTreeHelper]::GetChildrenCount($parent);for($childIndex=0;$childIndex -lt $childCount;$childIndex++){$child=[Windows.Media.VisualTreeHelper]::GetChild($parent,$childIndex);if($null -ne $child){$pending.Push($child)}}}
        }
    })|Out-Null
}

function Refresh-ProjectSessionTree {
    if($null -eq $ProjectTreePanel){return}
    foreach($oldNode in @($ProjectTreePanel.Children)){if($oldNode -is [Windows.Controls.Expander] -and $null -ne $oldNode.Tag){$script:projectTreeExpanded[[string]$oldNode.Tag]=[bool]$oldNode.IsExpanded}}
    $ProjectTreePanel.Children.Clear();$projects=@(Get-AtaraxiaProjectNames (Get-ProjectsRoot));$active=[string](Get-AtaraxiaConfig).project_name;$ProjectGroupExpander.Header=Get-AppText 'gui_projects'
    if($projects.Count -eq 0){$empty=[Windows.Controls.TextBlock]::new();$empty.Text=Get-AppText 'gui_no_projects';$empty.Foreground=$window.Resources['SecondaryTextBrush'];$empty.Margin=[Windows.Thickness]::new(6,4,2,4);$ProjectTreePanel.Children.Add($empty)|Out-Null}
    foreach($projectName in $projects){
        $projectPath=Get-AtaraxiaProjectPath (Get-ProjectsRoot) $projectName;$node=[Windows.Controls.Expander]::new();$node.Tag=$projectName;$node.Margin=[Windows.Thickness]::new(0,1,0,1);$node.Padding=[Windows.Thickness]::new(4,2,4,2);$node.Foreground=$window.Resources['PrimaryTextBrush'];$node.IsExpanded=if($script:projectTreeExpanded.ContainsKey($projectName)){$script:projectTreeExpanded[$projectName]}else{$projectName -ieq $active}
        $header=[Windows.Controls.DockPanel]::new();$header.LastChildFill=$true;$projectText=[Windows.Controls.TextBlock]::new();$projectText.Text=$projectName;$projectText.FontWeight=if($projectName -ieq $active){[Windows.FontWeights]::SemiBold}else{[Windows.FontWeights]::Normal};$projectText.VerticalAlignment='Center'
        $choose=[Windows.Controls.Button]::new();$choose.Width=28;$choose.Height=26;$choose.Padding=[Windows.Thickness]::new(3);$choose.Margin=[Windows.Thickness]::new(5,0,0,0);$choose.ToolTip=Get-AppText 'gui_use_project';$choose.IsEnabled=($projectName -ine $active);$choose.Tag=$projectName;$chooseIcon=[Windows.Shapes.Path]::new();$chooseIcon.Data=[Windows.Media.Geometry]::Parse('M3,10 L8,15 L17,5');$chooseIcon.Width=15;$chooseIcon.Height=15;$chooseIcon.Stretch='Uniform';$chooseIcon.Fill=[Windows.Media.Brushes]::Transparent;$chooseIcon.SetResourceReference([Windows.Shapes.Shape]::StrokeProperty,'IconBrush');$chooseIcon.StrokeThickness=1.7;$chooseIcon.StrokeStartLineCap='Round';$chooseIcon.StrokeEndLineCap='Round';$choose.Content=$chooseIcon;$choose.Style=$window.Resources['IconButtonHover'];$choose.Add_Click({try{Select-AtaraxiaDrawerProject ([string]$this.Tag)}catch{Show-AtaraxiaMessageDialog -Message $_.Exception.Message -Title (Get-AppText 'gui_title') -Kind error|Out-Null}}.GetNewClosure());[Windows.Controls.DockPanel]::SetDock($choose,[Windows.Controls.Dock]::Right)
        $newSessionForProject=[Windows.Controls.Button]::new();$newSessionForProject.Width=28;$newSessionForProject.Height=26;$newSessionForProject.Padding=[Windows.Thickness]::new(3);$newSessionForProject.Margin=[Windows.Thickness]::new(5,0,0,0);$newSessionForProject.ToolTip=Get-AppText 'gui_new_session';$newSessionForProject.Tag=$projectName;$newSessionIcon=[Windows.Shapes.Path]::new();Set-AtaraxiaPathIcon $newSessionIcon 'new-session';$newSessionIcon.SetResourceReference([Windows.Shapes.Shape]::StrokeProperty,'IconBrush');$newSessionIcon.StrokeThickness=1.5;$newSessionIcon.StrokeStartLineCap='Round';$newSessionIcon.StrokeEndLineCap='Round';$newSessionIcon.StrokeLineJoin='Round';$newSessionForProject.Content=$newSessionIcon;$newSessionForProject.Style=$window.Resources['IconButtonHover'];$newSessionForProject.Add_Click({try{Begin-AtaraxiaNewSessionScreen ([string]$this.Tag)}catch{Show-AtaraxiaMessageDialog -Message $_.Exception.Message -Title (Get-AppText 'gui_title') -Kind error|Out-Null}}.GetNewClosure());[Windows.Controls.DockPanel]::SetDock($newSessionForProject,[Windows.Controls.Dock]::Right)
        $header.Children.Add($newSessionForProject)|Out-Null;$header.Children.Add($choose)|Out-Null;$header.Children.Add($projectText)|Out-Null;$node.Header=$header;$node.Add_Expanded({$script:projectTreeExpanded[[string]$this.Tag]=$true}.GetNewClosure());$node.Add_Collapsed({$script:projectTreeExpanded[[string]$this.Tag]=$false}.GetNewClosure())
        $sessionList=[Windows.Controls.StackPanel]::new();$sessionList.Margin=[Windows.Thickness]::new(16,0,0,2);$sessions=@(Get-AtaraxiaSessions $projectPath)
        foreach($session in $sessions){$sessionButton=[Windows.Controls.Button]::new();$sessionButton.Content=[string]$session.title;$sessionButton.Tag=$session;$sessionButton.HorizontalContentAlignment='Left';$sessionButton.Padding=[Windows.Thickness]::new(6,4,4,4);$sessionButton.Margin=[Windows.Thickness]::new(0,1,0,1);$sessionButton.Background=$window.Resources['PanelBrush'];$sessionButton.Foreground=$window.Resources['PrimaryTextBrush'];$sessionButton.Style=$window.Resources['IconButtonHover'];$sessionCopy=$session;$projectCopy=$projectName;$sessionButton.Add_Click({try{Select-AtaraxiaDrawerSession $projectCopy $sessionCopy}catch{Show-AtaraxiaMessageDialog -Message $_.Exception.Message -Title (Get-AppText 'gui_title') -Kind error|Out-Null}}.GetNewClosure());$sessionList.Children.Add($sessionButton)|Out-Null}
        if($sessions.Count -eq 0){$empty=[Windows.Controls.TextBlock]::new();$empty.Text=Get-AppText 'gui_no_sessions';$empty.Foreground=$window.Resources['SecondaryTextBrush'];$empty.Margin=[Windows.Thickness]::new(6,4,2,4);$sessionList.Children.Add($empty)|Out-Null}
        $node.Content=$sessionList;Enable-AtaraxiaSmoothExpander $node;$ProjectTreePanel.Children.Add($node)|Out-Null
    }
    $RecentSessionsPanel.Children.Clear();$RecentSessionsExpander.Header=Get-AppText 'gui_recent_sessions';$RecentSessionsExpander.IsExpanded=$script:recentSessionsExpanded
    if($RecentSessionsExpander.Tag -ne 'wired'){$RecentSessionsExpander.Add_Expanded({$script:recentSessionsExpanded=$true}.GetNewClosure());$RecentSessionsExpander.Add_Collapsed({$script:recentSessionsExpanded=$false}.GetNewClosure());$RecentSessionsExpander.Tag='wired'}
    $config=Get-AtaraxiaConfig;$maximum=5;$guiProperty=$config.PSObject.Properties['gui'];if($null -ne $guiProperty -and $null -ne $guiProperty.Value.PSObject.Properties['recent_sessions_max']){$maximum=[int]$guiProperty.Value.recent_sessions_max};if($maximum -lt 0){$maximum=0};$recentSessions=@(Get-AtaraxiaRecentSessions (Get-ProjectsRoot) $maximum)
    foreach($session in $recentSessions){$sessionButton=[Windows.Controls.Button]::new();$sessionButton.Content=[string]$session.title;$sessionButton.Tag=$session;$sessionButton.HorizontalContentAlignment='Left';$sessionButton.Padding=[Windows.Thickness]::new(6,4,4,4);$sessionButton.Margin=[Windows.Thickness]::new(0,1,0,1);$sessionButton.Background=$window.Resources['PanelBrush'];$sessionButton.Foreground=$window.Resources['PrimaryTextBrush'];$sessionButton.Style=$window.Resources['IconButtonHover'];$sessionCopy=$session;$sessionButton.Add_Click({try{Select-AtaraxiaDrawerSession ([string]$sessionCopy.project_name) $sessionCopy}catch{Show-AtaraxiaMessageDialog -Message $_.Exception.Message -Title (Get-AppText 'gui_title') -Kind error|Out-Null}}.GetNewClosure());$RecentSessionsPanel.Children.Add($sessionButton)|Out-Null}
    if($recentSessions.Count -eq 0){$empty=[Windows.Controls.TextBlock]::new();$empty.Text=Get-AppText 'gui_no_recent_sessions';$empty.Foreground=$window.Resources['SecondaryTextBrush'];$empty.Margin=[Windows.Thickness]::new(6,4,2,4);$RecentSessionsPanel.Children.Add($empty)|Out-Null}
}

function New-AtaraxiaGuiSession([string]$ProjectName) {
    $config=Get-AtaraxiaConfig;$contracts=Import-RoleContracts $config $RuntimeConfig.Text
    $projectPath=Get-AtaraxiaProjectPath (Get-ProjectsRoot) $ProjectName
    if(-not(Test-Path -LiteralPath $projectPath -PathType Container)){New-AtaraxiaProject (Get-ProjectsRoot) $ProjectName|Out-Null}
    return New-AtaraxiaSession $projectPath $contracts 'New session'
}

function Materialize-AtaraxiaPendingSession([string]$FirstPrompt) {
    if([string]::IsNullOrWhiteSpace($script:pendingSessionProject)){return $null}
    $session=New-AtaraxiaGuiSession $script:pendingSessionProject;$script:pendingSessionProject=''
    Load-AtaraxiaTask (Get-AtaraxiaTaskPath $session)
    return $session
}

function Refresh-AtaraxiaSessionSelector {
    $projectName=[string](Get-AtaraxiaConfig).project_name;$projectPath=Get-AtaraxiaProjectPath (Get-ProjectsRoot) $projectName
    $sessions=@(Get-AtaraxiaSessions $projectPath);$script:loadingSession=$true
    try{$SessionSelector.ItemsSource=$sessions;if(-not [string]::IsNullOrWhiteSpace($script:taskPath)){$taskDirectory=Split-Path -Parent $script:taskPath;$match=@($sessions|Where-Object{$_.path -ieq $taskDirectory}|Select-Object -First 1);if($match.Count -gt 0){$SessionSelector.SelectedItem=$match[0]}else{$SessionSelector.SelectedItem=$null}}else{$SessionSelector.SelectedItem=$null}}finally{$script:loadingSession=$false}
}

function Select-AtaraxiaDrawerProject([string]$ProjectName) {
    Assert-ProjectManagerIdle;$null=Set-AtaraxiaActiveProject ([IO.Path]::GetFullPath($RuntimeConfig.Text)) (Get-ProjectsRoot) $ProjectName
    $script:taskPath='';Reset-LoadedTask;$TaskName.Text=$ProjectName;$Status.Text=Get-AppText 'gui_ready';Refresh-AtaraxiaSessionSelector;Refresh-ProjectSessionTree
}

function Select-AtaraxiaDrawerSession([string]$ProjectName,[object]$Session) {
    Assert-ProjectManagerIdle;$projectPath=Get-AtaraxiaProjectPath (Get-ProjectsRoot) $ProjectName
    $sessionPath=[IO.Path]::GetFullPath([string]$Session.path);$sessionsRoot=[IO.Path]::GetFullPath((Join-Path $projectPath 'sessions'))
    if(-not $sessionPath.StartsWith($sessionsRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'The selected session is outside its project.'}
    if([string](Get-AtaraxiaConfig).project_name -ine $ProjectName){$null=Set-AtaraxiaActiveProject ([IO.Path]::GetFullPath($RuntimeConfig.Text)) (Get-ProjectsRoot) $ProjectName}
    Load-AtaraxiaTask (Get-AtaraxiaTaskPath $Session);Refresh-AtaraxiaSessionSelector;Refresh-ProjectSessionTree
}

function Begin-AtaraxiaNewSessionScreen([string]$ProjectName) {
    Assert-ProjectManagerIdle;$projectPath=Get-AtaraxiaProjectPath (Get-ProjectsRoot) $ProjectName
    if(-not(Test-Path -LiteralPath $projectPath -PathType Container)){New-AtaraxiaProject (Get-ProjectsRoot) $ProjectName|Out-Null}
    if([string](Get-AtaraxiaConfig).project_name -ine $ProjectName){$null=Set-AtaraxiaActiveProject ([IO.Path]::GetFullPath($RuntimeConfig.Text)) (Get-ProjectsRoot) $ProjectName}
    Reset-LoadedTask;$script:pendingSessionProject=$ProjectName;$TaskName.Text=$ProjectName;$Goal.Focus()|Out-Null;$RunTask.IsEnabled=$true
    Refresh-AtaraxiaSessionSelector;Refresh-ProjectSessionTree;$Status.Text=Get-AppText 'gui_new_session_for_project'
}

function New-AtaraxiaSessionFromCurrentProject { Begin-AtaraxiaNewSessionScreen ([string](Get-AtaraxiaConfig).project_name) }

function Rename-AtaraxiaGuiSession {
    $session=$SessionSelector.SelectedItem;if($null -eq $session){return}
    $title=Show-ProjectNameDialog (Get-AppText 'gui_rename_session') ([string]$session.title);if([string]::IsNullOrWhiteSpace($title)){return}
    $null=Set-AtaraxiaSessionTitle ([string]$session.path) $title 'user';Refresh-AtaraxiaSessionSelector;Refresh-ProjectSessionTree
}

function Stop-AtaraxiaRun {
    if($null -eq $script:process){return}
    try{$script:process.Refresh();if(-not $script:process.HasExited){$script:process.Kill();$script:process.WaitForExit(5000)}}catch{}
    $script:process.Dispose();$script:process=$null
    if(-not [string]::IsNullOrWhiteSpace($script:taskPath)){
        $hostPath=(Get-Process -Id $PID).Path;$runner=Join-Path $PSScriptRoot 'Invoke-Agent.ps1';$outPath=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-rollback-'+[guid]::NewGuid().ToString('N')+'.out');$errPath=$outPath+'.err'
        $args=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$runner+'"'),'-Rollback',('"'+$script:taskPath+'"'),'-ConfigPath',('"'+[IO.Path]::GetFullPath($RuntimeConfig.Text)+'"')) -join ' '
        try{$rollback=Start-Process -FilePath $hostPath -ArgumentList $args -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru -Wait -RedirectStandardOutput $outPath -RedirectStandardError $errPath;if($rollback.ExitCode -eq 0){$Status.Text=Get-AppText 'gui_stop_restored'}else{$Status.Text=if(Test-Path -LiteralPath $errPath){Get-Content -LiteralPath $errPath -Raw}else{'Rollback failed.'}}}finally{foreach($file in @($outPath,$errPath)){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue}}}
    }
    $script:currentRole='';$Progress.IsIndeterminate=$false;Set-RunTaskIcon $false;$RunTask.IsEnabled=$true
    foreach($file in @($script:processStdout,$script:processStderr)){if(-not [string]::IsNullOrWhiteSpace([string]$file) -and (Test-Path -LiteralPath $file)){Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue}}
    if(-not [string]::IsNullOrWhiteSpace($script:taskPath)){Refresh-AtaraxiaConversation}
}

function Finish-AtaraxiaProcess {
    if($null -eq $script:process){return};$script:process.Refresh();if(-not $script:process.HasExited){return}
    $exitCode=$script:process.ExitCode;$script:process.Dispose();$script:process=$null;$script:currentRole='';$Progress.IsIndeterminate=$false;Set-RunTaskIcon $false
    foreach($file in @($script:processStdout,$script:processStderr)){if(-not [string]::IsNullOrWhiteSpace([string]$file) -and (Test-Path -LiteralPath $file)){Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue}}
    $Status.Text=if($exitCode -eq 0){Get-AppText 'gui_ready'}else{"Agent exited with code $exitCode."}
    if(-not [string]::IsNullOrWhiteSpace($script:taskPath)){try{Refresh-AtaraxiaSessionSelector;Refresh-ProjectSessionTree;Refresh-AtaraxiaConversation}catch{$Status.Text=$_.Exception.Message}}
    $RunTask.IsEnabled=$true;$EditLast.IsEnabled=$true
}

function Start-AtaraxiaProcess {
    param([string]$Request,[switch]$ReplaceLatest)
    if($null -ne $script:process){return};$cleanRequest=$Request.Trim();if([string]::IsNullOrWhiteSpace($cleanRequest) -or [string]::IsNullOrWhiteSpace($Goal.Text)){return}
    Assert-AgentPlainText $cleanRequest 'User query' -MaximumLength 100000 -AllowMultiline
    if(-not [string]::IsNullOrWhiteSpace($script:pendingSessionProject)){$null=Materialize-AtaraxiaPendingSession $cleanRequest}
    if([string]::IsNullOrWhiteSpace($script:taskPath)){throw 'Select or create a session before sending a query.'}
    $conversationPath=Join-Path (Split-Path -Parent $script:taskPath) 'conversation.json';if($ReplaceLatest){$null=Add-AtaraxiaRequest $conversationPath $cleanRequest -ReplaceLatest}else{$null=Add-AtaraxiaRequest $conversationPath $cleanRequest}
    $task=Read-AgentJsonFile $script:taskPath;$task.goal=$cleanRequest;$temp=$script:taskPath+'.tmp';[IO.File]::WriteAllText($temp,($task|ConvertTo-Json -Depth 100),[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temp -Destination $script:taskPath -Force
    Touch-AtaraxiaSession (Split-Path -Parent $script:taskPath);$script:editing=$false;$Goal.Clear();Refresh-AtaraxiaConversation;Refresh-AtaraxiaSessionSelector;Refresh-ProjectSessionTree
    $runner=Join-Path $PSScriptRoot 'Invoke-Agent.ps1';$hostPath=(Get-Process -Id $PID).Path;$script:processStdout=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-agent-'+[guid]::NewGuid().ToString('N')+'.out');$script:processStderr=$script:processStdout+'.err';$script:stdoutLineCount=0
    $args=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$runner+'"'),'-Run',('"'+$script:taskPath+'"'),'-Step','-1','-ConfigPath',('"'+[IO.Path]::GetFullPath($RuntimeConfig.Text)+'"')) -join ' '
    $script:process=Start-Process -FilePath $hostPath -ArgumentList $args -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $script:processStdout -RedirectStandardError $script:processStderr
    $script:currentRole='';$Status.Text=Get-AppText 'gui_running_workflow';$Progress.IsIndeterminate=$true;Set-RunTaskIcon $true;$RunTask.IsEnabled=$true;$EditLast.IsEnabled=$false
}

function Receive-AtaraxiaProcessOutput {
    if($null -eq $script:process){return}
    if(Test-Path -LiteralPath $script:processStdout){$lines=@(Get-Content -LiteralPath $script:processStdout -ErrorAction SilentlyContinue);while($script:stdoutLineCount -lt $lines.Count){$line=[string]$lines[$script:stdoutLineCount];$script:stdoutLineCount++;$roleEvent=Convert-AtaraxiaRunOutput $line;if($null -ne $roleEvent){$script:currentRole=$roleEvent.role;$item=[pscustomobject]@{kind='role';role=$roleEvent.role};if($item.kind -eq 'role'){$Status.Text=(Get-AppText 'gui_running_role' @((Get-AtaraxiaRoleLabel $item.role)))}}}}
    if(Test-Path -LiteralPath $script:processStderr){$errorText=Get-Content -LiteralPath $script:processStderr -Raw -ErrorAction SilentlyContinue;if(-not [string]::IsNullOrWhiteSpace($errorText)){$Status.Text=$errorText.Trim()}}
    Finish-AtaraxiaProcess
}

function Select-AtaraxiaSessionFromSelector {
    if($script:loadingSession -or $null -eq $SessionSelector.SelectedItem){return}
    Select-AtaraxiaDrawerSession ([string](Get-AtaraxiaConfig).project_name) $SessionSelector.SelectedItem
}

function Set-AtaraxiaCommonPromptForCurrentScope([ValidateSet('project','session')][string]$Scope) {
    $initial='';$title=Get-AppText $(if($Scope -eq 'project'){'gui_project_prompt'}else{'gui_session_prompt'})
    if($Scope -eq 'project'){$path=Get-ActiveProjectPath;$metadata=Join-Path $path 'project.json';if(Test-Path -LiteralPath $metadata -PathType Leaf){$value=(Read-AgentJsonFile $metadata).PSObject.Properties['common_prompt'];if($null -ne $value){$initial=[string]$value.Value}}}
    else{if([string]::IsNullOrWhiteSpace($script:taskPath)){return};$path=Split-Path -Parent $script:taskPath;$metadata=Join-Path $path 'session.json';if(Test-Path -LiteralPath $metadata -PathType Leaf){$value=(Read-AgentJsonFile $metadata).PSObject.Properties['common_prompt'];if($null -ne $value){$initial=[string]$value.Value}}}
    $text=Show-CommonPromptDialog $title $initial;if($null -eq $text){return}
    Save-AtaraxiaCommonPrompt $Scope $path $text
}

function Save-AtaraxiaCommonPrompt([ValidateSet('project','session')][string]$Scope,[string]$Path,[string]$Text) {
    if($Scope -eq 'project'){Set-AtaraxiaProjectCommonPrompt $Path $Text}else{Set-AtaraxiaSessionCommonPrompt $Path $Text}
}

function New-AtaraxiaProjectFromGui {
    Assert-ProjectManagerIdle;$name=Show-ProjectNameDialog (Get-AppText 'gui_new_project') '';if([string]::IsNullOrWhiteSpace($name)){return}
    $null=New-AtaraxiaProject (Get-ProjectsRoot) $name;$null=Set-AtaraxiaActiveProject ([IO.Path]::GetFullPath($RuntimeConfig.Text)) (Get-ProjectsRoot) $name;Reset-LoadedTask;Refresh-AtaraxiaSessionSelector;Refresh-ProjectSessionTree
}
function Rename-AtaraxiaActiveProjectFromGui {
    Assert-ProjectManagerIdle;$old=[string](Get-AtaraxiaConfig).project_name;$name=Show-ProjectNameDialog (Get-AppText 'gui_rename_project') $old;if([string]::IsNullOrWhiteSpace($name) -or $name -ceq $old){return}
    $null=Rename-AtaraxiaProject (Get-ProjectsRoot) $old $name;$config=Get-AtaraxiaConfig;$config.project_name=$name;$temp=$RuntimeConfig.Text+'.tmp';[IO.File]::WriteAllText($temp,($config|ConvertTo-Json -Depth 100),[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temp -Destination $RuntimeConfig.Text -Force;Reset-LoadedTask;Refresh-AtaraxiaSessionSelector;Refresh-ProjectSessionTree
}

function Wire-AtaraxiaEvents {
    $NewProject.Add_Click({try{New-AtaraxiaProjectFromGui}catch{Show-AtaraxiaMessageDialog -Message $_.Exception.Message -Title (Get-AppText 'gui_title') -Kind error|Out-Null}})
    $RenameProject.Add_Click({try{Rename-AtaraxiaActiveProjectFromGui}catch{Show-AtaraxiaMessageDialog -Message $_.Exception.Message -Title (Get-AppText 'gui_title') -Kind error|Out-Null}})
    $NewSession.Add_Click({try{New-AtaraxiaSessionFromCurrentProject}catch{Show-AtaraxiaMessageDialog -Message $_.Exception.Message -Title (Get-AppText 'gui_title') -Kind error|Out-Null}})
    $RenameSession.Add_Click({try{Rename-AtaraxiaGuiSession}catch{Show-AtaraxiaMessageDialog -Message $_.Exception.Message -Title (Get-AppText 'gui_title') -Kind error|Out-Null}})
    $SessionSelector.Add_SelectionChanged({try{Select-AtaraxiaSessionFromSelector}catch{Show-AtaraxiaMessageDialog -Message $_.Exception.Message -Title (Get-AppText 'gui_title') -Kind error|Out-Null}})
    $ProjectPromptButton.Add_Click({try{Set-AtaraxiaCommonPromptForCurrentScope 'project'}catch{Show-AtaraxiaMessageDialog -Message $_.Exception.Message -Title (Get-AppText 'gui_title') -Kind error|Out-Null}})
    $SessionPromptButton.Add_Click({try{Set-AtaraxiaCommonPromptForCurrentScope 'session'}catch{Show-AtaraxiaMessageDialog -Message $_.Exception.Message -Title (Get-AppText 'gui_title') -Kind error|Out-Null}})
    $OtherSession.Add_Click({$OtherSession.ContextMenu.PlacementTarget=$OtherSession;$OtherSession.ContextMenu.IsOpen=$true})
    $script:CopySessionIdMenuItem.Add_Click({$session=$SessionSelector.SelectedItem;if($null -ne $session){[Windows.Clipboard]::SetText([string]$session.id)}})
    $CreateTask.Add_Click({try{New-AtaraxiaSessionFromCurrentProject;$Goal.Focus()|Out-Null}catch{Show-AtaraxiaMessageDialog -Message $_.Exception.Message -Title (Get-AppText 'gui_title') -Kind error|Out-Null}})
    $EditLast.Add_Click({$conversation=Get-AtaraxiaConversation (Join-Path (Split-Path -Parent $script:taskPath) 'conversation.json');$last=@($conversation.entries|Where-Object{$_.kind -eq 'user_query'}|Select-Object -Last 1);if($last.Count -gt 0){$Goal.Text=[string]$last[0].body;$script:editing=$true;$Goal.Focus()|Out-Null;$Goal.CaretIndex=$Goal.Text.Length}})
    $RunTask.Add_Click({try{if($null -ne $script:process){Stop-AtaraxiaRun}else{$replace=$script:editing;Start-AtaraxiaProcess ([string]$Goal.Text) -ReplaceLatest:$replace}}catch{Show-AtaraxiaMessageDialog -Message $_.Exception.Message -Title (Get-AppText 'gui_title') -Kind error|Out-Null}})
    $Goal.Add_PreviewKeyDown({param($sender,$eventArgs)if($eventArgs.Key -eq [Windows.Input.Key]::Enter){if([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Shift){return};$eventArgs.Handled=$true;$RunTask.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))}})
    $ScrollToLatest.Add_Click({$ConversationScrollViewer.ScrollToEnd()})
    $ConversationScrollViewer.Add_ScrollChanged({Update-AtaraxiaScrollToLatestButton})
    $BrowseConfig.Add_Click({$picked=Show-AtaraxiaPathPicker -Owner $window -Kind file -Title (Get-AppText 'gui_runtime_config') -InitialDirectory (Split-Path -Parent $RuntimeConfig.Text) -Patterns @('*.json');if($picked){$RuntimeConfig.Text=[IO.Path]::GetFullPath($picked);Load-AtaraxiaThemePreference;Refresh-AtaraxiaModelSelector;Refresh-ProjectSessionTree}})
    $BrowseTask.Add_Click({$picked=Show-AtaraxiaPathPicker -Owner $window -Kind file -Title (Get-AppText 'gui_open_task') -InitialDirectory (Get-TaskDirectory) -Patterns @('*.task.json');if($picked){try{Load-AtaraxiaTask $picked}catch{Show-AtaraxiaMessageDialog -Message $_.Exception.Message -Title (Get-AppText 'gui_title') -Kind error|Out-Null}}})
    $BrowseWorkspace.Add_Click({$picked=Show-AtaraxiaPathPicker -Owner $window -Kind folder -Title (Get-AppText 'gui_browse_folder') -InitialDirectory $Workspace.Text;if($picked){$Workspace.Text=$picked}})
    $KoboldToggle.Add_Click({Toggle-KoboldCppFromGui});$KoboldRestart.Add_Click({Restart-KoboldCppFromGui})
    $window.Add_Closing({if($script:modelParametersDirty -and $ParametersExpander.IsExpanded){try{Save-AtaraxiaModelParameters}catch{$Status.Text=$_.Exception.Message}};if($null -ne $script:process){Stop-AtaraxiaRun}})
    $script:uiTimer=[Windows.Threading.DispatcherTimer]::new();$script:uiTimer.Interval=[TimeSpan]::FromMilliseconds(250);$script:uiTimer.Add_Tick({Receive-AtaraxiaProcessOutput;Complete-KoboldCppAcquisitionIfFinished;if(([DateTime]::UtcNow-$script:lastKoboldPoll).TotalMilliseconds -ge 2000){$script:lastKoboldPoll=[DateTime]::UtcNow;Update-KoboldConnectionIndicator}});$script:uiTimer.Start()
}

$minimumSplashMilliseconds=1100
if($null -ne $script:splashWindow){$remaining=[Math]::Max(0,$minimumSplashMilliseconds-[int]$script:splashShownAt.ElapsedMilliseconds);$frame=[Windows.Threading.DispatcherFrame]::new();$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds($remaining);$timer.Add_Tick({$timer.Stop();$frame.Continue=$false}.GetNewClosure());$timer.Start();[Windows.Threading.Dispatcher]::PushFrame($frame);$script:splashWindow.Close();$script:splashWindow=$null}
try {
    Set-AtaraxiaLanguage ([string](Get-AtaraxiaConfig).interface_language)
    Load-AtaraxiaThemePreference
    Refresh-AtaraxiaSessionSelector
    Refresh-ProjectSessionTree
    Wire-AtaraxiaEvents
    if(-not [string]::IsNullOrWhiteSpace([string](Get-AtaraxiaConfig).project_name)){$activeProject=Get-AtaraxiaProjectPath (Get-ProjectsRoot) ([string](Get-AtaraxiaConfig).project_name);if(Test-Path -LiteralPath $activeProject -PathType Container){$script:pendingSessionProject=''}}
    try{Start-KoboldCppAcquisitionIfMissing}catch{$Status.Text=$_.Exception.Message}
    $window.Add_ContentRendered({ Register-AtaraxiaSmoothExpanders $window }.GetNewClosure())
    $null=$window.ShowDialog()
} catch {
    if($null -ne $script:splashWindow){$script:splashWindow.Close()}
    Show-AtaraxiaMessageDialog -Message $_.Exception.ToString() -Title '' -Kind error|Out-Null
    throw
} finally {
    if($null -ne $script:uiTimer){$script:uiTimer.Stop()}
    if($null -ne $script:process -and -not $script:process.HasExited){$script:process.Kill();$script:process.WaitForExit(3000)}
    if($null -ne $script:koboldSetupProcess -and -not $script:koboldSetupProcess.HasExited){$script:koboldSetupProcess.Kill();$script:koboldSetupProcess.WaitForExit(3000)}
}
