Set-StrictMode -Version Latest

$script:AtaraxiaDialogContractPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'configs/gui-dialog-contracts.json'
$script:AtaraxiaDialogDefinitions = Get-Content -LiteralPath $script:AtaraxiaDialogContractPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($script:AtaraxiaDialogDefinitions.schema_version -ne 1 -or [string]::IsNullOrWhiteSpace([string]$script:AtaraxiaDialogDefinitions.contract_id)) { throw 'GUI dialog contract definition is invalid.' }

function New-AtaraxiaDialogContract {
    param(
        [string]$Kind,
        [string]$Title,
        [string]$Message='',
        [string]$Value='',
        [string]$Icon='dialog-info',
        [string]$PrimaryLabel='',
        [string]$SecondaryLabel=''
    )
    $definition = $script:AtaraxiaDialogKinds[$Kind]
    if ($null -eq $definition) { throw "Unsupported dialog contract kind: $Kind" }
    if ([string]::IsNullOrWhiteSpace($Icon)) { $Icon = [string]$definition.default_icon }
    return [pscustomobject][ordered]@{
        contract_id=[string]$script:AtaraxiaDialogDefinitions.contract_id
        schema_version=[int]$script:AtaraxiaDialogDefinitions.schema_version
        kind=$Kind
        title=$Title
        message=$Message
        value=$Value
        icon=$Icon
        primary_label=$PrimaryLabel
        secondary_label=$SecondaryLabel
    }
}

function New-AtaraxiaDialogWindow {
    param([Windows.Window]$Owner,[string]$Title,[string]$Icon,[double]$Width=480,[double]$Height=260,[string]$PrimaryLabel,[string]$SecondaryLabel)
    [xml]$shellXaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" ShowInTaskbar="False" Focusable="True">
 <Border x:Name="DialogFrame" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="9" Padding="18">
  <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
   <Grid x:Name="DialogHeader" Grid.Row="0" Margin="0,0,0,14"><Grid.ColumnDefinitions><ColumnDefinition Width="30"/><ColumnDefinition Width="*"/><ColumnDefinition Width="34"/></Grid.ColumnDefinitions><Path x:Name="DialogIcon" Grid.Column="0" Width="20" Height="20" Stretch="Uniform" Fill="Transparent" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" VerticalAlignment="Center"/><TextBlock x:Name="DialogTitle" Grid.Column="1" FontSize="16" FontWeight="SemiBold" Foreground="{DynamicResource PrimaryTextBrush}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/><Button x:Name="DialogClose" Grid.Column="2" Width="30" Height="28" Padding="0" ToolTip="Close"><Path x:Name="DialogCloseIcon" Width="14" Height="14" Stretch="Uniform" Fill="Transparent" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/></Button></Grid>
   <ContentControl x:Name="DialogBody" Grid.Row="1" Foreground="{DynamicResource PrimaryTextBrush}"/>
   <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0"><Button x:Name="DialogSecondary" MinWidth="92" Height="34" Margin="0,0,8,0"/><Button x:Name="DialogPrimary" MinWidth="92" Height="34" IsDefault="True" Background="{DynamicResource AccentBrush}" Foreground="{DynamicResource AccentTextBrush}"/></StackPanel>
  </Grid>
 </Border>
</Window>
'@
    $dialog=[Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($shellXaml))
    $dialog.Owner=$Owner;$dialog.Title=$Title;$dialog.Width=$Width;$dialog.Height=$Height
    $dialog.Resources.MergedDictionaries.Add($Owner.Resources)
    $parts=@{frame=$dialog.FindName('DialogFrame');header=$dialog.FindName('DialogHeader');icon=$dialog.FindName('DialogIcon');title=$dialog.FindName('DialogTitle');close=$dialog.FindName('DialogClose');close_icon=$dialog.FindName('DialogCloseIcon');body=$dialog.FindName('DialogBody');primary=$dialog.FindName('DialogPrimary');secondary=$dialog.FindName('DialogSecondary')}
    $parts.title.Text=$Title;$parts.primary.Content=$PrimaryLabel;$parts.secondary.Content=$SecondaryLabel
    $parts.icon.Data=Get-AtaraxiaUiIconGeometry $Icon
    $parts.close_icon.Data=Get-AtaraxiaUiIconGeometry 'dialog-close'
    $parts.close_icon.SetResourceReference([Windows.Shapes.Shape]::StrokeProperty,'IconBrush')
    if([string]::IsNullOrWhiteSpace($SecondaryLabel)){$parts.secondary.Visibility=[Windows.Visibility]::Collapsed}
    $parts.secondary.Add_Click({$dialog.DialogResult=$false}.GetNewClosure())
    $parts.close.Add_Click({$dialog.DialogResult=$false}.GetNewClosure())
    $parts.title.Add_PreviewMouseLeftButtonDown({param($sender,$eventArgs)if($eventArgs.ChangedButton -eq [Windows.Input.MouseButton]::Left -and $eventArgs.ButtonState -eq [Windows.Input.MouseButtonState]::Pressed){$dialog.DragMove()}}.GetNewClosure())
    return [pscustomobject]@{window=$dialog;parts=$parts}
}

