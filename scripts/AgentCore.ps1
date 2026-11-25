Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Localization.ps1')
. (Join-Path $PSScriptRoot 'StructuredData.ps1')
. (Join-Path $PSScriptRoot 'RoleContracts.ps1')
. (Join-Path $PSScriptRoot 'CommonPrompts.ps1')

function Agent-ConvertModelJson([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'Model response is empty.' }
    if ([Text.Encoding]::UTF8.GetByteCount($Text) -gt 1048576) { throw 'Model response exceeds the 1 MiB safety limit.' }
    $normalized = [string]$Text
    if ($normalized -match '(?s)^\s*```(?:json)?\s*\r?\n(?<json>.*?)\r?\n```\s*$') { $normalized = $Matches['json'] }
    elseif ($normalized -match '(?s)^\s*```') { throw 'Model response contains an invalid JSON code fence.' }
    return ConvertFrom-AgentJsonText $normalized 'Model response' 1048576
}

function Agent-FormatMarkdown([object]$Value, [int]$Indent = 0) {
    $prefix = ' ' * $Indent
    if ($null -eq $Value) { return "${prefix}(not available)" }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $lines = @()
        foreach ($property in $Value.PSObject.Properties) {
            if ($lines.Count -gt 0) { $lines += '' }
            $level = if ($Indent -eq 0) { '##' } else { '###' }
            $lines += "${prefix}${level} $($property.Name)"
            $lines += Agent-FormatMarkdown $property.Value ($Indent + 2)
        }
        return $lines -join "`r`n"
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return (@($Value | ForEach-Object { "${prefix}- $((Agent-FormatMarkdown $_ 0).Trim())" }) -join "`r`n")
    }
    return "${prefix}$Value"
}

function Agent-FormatJson([object]$Value, [object]$Config) {
    $pretty = $true
    $indent = 2
    if ($null -ne $Config.PSObject.Properties['json_pretty']) { $pretty = [bool]$Config.json_pretty }
    if ($null -ne $Config.PSObject.Properties['json_indent']) { $indent = [int]$Config.json_indent }
    if ($indent -lt 0 -or $indent -gt 8) { throw (Get-AppText 'json_indent_invalid') }
    if (-not $pretty) { return ConvertTo-Json -InputObject $Value -Depth 40 -Compress }
    $json = ConvertTo-Json -InputObject $Value -Depth 40
    if ($indent -ne 2) {
        $json = [regex]::Replace($json, '(?m)^ +', { param($match) ' ' * ([int]($match.Value.Length * $indent / 2)) })
    }
    return $json
}

function Agent-FormatInput([object]$Value, [object]$Config) {
    $format = if ($null -ne $Config.PSObject.Properties['llm_input_format']) { [string]$Config.llm_input_format } else { 'json' }
    switch ($format.ToLowerInvariant()) {
        'json' { return Agent-FormatJson (Agent-ApplyLanguage $Value $Config) $Config }
        'markdown' { return Agent-FormatMarkdown ([pscustomobject](Agent-ApplyLanguage $Value $Config)) }
        default { throw (Get-AppText 'input_format_invalid' @($format)) }
    }
}

function Agent-ApplyLanguage([object]$Value, [object]$Config) {
    $language = if ($null -ne $Config.PSObject.Properties['user_output_language']) { [string]$Config.user_output_language } else { 'Japanese' }
    $Value | Add-Member -NotePropertyName user_output_language -NotePropertyValue $language -Force
    $Value | Add-Member -NotePropertyName internal_language -NotePropertyValue 'English' -Force
    return $Value
}

