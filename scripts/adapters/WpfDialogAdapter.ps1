Set-StrictMode -Version Latest

function New-AtaraxiaDialogWindow {
    param([Windows.Window]$Owner,[string]$Title,[string]$Icon,[double]$Width=480,[double]$Height=260,[string]$PrimaryLabel,[string]$SecondaryLabel)
    [xml]$shellXaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" ShowInTaskbar="False" Focusable="True" FontFamily="Segoe UI" FontSize="14">
 <Border x:Name="DialogFrame" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="12" Padding="18">
  <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
   <Grid x:Name="DialogHeader" Grid.Row="0" Margin="0,0,0,14"><Grid.ColumnDefinitions><ColumnDefinition Width="30"/><ColumnDefinition Width="*"/><ColumnDefinition Width="34"/></Grid.ColumnDefinitions><Path x:Name="DialogIcon" Grid.Column="0" Width="20" Height="20" Stretch="Uniform" Fill="Transparent" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" VerticalAlignment="Center"/><TextBlock x:Name="DialogTitle" Grid.Column="1" FontSize="16" FontWeight="SemiBold" Foreground="{DynamicResource PrimaryTextBrush}" VerticalAlignment="Center" TextWrapping="Wrap"/><Button x:Name="DialogClose" Grid.Column="2" Width="34" Height="34" Padding="0" ToolTip="Close" AutomationProperties.Name="{Binding ToolTip, RelativeSource={RelativeSource Self}}"><Path x:Name="DialogCloseIcon" Width="14" Height="14" Stretch="Uniform" Fill="Transparent" Stroke="{DynamicResource IconBrush}" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/></Button></Grid>
   <ContentControl x:Name="DialogBody" Grid.Row="1" Foreground="{DynamicResource PrimaryTextBrush}"/>
   <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0"><Button x:Name="DialogSecondary" MinWidth="104" Height="40" Margin="0,0,8,0"/><Button x:Name="DialogPrimary" MinWidth="104" Height="40" IsDefault="True" Background="{DynamicResource AccentBrush}" Foreground="{DynamicResource AccentTextBrush}"/></StackPanel>
  </Grid>
 </Border>
</Window>
'@
    $dialog=[Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($shellXaml))
    if($null -ne $Owner -and $Owner.IsVisible){$dialog.Owner=$Owner}else{$dialog.WindowStartupLocation=[Windows.WindowStartupLocation]::CenterScreen};$dialog.Title=$Title;$dialog.Width=$Width;$dialog.Height=$Height
    $dialog.Resources.MergedDictionaries.Add($Owner.Resources)
    $parts=@{frame=$dialog.FindName('DialogFrame');header=$dialog.FindName('DialogHeader');icon=$dialog.FindName('DialogIcon');title=$dialog.FindName('DialogTitle');close=$dialog.FindName('DialogClose');close_icon=$dialog.FindName('DialogCloseIcon');body=$dialog.FindName('DialogBody');primary=$dialog.FindName('DialogPrimary');secondary=$dialog.FindName('DialogSecondary')}
    $parts.title.Text=$Title;$parts.primary.Content=$PrimaryLabel;$parts.secondary.Content=$SecondaryLabel
    $parts.icon.Data=Get-AtaraxiaWpfUiIconGeometry $projectRoot $Icon
    $parts.close_icon.Data=Get-AtaraxiaWpfUiIconGeometry $projectRoot 'dialog-close'
    $closeIconStroke=[Windows.Data.Binding]::new('Foreground');$closeIconRelativeSource=[Windows.Data.RelativeSource]::new();$closeIconRelativeSource.Mode=[Windows.Data.RelativeSourceMode]::FindAncestor;$closeIconRelativeSource.AncestorType=[Windows.Controls.Primitives.ButtonBase];$closeIconStroke.RelativeSource=$closeIconRelativeSource;$null=$parts.close_icon.SetBinding([Windows.Shapes.Shape]::StrokeProperty,$closeIconStroke)
    if([string]::IsNullOrWhiteSpace($SecondaryLabel)){$parts.secondary.Visibility=[Windows.Visibility]::Collapsed}
    $parts.title.Add_PreviewMouseLeftButtonDown({param($sender,$eventArgs)if($eventArgs.ChangedButton -eq [Windows.Input.MouseButton]::Left -and $eventArgs.ButtonState -eq [Windows.Input.MouseButtonState]::Pressed){$dialog.DragMove()}}.GetNewClosure())
    return [pscustomobject]@{window=$dialog;parts=$parts}
}