function Show-AtaraxiaDialog {
    param([Parameter(Mandatory)][pscustomobject]$Contract,[Parameter(Mandatory)][Windows.Window]$Owner)
    $secondary=if([string]::IsNullOrWhiteSpace([string]$Contract.secondary_label)){Get-AppText 'gui_cancel'}else{[string]$Contract.secondary_label}
    $width=if($Contract.kind -eq 'multiline'){660}else{480};$height=if($Contract.kind -eq 'multiline'){500}else{if($Contract.kind -eq 'message' -or $Contract.kind -eq 'confirm'){240}else{220}}
    $shell=New-AtaraxiaDialogWindow $Owner ([string]$Contract.title) ([string]$Contract.icon) $width $height ([string]$Contract.primary_label) $secondary
    $shell.parts.primary.Add_Click({$shell.window.DialogResult=$true}.GetNewClosure())
    $body=[Windows.Controls.StackPanel]::new();$body.Margin=[Windows.Thickness]::new(2,0,2,0)
    if(-not[string]::IsNullOrWhiteSpace([string]$Contract.message)){$message=[Windows.Controls.TextBlock]::new();$message.Text=[string]$Contract.message;$message.TextWrapping='Wrap';$message.MaxWidth=620;$message.Foreground=$Owner.Resources['PrimaryTextBrush'];$body.Children.Add($message)|Out-Null}
    $input=$null
    if($Contract.kind -eq 'input' -or $Contract.kind -eq 'multiline'){$input=[Windows.Controls.TextBox]::new();$input.Text=[string]$Contract.value;$inputTopMargin=if([string]::IsNullOrWhiteSpace([string]$Contract.message)){0}else{10};$input.Margin=[Windows.Thickness]::new(0,$inputTopMargin,0,0);$input.Padding=[Windows.Thickness]::new(8,6,8,6);$input.Background=$Owner.Resources['SurfaceBrush'];$input.Foreground=$Owner.Resources['PrimaryTextBrush'];$input.BorderBrush=$Owner.Resources['BorderBrush'];if($Contract.kind -eq 'multiline'){$input.AcceptsReturn=$true;$input.TextWrapping='Wrap';$input.VerticalScrollBarVisibility='Auto';$input.MinHeight=300;$input.VerticalContentAlignment='Top'}else{$input.Height=34;$input.VerticalContentAlignment='Center'};$body.Children.Add($input)|Out-Null}
    $shell.parts.body.Content=$body
    if($Contract.kind -eq 'message'){$shell.parts.secondary.Visibility=[Windows.Visibility]::Collapsed;$shell.parts.primary.Content=if([string]::IsNullOrWhiteSpace([string]$Contract.primary_label)){Get-AppText 'gui_ok'}else{[string]$Contract.primary_label}}
    if($Contract.kind -eq 'confirm'){$shell.parts.primary.Content=if([string]::IsNullOrWhiteSpace([string]$Contract.primary_label)){Get-AppText 'gui_yes'}else{[string]$Contract.primary_label};$shell.parts.secondary.Content=if([string]::IsNullOrWhiteSpace([string]$Contract.secondary_label)){Get-AppText 'gui_no'}else{[string]$Contract.secondary_label}}
    if($null -ne $input){$shell.window.Add_ContentRendered({$input.Focus();if($Contract.kind -eq 'input'){$input.SelectAll()}}.GetNewClosure());$input.Add_PreviewKeyDown({param($sender,$eventArgs)if($Contract.kind -eq 'input' -and $eventArgs.Key -eq [Windows.Input.Key]::Enter){$shell.parts.primary.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent));$eventArgs.Handled=$true}elseif($Contract.kind -eq 'multiline' -and $eventArgs.Key -eq [Windows.Input.Key]::Enter -and [Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control){$shell.parts.primary.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent));$eventArgs.Handled=$true}}.GetNewClosure())}
    $result=$shell.window.ShowDialog()
    if($Contract.kind -eq 'input' -or $Contract.kind -eq 'multiline'){if($result){return [string]$input.Text};return $null}
    if($Contract.kind -eq 'confirm'){return [bool]$result}
    return $null
}