function Agent-EnsureMessagesFit([object]$Config, [object[]]$Messages, [string]$RoleId, [object]$CompressorRoleConfig) {
    if ($null -eq $Config.override) { return ,$Messages }
    $contextSize = [int]$Config.override.context_size
    $responseTokens = if ($null -ne $Config.override.PSObject.Properties['max_tokens']) { [int]$Config.override.max_tokens } elseif ($null -ne $Config.override.PSObject.Properties['max_completion_tokens']) { [int]$Config.override.max_completion_tokens } else { 0 }
    if ($contextSize -lt 1 -or $responseTokens -lt 1) { throw (Get-AppText 'context_size_invalid') }
    for ($contextAttempt = 0; ; $contextAttempt++) {
        $promptTokens = Get-KoboldCppTokenCount $Config $Messages
        $requiredTokens = $promptTokens + $responseTokens
        if ($requiredTokens -le $contextSize) { return ,$Messages }
        if ($contextAttempt -ge 3 -or $RoleId -eq 'context_compressor' -or $null -eq $CompressorRoleConfig) { throw (Get-AppText 'agent_context_exceeded' @($requiredTokens, $contextSize)) }
        $content = $Messages[-1].content
        $textContent = if ($content -is [string]) { $content } else { (@($content | Where-Object { $_.type -eq 'text' } | ForEach-Object { [string]$_.text }) -join "`r`n`r`n") }
        if ([string]::IsNullOrWhiteSpace($textContent)) { throw (Get-AppText 'agent_context_exceeded' @($requiredTokens, $contextSize)) }
        $excess = $requiredTokens - $contextSize
        $sourceTokens = Get-KoboldCppTokenCount $Config $textContent
        $targetTokens = [Math]::Max(64, $sourceTokens - $excess - 128)
        $compressed = Agent-CompressPromptText $Config $CompressorRoleConfig $textContent $targetTokens $RoleId 0
        if ($content -is [string]) { $Messages[-1].content = $compressed }
        else {
            $updatedContent = [System.Collections.Generic.List[object]]::new()
            $insertedText = $false
            foreach ($part in $content) {
                if ($part.type -eq 'text') {
                    if (-not $insertedText) { $updatedContent.Add([pscustomobject][ordered]@{ type='text'; text=$compressed }); $insertedText = $true }
                } else { $updatedContent.Add($part) }
            }
            if (-not $insertedText) { $updatedContent.Insert(0, [pscustomobject][ordered]@{ type='text'; text=$compressed }) }
            $Messages[-1].content = @($updatedContent.ToArray())
        }
    }
}

function Agent-InvokeRole([object]$Config, [object[]]$Messages, [object]$ResponseFormat, [object]$Schema, [string]$RoleId = '', [object]$CompressorRoleConfig = $null) {
    $limit = if ($null -ne $Config.PSObject.Properties['json_retry_limit']) { [int]$Config.json_retry_limit } else { 0 }
    $attempt = 0
    while ($true) {
        try {
            $Messages = Agent-EnsureMessagesFit $Config $Messages $RoleId $CompressorRoleConfig
            $bodyObject = @{ messages = $Messages; stream = $false; response_format = $ResponseFormat }
            if ($null -ne $Config.override) {
                foreach ($property in $Config.override.PSObject.Properties) { $bodyObject[$property.Name] = $property.Value }
                $bodyObject.response_format = $ResponseFormat
            }
            $uri=New-AgentHttpUri ([string]$Config.api_server) ([string]$Config.generate_path)
            $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json; charset=utf-8' -Body ($bodyObject | ConvertTo-Json -Depth 20) -TimeoutSec 300 -MaximumRedirection 0
            $text = if ($null -ne $response.choices -and $response.choices.Count -gt 0) { [string]$response.choices[0].message.content } else { [string]$response.text }
            if ([string]::IsNullOrWhiteSpace($text)) { throw (Get-AppText 'empty_agent_response') }
            $result = Agent-ConvertModelJson $text
            Assert-JsonSchema $result $Schema
            return $result
        } catch {
            if ($limit -ne -1 -and $attempt -ge $limit) { throw }
            $attempt++
            $retryText = "## Retry Instructions`r`nThe previous response could not be parsed as JSON or did not match the supplied JSON Schema. Return only a JSON object that satisfies the required fields, types, and allowed values."
            if ($Messages[-1].content -is [string]) { $Messages[-1].content += "`r`n`r`n$retryText" }
            else { $Messages[-1].content = @($Messages[-1].content) + @([pscustomobject][ordered]@{ type='text'; text=$retryText }) }
            $Messages = Agent-EnsureMessagesFit $Config $Messages $RoleId $CompressorRoleConfig
        }
    }
}