function Render-AtaraxiaWpfDialog {
    param([Parameter(Mandatory)][pscustomobject]$Contract,[Parameter(Mandatory)][Windows.Window]$Owner)
    $completeDialogAction=${function:Complete-AtaraxiaWpfDialogAction}
    $secondary=[string]$Contract.secondary_label
    $width=if($Contract.kind -eq 'multiline'){660}else{480};$height=if($Contract.kind -eq 'multiline'){500}else{if($Contract.kind -eq 'message' -or $Contract.kind -eq 'confirm'){240}else{220}}
    $shell=New-AtaraxiaDialogWindow $Owner ([string]$Contract.title) ([string]$Contract.icon) $width $height ([string]$Contract.primary_label) $secondary
    $primaryAction=switch([string]$Contract.kind){'message'{'ok'}'confirm'{'primary'}'input'{'confirm'}'multiline'{'confirm'}}
    $shell.parts.primary.Add_Click({$value=if($null -ne $dialogInput){[string]$dialogInput.Text}else{''};& $completeDialogAction $shell $Contract $primaryAction $value|Out-Null}.GetNewClosure())
    $secondaryAction=if($Contract.kind -eq 'confirm'){'secondary'}else{'cancel'}
    $copyableError=($Contract.kind -eq 'message' -and $Contract.icon -eq 'dialog-error')
    if($copyableError){$shell.parts.secondary.Visibility=[Windows.Visibility]::Visible;$shell.parts.secondary.Content=[string]$Contract.secondary_label;$shell.parts.secondary.Add_Click({[Windows.Clipboard]::SetText([string]$Contract.message);& $completeDialogAction $shell $Contract 'ok' ''|Out-Null}.GetNewClosure())}else{$shell.parts.secondary.Add_Click({& $completeDialogAction $shell $Contract $secondaryAction ''|Out-Null}.GetNewClosure())}
    $closeAction=if($Contract.kind -eq 'message'){'ok'}else{'close'}
    $shell.parts.close.Add_Click({& $completeDialogAction $shell $Contract $closeAction ''|Out-Null}.GetNewClosure())
    $body=[Windows.Controls.StackPanel]::new();$body.Margin=[Windows.Thickness]::new(2,0,2,0)
    if(-not[string]::IsNullOrWhiteSpace([string]$Contract.message)){$message=[Windows.Controls.TextBlock]::new();$message.Text=[string]$Contract.message;$message.TextWrapping='Wrap';$message.MaxWidth=620;$message.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,'PrimaryTextBrush');$body.Children.Add($message)|Out-Null}
    $dialogInput=$null
    if($Contract.kind -eq 'input' -or $Contract.kind -eq 'multiline'){$dialogInput=[Windows.Controls.TextBox]::new();$dialogInput.Text=[string]$Contract.value;$inputTopMargin=if([string]::IsNullOrWhiteSpace([string]$Contract.message)){0}else{10};$dialogInput.Margin=[Windows.Thickness]::new(0,$inputTopMargin,0,0);$dialogInput.Padding=[Windows.Thickness]::new(8,6,8,6);$dialogInput.SetResourceReference([Windows.Controls.Control]::BackgroundProperty,'SurfaceBrush');$dialogInput.SetResourceReference([Windows.Controls.Control]::ForegroundProperty,'PrimaryTextBrush');$dialogInput.SetResourceReference([Windows.Controls.Control]::BorderBrushProperty,'BorderBrush');if($Contract.kind -eq 'multiline'){$dialogInput.AcceptsReturn=$true;$dialogInput.TextWrapping='Wrap';$dialogInput.VerticalScrollBarVisibility='Auto';$dialogInput.MinHeight=300;$dialogInput.VerticalContentAlignment='Top'}else{$dialogInput.MinHeight=40;$dialogInput.VerticalContentAlignment='Center'};$body.Children.Add($dialogInput)|Out-Null}
    $shell.parts.body.Content=$body
    if($Contract.kind -eq 'message'){if(-not $copyableError){$shell.parts.secondary.Visibility=[Windows.Visibility]::Collapsed};$shell.parts.primary.Content=[string]$Contract.primary_label}
    if($Contract.kind -eq 'confirm'){$shell.parts.primary.Content=[string]$Contract.primary_label;$shell.parts.secondary.Content=[string]$Contract.secondary_label}
    if($null -ne $dialogInput){$shell.window.Add_ContentRendered({$null=$dialogInput.Focus();if($Contract.kind -eq 'input'){$dialogInput.SelectAll()}}.GetNewClosure());$dialogInput.Add_PreviewKeyDown({param($sender,$eventArgs)if($Contract.kind -eq 'input' -and $eventArgs.Key -eq [Windows.Input.Key]::Enter){& $completeDialogAction $shell $Contract 'confirm' ([string]$dialogInput.Text)|Out-Null;$eventArgs.Handled=$true}elseif($Contract.kind -eq 'multiline' -and $eventArgs.Key -eq [Windows.Input.Key]::Enter -and [Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control){& $completeDialogAction $shell $Contract 'confirm' ([string]$dialogInput.Text)|Out-Null;$eventArgs.Handled=$true}}.GetNewClosure())}
    $result=$shell.window.ShowDialog()
    if($Contract.kind -eq 'input' -or $Contract.kind -eq 'multiline'){if($result){return [string]$dialogInput.Text};return $null}
    if($Contract.kind -eq 'confirm'){return [bool]$result}
    return $null
}

