Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Localization.ps1')
. (Join-Path $PSScriptRoot 'StructuredData.ps1')
. (Join-Path $PSScriptRoot 'WorkspaceFileStorePort.ps1')
. (Join-Path $PSScriptRoot 'RoleContracts.ps1')
. (Join-Path $PSScriptRoot 'CommonPrompts.ps1')
. (Join-Path $PSScriptRoot 'AgentWorkflow.ps1')
. (Join-Path $PSScriptRoot 'AgentRoleExecution.ps1')
. (Join-Path $PSScriptRoot 'AgentState.ps1')
. (Join-Path $PSScriptRoot 'AgentValidation.ps1')

function Agent-NewTaskTemplate([string]$Name, [object]$RoleContracts = $null) {
    if ($null -eq $RoleContracts) { $RoleContracts = Import-RoleContracts ([pscustomobject]@{}) }
    $roleSpecs = @($RoleContracts.generic_agent.roles | ForEach-Object {
        [pscustomobject][ordered]@{
            id=[string]$_.id
            system_prompt=[string]$_.system_prompt
            purpose=[string]$_.purpose
            input_schema=Resolve-RoleContractSchema $RoleContracts $_.input_schema_ref
            output_schema=Resolve-RoleContractSchema $RoleContracts $_.output_schema_ref
        }
    })
    $stages = @(
        @{ id='Core'; role_id='core'; result_key='workflow_design'; allowed_next_stages=@('Core'); default_next='Core'; transitions=@(@{ next='Core' }) },
        @{ id='Route'; role_id='router'; result_key='routing'; dynamic_transition_field='next_stage'; route_options_from_previous=$true; transitions=@() }
    )
    return [ordered]@{ name=$Name; goal=''; context=''; constraints=@(); working_directory=''; workflow=[ordered]@{ initial_stage='Core'; terminal_state='Complete'; waiting_state='AwaitUser'; replan_state='ReplanCore'; max_core_replans_per_query=2; stages=$stages }; roles=$roleSpecs }
}

function Agent-EnsureCoreWorkflow([object]$Task,[object]$RoleContracts) {
    $changed=$false
    foreach($roleId in @('core','router')){
        $contract=@($RoleContracts.generic_agent.roles|Where-Object{$_.id -eq $roleId}|Select-Object -First 1)
        if($contract.Count -eq 0){throw "Required system role contract is missing: $roleId"}
        $existing=@($Task.roles|Where-Object{$_.id -eq $roleId}|Select-Object -First 1)
        if($existing.Count -eq 0){
            $Task.roles=@($Task.roles)+@([pscustomobject][ordered]@{id=$roleId;system_prompt=[string]$contract[0].system_prompt;purpose=[string]$contract[0].purpose;input_schema=Resolve-RoleContractSchema $RoleContracts $contract[0].input_schema_ref;output_schema=Resolve-RoleContractSchema $RoleContracts $contract[0].output_schema_ref})
            $changed=$true
        }
    }
    $stages=@($Task.workflow.stages);$core=@($stages|Where-Object{$_.id -eq 'Core'}|Select-Object -First 1);$route=@($stages|Where-Object{$_.id -eq 'Route'}|Select-Object -First 1)
    if($null -eq $Task.workflow.PSObject.Properties['waiting_state']){$Task.workflow|Add-Member -NotePropertyName waiting_state -NotePropertyValue 'AwaitUser' -Force;$changed=$true}
    if($null -eq $Task.workflow.PSObject.Properties['replan_state']){$Task.workflow|Add-Member -NotePropertyName replan_state -NotePropertyValue 'ReplanCore' -Force;$changed=$true}
    if($null -eq $Task.workflow.PSObject.Properties['max_core_replans_per_query']){$Task.workflow|Add-Member -NotePropertyName max_core_replans_per_query -NotePropertyValue 2 -Force;$changed=$true}
    if($core.Count -eq 0){
        $oldInitial=[string]$Task.workflow.initial_stage
        $stages=@([pscustomobject][ordered]@{id='Core';role_id='core';result_key='workflow_design';allowed_next_stages=@($oldInitial);default_next=$oldInitial;transitions=@(@{next=$oldInitial})})+@($stages)
        $Task.workflow.initial_stage='Core';$changed=$true
    }elseif([string]$core[0].role_id -ne 'core'){throw 'The reserved Core stage is assigned to another role.'}
    if($route.Count -eq 0){$stages+=@([pscustomobject][ordered]@{id='Route';role_id='router';result_key='routing';dynamic_transition_field='next_stage';route_options_from_previous=$true;transitions=@()});$changed=$true}
    $Task.workflow.stages=$stages
    return $changed
}

