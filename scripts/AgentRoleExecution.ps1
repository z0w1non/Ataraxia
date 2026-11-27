Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Localization.ps1')
. (Join-Path $PSScriptRoot 'StructuredData.ps1')
. (Join-Path $PSScriptRoot 'RoleContracts.ps1')
. (Join-Path $PSScriptRoot 'CommonPrompts.ps1')

function New-AgentDependencies([scriptblock]$CountTokens=$null,[scriptblock]$SendCompletion=$null) {
    return [pscustomobject]@{count_tokens=$CountTokens;send_completion=$SendCompletion}
}

function Invoke-AgentTokenCounter([object]$Config,[object]$Value,[object]$Dependencies=$null) {
    $dependency=if($null -ne $Dependencies -and $null -ne $Dependencies.PSObject.Properties['count_tokens']){$Dependencies.PSObject.Properties['count_tokens'].Value}else{$null}
    if($dependency -is [scriptblock]){return [int](& $dependency $Config $Value)}
    return Get-KoboldCppTokenCount $Config $Value
}

function Invoke-AgentCompletion([object]$Config,[object]$Request,[object]$Dependencies=$null) {
    $dependency=if($null -ne $Dependencies -and $null -ne $Dependencies.PSObject.Properties['send_completion']){$Dependencies.PSObject.Properties['send_completion'].Value}else{$null}
    if($dependency -is [scriptblock]){return & $dependency $Config $Request}
    $uri=New-AgentHttpUri ([string]$Config.api_server) ([string]$Config.generate_path)
    return Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json; charset=utf-8' -Body ($Request|ConvertTo-Json -Depth 20) -TimeoutSec 300 -MaximumRedirection 0
}

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

