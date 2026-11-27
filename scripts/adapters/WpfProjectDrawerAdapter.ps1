Set-StrictMode -Version Latest

function Set-AtaraxiaWpfProjectDrawer {
    param(
        [Parameter(Mandatory)][Windows.Window]$Owner,
        [Parameter(Mandatory)][object]$ViewModel,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpandedState,
        [Parameter(Mandatory)][object]$Port,
        [Parameter(Mandatory)][scriptblock]$GetText,
        [Parameter(Mandatory)][scriptblock]$SetIcon,
        [Parameter(Mandatory)][scriptblock]$OnAction,
        [Parameter(Mandatory)][object]$SmoothExpanderRegistry,
        [Parameter(Mandatory)][Windows.Controls.Panel]$ProjectTreePanel,
        [Parameter(Mandatory)][Windows.Controls.Panel]$RecentSessionsPanel,
        [Parameter(Mandatory)][Windows.Controls.Expander]$RecentSessionsExpander,
        [Parameter(Mandatory)][Windows.Controls.TextBlock]$ProjectGroupTitle,
        [Parameter(Mandatory)][Windows.Controls.TextBlock]$RecentSessionsTitle,
        [bool]$RecentSessionsExpanded=$false,
        [string]$ActiveProjectName=''
    )
    foreach($oldNode in @($ProjectTreePanel.Children)){
        if($oldNode -is [Windows.Controls.Expander] -and $null -ne $oldNode.Tag){$ExpandedState[[string]$oldNode.Tag]=[bool]$oldNode.IsExpanded}
    }
    $ProjectTreePanel.Children.Clear();$projects=@($ViewModel.projects);$ProjectGroupTitle.Text=& $GetText 'gui_projects'
    if($projects.Count -eq 0){$empty=[Windows.Controls.TextBlock]::new();$empty.Text=& $GetText 'gui_no_projects';$empty.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,'SecondaryTextBrush');$empty.Margin=[Windows.Thickness]::new(6,4,2,4);$ProjectTreePanel.Children.Add($empty)|Out-Null}
    foreach($project in $projects){
        $projectName=[string]$project.name;$node=[Windows.Controls.Expander]::new();$node.Tag=$projectName;$node.Margin=[Windows.Thickness]::new(0,1,0,1);$node.Padding=[Windows.Thickness]::new(4,2,4,2);$node.SetResourceReference([Windows.Controls.Control]::ForegroundProperty,'PrimaryTextBrush');$node.IsExpanded=if($ExpandedState.Contains($projectName)){$ExpandedState[$projectName]}else{$projectName -ieq $ActiveProjectName}
        $header=[Windows.Controls.DockPanel]::new();$header.LastChildFill=$true
        $projectText=[Windows.Controls.Button]::new();$projectText.Content=$projectName;$projectText.HorizontalContentAlignment='Left';$projectText.Padding=[Windows.Thickness]::new(4,2,4,2);$projectText.Background=[Windows.Media.Brushes]::Transparent;$projectText.BorderThickness=[Windows.Thickness]::new(0);$projectText.SetResourceReference([Windows.Controls.Control]::ForegroundProperty,'PrimaryTextBrush');$projectText.Style=$Owner.Resources['IconButtonHover'];$projectText.FontWeight=if($project.is_active){[Windows.FontWeights]::SemiBold}else{[Windows.FontWeights]::Normal};$projectText.VerticalAlignment='Center'
        $projectExpander=$node;$projectExpandTarget='project-expand:'+ $projectName;Register-AtaraxiaGuiViewTarget $Port $projectExpandTarget $projectText;Register-AtaraxiaGuiViewAction $Port $projectExpandTarget 'activate' {$projectExpander.IsExpanded=-not $projectExpander.IsExpanded}.GetNewClosure()
        $choose=[Windows.Controls.Button]::new();$choose.Width=28;$choose.Height=26;$choose.Padding=[Windows.Thickness]::new(3);$choose.Margin=[Windows.Thickness]::new(5,0,0,0);$choose.ToolTip=& $GetText 'gui_use_project';Set-AtaraxiaWpfAutomationName $choose ([string]$choose.ToolTip);$choose.IsEnabled=($projectName -ine $ActiveProjectName);$choose.Tag=$projectName
        $chooseIcon=[Windows.Shapes.Path]::new();$chooseIcon.Data=[Windows.Media.Geometry]::Parse('M3,10 L8,15 L17,5');$chooseIcon.Width=15;$chooseIcon.Height=15;$chooseIcon.Stretch='Uniform';$chooseIcon.Fill=[Windows.Media.Brushes]::Transparent;$chooseIcon.SetResourceReference([Windows.Shapes.Shape]::StrokeProperty,'IconBrush');$chooseIcon.StrokeThickness=1.7;$chooseIcon.StrokeStartLineCap='Round';$chooseIcon.StrokeEndLineCap='Round';$choose.Content=$chooseIcon;& $SetIcon $chooseIcon '';$choose.Style=$Owner.Resources['IconButtonHover']
        $projectSelectTarget='project-select:'+ $projectName;Register-AtaraxiaGuiViewTarget $Port $projectSelectTarget $choose;$projectForSelection=$projectName;Register-AtaraxiaGuiViewAction $Port $projectSelectTarget 'activate' {& $OnAction 'select_project' $projectForSelection}.GetNewClosure();[Windows.Controls.DockPanel]::SetDock($choose,[Windows.Controls.Dock]::Right)
        $newSession=[Windows.Controls.Button]::new();$newSession.Width=28;$newSession.Height=26;$newSession.Padding=[Windows.Thickness]::new(3);$newSession.Margin=[Windows.Thickness]::new(5,0,0,0);$newSession.ToolTip=& $GetText 'gui_new_session';Set-AtaraxiaWpfAutomationName $newSession ([string]$newSession.ToolTip);$newSession.Tag=$projectName
        $newSessionIcon=[Windows.Shapes.Path]::new();& $SetIcon $newSessionIcon 'new-session';$newSessionIcon.SetResourceReference([Windows.Shapes.Shape]::StrokeProperty,'IconBrush');$newSessionIcon.StrokeThickness=1.5;$newSessionIcon.StrokeStartLineCap='Round';$newSessionIcon.StrokeEndLineCap='Round';$newSessionIcon.StrokeLineJoin='Round';$newSession.Content=$newSessionIcon;$newSession.Style=$Owner.Resources['IconButtonHover']
        $newSessionTarget='project-new-session:'+ $projectName;Register-AtaraxiaGuiViewTarget $Port $newSessionTarget $newSession;$projectForSession=$projectName;Register-AtaraxiaGuiViewAction $Port $newSessionTarget 'activate' {& $OnAction 'new_session' $projectForSession}.GetNewClosure();[Windows.Controls.DockPanel]::SetDock($newSession,[Windows.Controls.Dock]::Right)
        $projectMenu=[Windows.Controls.ContextMenu]::new();$renameItem=[Windows.Controls.MenuItem]::new();$renameItem.Header=& $GetText 'gui_rename_project';$renameTarget='project-rename:'+ $projectName;Register-AtaraxiaGuiViewTarget $Port $renameTarget $renameItem;$projectForRename=$projectName;Register-AtaraxiaGuiViewAction $Port $renameTarget 'activate' {& $OnAction 'rename_project' $projectForRename}.GetNewClosure();$projectMenu.Items.Add($renameItem)|Out-Null;$projectText.ContextMenu=$projectMenu
        $header.Children.Add($newSession)|Out-Null;$header.Children.Add($choose)|Out-Null;$header.Children.Add($projectText)|Out-Null;$node.Header=$header
        $treeTarget='project-tree:'+ $projectName;Register-AtaraxiaGuiViewTarget $Port $treeTarget $node;Register-AtaraxiaGuiViewAction $Port $treeTarget 'expanded_change' {param($expanded)$ExpandedState[$projectName]=[bool]$expanded}.GetNewClosure()
        $sessionList=[Windows.Controls.StackPanel]::new();$sessionList.Margin=[Windows.Thickness]::new(16,0,0,2);$sessions=@($project.sessions)
        foreach($session in $sessions){$button=[Windows.Controls.Button]::new();$button.Content=[string]$session.title;$button.Tag=$session;$button.HorizontalContentAlignment='Left';$button.Padding=[Windows.Thickness]::new(6,4,4,4);$button.Margin=[Windows.Thickness]::new(0,1,0,1);$button.SetResourceReference([Windows.Controls.Control]::BackgroundProperty,'PanelBrush');$button.SetResourceReference([Windows.Controls.Control]::ForegroundProperty,'PrimaryTextBrush');$button.Style=$Owner.Resources['IconButtonHover'];$sessionCopy=$session;$projectCopy=$projectName;$target='session:'+ $projectName+':'+[string]$session.id;Register-AtaraxiaGuiViewTarget $Port $target $button;Register-AtaraxiaGuiViewAction $Port $target 'activate' {& $OnAction 'select_session' ([pscustomobject]@{project_name=$projectCopy;session=$sessionCopy})}.GetNewClosure();$sessionList.Children.Add($button)|Out-Null}
        if($sessions.Count -eq 0){$empty=[Windows.Controls.TextBlock]::new();$empty.Text=& $GetText 'gui_no_sessions';$empty.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,'SecondaryTextBrush');$empty.Margin=[Windows.Thickness]::new(6,4,2,4);$sessionList.Children.Add($empty)|Out-Null}
        $node.Content=$sessionList;Enable-AtaraxiaWpfSmoothExpander $node $Port $SmoothExpanderRegistry;$ProjectTreePanel.Children.Add($node)|Out-Null
    }
    $RecentSessionsPanel.Children.Clear();$RecentSessionsTitle.Text=& $GetText 'gui_recent_sessions';$recent=@($ViewModel.recent_sessions)
    foreach($session in $recent){$button=[Windows.Controls.Button]::new();$button.Content=[string]$session.title;$button.Tag=$session;$button.HorizontalContentAlignment='Left';$button.Padding=[Windows.Thickness]::new(6,4,4,4);$button.Margin=[Windows.Thickness]::new(0,1,0,1);$button.SetResourceReference([Windows.Controls.Control]::BackgroundProperty,'PanelBrush');$button.SetResourceReference([Windows.Controls.Control]::ForegroundProperty,'PrimaryTextBrush');$button.Style=$Owner.Resources['IconButtonHover'];$sessionCopy=$session;$target='recent-session:'+ [string]$session.id;Register-AtaraxiaGuiViewTarget $Port $target $button;Register-AtaraxiaGuiViewAction $Port $target 'activate' {& $OnAction 'select_session' ([pscustomobject]@{project_name=[string]$sessionCopy.project_name;session=$sessionCopy})}.GetNewClosure();$RecentSessionsPanel.Children.Add($button)|Out-Null}
    if($recent.Count -eq 0){$empty=[Windows.Controls.TextBlock]::new();$empty.Text=& $GetText 'gui_no_recent_sessions';$empty.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,'SecondaryTextBrush');$empty.Margin=[Windows.Thickness]::new(6,4,2,4);$RecentSessionsPanel.Children.Add($empty)|Out-Null}
    $RecentSessionsExpander.IsExpanded=$RecentSessionsExpanded
}