function Complete-AtaraxiaWpfDialogAction([object]$Shell,[object]$Contract,[string]$Action,[string]$Value='') {
    $decision=Resolve-AtaraxiaDialogAction $Contract $Action $Value
    if(-not $decision.completed){return $decision}
    $Shell.window.Tag=$decision.outputs
    if($null -ne $decision.outputs.PSObject.Properties['confirmed']){$accepted=[bool]$decision.outputs.confirmed}elseif($null -ne $decision.outputs.PSObject.Properties['cancelled']){$accepted=(-not [bool]$decision.outputs.cancelled)}else{$accepted=$true}
    $Shell.window.DialogResult=$accepted
    return $decision
}

function Render-AtaraxiaWpfPathPicker {
    param([Parameter(Mandatory)][pscustomobject]$Contract,[Parameter(Mandatory)][Windows.Window]$Owner,[string]$InitialDirectory,[string[]]$Patterns=@('*'),[scriptblock]$TextResolver)
    $Kind=if($Contract.kind -eq 'folder_picker'){'folder'}else{'file'};$Title=[string]$Contract.title
    $shell=New-AtaraxiaDialogWindow $Owner $Title $contract.icon 760 560 $contract.primary_label $contract.secondary_label
    $shell.parts.secondary.Content=$contract.secondary_label
    $shell.parts.secondary.Add_Click({Complete-AtaraxiaWpfDialogAction $shell $contract 'cancel' ''|Out-Null}.GetNewClosure());$shell.parts.close.Add_Click({Complete-AtaraxiaWpfDialogAction $shell $contract 'cancel' ''|Out-Null}.GetNewClosure())
    $layout=[Windows.Controls.Grid]::new();$layout.RowDefinitions.Add([Windows.Controls.RowDefinition]::new());$layout.RowDefinitions.Add([Windows.Controls.RowDefinition]::new());$layout.RowDefinitions.Add([Windows.Controls.RowDefinition]::new());$layout.RowDefinitions[0].Height=[Windows.GridLength]::new(36);$layout.RowDefinitions[1].Height=[Windows.GridLength]::new(22);$layout.RowDefinitions[2].Height=[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)
    $toolbar=[Windows.Controls.DockPanel]::new();$toolbar.LastChildFill=$true;$up=[Windows.Controls.Button]::new();$up.Width=32;$up.Height=30;$up.Padding=[Windows.Thickness]::new(4);$up.Margin=[Windows.Thickness]::new(0,0,6,0);$up.ToolTip=& $TextResolver 'gui_parent_folder';Set-AtaraxiaWpfAutomationName $up ([string]$up.ToolTip);$upIcon=[Windows.Shapes.Path]::new();$upIcon.Data=Get-AtaraxiaWpfUiIconGeometry $projectRoot 'dialog-up';$upIcon.Width=16;$upIcon.Height=16;$upIcon.Stretch='Uniform';$upIcon.Fill=[Windows.Media.Brushes]::Transparent;$upIcon.SetResourceReference([Windows.Shapes.Shape]::StrokeProperty,'IconBrush');$up.Content=$upIcon;[Windows.Controls.DockPanel]::SetDock($up,[Windows.Controls.Dock]::Left);$toolbar.Children.Add($up)|Out-Null
    $go=[Windows.Controls.Button]::new();$go.Content=& $TextResolver 'gui_go';$go.MinWidth=54;$go.Margin=[Windows.Thickness]::new(6,0,0,0);[Windows.Controls.DockPanel]::SetDock($go,[Windows.Controls.Dock]::Right);$toolbar.Children.Add($go)|Out-Null
    $address=[Windows.Controls.TextBox]::new();$address.VerticalContentAlignment='Center';$address.Padding=[Windows.Thickness]::new(7,4,7,4);$toolbar.Children.Add($address)|Out-Null;[Windows.Controls.Grid]::SetRow($toolbar,0);$layout.Children.Add($toolbar)|Out-Null
    $status=[Windows.Controls.TextBlock]::new();$status.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,'SecondaryTextBrush');$status.VerticalAlignment='Center';$status.TextWrapping='Wrap';[Windows.Controls.Grid]::SetRow($status,1);$layout.Children.Add($status)|Out-Null
    $scroll=[Windows.Controls.ScrollViewer]::new();$scroll.VerticalScrollBarVisibility='Auto';$scroll.Margin=[Windows.Thickness]::new(0,4,0,0);$list=[Windows.Controls.StackPanel]::new();$scroll.Content=$list;[Windows.Controls.Grid]::SetRow($scroll,2);$layout.Children.Add($scroll)|Out-Null;$shell.parts.body.Content=$layout
    $state=@{directory='';selected='';items=@();refresh=$null}
    $refresh={
        try{$state.directory=Resolve-AtaraxiaDialogDirectory $state.directory (& $TextResolver 'gui_path_invalid');$address.Text=$state.directory;$list.Children.Clear();$state.selected='';$shell.parts.primary.IsEnabled=($Kind -eq 'folder');$state.items=@(Get-AtaraxiaDialogPathEntries $state.directory $Kind $Patterns);$status.Text=if($state.items.Count -eq 0){& $TextResolver 'gui_no_files'}else{[string]$state.directory}
            foreach($entry in $state.items){$row=[Windows.Controls.Button]::new();$row.HorizontalContentAlignment='Left';$row.Padding=[Windows.Thickness]::new(7,5,7,5);$row.Margin=[Windows.Thickness]::new(0,1,0,1);$row.Tag=$entry.FullName;Set-AtaraxiaWpfAutomationName $row ([string]$entry.Name);$row.Background=[Windows.Media.Brushes]::Transparent;$line=[Windows.Controls.DockPanel]::new();$line.LastChildFill=$true;$glyph=[Windows.Shapes.Path]::new();$glyph.Data=Get-AtaraxiaWpfUiIconGeometry $projectRoot $(if($entry.PSIsContainer){'dialog-folder'}else{'dialog-file'});$glyph.Width=17;$glyph.Height=17;$glyph.Margin=[Windows.Thickness]::new(0,0,9,0);$glyph.Stretch='Uniform';$glyph.Fill=[Windows.Media.Brushes]::Transparent;$glyph.SetResourceReference([Windows.Shapes.Shape]::StrokeProperty,'IconBrush');[Windows.Controls.DockPanel]::SetDock($glyph,[Windows.Controls.Dock]::Left);$line.Children.Add($glyph)|Out-Null;$label=[Windows.Controls.TextBlock]::new();$label.Text=$entry.Name;$label.VerticalAlignment='Center';$line.Children.Add($label)|Out-Null;$row.Content=$line;$copy=$entry;$row.Add_Click({$state.selected=$copy.FullName;$address.Text=$copy.FullName;$status.Text=$copy.FullName;foreach($child in $list.Children){if([string]$child.Tag -ieq $state.selected){$child.SetResourceReference([Windows.Controls.Control]::BackgroundProperty,'PanelBrush')}else{$child.Background=[Windows.Media.Brushes]::Transparent}};$shell.parts.primary.IsEnabled=($Kind -eq 'folder' -or -not $copy.PSIsContainer)}.GetNewClosure());$row.Add_MouseDoubleClick({if($copy.PSIsContainer){$navigation=Resolve-AtaraxiaDialogAction $contract 'navigate' $copy.FullName;$state.directory=$navigation.outputs.path;& $state.refresh}elseif($Kind -eq 'file'){$decision=Complete-AtaraxiaWpfDialogAction $shell $contract 'open' $copy.FullName;if($decision.completed){$state.selected=$decision.outputs.path}}}.GetNewClosure());$list.Children.Add($row)|Out-Null}
        }catch{$list.Children.Clear();$status.Text=$_.Exception.Message;$shell.parts.primary.IsEnabled=$false}
    }.GetNewClosure()
    if([string]::IsNullOrWhiteSpace($InitialDirectory) -or -not(Test-AtaraxiaDialogDirectory $InitialDirectory)){$InitialDirectory=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)}
    $state.refresh=$refresh;$state.directory=[IO.Path]::GetFullPath($InitialDirectory);& $state.refresh
    $go.Add_Click({$navigation=Resolve-AtaraxiaDialogAction $contract 'navigate' ([string]$address.Text);$state.directory=$navigation.outputs.path;& $state.refresh}.GetNewClosure());$address.Add_PreviewKeyDown({param($sender,$eventArgs)if($eventArgs.Key -eq [Windows.Input.Key]::Enter){$navigation=Resolve-AtaraxiaDialogAction $contract 'navigate' ([string]$address.Text);$state.directory=$navigation.outputs.path;& $state.refresh;$eventArgs.Handled=$true}}.GetNewClosure())
    $up.Add_Click({$parent=[IO.Directory]::GetParent($state.directory);if($null -ne $parent){$navigation=Resolve-AtaraxiaDialogAction $contract 'navigate' $parent.FullName;$state.directory=$navigation.outputs.path;& $state.refresh}}.GetNewClosure())
    $shell.parts.primary.Add_Click({$path=if($Kind -eq 'folder'){if(-not[string]::IsNullOrWhiteSpace($state.selected) -and (Test-AtaraxiaDialogDirectory $state.selected)){$state.selected}else{$state.directory}}else{[string]$state.selected};$action=if($Kind -eq 'folder'){'select'}else{'open'};$decision=Complete-AtaraxiaWpfDialogAction $shell $contract $action $path;if($decision.completed){$state.selected=$decision.outputs.path}}.GetNewClosure())
    if($shell.window.ShowDialog()){return [string]$state.selected};return $null
}