function Agent-EnsureMessagesFit([object]$Config, [object[]]$Messages, [string]$RoleId, [object]$CompressorRoleConfig,[object]$Dependencies=$null) {
    if ($null -eq $Config.override) { return ,$Messages }
    $contextSize = [int]$Config.override.context_size
    $responseTokens = if ($null -ne $Config.override.PSObject.Properties['max_tokens']) { [int]$Config.override.max_tokens } elseif ($null -ne $Config.override.PSObject.Properties['max_completion_tokens']) { [int]$Config.override.max_completion_tokens } else { 0 }
    if ($contextSize -lt 1 -or $responseTokens -lt 1) { throw (Get-AppText 'context_size_invalid') }
    for ($contextAttempt = 0; ; $contextAttempt++) {
        $promptTokens = Invoke-AgentTokenCounter $Config $Messages $Dependencies
        $requiredTokens = $promptTokens + $responseTokens
        if ($requiredTokens -le $contextSize) { return ,$Messages }
        if($contextAttempt -ge 3){throw (Get-AppText 'role_context_compression_exhausted' @($RoleId,$requiredTokens,$contextSize))}
        if($RoleId -eq 'context_compressor'){throw (Get-AppText 'context_compression_impossible' @($requiredTokens,$contextSize))}
        if($null -eq $CompressorRoleConfig){throw (Get-AppText 'agent_context_exceeded' @($requiredTokens,$contextSize))}
        $content = $Messages[-1].content
        $textContent = if ($content -is [string]) { $content } else { (@($content | Where-Object { $_.type -eq 'text' } | ForEach-Object { [string]$_.text }) -join "`r`n`r`n") }
        if ([string]::IsNullOrWhiteSpace($textContent)) { throw (Get-AppText 'context_compression_no_source' @($RoleId,$requiredTokens,$contextSize)) }
        $excess = $requiredTokens - $contextSize
        $sourceTokens = Invoke-AgentTokenCounter $Config $textContent $Dependencies
        $targetTokens = [Math]::Max(64, $sourceTokens - $excess - 128)
        $compressed = Agent-CompressPromptText $Config $CompressorRoleConfig $textContent $targetTokens $RoleId 0 $Dependencies
        $compressedTokens=Invoke-AgentTokenCounter $Config $compressed $Dependencies
        if($compressedTokens -ge $sourceTokens){throw (Get-AppText 'context_compression_no_progress' @($sourceTokens,$compressedTokens))}
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

function Agent-InvokeRole([object]$Config, [object[]]$Messages, [object]$ResponseFormat, [object]$Schema, [string]$RoleId = '', [object]$CompressorRoleConfig = $null,[object]$Dependencies=$null) {
    $limit = if ($null -ne $Config.PSObject.Properties['json_retry_limit']) { [int]$Config.json_retry_limit } else { 0 }
    if ($limit -lt -1) { throw 'json_retry_limit must be -1 or greater.' }
    $attempt = 0
    while ($true) {
        $Messages = Agent-EnsureMessagesFit $Config $Messages $RoleId $CompressorRoleConfig $Dependencies
        $bodyObject = @{ messages = $Messages; stream = $false; response_format = $ResponseFormat }
        if ($null -ne $Config.override) {
            foreach ($property in $Config.override.PSObject.Properties) { $bodyObject[$property.Name] = $property.Value }
            $bodyObject.response_format = $ResponseFormat
        }
        $response = Invoke-AgentCompletion $Config $bodyObject $Dependencies
        $text = if ($null -ne $response.choices -and $response.choices.Count -gt 0) { [string]$response.choices[0].message.content } else { [string]$response.text }
        try {
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
        }
    }
}

function Agent-GetSchema([string]$Role, [object]$RoleConfig = $null) {
    if ($null -eq $RoleConfig -or $null -eq $RoleConfig.PSObject.Properties['output_schema']) { throw (Get-AppText 'schema_missing' @($Role)) }
    return @{ type='json_schema'; json_schema=@{ name=($Role -replace '[^a-zA-Z0-9_-]','_') + '_response'; schema=$RoleConfig.output_schema } }
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

function Agent-EstimateTokens([object]$Config, [object]$Value,[object]$Dependencies=$null) {
    $text = $Value | ConvertTo-Json -Depth 40 -Compress
    return Invoke-AgentTokenCounter $Config $text $Dependencies
}

function Agent-CompressContext([object]$Config, [object]$Task, [object]$State, [object]$RoleConfig, [string]$Phase, [int]$TargetTokens,[object]$Dependencies=$null) {
    $beforeTokens = Agent-EstimateTokens $Config $State.results $Dependencies
    $summary = [pscustomobject][ordered]@{ goal=$Task.goal; context=$Task.context; constraints=@($Task.constraints); latest_stage=if (@($State.history).Count) { @($State.history)[-1].phase } else { '' }; results=$State.results; target_tokens=$TargetTokens; internal_language='English'; user_output_language=[string]$Config.user_output_language }
    $system = Agent-GetRoleSystemPrompt $Config $RoleConfig ([string]$RoleConfig.purpose)
    $roleInput = Agent-SelectRoleInput $summary $RoleConfig $Config
    $messages = @([pscustomobject]@{ role='system'; content=$system }, [pscustomobject]@{ role='user'; content=(Agent-FormatInput $roleInput $Config) })
    Write-AppLogEvent (New-AppLogEvent 'run' ([ordered]@{ role='context_compressor' }))
    $result = Agent-InvokeRole $Config $messages (Agent-GetSchema 'context_compressor' $RoleConfig) $RoleConfig.output_schema 'context_compressor' $null $Dependencies
    $State | Add-Member -NotePropertyName context_summary -NotePropertyValue $result -Force
    $afterTokens = Agent-EstimateTokens $Config $result $Dependencies
    Write-AppLogEvent (New-AppLogEvent 'context_compression' ([ordered]@{ role='context_compressor'; before_tokens=$beforeTokens; after_tokens=$afterTokens; target_tokens=$TargetTokens }))
    return $State
}

function Agent-CompressPromptText([object]$Config, [object]$RoleConfig, [string]$Text, [int]$TargetTokens, [string]$TargetRole, [int]$Depth = 0,[object]$Dependencies=$null) {
    if ($Depth -gt 12) { throw (Get-AppText 'agent_context_exceeded' @(0, [int]$Config.override.context_size)) }
    $inputData = [pscustomobject][ordered]@{ goal="Compress the input for role '$TargetRole' so the request fits its context window."; context=$Text; constraints=@('Preserve facts, requirements, decisions, and recent details.'); latest_stage=$TargetRole; results=[pscustomobject]@{}; target_tokens=[int]$TargetTokens; user_output_language=[string]$Config.user_output_language; internal_language='English' }
    $roleInput = Agent-SelectRoleInput $inputData $RoleConfig $Config
    $system = Agent-GetRoleSystemPrompt $Config $RoleConfig ([string]$RoleConfig.purpose)
    $messages = @([pscustomobject]@{ role='system'; content=$system }, [pscustomobject]@{ role='user'; content=(Agent-FormatInput $roleInput $Config) })
    $promptTokens = Invoke-AgentTokenCounter $Config $messages $Dependencies
    $contextSize = [int]$Config.override.context_size
    $responseTokens = if ($null -ne $Config.override.PSObject.Properties['max_tokens']) { [int]$Config.override.max_tokens } else { [int]$Config.override.max_completion_tokens }
    if (($promptTokens + $responseTokens) -gt $contextSize) {
        $split=Get-AgentTokenBalancedSplit $Config $Text $Dependencies
        $halfTarget = [Math]::Max(64, [Math]::Floor($TargetTokens / 2))
        $first = Agent-CompressPromptText $Config $RoleConfig $split.left $halfTarget $TargetRole ($Depth + 1) $Dependencies
        $second = Agent-CompressPromptText $Config $RoleConfig $split.right $halfTarget $TargetRole ($Depth + 1) $Dependencies
        return Agent-CompressPromptText $Config $RoleConfig ($first + "`r`n`r`n" + $second) $TargetTokens $TargetRole ($Depth + 1) $Dependencies
    }
    Write-AppLogEvent (New-AppLogEvent 'run' ([ordered]@{ role='context_compressor'; target_role=$TargetRole; target_tokens=$TargetTokens }))
    $result = Agent-InvokeRole $Config $messages (Agent-GetSchema 'context_compressor' $RoleConfig) $RoleConfig.output_schema 'context_compressor' $null $Dependencies
    if ([string]::IsNullOrWhiteSpace([string]$result.compressed_context)) { throw 'Context compressor returned an empty summary.' }
    return [string]$result.compressed_context
}

function Get-AgentTokenBalancedSplit([object]$Config,[string]$Text,[object]$Dependencies=$null) {
    $boundaries=[Globalization.StringInfo]::ParseCombiningCharacters($Text)
    if($boundaries.Count -lt 2){throw (Get-AppText 'agent_context_exceeded' @(0,[int]$Config.override.context_size))}
    $totalTokens=Invoke-AgentTokenCounter $Config $Text $Dependencies
    if($totalTokens -lt 2){throw (Get-AppText 'agent_context_exceeded' @($totalTokens,[int]$Config.override.context_size))}
    $target=[Math]::Floor($totalTokens/2);$low=1;$high=$boundaries.Count-1;$below=$null;$above=$null
    while($low -le $high){
        $middle=[int][Math]::Floor(($low+$high)/2);$index=$boundaries[$middle];$tokens=Invoke-AgentTokenCounter $Config $Text.Substring(0,$index) $Dependencies
        if($tokens -le $target){$below=[pscustomobject]@{index=$index;tokens=$tokens};$low=$middle+1}else{$above=[pscustomobject]@{index=$index;tokens=$tokens};$high=$middle-1}
    }
    $candidates=@();if($null -ne $below){$candidates+=@($below)};if($null -ne $above){$candidates+=@($above)}
    if($candidates.Count -eq 0){throw (Get-AppText 'agent_context_exceeded' @($totalTokens,[int]$Config.override.context_size))}
    $best=$candidates|Sort-Object @{Expression={[Math]::Abs($_.tokens-$target)}}|Select-Object -First 1
    $splitIndex=[int]$best.index;while($splitIndex -gt 0 -and [char]::IsWhiteSpace($Text[$splitIndex-1])){$splitIndex--}
    if($splitIndex -eq 0 -or $splitIndex -ge $Text.Length){throw (Get-AppText 'agent_context_exceeded' @($totalTokens,[int]$Config.override.context_size))}
    $left=$Text.Substring(0,$splitIndex);$right=$Text.Substring($splitIndex);$leftTokens=Invoke-AgentTokenCounter $Config $left $Dependencies
    return [pscustomobject]@{left=$left;right=$right;left_tokens=$leftTokens;total_tokens=$totalTokens}
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
