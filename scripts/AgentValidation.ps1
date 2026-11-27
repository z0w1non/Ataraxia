Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Localization.ps1')
. (Join-Path $PSScriptRoot 'StructuredData.ps1')
. (Join-Path $PSScriptRoot 'RoleContracts.ps1')
. (Join-Path $PSScriptRoot 'AgentWorkflow.ps1')

function Assert-AgentPositiveInteger([object]$Value,[string]$SettingName) {
    if (($Value -isnot [byte] -and $Value -isnot [int16] -and $Value -isnot [int] -and $Value -isnot [long]) -or [long]$Value -lt 1) { throw "$SettingName must be a positive integer." }
}

function Agent-ValidateExecutionConfig([object]$Config) {
    if ($Config -isnot [System.Management.Automation.PSCustomObject] -and $Config -isnot [System.Collections.IDictionary]) { throw 'Execution config must be an object.' }
    $format=Get-StructuredProperty $Config 'llm_input_format'
    if($format.exists -and ([string]$format.value).ToLowerInvariant() -notin @('json','markdown')){throw 'llm_input_format must be json or markdown.'}
    $indent=Get-StructuredProperty $Config 'json_indent'
    if($indent.exists -and (($indent.value -isnot [byte] -and $indent.value -isnot [int16] -and $indent.value -isnot [int] -and $indent.value -isnot [long]) -or [int]$indent.value -lt 0 -or [int]$indent.value -gt 8)){throw 'json_indent must be an integer from 0 through 8.'}
    $retry=Get-StructuredProperty $Config 'json_retry_limit'
    if($retry.exists -and (($retry.value -isnot [byte] -and $retry.value -isnot [int16] -and $retry.value -isnot [int] -and $retry.value -isnot [long]) -or [long]$retry.value -lt -1)){throw 'json_retry_limit must be -1 or a non-negative integer.'}
    $override=Get-StructuredProperty $Config 'override'
    if($override.exists -and $null -ne $override.value){
        $contextSize=Get-StructuredProperty $override.value 'context_size';$responseTokens=Get-StructuredProperty $override.value 'max_tokens'
        if(-not $responseTokens.exists){$responseTokens=Get-StructuredProperty $override.value 'max_completion_tokens'}
        if(-not $contextSize.exists){throw 'override.context_size is required.'};Assert-AgentPositiveInteger $contextSize.value 'override.context_size'
        if(-not $responseTokens.exists){throw 'override.max_tokens or override.max_completion_tokens is required.'};Assert-AgentPositiveInteger $responseTokens.value 'override.max_tokens'
    }
    $compression=Get-StructuredProperty $Config 'context_compression'
    if($compression.exists -and $null -ne $compression.value){
        $enabled=Get-StructuredProperty $compression.value 'enabled'
        if($enabled.exists -and $enabled.value -isnot [bool]){throw 'context_compression.enabled must be a boolean.'}
        if($enabled.exists -and [bool]$enabled.value){
            foreach($name in @('trigger_tokens','target_tokens')){$value=Get-StructuredProperty $compression.value $name;if(-not $value.exists){throw "context_compression.$name is required when compression is enabled."};Assert-AgentPositiveInteger $value.value "context_compression.$name"}
            $role=Get-StructuredProperty $compression.value 'role_id';if(-not $role.exists -or [string]::IsNullOrWhiteSpace([string]$role.value)){throw 'context_compression.role_id is required when compression is enabled.'}
        }
    }
}

