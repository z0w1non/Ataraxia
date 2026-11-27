Set-StrictMode -Version Latest

function New-AtaraxiaGuiScreenState {
    return [pscustomobject][ordered]@{
        task_path=''
        editing=$false
        pending_session_project=''
        project_tree_expanded=@{}
        recent_sessions_expanded=$false
    }
}

function Reset-AtaraxiaGuiScreenTask([object]$State) {
    if($null -eq $State){throw 'GUI screen state is required.'}
    $next=New-AtaraxiaGuiScreenState
    $next.project_tree_expanded=$State.project_tree_expanded
    $next.recent_sessions_expanded=$State.recent_sessions_expanded
    return $next
}

function Set-AtaraxiaGuiScreenTask([object]$State,[string]$TaskPath) {
    if($null -eq $State){throw 'GUI screen state is required.'}
    if([string]::IsNullOrWhiteSpace($TaskPath)){throw 'GUI screen task path is required.'}
    $State.task_path=[IO.Path]::GetFullPath($TaskPath)
    $State.editing=$false
    $State.pending_session_project=''
    return $State
}
