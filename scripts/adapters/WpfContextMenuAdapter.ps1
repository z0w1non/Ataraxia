Set-StrictMode -Version Latest

function New-AtaraxiaWpfSessionContextMenu([Windows.Controls.Button]$Owner,[object]$Presentation) {
    if($null -eq $Owner -or $null -eq $Presentation -or $null -eq $Presentation.menu_labels){throw 'Session context menu adapter requires a button and localized presentation data.'}
    $menu=[Windows.Controls.ContextMenu]::new();$items=[ordered]@{}
    foreach($entry in @(@('copy_session_id','copy_session_id'),@('rename_session','rename_session'),@('session_prompt','session_prompt'))){$item=[Windows.Controls.MenuItem]::new();$item.Tag=[string]$entry[0];$item.Header=[string]$Presentation.menu_labels.($entry[1]);$menu.Items.Add($item)|Out-Null;$items[[string]$entry[0]]=$item}
    $Owner.ContextMenu=$menu
    return [pscustomobject][ordered]@{menu=$menu;copy_session_id=$items.copy_session_id;rename_session=$items.rename_session;session_prompt=$items.session_prompt}
}

function Set-AtaraxiaWpfSessionContextMenuLanguage([object]$Menu,[object]$Presentation) {
    if($null -eq $Menu -or $null -eq $Presentation -or $null -eq $Presentation.menu_labels){throw 'Session context menu localization requires menu items and presentation data.'}
    $labels=$Presentation.menu_labels
    $Menu.copy_session_id.Header=[string]$labels.copy_session_id;$Menu.rename_session.Header=[string]$labels.rename_session;$Menu.session_prompt.Header=[string]$labels.session_prompt
}

function Register-AtaraxiaWpfConversationCopyMenus([Windows.Controls.ItemsControl]$Conversation,[object]$Port,[string]$CopyLabel) {
    if($null -eq $Conversation -or $null -eq $Port -or [string]::IsNullOrWhiteSpace($CopyLabel)){throw 'Conversation copy menu adapter requires a view, view port, and localized copy label.'}
    $registered=0
    foreach($item in $Conversation.Items){
        if($item.kind -ne 'user'){continue}
        $container=$Conversation.ItemContainerGenerator.ContainerFromItem($item);if($null -eq $container){continue}
        $pending=[System.Collections.Generic.Stack[Windows.DependencyObject]]::new();$pending.Push($container)
        while($pending.Count -gt 0){
            $parent=$pending.Pop()
            if($parent -is [Windows.Controls.TextBox] -and $null -ne $parent.ContextMenu){
                $menuItem=$parent.ContextMenu.Items[0];$menuItem.Header=$CopyLabel;$copyTarget=$parent;$copyTargetKey='request-copy:'+ [string][Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($parent)
                if([string]$menuItem.Tag -cne $copyTargetKey){Register-AtaraxiaGuiViewTarget $Port $copyTargetKey $menuItem;$handler={Set-AtaraxiaGuiClipboardText $Port ([string]$copyTarget.Text)}.GetNewClosure();Register-AtaraxiaGuiViewAction $Port $copyTargetKey 'activate' $handler;$menuItem.Tag=$copyTargetKey;$registered++}
                continue
            }
            $childCount=[Windows.Media.VisualTreeHelper]::GetChildrenCount($parent)
            for($childIndex=0;$childIndex -lt $childCount;$childIndex++){$child=[Windows.Media.VisualTreeHelper]::GetChild($parent,$childIndex);if($null -ne $child){$pending.Push($child)}}
        }
    }
    return $registered
}