function Agent-InstallDesignedWorkflow([object]$Task,[object]$CoreResult,[object]$State=$null) {
    $design=Get-StructuredProperty $CoreResult 'workflow'
    if(-not $design.exists){throw 'Core role did not provide a workflow design.'}
    $initial=[string](Get-StructuredProperty $design.value 'initial_stage').value
    $specs=@((Get-StructuredProperty $design.value 'stages').value)
    if($specs.Count -lt 1 -or $specs.Count -gt 16){throw 'Designed workflow must contain between 1 and 16 stages.'}
    $roleIds=@($Task.roles|ForEach-Object{[string]$_.id})
    $internalRoles=@('core','router','reporter','context_compressor','session_namer')
    $requestNumber=1
    if($null -ne $Task.workflow.PSObject.Properties['request_count']){$requestNumber=[int]$Task.workflow.request_count+1}
    $prefix="Q${requestNumber}_";$resultPrefix="q${requestNumber}_"
    $mappedIds=@{};$mappedKeys=@{};$stages=[System.Collections.Generic.List[object]]::new()
    $terminalState=[string]$Task.workflow.terminal_state
    foreach($spec in $specs){
        $id=[string]$spec.id;$roleId=[string]$spec.role_id;$resultKey=[string]$spec.result_key
        if($id -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,31}$' -or $id -in @('Core','Route','Complete','AwaitUser','ReplanCore') -or $mappedIds.ContainsKey($id)){throw "Core returned an invalid or duplicate workflow stage id: $id"}
        if($resultKey -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,47}$' -or $resultKey -eq 'workflow_design' -or $mappedKeys.ContainsKey($resultKey)){throw "Core returned an invalid or duplicate result key: $resultKey"}
        if($roleId -notin $roleIds -or $roleId -in $internalRoles){throw "Core selected a role that is not available for workflow work: $roleId"}
        $mappedId=$prefix+$id;if($mappedId.Length -gt 32){$mappedId=$mappedId.Substring(0,32)}
        $mappedKey=$resultPrefix+$resultKey;if($mappedKey.Length -gt 48){$mappedKey=$mappedKey.Substring(0,48)}
        if($mappedId -in $mappedIds.Values -or $mappedKey -in $mappedKeys.Values){throw 'Core workflow stage ids or result keys collide after request namespacing.'}
        $mappedIds[$id]=$mappedId;$mappedKeys[$resultKey]=$mappedKey
    }
    if(-not $mappedIds.ContainsKey($initial)){throw "Core selected an initial stage that is not defined: $initial"}
    foreach($spec in $specs){
        $originalId=[string]$spec.id;$id=[string]$mappedIds[$originalId];$roleId=[string]$spec.role_id;$resultKey=[string]$mappedKeys[[string]$spec.result_key]
        $next=@($spec.next_stages|ForEach-Object{if($_ -eq 'Complete'){$terminalState}elseif($_ -eq 'AwaitUser'){'AwaitUser'}elseif($_ -eq 'ReplanCore'){'ReplanCore'}elseif($mappedIds.ContainsKey([string]$_)){[string]$mappedIds[[string]$_]}else{throw "Workflow stage '$originalId' points to an unknown next stage: $_"}})
        if($next.Count -eq 0){throw "Workflow stage '$originalId' has no next stages."}
        $stage=[ordered]@{id=$id;role_id=$roleId;result_key=$resultKey;allowed_next_stages=$next;default_next='Route';transitions=@(@{next='Route'})}
        if($roleId -eq 'executor'){$stage.changes_field='file_changes';$stage.commands_field='commands'}
        if($roleId -eq 'improver'){$stage.increment_cycle=$true}
        $stages.Add([pscustomobject]$stage)
    }
    $mappedInitial=[string]$mappedIds[$initial]
    $reachable=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $pending=[System.Collections.Generic.Queue[string]]::new();$pending.Enqueue($mappedInitial)
    while($pending.Count -gt 0){$current=$pending.Dequeue();if(-not $reachable.Add($current)){continue};$currentStage=@($stages|Where-Object{$_.id -ceq $current})[0];foreach($target in @($currentStage.allowed_next_stages)){if($target -ne $terminalState -and $target -notin @('AwaitUser','ReplanCore')){$pending.Enqueue([string]$target)}}}
    foreach($stage in $stages){if(-not $reachable.Contains([string]$stage.id)){throw "Workflow stage '$($stage.id)' is unreachable from '$mappedInitial'."}}
    foreach($id in @($stages|ForEach-Object{[string]$_.id})){
        $canComplete=$false;$seen=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$todo=[System.Collections.Generic.Stack[string]]::new();$todo.Push($id)
        while($todo.Count -gt 0){$current=$todo.Pop();$currentStage=@($stages|Where-Object{$_.id -ceq $current})[0];foreach($target in @($currentStage.allowed_next_stages)){if($target -eq $terminalState){$canComplete=$true;break};if($target -notin @('AwaitUser','ReplanCore') -and $seen.Add([string]$target)){$todo.Push([string]$target)}};if($canComplete){break}}
        if(-not $canComplete){throw "No completion path exists from workflow stage '$id'."}
    }
    $coreStage=Agent-GetWorkflowStage $Task.workflow 'Core';$coreStage.allowed_next_stages=@($mappedInitial);$coreStage.default_next=$mappedInitial;$coreStage.transitions=@(@{next=$mappedInitial})
    $routeStage=Agent-GetWorkflowStage $Task.workflow 'Route'
    $retainedStages=[System.Collections.Generic.List[object]]::new()
    if($null -ne $State){
        $usedStageIds=@($State.history|ForEach-Object{[string]$_.phase});$usedResultKeys=@($State.results.PSObject.Properties.Name)
        foreach($oldStage in @($Task.workflow.stages)){if($oldStage.id -in @('Core','Route')){continue};if($oldStage.id -in $usedStageIds -or $oldStage.result_key -in $usedResultKeys){$retainedStages.Add($oldStage)}}
    }
    $requestId=if($null -ne $State -and $null -ne $State.PSObject.Properties['core_request_id']){[string]$State.core_request_id}else{[guid]::NewGuid().ToString('N')}
    $Task|Add-Member -NotePropertyName core_request_goal -NotePropertyValue ([string]$Task.goal) -Force
    $Task.workflow=[pscustomobject][ordered]@{initial_stage='Core';terminal_state='Complete';waiting_state='AwaitUser';replan_state='ReplanCore';max_core_replans_per_query=2;core_configured=$true;request_count=$requestNumber;core_request_id=$requestId;stages=@($coreStage)+@($retainedStages.ToArray())+@($stages.ToArray())+@($routeStage)}
    Agent-ValidateTask $Task
    return $Task
}
