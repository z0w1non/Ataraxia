Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'StructuredData.ps1')
. (Join-Path $PSScriptRoot 'JsonFileStore.ps1')

function New-AtaraxiaStoreDependencies([scriptblock]$ReadJson=$null,[scriptblock]$WriteJson=$null,[scriptblock]$UtcNow=$null) {
    return [pscustomobject]@{ read_json=$ReadJson; write_json=$WriteJson; utc_now=$UtcNow }
}

function Get-AtaraxiaStoreUtcNow([object]$Dependencies) {
    if ($null -ne $Dependencies -and $Dependencies.utc_now -is [scriptblock]) { return (& $Dependencies.utc_now) }
    return [DateTime]::UtcNow
}

function Get-AtaraxiaConversation([string]$Path,[object]$Dependencies=$null) {
    if ($null -ne $Dependencies -and $Dependencies.read_json -is [scriptblock]) {
        $conversation=& $Dependencies.read_json $Path
        if ($null -eq $conversation) { return [pscustomobject][ordered]@{ schema_version=1; artifact_type='conversation'; entries=@() } }
    } else {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject][ordered]@{ schema_version=1; artifact_type='conversation'; entries=@() } }
    $conversation=Read-AgentJsonFile $Path
    }
    if ($conversation.artifact_type -ne 'conversation' -or $null -eq $conversation.entries) { throw "Invalid conversation file: $Path" }
    return $conversation
}

function Save-AtaraxiaConversation([string]$Path,[object]$Conversation,[object]$Dependencies=$null) {
    if ($null -ne $Dependencies -and $Dependencies.write_json -is [scriptblock]) { & $Dependencies.write_json $Path $Conversation | Out-Null; return }
    Write-AtaraxiaJsonStoreFile $Path $Conversation $null 40
}

function Add-AtaraxiaRequest([string]$Path,[string]$Body,[switch]$ReplaceLatest,[object]$Dependencies=$null) {
    if ([string]::IsNullOrWhiteSpace($Body)) { throw 'Request must not be empty.' }
    if($Body -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'){throw 'Request contains unsupported control characters.'}
    try{[Text.UTF8Encoding]::new($false,$true).GetByteCount($Body)|Out-Null}catch{throw 'Request contains invalid Unicode text.'}
    $conversation=Get-AtaraxiaConversation $Path $Dependencies
    $timestamp=(Get-AtaraxiaStoreUtcNow $Dependencies).ToString('o')
    $entries=@($conversation.entries)
    $latest=-1
    for($index=$entries.Count-1;$index -ge 0;$index--) { if($entries[$index].kind -eq 'user_query'){$latest=$index;break} }
    if($ReplaceLatest -and $latest -ge 0) {
        $entries=@($entries[0..$latest])
        $entries[$latest].body=$Body
        $entries[$latest].timestamp=$timestamp
    } else {
        $entries+=@([pscustomobject][ordered]@{kind='user_query';body=$Body;timestamp=$timestamp})
    }
    $conversation.entries=$entries
    Save-AtaraxiaConversation $Path $conversation $Dependencies
    return $conversation
}
