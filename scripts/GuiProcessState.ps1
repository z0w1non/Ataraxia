Set-StrictMode -Version Latest

function New-AtaraxiaGuiProcessState {
    return [pscustomobject][ordered]@{phase='idle';output_line_count=0;current_role='';exit_code=$null}
}

function Assert-AtaraxiaGuiProcessState([object]$State) {
    if($null -eq $State -or $null -eq $State.PSObject.Properties['phase'] -or $null -eq $State.PSObject.Properties['output_line_count'] -or $null -eq $State.PSObject.Properties['current_role'] -or $null -eq $State.PSObject.Properties['exit_code']){throw 'GUI process state is invalid.'}
}

function Start-AtaraxiaGuiProcessState([object]$State) {
    Assert-AtaraxiaGuiProcessState $State
    if($State.phase -eq 'running'){throw 'A GUI process is already running.'}
    $State.phase='running';$State.output_line_count=0;$State.current_role='';$State.exit_code=$null
    return $State
}

function Update-AtaraxiaGuiProcessState([object]$State,[object]$Update) {
    Assert-AtaraxiaGuiProcessState $State
    if($State.phase -ne 'running'){throw 'GUI process output can only update a running process.'}
    if($null -eq $Update -or $null -eq $Update.PSObject.Properties['next_index'] -or $null -eq $Update.PSObject.Properties['role_events']){throw 'GUI process output update is invalid.'}
    $nextIndex=0
    if(-not [int]::TryParse([string]$Update.next_index,[ref]$nextIndex) -or $nextIndex -lt [int]$State.output_line_count){throw 'GUI process output cursor cannot move backwards.'}
    $role=[string]$State.current_role
    foreach($event in @($Update.role_events)){if($null -eq $event -or [string]::IsNullOrWhiteSpace([string]$event.role)){throw 'GUI process role event is invalid.'};$role=[string]$event.role}
    $State.output_line_count=$nextIndex;$State.current_role=$role
    return $State
}

function Complete-AtaraxiaGuiProcessState([object]$State,[int]$ExitCode) {
    Assert-AtaraxiaGuiProcessState $State
    if($State.phase -ne 'running'){throw 'Only a running GUI process can complete.'}
    $State.phase='completed';$State.current_role='';$State.exit_code=$ExitCode
    return $State
}

function Stop-AtaraxiaGuiProcessState([object]$State) {
    Assert-AtaraxiaGuiProcessState $State
    if($State.phase -ne 'running'){throw 'Only a running GUI process can stop.'}
    $State.phase='stopped';$State.current_role='';$State.exit_code=$null
    return $State
}
