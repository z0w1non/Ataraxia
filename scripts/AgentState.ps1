Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Localization.ps1')
. (Join-Path $PSScriptRoot 'StructuredData.ps1')
. (Join-Path $PSScriptRoot 'RoleContracts.ps1')
. (Join-Path $PSScriptRoot 'WorkspaceFileStorePort.ps1')
. (Join-Path $PSScriptRoot 'AgentWorkflow.ps1')

function Agent-SaveState([string]$Path, [object]$State,[string]$JournalPath='',[object]$FileStore) {
    $temporaryPath = "$Path.tmp"
    $json = $State | ConvertTo-Json -Depth 40
    if([Text.Encoding]::UTF8.GetByteCount($json) -gt 2097152){throw 'Task state exceeds the 2 MiB safety limit.'}
    if(-not [string]::IsNullOrWhiteSpace($JournalPath)){Update-AgentChangeJournalState $JournalPath $json $FileStore}
    Ensure-AgentWorkspaceStoreDirectory $FileStore (Split-Path -Parent $Path)
    Write-AgentWorkspaceStoreBytes $FileStore $temporaryPath ([System.Text.UTF8Encoding]::new($false).GetBytes($json))
    Move-AgentWorkspaceStoreFile $FileStore $temporaryPath $Path -Force
}

function Agent-ValidateState([object]$State, [object]$Task) {
    $workflow = $Task.workflow
    if ($State -isnot [System.Management.Automation.PSCustomObject] -and $State -isnot [System.Collections.IDictionary]) { throw (Get-AppText 'state_object_invalid') }
    $cycleProperty = $State.PSObject.Properties['cycle']
    if ($null -eq $cycleProperty) { throw (Get-AppText 'state_cycle_invalid') }
    $cycleValue = $cycleProperty.Value
    $cycleIsInteger = $cycleValue -is [byte] -or $cycleValue -is [int16] -or $cycleValue -is [int] -or $cycleValue -is [long]
    if (-not $cycleIsInteger -or [long]$cycleValue -lt 0) { throw (Get-AppText 'state_cycle_invalid') }
    $phaseProperty = $State.PSObject.Properties['phase']
    if ($null -eq $phaseProperty -or [string]::IsNullOrWhiteSpace([string]$phaseProperty.Value)) { throw (Get-AppText 'state_phase_missing') }
    $historyProperty = $State.PSObject.Properties['history']
    if ($null -eq $historyProperty -or $null -eq $historyProperty.Value) { $State | Add-Member -NotePropertyName history -NotePropertyValue @() -Force }
    $resultsProperty = $State.PSObject.Properties['results']
    if ($null -eq $resultsProperty) { $State | Add-Member -NotePropertyName results -NotePropertyValue ([pscustomobject]@{}) -Force }
    if ($State.history -isnot [System.Array] -and $State.history -isnot [System.Collections.IList]) { throw (Get-AppText 'state_history_invalid') }
    foreach ($entry in $State.history) {
        if ($null -eq $entry) { throw (Get-AppText 'state_history_entry_invalid') }
        $entryCycle = Get-StructuredProperty $entry 'cycle'
        $entryPhase = Get-StructuredProperty $entry 'phase'
        $entryRole = Get-StructuredProperty $entry 'role'
        $entryResult = Get-StructuredProperty $entry 'result'
        if (-not $entryCycle.exists -or -not $entryPhase.exists -or -not $entryRole.exists -or -not $entryResult.exists) { throw (Get-AppText 'state_history_entry_invalid') }
        $entryCycleIsInteger = $entryCycle.value -is [byte] -or $entryCycle.value -is [int16] -or $entryCycle.value -is [int] -or $entryCycle.value -is [long]
        if (-not $entryCycleIsInteger -or [long]$entryCycle.value -lt 0 -or [string]::IsNullOrWhiteSpace([string]$entryPhase.value) -or [string]::IsNullOrWhiteSpace([string]$entryRole.value)) { throw (Get-AppText 'state_history_entry_invalid') }
        if ($entryResult.value -isnot [System.Management.Automation.PSCustomObject] -and $entryResult.value -isnot [System.Collections.IDictionary]) { throw (Get-AppText 'state_history_entry_invalid') }
        foreach ($historyListName in @('files_changed','commands_run')) {
            $historyList = Get-StructuredProperty $entry $historyListName
            if ($historyList.exists -and $historyList.value -isnot [System.Array] -and $historyList.value -isnot [System.Collections.IList]) { throw (Get-AppText 'state_history_entry_invalid') }
        }
    }
    if ($null -ne $workflow) {
        $validPhases = @($workflow.stages | ForEach-Object { [string]$_.id }) + @([string]$workflow.terminal_state)
        foreach($specialStateName in @('waiting_state','replan_state')){$specialState=Get-StructuredProperty $workflow $specialStateName;if($specialState.exists -and -not [string]::IsNullOrWhiteSpace([string]$specialState.value)){$validPhases+=@([string]$specialState.value)}}
        if ($validPhases -notcontains [string]$State.phase) { throw (Get-AppText 'state_phase_invalid' @([string]$State.phase)) }
        foreach ($entry in $State.history) {
            $entryStage = Agent-GetWorkflowStage $workflow ([string](Get-StructuredProperty $entry 'phase').value)
            if ($null -eq $entryStage -or [string](Get-StructuredProperty $entry 'role').value -ne [string]$entryStage.role_id) { throw (Get-AppText 'state_history_entry_invalid') }
            $entryRole = @($Task.roles | Where-Object { [string]$_.id -eq [string]$entryStage.role_id })[0]
            Assert-JsonSchema (Get-StructuredProperty $entry 'result').value $entryRole.output_schema
        }
    }
    if ($State.results -isnot [System.Management.Automation.PSCustomObject] -and $State.results -isnot [System.Collections.IDictionary]) { throw (Get-AppText 'state_results_invalid') }
    $resultEntries = if ($State.results -is [System.Collections.IDictionary]) { @($State.results.Keys | ForEach-Object { [pscustomobject]@{ key=[string]$_; value=$State.results[$_] } }) } else { @($State.results.PSObject.Properties | ForEach-Object { [pscustomobject]@{ key=$_.Name; value=$_.Value } }) }
    foreach ($resultEntry in $resultEntries) {
        if ($resultEntry.value -isnot [System.Management.Automation.PSCustomObject] -and $resultEntry.value -isnot [System.Collections.IDictionary]) { throw (Get-AppText 'state_results_invalid') }
        if ($null -ne $workflow) {
            $resultStage = @($workflow.stages | Where-Object { [string]$_.result_key -eq [string]$resultEntry.key })[0]
            if ($null -eq $resultStage) { throw (Get-AppText 'state_result_key_invalid' @([string]$resultEntry.key)) }
            $resultRole = @($Task.roles | Where-Object { [string]$_.id -eq [string]$resultStage.role_id })[0]
            Assert-JsonSchema $resultEntry.value $resultRole.output_schema
        }
    }
    if ($null -ne $State.PSObject.Properties['phase_result']) { $State.PSObject.Properties.Remove('phase_result') }
    return $State
}
