Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Localization.ps1')
. (Join-Path $PSScriptRoot 'StructuredData.ps1')

function Agent-GetWorkflowStage([object]$Workflow, [string]$StageId) {
    return @($Workflow.stages | Where-Object { [string]$_.id -eq $StageId })[0]
}

function Agent-GetRoutingOptions([object]$Task, [object]$State) {
    if (@($State.history).Count -eq 0) { return @() }
    $latest = @($State.history)[-1]
    $previousStage = Agent-GetWorkflowStage $Task.workflow ([string]$latest.phase)
    $allowedTargets = Get-StructuredProperty $previousStage 'allowed_next_stages'
    if ($null -eq $previousStage -or -not $allowedTargets.exists) { return @() }
    $targets = @($allowedTargets.value | ForEach-Object { [string]$_ })
    if ([string](Get-StructuredProperty $previousStage 'role_id').value -eq 'reviewer') {
        $approved = Get-StructuredProperty $latest.result 'approved'
        if ($approved.exists -and [bool]$approved.value) { $targets = @($targets | Where-Object { $_ -eq [string]$Task.workflow.terminal_state }) }
        else { $targets = @($targets | Where-Object { $_ -ne [string]$Task.workflow.terminal_state }) }
    }
    $waitingState=Get-StructuredProperty $Task.workflow 'waiting_state'
    if($waitingState.exists){$targets+=@([string]$waitingState.value)}
    $replanState=Get-StructuredProperty $Task.workflow 'replan_state'
    $replanCount=Get-StructuredProperty $State 'core_replans_this_query'
    $replanLimit=Get-StructuredProperty $Task.workflow 'max_core_replans_per_query'
    if($replanState.exists -and [int]$(if($replanCount.exists){$replanCount.value}else{0}) -lt [int]$(if($replanLimit.exists){$replanLimit.value}else{2})){$targets+=@([string]$replanState.value)}
    $options = foreach ($target in $targets) {
        if ($target -eq [string]$Task.workflow.terminal_state) { [pscustomobject][ordered]@{ id=$target; role_id=''; purpose='Task terminal state' }; continue }
        if($waitingState.exists -and $target -eq [string]$waitingState.value){[pscustomobject][ordered]@{id=$target;role_id='';purpose='Wait for additional user input; resume planning when it arrives.'};continue}
        if($replanState.exists -and $target -eq [string]$replanState.value){[pscustomobject][ordered]@{id=$target;role_id='';purpose='Return to Core to redesign a workflow using accumulated results.'};continue}
        $stage = Agent-GetWorkflowStage $Task.workflow $target
        if ($null -eq $stage) { continue }
        $stageRoleId = [string](Get-StructuredProperty $stage 'role_id').value
        $role = @($Task.roles | Where-Object { [string](Get-StructuredProperty $_ 'id').value -eq $stageRoleId })[0]
        [pscustomobject][ordered]@{ id=$target; role_id=$stageRoleId; purpose=[string](Get-StructuredProperty $role 'purpose').value }
    }
    return @($options)
}

function Agent-ResolveTransition([object]$Workflow, [object]$Stage, [object]$Result) {
    $dynamicField = Get-StructuredProperty $Stage 'dynamic_transition_field'
    if ($dynamicField.exists) {
        $selected = Get-StructuredProperty $Result ([string]$dynamicField.value)
        $target = if ($selected.exists) { [string]$selected.value } else { '' }
        $candidateProperty = Get-StructuredProperty $Stage 'allowed_next_stages'
        $candidates = if ($candidateProperty.exists) { @($candidateProperty.value) } else { @() }
        if ([string]::IsNullOrWhiteSpace($target) -or $candidates -notcontains $target) { throw (Get-AppText 'transition_unmatched' @([string]$Stage.id)) }
        $waitingState=Get-StructuredProperty $Workflow 'waiting_state'
        $replanState=Get-StructuredProperty $Workflow 'replan_state'
        if ($target -ne [string]$Workflow.terminal_state -and (-not $waitingState.exists -or $target -ne [string]$waitingState.value) -and (-not $replanState.exists -or $target -ne [string]$replanState.value) -and $null -eq (Agent-GetWorkflowStage $Workflow $target)) { throw (Get-AppText 'transition_unmatched' @([string]$Stage.id)) }
        return $target
    }
    foreach ($transition in @($Stage.transitions)) {
        $field = Get-StructuredProperty $transition 'field'
        if (-not $field.exists -or [string]::IsNullOrWhiteSpace([string]$field.value)) { return [string]$transition.next }
        $property = Get-StructuredProperty $Result ([string]$field.value)
        $expected = Get-StructuredProperty $transition 'equals'
        if ($property.exists -and $expected.exists) {
            $matches = if ($property.value -is [bool] -and $expected.value -is [bool]) { $property.value -eq $expected.value } else { [string]$property.value -ieq [string]$expected.value }
            if ($matches) { return [string]$transition.next }
        }
    }
    $defaultNext = if ($null -ne $Stage.PSObject.Properties['default_next']) { [string]$Stage.default_next } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($defaultNext)) { return $defaultNext }
    throw (Get-AppText 'transition_unmatched' @([string]$Stage.id))
}

function Agent-NextState([object]$State, [object]$Workflow, [object]$Stage, [object]$Result) {
    $State.results | Add-Member -NotePropertyName ([string]$Stage.result_key) -NotePropertyValue $Result -Force
    if ($null -ne $Stage.PSObject.Properties['increment_cycle'] -and [bool]$Stage.increment_cycle) { $State.cycle = [int]$State.cycle + 1 }
    $State.phase = Agent-ResolveTransition $Workflow $Stage $Result
    return $State
}