function Show-AtaraxiaMessageDialog {
    param([string]$Message,[string]$Title,[ValidateSet('information','warning','error','question')][string]$Kind='error',[bool]$Confirm=$false,[string]$PrimaryLabel='',[string]$SecondaryLabel='')
    if([string]::IsNullOrWhiteSpace($Title)){$Title=Get-AppText 'gui_title'}
    $iconName=switch($Kind){'warning'{'dialog-warning'}'error'{'dialog-error'}'question'{'dialog-question'}default{'dialog-info'}}
    $type=if($Confirm){'confirm'}else{'message'}
    $contract=New-AtaraxiaDialogContract -Kind $type -Title $Title -Message $Message -Icon $iconName -PrimaryLabel $PrimaryLabel -SecondaryLabel $SecondaryLabel
    return Show-AtaraxiaDialog $contract $window
}

function Show-AtaraxiaInputDialog([string]$Title,[string]$InitialValue='',[string]$Message='') {
    $contract=New-AtaraxiaDialogContract -Kind input -Title $Title -Message $Message -Value $InitialValue -Icon 'dialog-input' -PrimaryLabel (Get-AppText 'gui_confirm')
    return Show-AtaraxiaDialog $contract $window
}

function Show-AtaraxiaMultilineDialog([string]$Title,[string]$InitialValue='',[string]$Message='') {
    $contract=New-AtaraxiaDialogContract -Kind multiline -Title $Title -Message $Message -Value $InitialValue -Icon 'dialog-text' -PrimaryLabel (Get-AppText 'gui_confirm')
    return Show-AtaraxiaDialog $contract $window
}

function Show-AtaraxiaProjectNameDialog([string]$Title,[string]$InitialValue='') { return Show-AtaraxiaInputDialog $Title $InitialValue }
function Show-AtaraxiaCommonPromptDialog([string]$Title,[string]$InitialValue) { return Show-AtaraxiaMultilineDialog $Title $InitialValue }