function Agent-GetSchema([string]$Role, [object]$RoleConfig = $null) {
    if ($null -eq $RoleConfig -or $null -eq $RoleConfig.PSObject.Properties['output_schema']) { throw (Get-AppText 'schema_missing' @($Role)) }
    return @{ type='json_schema'; json_schema=@{ name=($Role -replace '[^a-zA-Z0-9_-]','_') + '_response'; schema=$RoleConfig.output_schema } }
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

function Agent-SelectRoleInput([object]$InputData, [object]$RoleConfig, [object]$Config) {
    $localizedInput = Agent-ApplyLanguage $InputData $Config
    $selected = [ordered]@{}
    foreach ($property in $RoleConfig.input_schema.properties.PSObject.Properties) {
        $value = Get-StructuredProperty $localizedInput $property.Name
        if ($value.exists) { $selected[$property.Name] = $value.value }
    }
    $result = [pscustomobject]$selected
    Assert-JsonSchema $result $RoleConfig.input_schema
    return $result
}

function Agent-EstimateTokens([object]$Config, [object]$Value) {
    $text = $Value | ConvertTo-Json -Depth 40 -Compress
    return Get-KoboldCppTokenCount $Config $text
}

function Agent-CompressContext([object]$Config, [object]$Task, [object]$State, [object]$RoleConfig, [string]$Phase, [int]$TargetTokens) {
    $beforeTokens = Agent-EstimateTokens $Config $State.results
    $summary = [pscustomobject][ordered]@{ goal=$Task.goal; context=$Task.context; constraints=@($Task.constraints); latest_stage=if (@($State.history).Count) { @($State.history)[-1].phase } else { '' }; results=$State.results; target_tokens=$TargetTokens; internal_language='English'; user_output_language=[string]$Config.user_output_language }
    $system = Agent-GetRoleSystemPrompt $Config $RoleConfig ([string]$RoleConfig.purpose)
    $roleInput = Agent-SelectRoleInput $summary $RoleConfig $Config
    $messages = @([pscustomobject]@{ role='system'; content=$system }, [pscustomobject]@{ role='user'; content=(Agent-FormatInput $roleInput $Config) })
    Write-AppLogEvent (New-AppLogEvent 'run' ([ordered]@{ role='context_compressor' }))
    $result = Agent-InvokeRole $Config $messages (Agent-GetSchema 'context_compressor' $RoleConfig) $RoleConfig.output_schema 'context_compressor'
    $State | Add-Member -NotePropertyName context_summary -NotePropertyValue $result -Force
    $afterTokens = Agent-EstimateTokens $Config $result
    Write-AppLogEvent (New-AppLogEvent 'context_compression' ([ordered]@{ role='context_compressor'; before_tokens=$beforeTokens; after_tokens=$afterTokens; target_tokens=$TargetTokens }))
    return $State
}

function Agent-CompressPromptText([object]$Config, [object]$RoleConfig, [string]$Text, [int]$TargetTokens, [string]$TargetRole, [int]$Depth = 0) {
    if ($Depth -gt 12) { throw (Get-AppText 'agent_context_exceeded' @(0, [int]$Config.override.context_size)) }
    $inputData = [pscustomobject][ordered]@{ goal="Compress the input for role '$TargetRole' so the request fits its context window."; context=$Text; constraints=@('Preserve facts, requirements, decisions, and recent details.'); latest_stage=$TargetRole; results=[pscustomobject]@{}; target_tokens=[int]$TargetTokens; user_output_language=[string]$Config.user_output_language; internal_language='English' }
    $roleInput = Agent-SelectRoleInput $inputData $RoleConfig $Config
    $system = Agent-GetRoleSystemPrompt $Config $RoleConfig ([string]$RoleConfig.purpose)
    $messages = @([pscustomobject]@{ role='system'; content=$system }, [pscustomobject]@{ role='user'; content=(Agent-FormatInput $roleInput $Config) })
    $promptTokens = Get-KoboldCppTokenCount $Config $messages
    $contextSize = [int]$Config.override.context_size
    $responseTokens = if ($null -ne $Config.override.PSObject.Properties['max_tokens']) { [int]$Config.override.max_tokens } else { [int]$Config.override.max_completion_tokens }
    if (($promptTokens + $responseTokens) -gt $contextSize) {
        $split=Get-AgentTokenBalancedSplit $Config $Text
        $halfTarget = [Math]::Max(64, [Math]::Floor($TargetTokens / 2))
        $first = Agent-CompressPromptText $Config $RoleConfig $split.left $halfTarget $TargetRole ($Depth + 1)
        $second = Agent-CompressPromptText $Config $RoleConfig $split.right $halfTarget $TargetRole ($Depth + 1)
        return Agent-CompressPromptText $Config $RoleConfig ($first + "`r`n`r`n" + $second) $TargetTokens $TargetRole ($Depth + 1)
    }
    Write-AppLogEvent (New-AppLogEvent 'run' ([ordered]@{ role='context_compressor'; target_role=$TargetRole; target_tokens=$TargetTokens }))
    $result = Agent-InvokeRole $Config $messages (Agent-GetSchema 'context_compressor' $RoleConfig) $RoleConfig.output_schema 'context_compressor'
    if ([string]::IsNullOrWhiteSpace([string]$result.compressed_context)) { throw 'Context compressor returned an empty summary.' }
    return [string]$result.compressed_context
}

function Get-AgentTokenBalancedSplit([object]$Config,[string]$Text) {
    $boundaries=[Globalization.StringInfo]::ParseCombiningCharacters($Text)
    if($boundaries.Count -lt 2){throw (Get-AppText 'agent_context_exceeded' @(0,[int]$Config.override.context_size))}
    $totalTokens=Get-KoboldCppTokenCount $Config $Text
    if($totalTokens -lt 2){throw (Get-AppText 'agent_context_exceeded' @($totalTokens,[int]$Config.override.context_size))}
    $target=[Math]::Floor($totalTokens/2);$low=1;$high=$boundaries.Count-1;$below=$null;$above=$null
    while($low -le $high){
        $middle=[int][Math]::Floor(($low+$high)/2);$index=$boundaries[$middle];$tokens=Get-KoboldCppTokenCount $Config $Text.Substring(0,$index)
        if($tokens -le $target){$below=[pscustomobject]@{index=$index;tokens=$tokens};$low=$middle+1}else{$above=[pscustomobject]@{index=$index;tokens=$tokens};$high=$middle-1}
    }
    $candidates=@();if($null -ne $below){$candidates+=@($below)};if($null -ne $above){$candidates+=@($above)}
    if($candidates.Count -eq 0){throw (Get-AppText 'agent_context_exceeded' @($totalTokens,[int]$Config.override.context_size))}
    $best=$candidates|Sort-Object @{Expression={[Math]::Abs($_.tokens-$target)}}|Select-Object -First 1
    $splitIndex=[int]$best.index;while($splitIndex -gt 0 -and [char]::IsWhiteSpace($Text[$splitIndex-1])){$splitIndex--}
    if($splitIndex -eq 0 -or $splitIndex -ge $Text.Length){throw (Get-AppText 'agent_context_exceeded' @($totalTokens,[int]$Config.override.context_size))}
    $left=$Text.Substring(0,$splitIndex);$right=$Text.Substring($splitIndex);$leftTokens=Get-KoboldCppTokenCount $Config $left
    return [pscustomobject]@{left=$left;right=$right;left_tokens=$leftTokens;total_tokens=$totalTokens}
}

function Agent-GetPhaseInput([object]$Task, [object]$State, [string]$Phase) {
    $latest = if (@($State.history).Count -gt 0) { @($State.history)[-1] } else { $null }
    $phaseResult = if ($null -ne $latest) { $latest.result } else { $null }
    if ($null -ne $latest -and ($null -ne $latest.PSObject.Properties['commands_run'] -or $null -ne $latest.PSObject.Properties['files_changed'])) {
        $phaseResult = [pscustomobject][ordered]@{ result=$latest.result; commands_run=if ($null -ne $latest.PSObject.Properties['commands_run']) { @($latest.commands_run) } else { @() }; files_changed=if ($null -ne $latest.PSObject.Properties['files_changed']) { @($latest.files_changed) } else { @() } }
    }
    $context = if ($null -ne $Task.PSObject.Properties['context']) { $Task.context } else { '' }
    $constraints = if ($null -ne $Task.PSObject.Properties['constraints']) { @($Task.constraints) } else { @() }
    $results = $State.results
    if ($null -ne $State.PSObject.Properties['context_summary'] -and $null -ne $State.context_summary) { $results = [pscustomobject][ordered]@{ compressed_context=$State.context_summary.compressed_context; retained_facts=@($State.context_summary.retained_facts); open_items=@($State.context_summary.open_items) } }
    return [pscustomobject][ordered]@{
        goal = $Task.goal
        context = $context
        constraints = $constraints
        cycle = [int]$State.cycle
        phase = $Phase
        phase_data = $phaseResult
        latest_stage = if ($null -ne $latest) { $latest.phase } else { '' }
        results = $results
        workspace_root = '.'
        workspace_files = @()
        workspace_media = @()
        available_next_stages = @()
        allowed_commands = @()
        context_summary = if ($null -ne $State.PSObject.Properties['context_summary']) { $State.context_summary } else { $null }
    }
}

function Agent-GetRoleSystemPrompt([object]$Config, [object]$RoleConfig, [string]$FallbackPurpose) {
    $root = if ($null -ne $Config.resources_root) { [string]$Config.resources_root } else { '' }
    $user = if ($null -ne $Config.resources_user) { [string]$Config.resources_user } else { 'default-user' }
    $name = [string]$RoleConfig.system_prompt
    if ([string]::IsNullOrWhiteSpace($name)) { $rolePrompt=$FallbackPurpose; $prompt=Get-StructuredProperty $Config 'agent_common_prompt';if($prompt.exists -and -not [string]::IsNullOrWhiteSpace([string]$prompt.value)){return "$rolePrompt`r`n`r`n$($prompt.value)"};return $rolePrompt }
    $fileName = if ([System.IO.Path]::GetExtension($name)) { $name } else { "$name.json" }
    if($fileName.Length -gt 128 -or $fileName -match '[\\/:\x00-\x1F\x7F]' -or $fileName -in @('.','..')){throw 'Role system prompt must be a safe file name.'}
    $bases = @((Join-Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'data') $user) 'sysprompt'))
    if (-not [string]::IsNullOrWhiteSpace($root)) { $bases += Join-Path (Join-Path $root (Join-Path 'data' $user)) 'sysprompt' }
    $candidates = $bases | ForEach-Object { Join-Path $_ $fileName }
    foreach ($path in $candidates) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        if((Get-Item -LiteralPath $path -Force).Length -gt 1048576){throw "System prompt exceeds the 1 MiB safety limit: $path"}
        $raw = [Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($path))
        if ([System.IO.Path]::GetExtension($path) -eq '.json') {
            $resource = ConvertFrom-AgentJsonText $raw "System prompt '$fileName'" 1048576
            foreach ($field in @('content','description','prompt','text')) {
                if ($null -ne $resource.PSObject.Properties[$field] -and -not [string]::IsNullOrWhiteSpace([string]$resource.$field)) { $rolePrompt=[string]$resource.$field;$prompt=Get-StructuredProperty $Config 'agent_common_prompt';if($prompt.exists -and -not [string]::IsNullOrWhiteSpace([string]$prompt.value)){return "$rolePrompt`r`n`r`n$($prompt.value)"};return $rolePrompt }
            }
        }
        $rolePrompt=$raw.Trim();$prompt=Get-StructuredProperty $Config 'agent_common_prompt';if($prompt.exists -and -not [string]::IsNullOrWhiteSpace([string]$prompt.value)){return "$rolePrompt`r`n`r`n$($prompt.value)"};return $rolePrompt
    }
    $prompt=Get-StructuredProperty $Config 'agent_common_prompt'
    if($prompt.exists -and -not [string]::IsNullOrWhiteSpace([string]$prompt.value)){return "$FallbackPurpose`r`n`r`n$($prompt.value)"}
    return $FallbackPurpose
}

function Agent-NextState([object]$State, [object]$Workflow, [object]$Stage, [object]$Result) {
    $State.results | Add-Member -NotePropertyName ([string]$Stage.result_key) -NotePropertyValue $Result -Force
    if ($null -ne $Stage.PSObject.Properties['increment_cycle'] -and [bool]$Stage.increment_cycle) { $State.cycle = [int]$State.cycle + 1 }
    $State.phase = Agent-ResolveTransition $Workflow $Stage $Result
    return $State
}

function Agent-SaveState([string]$Path, [object]$State,[string]$JournalPath='') {
    $temporaryPath = "$Path.tmp"
    $json = $State | ConvertTo-Json -Depth 40
    if([Text.Encoding]::UTF8.GetByteCount($json) -gt 2097152){throw 'Task state exceeds the 2 MiB safety limit.'}
    if(-not [string]::IsNullOrWhiteSpace($JournalPath)){Update-AgentChangeJournalState $JournalPath $json}
    [System.IO.File]::WriteAllText($temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
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
