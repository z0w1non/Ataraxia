[CmdletBinding()]
param(
    [Parameter(ParameterSetName='New', Mandatory=$true)] [string]$New,
    [Parameter(ParameterSetName='Run', Mandatory=$true)] [string]$Run,
    [Parameter(ParameterSetName='Resume', Mandatory=$true)] [string]$Resume,
    [Parameter(ParameterSetName='Rollback', Mandatory=$true)] [string]$Rollback,
    [string]$ConfigPath = (Join-Path (Join-Path $PSScriptRoot '..\configs') 'config.json'),
    [int]$Step = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'AgentCore.ps1')
. (Join-Path $PSScriptRoot 'AgentHarness.ps1')
. (Join-Path $PSScriptRoot 'Logging.ps1')
. (Join-Path $PSScriptRoot 'KoboldCppSettings.ps1')
. (Join-Path $PSScriptRoot 'KoboldCppApi.ps1')
. (Join-Path $PSScriptRoot 'SessionStore.ps1')
. (Join-Path $PSScriptRoot 'CommonPrompts.ps1')

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw (Get-AppText 'config_file_missing' @($ConfigPath)) }
$config = Read-AgentJsonFile $ConfigPath
if ([string]::IsNullOrWhiteSpace([string]$config.interface_language)) { throw (Get-AppText 'config_language_required') }
Set-AppLanguage ([string]$config.interface_language)
$koboldcppSettings = Import-KoboldCppSettings $config $ConfigPath
$config | Add-Member -NotePropertyName role_contracts -NotePropertyValue (Import-RoleContracts $config $ConfigPath) -Force
$harnessSettings = Import-AgentHarnessSettings $config $ConfigPath
if ([string]::IsNullOrWhiteSpace([string]$config.user_output_language)) { throw (Get-AppText 'output_language_required') }
$projectName = [string]$config.project_name
if ($projectName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { throw 'config.project_name must be a safe project folder name.' }
$projectDirectory = Join-Path (Join-Path $projectRoot 'projects') $projectName
$taskPath = if ($PSCmdlet.ParameterSetName -eq 'New') { Join-Path $projectDirectory "$New.task.json" } else { if ($PSCmdlet.ParameterSetName -eq 'Run') { $Run } elseif($PSCmdlet.ParameterSetName -eq 'Rollback'){$Rollback}else{$Resume} }
if ($PSCmdlet.ParameterSetName -eq 'New') {
    if ($New -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { throw (Get-AppText 'task_name_invalid') }
    if (Test-Path -LiteralPath $taskPath -PathType Leaf) { throw "Task already exists: $taskPath" }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $taskPath) | Out-Null
    $task = Agent-NewTaskTemplate $New $config.role_contracts | ConvertTo-Json -Depth 20
    Set-Content -LiteralPath $taskPath -Value $task -Encoding UTF8
    Write-AppLogEvent (New-AppLogEvent -Kind 'result' -Data ([ordered]@{ task_created=$true; path=$taskPath }))
    exit 0
}

$task = Read-AgentJsonFile $taskPath
$coreSupportChanged=$false
if($PSCmdlet.ParameterSetName -ne 'Rollback'){$coreSupportChanged=Agent-EnsureCoreWorkflow $task $config.role_contracts}
Agent-ValidateTask $task
if($coreSupportChanged){$migrationJson=$task|ConvertTo-Json -Depth 100;[IO.File]::WriteAllText("$taskPath.tmp",$migrationJson,[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath "$taskPath.tmp" -Destination $taskPath -Force}
if ($Step -eq 0 -or $Step -lt -1) { throw (Get-AppText 'step_invalid') }
$taskDir = Split-Path -Parent $taskPath
$config | Add-Member -NotePropertyName agent_common_prompt -NotePropertyValue (Get-AtaraxiaCommonPromptForTaskDirectory $taskDir) -Force
$workspaceDirectory = Resolve-AgentWorkspaceDirectory ([string]$task.working_directory) $taskDir
$statePath = Join-Path $taskDir 'state.json'
$journalPath = Join-Path $taskDir 'run-changes.json'
if($PSCmdlet.ParameterSetName -eq 'Rollback'){
    $restored=Restore-AgentRunChanges $workspaceDirectory $journalPath $statePath
    Write-AppLogEvent (New-AppLogEvent -Kind 'result' -Data ([ordered]@{run_stopped=$true;restored_files=@($restored.restored_files);state_restored=[bool]$restored.state_restored}))
    exit 0
}
$sessionMetadataPath=Join-Path $taskDir 'session.json'
if(Test-Path -LiteralPath $sessionMetadataPath -PathType Leaf){
    $sessionMetadata=Read-AgentJsonFile $sessionMetadataPath
    $generatedProperty=$sessionMetadata.PSObject.Properties['title_generated']
    if($null -ne $generatedProperty -and -not [bool]$generatedProperty.Value -and -not [string]::IsNullOrWhiteSpace([string]$task.goal)){
        $namer=@($task.roles|Where-Object{$_.id -eq 'session_namer'}|Select-Object -First 1)
        if($namer.Count -eq 0){$contract=@($config.role_contracts.generic_agent.roles|Where-Object{$_.id -eq 'session_namer'}|Select-Object -First 1);if($contract.Count -gt 0){$namer=@([pscustomobject]@{id='session_namer';system_prompt=$contract[0].system_prompt;purpose=$contract[0].purpose;input_schema=(Resolve-RoleContractSchema $config.role_contracts $contract[0].input_schema_ref);output_schema=(Resolve-RoleContractSchema $config.role_contracts $contract[0].output_schema_ref)})}}
        if($namer.Count -gt 0){
            $namerRole=$namer[0]
            $namerInput=[pscustomobject][ordered]@{first_prompt=[string]$task.goal}
            $namerInput=Agent-SelectRoleInput $namerInput $namerRole $config
            $namerSystem=Agent-GetRoleSystemPrompt $config $namerRole ([string]$namerRole.purpose)
            $namerMessages=@([pscustomobject]@{role='system';content=$namerSystem},[pscustomobject]@{role='user';content=(Agent-FormatInput $namerInput $config)})
            Write-AppLogEvent (New-AppLogEvent -Kind 'run' -Data ([ordered]@{role='session_namer'}))
            $compressorRole=@($task.roles|Where-Object{$_.id -eq 'context_compressor'}|Select-Object -First 1)
            $nameResult=Agent-InvokeRole $config $namerMessages (Agent-GetSchema 'session_namer' $namerRole) $namerRole.output_schema 'session_namer' $(if($compressorRole.Count -gt 0){$compressorRole[0]}else{$null})
            Set-AtaraxiaSessionTitle $taskDir ([string]$nameResult.title) 'agent'|Out-Null
        }
    }
}
$null=New-AgentChangeJournal $journalPath $workspaceDirectory $statePath
$state = if (Test-Path -LiteralPath $statePath) { Read-AgentJsonFile $statePath 2097152 } else { [pscustomobject]@{ cycle=0; phase=[string]$task.workflow.initial_stage; history=@(); results=[pscustomobject]@{} } }
$state = Agent-ValidateState $state $task
$hasCoreRole=(@($task.roles|Where-Object{$_.id -eq 'core'}).Count -gt 0 -and $null -ne (Agent-GetWorkflowStage $task.workflow 'Core'))
$coreConfiguredProperty=Get-StructuredProperty $task.workflow 'core_configured'
if($hasCoreRole -and -not $coreConfiguredProperty.exists -and [string]$state.phase -ne 'Core'){
    $state.phase='Core';$state|Add-Member -NotePropertyName core_request_id -NotePropertyValue ([guid]::NewGuid().ToString('N')) -Force;Agent-SaveState $statePath $state $journalPath
}
if($hasCoreRole -and $coreConfiguredProperty.exists -and [bool]$coreConfiguredProperty.value){
    $goalChanged=([string](Get-StructuredProperty $task 'core_request_goal').value -cne [string]$task.goal)
    $atTerminal=([string]$state.phase -eq [string]$task.workflow.terminal_state)
    $waitingState=Get-StructuredProperty $task.workflow 'waiting_state';$awaitingUser=($waitingState.exists -and [string]$state.phase -eq [string]$waitingState.value)
    if($goalChanged -or (($atTerminal -or $awaitingUser) -and $PSCmdlet.ParameterSetName -eq 'Run')){
        $state.phase='Core';$state|Add-Member -NotePropertyName core_request_id -NotePropertyValue ([guid]::NewGuid().ToString('N')) -Force
        $state|Add-Member -NotePropertyName core_replans_this_query -NotePropertyValue 0 -Force
        Agent-SaveState $statePath $state $journalPath
    }
}
if($hasCoreRole -and [string]$state.phase -eq 'Core'){
    $stateRequestId=Get-StructuredProperty $state 'core_request_id'
    if(-not $stateRequestId.exists){$stateRequestId=[pscustomobject]@{exists=$true;value=[guid]::NewGuid().ToString('N')};$state|Add-Member -NotePropertyName core_request_id -NotePropertyValue $stateRequestId.value -Force;Agent-SaveState $statePath $state $journalPath}
    $taskRequestId=Get-StructuredProperty $task.workflow 'core_request_id'
    if($coreConfiguredProperty.exists -and [bool]$coreConfiguredProperty.value -and $taskRequestId.exists -and [string]$taskRequestId.value -ceq [string]$stateRequestId.value){
        $configuredCore=Agent-GetWorkflowStage $task.workflow 'Core';$state.phase=[string]$configuredCore.default_next;Agent-SaveState $statePath $state $journalPath
    }
}
$steps = if ($Step -eq -1) { [int]::MaxValue } else { $Step }
$stepCount = 0
for ($i = 0; $i -lt $steps; $i++) {
    if ([string]$state.phase -eq [string]$task.workflow.terminal_state) { break }
    $replanState=Get-StructuredProperty $task.workflow 'replan_state'
    if($replanState.exists -and [string]$state.phase -eq [string]$replanState.value){
        $replanCount=Get-StructuredProperty $state 'core_replans_this_query';$count=if($replanCount.exists){[int]$replanCount.value}else{0}
        $replanLimit=Get-StructuredProperty $task.workflow 'max_core_replans_per_query';$limit=if($replanLimit.exists){[int]$replanLimit.value}else{2}
        if($count -ge $limit){throw 'The workflow reached its configured Core replan limit for this user query.'}
        $state.phase='Core';$state|Add-Member -NotePropertyName core_replans_this_query -NotePropertyValue ($count+1) -Force;$state|Add-Member -NotePropertyName core_request_id -NotePropertyValue ([guid]::NewGuid().ToString('N')) -Force;Agent-SaveState $statePath $state $journalPath
    }
    $phase = [string]$state.phase
    $stage = Agent-GetWorkflowStage $task.workflow $phase
    if ($null -eq $stage) { throw (Get-AppText 'stage_not_defined' @($phase)) }
    $role = [string]$stage.role_id
    $roleConfig = @($task.roles | Where-Object { $_.id -eq $role })[0]
    if ($null -eq $roleConfig) { throw (Get-AppText 'task_role_not_defined' @($role)) }
    $compressionConfig = if ($null -ne $config.PSObject.Properties['context_compression']) { $config.context_compression } else { $null }
    $compressorRoleId = if ($null -ne $compressionConfig -and $null -ne $compressionConfig.PSObject.Properties['role_id']) { [string]$compressionConfig.role_id } else { 'context_compressor' }
    $compressorRoleConfig = @($task.roles | Where-Object { $_.id -eq $compressorRoleId })[0]
    if ($null -ne $compressionConfig -and [bool]$compressionConfig.enabled) {
        $threshold = [int]$compressionConfig.trigger_tokens
        $estimatedTokens = Agent-EstimateTokens $config $state.results
        if ($estimatedTokens -gt $threshold) {
            if ($null -eq $compressorRoleConfig) { throw (Get-AppText 'task_role_not_defined' @($compressorRoleId)) }
            $state = Agent-CompressContext $config $task $state $compressorRoleConfig $phase ([int]$compressionConfig.target_tokens)
            Agent-SaveState $statePath $state $journalPath
        }
    }
    $system = Agent-GetRoleSystemPrompt $config $roleConfig ([string]$roleConfig.purpose)
    $phaseInput = Agent-GetPhaseInput $task $state $phase
    $phaseInput | Add-Member -NotePropertyName workspace_files -NotePropertyValue (Get-AgentWorkspaceSnapshot $workspaceDirectory $harnessSettings) -Force
    $mediaPayloads = @(Get-AgentWorkspaceMedia $workspaceDirectory $harnessSettings)
    $phaseInput | Add-Member -NotePropertyName workspace_media -NotePropertyValue @($mediaPayloads | ForEach-Object { [pscustomobject][ordered]@{ path=$_.path; mime_type=$_.mime_type; sha256=$_.sha256; byte_length=$_.byte_length } }) -Force
    if ($phase -eq 'Route') {
        $routeOptions = @(Agent-GetRoutingOptions $task $state)
        if ($routeOptions.Count -eq 0) { throw 'The previous stage has no eligible routing options.' }
        $phaseInput | Add-Member -NotePropertyName available_next_stages -NotePropertyValue $routeOptions -Force
        $stage | Add-Member -NotePropertyName allowed_next_stages -NotePropertyValue @($routeOptions | ForEach-Object { [string]$_.id }) -Force
    }
    if($phase -eq 'Core'){
        $supportRoles=@('core','router','reporter','context_compressor','session_namer')
        $availableRoles=@($task.roles|Where-Object{$_.id -notin $supportRoles}|ForEach-Object{[pscustomobject][ordered]@{id=[string]$_.id;purpose=[string]$_.purpose}})
        $phaseInput|Add-Member -NotePropertyName available_roles -NotePropertyValue $availableRoles -Force
    }
    $phaseInput | Add-Member -NotePropertyName allowed_commands -NotePropertyValue @($harnessSettings.allowed_commands | ForEach-Object { [pscustomobject][ordered]@{ id=[string]$_.id; executable=[string]$_.executable; arguments_regex=[string]$_.arguments_regex } }) -Force
    $input = Agent-SelectRoleInput $phaseInput $roleConfig $config
    $userContent = Agent-FormatInput $input $config
    if ($mediaPayloads.Count -gt 0) { $userContent = ConvertTo-AgentMessageContent $userContent $mediaPayloads }
    $messages = @([pscustomobject]@{ role='system'; content=$system }, [pscustomobject]@{ role='user'; content=$userContent })
    Write-AppLogEvent (New-AppLogEvent -Kind 'run' -Data ([ordered]@{ role=$role }))
    $result = Agent-InvokeRole $config $messages (Agent-GetSchema $role $roleConfig) $roleConfig.output_schema $role $compressorRoleConfig
    if($phase -eq 'Core'){
        $task=Agent-InstallDesignedWorkflow $task $result $state
        $taskJson=$task|ConvertTo-Json -Depth 100
        if([Text.Encoding]::UTF8.GetByteCount($taskJson) -gt 4194304){throw 'Task definition exceeds the 4 MiB safety limit.'}
        $taskTemporaryPath="$taskPath.tmp"
        [IO.File]::WriteAllText($taskTemporaryPath,$taskJson,[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $taskTemporaryPath -Destination $taskPath -Force
        $stage=Agent-GetWorkflowStage $task.workflow 'Core'
    }
    $filesChanged = @()
    $commandsRun = @()
    if ($null -ne $stage.PSObject.Properties['changes_field']) {
        $changesProperty = $result.PSObject.Properties[[string]$stage.changes_field]
        $commandsProperty = $result.PSObject.Properties[[string]$stage.commands_field]
        if ($null -eq $changesProperty -or $null -eq $commandsProperty) { throw 'Executor result is missing configured file changes or commands.' }
        foreach ($command in @($commandsProperty.Value)) { Resolve-AgentAllowedCommand $harnessSettings $command | Out-Null }
        $changeResult = Apply-AgentWorkspaceChanges $workspaceDirectory @($changesProperty.Value) $journalPath
        $filesChanged = @($changeResult.changed_files)
        $commandsRun = @(Invoke-AgentCommandBatch $harnessSettings $workspaceDirectory @($commandsProperty.Value))
        Sync-AgentChangeJournal $journalPath $workspaceDirectory
    }
    $reportConfig = @($task.roles | Where-Object { $_.id -eq 'reporter' })[0]
    $roleReport = $null
    if ($null -ne $reportConfig -and $role -ne 'reporter') {
        $reportInput = ConvertFrom-AgentJsonText ($phaseInput | ConvertTo-Json -Depth 40) 'Reporter input'
        $reportInput.phase = 'Report'
        $reportInput.latest_stage = $role
        $reportInput.results = [pscustomobject][ordered]@{ role_result=$result; files_changed=$filesChanged; commands_run=$commandsRun }
        $reportRoleInput=Agent-SelectRoleInput $reportInput $reportConfig $config
        $reportSystem = Agent-GetRoleSystemPrompt $config $reportConfig 'Report completed work to the user.'
        $reportMessages = @([pscustomobject]@{ role='system'; content=$reportSystem }, [pscustomobject]@{ role='user'; content=(Agent-FormatInput $reportRoleInput $config) })
        Write-AppLogEvent (New-AppLogEvent -Kind 'run' -Data ([ordered]@{ role='Reporter' }))
        $roleReport = Agent-InvokeRole $config $reportMessages (Agent-GetSchema 'reporter' $reportConfig) $reportConfig.output_schema 'reporter' $compressorRoleConfig
        if ([string]::IsNullOrWhiteSpace([string]$roleReport.heading) -or [string]::IsNullOrWhiteSpace([string]$roleReport.body)) { throw 'Reporter response must contain heading and body.' }
    }
    $entry = [pscustomobject][ordered]@{ timestamp=[DateTime]::UtcNow.ToString('o'); cycle=$state.cycle; phase=$phase; role=$role; result=$result; report=$roleReport; files_changed=$filesChanged; commands_run=$commandsRun }
    $state.history = @($state.history) + @($entry)
    $state = Agent-NextState $state $task.workflow $stage $result
    Agent-SaveState $statePath $state $journalPath
    $stepCount++
    Write-AppLogEvent (New-AppLogEvent -Kind 'result' -Data ([ordered]@{ cycle=$state.cycle; phase=$phase; role=$role }))
    if ($state.phase -eq $task.workflow.terminal_state) { Write-AppLogEvent (New-AppLogEvent -Kind 'result' -Data ([ordered]@{ task_completed=$true; step_count=$stepCount })); break }
    if($waitingState.exists -and [string]$state.phase -eq [string]$waitingState.value){Write-AppLogEvent (New-AppLogEvent -Kind 'result' -Data ([ordered]@{awaiting_user_query=$true;step_count=$stepCount}));break}
}
if(Test-Path -LiteralPath $journalPath -PathType Leaf){Remove-Item -LiteralPath $journalPath -Force}