function Show-AtaraxiaPathPicker {
    param([Parameter(Mandatory)][Windows.Window]$Owner,[ValidateSet('file','folder')][string]$Kind,[string]$Title,[string]$InitialDirectory,[string[]]$Patterns=@('*'))
    $contract=New-AtaraxiaDialogContract -Kind $(if($Kind -eq 'folder'){'folder_picker'}else{'file_picker'}) -Title $Title -Icon $(if($Kind -eq 'folder'){'dialog-folder'}else{'dialog-file'}) -PrimaryLabel $(if($Kind -eq 'folder'){Get-AppText 'gui_choose_folder'}else{Get-AppText 'gui_open_file'}) -SecondaryLabel (Get-AppText 'gui_cancel')
    $shell=New-AtaraxiaDialogWindow $Owner $Title $contract.icon 760 560 $contract.primary_label $contract.secondary_label
    $shell.parts.secondary.Content=Get-AppText 'gui_cancel'
    $layout=[Windows.Controls.Grid]::new();$layout.RowDefinitions.Add([Windows.Controls.RowDefinition]::new());$layout.RowDefinitions.Add([Windows.Controls.RowDefinition]::new());$layout.RowDefinitions.Add([Windows.Controls.RowDefinition]::new());$layout.RowDefinitions[0].Height=[Windows.GridLength]::new(36);$layout.RowDefinitions[1].Height=[Windows.GridLength]::new(22);$layout.RowDefinitions[2].Height=[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)
    $toolbar=[Windows.Controls.DockPanel]::new();$toolbar.LastChildFill=$true;$up=[Windows.Controls.Button]::new();$up.Width=32;$up.Height=30;$up.Padding=[Windows.Thickness]::new(4);$up.Margin=[Windows.Thickness]::new(0,0,6,0);$up.ToolTip=Get-AppText 'gui_parent_folder';$upIcon=[Windows.Shapes.Path]::new();$upIcon.Data=Get-AtaraxiaUiIconGeometry 'dialog-up';$upIcon.Width=16;$upIcon.Height=16;$upIcon.Stretch='Uniform';$upIcon.Fill=[Windows.Media.Brushes]::Transparent;$upIcon.SetResourceReference([Windows.Shapes.Shape]::StrokeProperty,'IconBrush');$up.Content=$upIcon;[Windows.Controls.DockPanel]::SetDock($up,[Windows.Controls.Dock]::Left);$toolbar.Children.Add($up)|Out-Null
    $go=[Windows.Controls.Button]::new();$go.Content=Get-AppText 'gui_go';$go.MinWidth=54;$go.Margin=[Windows.Thickness]::new(6,0,0,0);[Windows.Controls.DockPanel]::SetDock($go,[Windows.Controls.Dock]::Right);$toolbar.Children.Add($go)|Out-Null
    $address=[Windows.Controls.TextBox]::new();$address.VerticalContentAlignment='Center';$address.Padding=[Windows.Thickness]::new(7,4,7,4);$toolbar.Children.Add($address)|Out-Null;[Windows.Controls.Grid]::SetRow($toolbar,0);$layout.Children.Add($toolbar)|Out-Null
    $status=[Windows.Controls.TextBlock]::new();$status.Foreground=$Owner.Resources['SecondaryTextBrush'];$status.VerticalAlignment='Center';$status.TextTrimming='CharacterEllipsis';[Windows.Controls.Grid]::SetRow($status,1);$layout.Children.Add($status)|Out-Null
    $scroll=[Windows.Controls.ScrollViewer]::new();$scroll.VerticalScrollBarVisibility='Auto';$scroll.Margin=[Windows.Thickness]::new(0,4,0,0);$list=[Windows.Controls.StackPanel]::new();$scroll.Content=$list;[Windows.Controls.Grid]::SetRow($scroll,2);$layout.Children.Add($scroll)|Out-Null;$shell.parts.body.Content=$layout
    $state=@{directory='';selected='';items=@();refresh=$null}
    $refresh={
        try{$state.directory=[IO.Path]::GetFullPath($state.directory);if(-not(Test-Path -LiteralPath $state.directory -PathType Container)){throw (Get-AppText 'gui_path_invalid')};$address.Text=$state.directory;$list.Children.Clear();$state.selected='';$shell.parts.primary.IsEnabled=($Kind -eq 'folder');$state.items=@(Get-ChildItem -LiteralPath $state.directory -Force -ErrorAction Stop|Where-Object{$entry=$_;if($entry.PSIsContainer){$true}elseif($Kind -eq 'folder'){$false}else{$matched=$false;foreach($pattern in $Patterns){if($entry.Name -like $pattern){$matched=$true;break}};$matched}}|Sort-Object @{Expression={if($_.PSIsContainer){0}else{1}}},Name);$status.Text=if($state.items.Count -eq 0){Get-AppText 'gui_no_files'}else{[string]$state.directory}
            foreach($entry in $state.items){$row=[Windows.Controls.Button]::new();$row.HorizontalContentAlignment='Left';$row.Padding=[Windows.Thickness]::new(7,5,7,5);$row.Margin=[Windows.Thickness]::new(0,1,0,1);$row.Tag=$entry.FullName;$row.Background=[Windows.Media.Brushes]::Transparent;$line=[Windows.Controls.DockPanel]::new();$line.LastChildFill=$true;$glyph=[Windows.Shapes.Path]::new();$glyph.Data=Get-AtaraxiaUiIconGeometry $(if($entry.PSIsContainer){'dialog-folder'}else{'dialog-file'});$glyph.Width=17;$glyph.Height=17;$glyph.Margin=[Windows.Thickness]::new(0,0,9,0);$glyph.Stretch='Uniform';$glyph.Fill=[Windows.Media.Brushes]::Transparent;$glyph.SetResourceReference([Windows.Shapes.Shape]::StrokeProperty,'IconBrush');[Windows.Controls.DockPanel]::SetDock($glyph,[Windows.Controls.Dock]::Left);$line.Children.Add($glyph)|Out-Null;$label=[Windows.Controls.TextBlock]::new();$label.Text=$entry.Name;$label.VerticalAlignment='Center';$line.Children.Add($label)|Out-Null;$row.Content=$line;$copy=$entry;$row.Add_Click({$state.selected=$copy.FullName;$address.Text=$copy.FullName;$status.Text=$copy.FullName;foreach($child in $list.Children){$child.Background=if([string]$child.Tag -ieq $state.selected){$Owner.Resources['PanelBrush']}else{[Windows.Media.Brushes]::Transparent}};$shell.parts.primary.IsEnabled=($Kind -eq 'folder' -or -not $copy.PSIsContainer)}.GetNewClosure());$row.Add_MouseDoubleClick({if($copy.PSIsContainer){$state.directory=$copy.FullName;& $state.refresh}elseif($Kind -eq 'file'){$state.selected=$copy.FullName;$shell.window.DialogResult=$true}}.GetNewClosure());$list.Children.Add($row)|Out-Null}
        }catch{$list.Children.Clear();$status.Text=$_.Exception.Message;$shell.parts.primary.IsEnabled=$false}
    }.GetNewClosure()
    if([string]::IsNullOrWhiteSpace($InitialDirectory) -or -not(Test-Path -LiteralPath $InitialDirectory -PathType Container)){$InitialDirectory=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)}
    $state.refresh=$refresh;$state.directory=[IO.Path]::GetFullPath($InitialDirectory);& $state.refresh
    $go.Add_Click({$state.directory=$address.Text;& $state.refresh}.GetNewClosure());$address.Add_PreviewKeyDown({param($sender,$eventArgs)if($eventArgs.Key -eq [Windows.Input.Key]::Enter){$state.directory=$address.Text;& $state.refresh;$eventArgs.Handled=$true}}.GetNewClosure())
    $up.Add_Click({$parent=[IO.Directory]::GetParent($state.directory);if($null -ne $parent){$state.directory=$parent.FullName;& $state.refresh}}.GetNewClosure())
    $shell.parts.primary.Add_Click({if($Kind -eq 'folder'){$state.selected=if(-not[string]::IsNullOrWhiteSpace($state.selected) -and (Test-Path -LiteralPath $state.selected -PathType Container)){$state.selected}else{$state.directory};$shell.window.DialogResult=$true}elseif(-not[string]::IsNullOrWhiteSpace($state.selected) -and (Test-Path -LiteralPath $state.selected -PathType Leaf)){$shell.window.DialogResult=$true}}.GetNewClosure())
    if($shell.window.ShowDialog()){return [string]$state.selected};return $null
}
