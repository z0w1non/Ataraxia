Set-StrictMode -Version Latest

function New-AtaraxiaGuiNavigationState {
    return [pscustomobject][ordered]@{page='conversation';project_drawer_open=$true}
}

function Set-AtaraxiaGuiNavigationState([object]$State,[ValidateSet('open_settings','close_settings')][string]$Action) {
    if($null -eq $State -or $null -eq $State.PSObject.Properties['page'] -or $null -eq $State.PSObject.Properties['project_drawer_open']){throw 'GUI navigation state is invalid.'}
    $next=if($Action -eq 'open_settings'){[pscustomobject][ordered]@{page='settings';project_drawer_open=$false}}else{[pscustomobject][ordered]@{page='conversation';project_drawer_open=$true}}
    $visibility=[pscustomobject][ordered]@{conversation_page=($next.page -eq 'conversation');settings_panel=($next.page -eq 'settings');project_drawer=[bool]$next.project_drawer_open}
    return [pscustomobject][ordered]@{state=$next;visibility=$visibility}
}
