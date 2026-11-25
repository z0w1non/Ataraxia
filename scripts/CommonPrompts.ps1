Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'StructuredData.ps1')

function Save-AtaraxiaPromptMetadata([string]$Path,[string]$Property,[string]$Text) {
    if(-not(Test-Path -LiteralPath $Path -PathType Container)){New-Item -ItemType Directory -Force -Path $Path|Out-Null}
    $metadataPath=Join-Path $Path 'project.json'
    if(Test-Path -LiteralPath $metadataPath -PathType Leaf){$metadata=Read-AgentJsonFile $metadataPath}else{$metadata=[pscustomobject][ordered]@{schema_version=1;artifact_type='project'}}
    Assert-AgentPlainText $Text 'Project common prompt' -AllowMultiline
    $metadata|Add-Member -NotePropertyName $Property -NotePropertyValue $Text -Force
    [IO.File]::WriteAllText($metadataPath,($metadata|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
}

function Set-AtaraxiaProjectCommonPrompt([string]$ProjectPath,[string]$Text) {
    Save-AtaraxiaPromptMetadata $ProjectPath 'common_prompt' $Text
}

function Set-AtaraxiaSessionCommonPrompt([string]$SessionPath,[string]$Text) {
    $metadataPath=Join-Path $SessionPath 'session.json'
    if(-not(Test-Path -LiteralPath $metadataPath -PathType Leaf)){throw "Session metadata was not found: $metadataPath"}
    $metadata=Read-AgentJsonFile $metadataPath
    Assert-AgentPlainText $Text 'Session common prompt' -AllowMultiline
    $metadata|Add-Member -NotePropertyName common_prompt -NotePropertyValue $Text -Force
    [IO.File]::WriteAllText($metadataPath,($metadata|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
}

function Get-AtaraxiaCommonPromptForTaskDirectory([string]$TaskDirectory) {
    $sessionPrompt='';$projectPrompt='';$sessionMetadata=Join-Path $TaskDirectory 'session.json'
    if(Test-Path -LiteralPath $sessionMetadata -PathType Leaf){$metadata=Read-AgentJsonFile $sessionMetadata;if($null -ne $metadata.PSObject.Properties['common_prompt']){$sessionPrompt=[string]$metadata.common_prompt;Assert-AgentPlainText $sessionPrompt 'Session common prompt' -AllowMultiline}}
    $sessionsRoot=Split-Path -Parent $TaskDirectory
    if((Split-Path -Leaf $sessionsRoot) -ieq 'sessions'){$projectPath=Split-Path -Parent $sessionsRoot;$projectMetadata=Join-Path $projectPath 'project.json';if(Test-Path -LiteralPath $projectMetadata -PathType Leaf){$metadata=Read-AgentJsonFile $projectMetadata;if($null -ne $metadata.PSObject.Properties['common_prompt']){$projectPrompt=[string]$metadata.common_prompt;Assert-AgentPlainText $projectPrompt 'Project common prompt' -AllowMultiline}}}
    $sections=@();if(-not[string]::IsNullOrWhiteSpace($projectPrompt)){$sections+=@("## Project common prompt`r`n$projectPrompt")};if(-not[string]::IsNullOrWhiteSpace($sessionPrompt)){$sections+=@("## Session common prompt`r`n$sessionPrompt")};$combined=$sections -join "`r`n`r`n";Assert-AgentPlainText $combined 'Combined common prompt' -AllowMultiline;return $combined
}