function Agent-ValidateTask([object]$Task) {
    if ($Task -isnot [System.Management.Automation.PSCustomObject] -and $Task -isnot [System.Collections.IDictionary]) { throw (Get-AppText 'task_object_invalid') }
    $nameProperty = Get-StructuredProperty $Task 'name'
    $goalProperty = Get-StructuredProperty $Task 'goal'
    $workingDirectoryProperty = Get-StructuredProperty $Task 'working_directory'
    $rolesProperty = Get-StructuredProperty $Task 'roles'
    $workflowProperty = Get-StructuredProperty $Task 'workflow'
    if (-not $nameProperty.exists -or [string]::IsNullOrWhiteSpace([string]$nameProperty.value)) { throw (Get-AppText 'task_name_required') }
    if (-not $goalProperty.exists -or [string]::IsNullOrWhiteSpace([string]$goalProperty.value)) { throw (Get-AppText 'task_goal_required') }
    if (-not $workingDirectoryProperty.exists -or [string]::IsNullOrWhiteSpace([string]$workingDirectoryProperty.value)) { throw (Get-AppText 'workspace_directory_required') }
    if (-not $rolesProperty.exists -or $rolesProperty.value -is [string] -or @($rolesProperty.value).Count -eq 0) { throw (Get-AppText 'task_role_required') }
    if (-not $workflowProperty.exists -or $null -eq $workflowProperty.value) { throw (Get-AppText 'workflow_required') }
    Assert-AgentPlainText ([string]$nameProperty.value) 'Task name' 128
    Assert-AgentPlainText ([string]$goalProperty.value) 'Task goal' -AllowMultiline
    $contextProperty=Get-StructuredProperty $Task 'context';if($contextProperty.exists){Assert-AgentPlainText ([string]$contextProperty.value) 'Task context' -AllowMultiline}
    $constraintProperty=Get-StructuredProperty $Task 'constraints';if($constraintProperty.exists){if($constraintProperty.value -is [string] -or @($constraintProperty.value).Count -gt 256){throw 'Task constraints must be an array containing at most 256 items.'};foreach($constraint in @($constraintProperty.value)){if($constraint -isnot [string]){throw 'Task constraints must be an array of strings.'};Assert-AgentPlainText $constraint 'Task constraint' -AllowMultiline}}
    $roleIds = @()
    foreach ($role in $rolesProperty.value) {
        $roleIdProperty = Get-StructuredProperty $role 'id'
        $systemPromptProperty = Get-StructuredProperty $role 'system_prompt'
        $purposeProperty = Get-StructuredProperty $role 'purpose'
        $inputSchemaProperty = Get-StructuredProperty $role 'input_schema'
        $schemaProperty = Get-StructuredProperty $role 'output_schema'
        if (-not $roleIdProperty.exists -or [string]::IsNullOrWhiteSpace([string]$roleIdProperty.value)) { throw (Get-AppText 'role_id_required') }
        $roleId = [string]$roleIdProperty.value
        if($roleId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'){throw (Get-AppText 'role_id_required')}
        if ($roleIds -contains $roleId) { throw (Get-AppText 'role_id_duplicate' @($roleId)) }
        $roleIds += $roleId
        if (-not $systemPromptProperty.exists -or [string]::IsNullOrWhiteSpace([string]$systemPromptProperty.value)) { throw (Get-AppText 'role_system_prompt_required' @($roleId)) }
        if (-not $purposeProperty.exists -or [string]::IsNullOrWhiteSpace([string]$purposeProperty.value)) { throw (Get-AppText 'role_purpose_required' @($roleId)) }
        Assert-AgentPlainText ([string]$purposeProperty.value) "Role '$roleId' purpose" -AllowMultiline
        $promptName=[string]$systemPromptProperty.value
        if($promptName.Length -gt 128 -or $promptName -match '[\\/:\x00-\x1F\x7F]' -or $promptName -in @('.','..')){throw "Role '$roleId' has an unsafe system prompt name."}
        foreach ($contractSchema in @(@{ property=$inputSchemaProperty }, @{ property=$schemaProperty })) {
            if (-not $contractSchema.property.exists) { throw (Get-AppText 'role_schema_invalid' @($roleId)) }
            $schema = $contractSchema.property.value
            $schemaType = Get-StructuredProperty $schema 'type'
            $schemaProperties = Get-StructuredProperty $schema 'properties'
            $schemaRequired = Get-StructuredProperty $schema 'required'
            if ($null -eq $schema -or -not $schemaType.exists -or $schemaType.value -ne 'object' -or -not $schemaProperties.exists -or @($schemaRequired.value).Count -eq 0) { throw (Get-AppText 'role_schema_invalid' @($roleId)) }
            foreach ($requiredName in $schemaRequired.value) { if (-not (Get-StructuredProperty $schemaProperties.value ([string]$requiredName)).exists) { throw (Get-AppText 'role_schema_key_missing' @($roleId, [string]$requiredName)) } }
        }
    }
    $workflow = $workflowProperty.value
    $stagesProperty = Get-StructuredProperty $workflow 'stages'
    if (-not $stagesProperty.exists -or @($stagesProperty.value).Count -eq 0) { throw (Get-AppText 'workflow_required') }
    $stages = @($stagesProperty.value)
    $stageIds = @($stages | ForEach-Object { [string](Get-StructuredProperty $_ 'id').value })
    if (@($stageIds | Select-Object -Unique).Count -ne $stageIds.Count) { throw (Get-AppText 'stage_id_unique') }
    $initialStage = Get-StructuredProperty $workflow 'initial_stage'
    $terminalState = Get-StructuredProperty $workflow 'terminal_state'
    $waitingState = Get-StructuredProperty $workflow 'waiting_state'
    if (-not $initialStage.exists -or [string]::IsNullOrWhiteSpace([string]$initialStage.value) -or $stageIds -notcontains [string]$initialStage.value) { throw (Get-AppText 'initial_stage_invalid') }
    if (-not $terminalState.exists -or [string]::IsNullOrWhiteSpace([string]$terminalState.value)) { throw (Get-AppText 'terminal_state_required') }
    if($waitingState.exists -and ([string]::IsNullOrWhiteSpace([string]$waitingState.value) -or [string]$waitingState.value -eq [string]$terminalState.value -or $stageIds -contains [string]$waitingState.value)){throw 'workflow.waiting_state must be a distinct non-stage state.'}
    $replanState=Get-StructuredProperty $workflow 'replan_state';if($replanState.exists -and ([string]::IsNullOrWhiteSpace([string]$replanState.value) -or [string]$replanState.value -eq [string]$terminalState.value -or ($waitingState.exists -and [string]$replanState.value -eq [string]$waitingState.value) -or $stageIds -contains [string]$replanState.value)){throw 'workflow.replan_state must be distinct from all other workflow states.'}
    foreach ($stage in $stages) {
        $stageId = [string](Get-StructuredProperty $stage 'id').value
        if ([string]::IsNullOrWhiteSpace($stageId)) { throw (Get-AppText 'stage_id_required') }
        $stageRole = Get-StructuredProperty $stage 'role_id'
        $resultKey = Get-StructuredProperty $stage 'result_key'
        $transitionsProperty = Get-StructuredProperty $stage 'transitions'
        if (-not $stageRole.exists -or $roleIds -notcontains [string]$stageRole.value) { throw (Get-AppText 'stage_role_missing' @($stageId, [string]$stageRole.value)) }
        if (-not $resultKey.exists -or [string]::IsNullOrWhiteSpace([string]$resultKey.value)) { throw (Get-AppText 'stage_result_key_required' @($stageId)) }
        $roleConfig = @($rolesProperty.value | Where-Object { [string](Get-StructuredProperty $_ 'id').value -eq [string]$stageRole.value })[0]
        if ($null -eq $roleConfig.PSObject.Properties['output_schema']) { throw (Get-AppText 'stage_schema_required' @([string]$stage.role_id)) }
        $defaultNextProperty = Get-StructuredProperty $stage 'default_next'
        $defaultNext = if ($defaultNextProperty.exists) { [string]$defaultNextProperty.value } else { '' }
        $transitions = if ($transitionsProperty.exists) { @($transitionsProperty.value) } else { @() }
        $dynamicField = Get-StructuredProperty $stage 'dynamic_transition_field'
        if ($dynamicField.exists) {
            if (-not (Get-StructuredProperty $roleConfig.output_schema.properties ([string]$dynamicField.value)).exists) { throw (Get-AppText 'transition_field_invalid' @($stageId, [string]$dynamicField.value)) }
            if (-not (Get-StructuredProperty $stage 'route_options_from_previous').exists) { throw (Get-AppText 'stage_transition_required' @($stageId)) }
        } elseif ($transitions.Count -eq 0 -and [string]::IsNullOrWhiteSpace($defaultNext)) { throw (Get-AppText 'stage_transition_required' @($stageId)) }
        $allowedTargets = Get-StructuredProperty $stage 'allowed_next_stages'
        if ($allowedTargets.exists) { foreach ($target in $allowedTargets.value) { if ($stageIds -notcontains [string]$target -and [string]$terminalState.value -ne [string]$target -and (-not $waitingState.exists -or [string]$waitingState.value -ne [string]$target) -and (-not $replanState.exists -or [string]$replanState.value -ne [string]$target)) { throw (Get-AppText 'transition_target_invalid' @($stageId, [string]$target)) } } }
        foreach ($transition in $transitions) {
            $next = Get-StructuredProperty $transition 'next'
            if (-not $next.exists -or [string]::IsNullOrWhiteSpace([string]$next.value) -or ($stageIds -notcontains [string]$next.value -and [string]$terminalState.value -ne [string]$next.value -and (-not $waitingState.exists -or [string]$waitingState.value -ne [string]$next.value) -and (-not $replanState.exists -or [string]$replanState.value -ne [string]$next.value))) { throw (Get-AppText 'transition_target_invalid' @($stageId, [string]$next.value)) }
            $transitionField = Get-StructuredProperty $transition 'field'
            if ($transitionField.exists) {
                if ([string]::IsNullOrWhiteSpace([string]$transitionField.value)) { throw (Get-AppText 'transition_field_required' @($stageId)) }
                if (-not (Get-StructuredProperty $roleConfig.output_schema.properties ([string]$transitionField.value)).exists) { throw (Get-AppText 'transition_field_invalid' @($stageId, [string]$transitionField.value)) }
                if (-not (Get-StructuredProperty $transition 'equals').exists) { throw (Get-AppText 'transition_equals_required' @($stageId)) }
            }
        }
    }
}

