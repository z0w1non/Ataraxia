Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'StructuredData.ps1')
. (Join-Path $PSScriptRoot 'JsonFileStore.ps1')

function Save-AtaraxiaPromptMetadata([string]$Path,[string]$Property,[string]$Text,[object]$Dependencies=$null) {
    if(-not(Test-AtaraxiaStorePath $Path 'Container' $Dependencies)){Ensure-AtaraxiaJsonStoreDirectory $Path $Dependencies}
    $metadataPath=Join-Path $Path 'project.json'
    if(Test-AtaraxiaStorePath $metadataPath 'Leaf' $Dependencies){$metadata=Read-AtaraxiaJsonStoreFile $metadataPath $Dependencies}else{$metadata=[pscustomobject][ordered]@{schema_version=1;artifact_type='project'}}
    Assert-AgentPlainText $Text 'Project common prompt' -AllowMultiline
    $metadata|Add-Member -NotePropertyName $Property -NotePropertyValue $Text -Force
    Write-AtaraxiaJsonStoreFile $metadataPath $metadata $Dependencies 20
}

function Set-AtaraxiaProjectCommonPrompt([string]$ProjectPath,[string]$Text,[object]$Dependencies=$null) {
    Save-AtaraxiaPromptMetadata $ProjectPath 'common_prompt' $Text $Dependencies
}

function Set-AtaraxiaSessionCommonPrompt([string]$SessionPath,[string]$Text,[object]$Dependencies=$null) {
    $metadataPath=Join-Path $SessionPath 'session.json'
    if(-not(Test-AtaraxiaStorePath $metadataPath 'Leaf' $Dependencies)){throw "Session metadata was not found: $metadataPath"}
    $metadata=Read-AtaraxiaJsonStoreFile $metadataPath $Dependencies
    Assert-AgentPlainText $Text 'Session common prompt' -AllowMultiline
    $metadata|Add-Member -NotePropertyName common_prompt -NotePropertyValue $Text -Force
    Write-AtaraxiaJsonStoreFile $metadataPath $metadata $Dependencies 20
}

function Get-AtaraxiaCommonPromptForTaskDirectory([string]$TaskDirectory,[object]$Dependencies=$null) {
    $sessionPrompt='';$projectPrompt='';$sessionMetadata=Join-Path $TaskDirectory 'session.json'
    if(Test-AtaraxiaStorePath $sessionMetadata 'Leaf' $Dependencies){$metadata=Read-AtaraxiaJsonStoreFile $sessionMetadata $Dependencies;if($null -ne $metadata.PSObject.Properties['common_prompt']){$sessionPrompt=[string]$metadata.common_prompt;Assert-AgentPlainText $sessionPrompt 'Session common prompt' -AllowMultiline}}
    $sessionsRoot=Split-Path -Parent $TaskDirectory
    if((Split-Path -Leaf $sessionsRoot) -ieq 'sessions'){$projectPath=Split-Path -Parent $sessionsRoot;$projectMetadata=Join-Path $projectPath 'project.json';if(Test-AtaraxiaStorePath $projectMetadata 'Leaf' $Dependencies){$metadata=Read-AtaraxiaJsonStoreFile $projectMetadata $Dependencies;if($null -ne $metadata.PSObject.Properties['common_prompt']){$projectPrompt=[string]$metadata.common_prompt;Assert-AgentPlainText $projectPrompt 'Project common prompt' -AllowMultiline}}}
    $sections=@();if(-not[string]::IsNullOrWhiteSpace($projectPrompt)){$sections+=@("## Project common prompt`r`n$projectPrompt")};if(-not[string]::IsNullOrWhiteSpace($sessionPrompt)){$sections+=@("## Session common prompt`r`n$sessionPrompt")};$combined=$sections -join "`r`n`r`n";Assert-AgentPlainText $combined 'Combined common prompt' -AllowMultiline;return $combined
}
