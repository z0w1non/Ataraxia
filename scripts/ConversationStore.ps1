Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'StructuredData.ps1')

function Get-AtaraxiaConversation([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject][ordered]@{ schema_version=1; artifact_type='conversation'; entries=@() } }
    $conversation=Read-AgentJsonFile $Path
    if ($conversation.artifact_type -ne 'conversation' -or $null -eq $conversation.entries) { throw "Invalid conversation file: $Path" }
    return $conversation
}

function Save-AtaraxiaConversation([string]$Path,[object]$Conversation) {
    $temporaryPath="$Path.tmp"
    $json=$Conversation | ConvertTo-Json -Depth 40
    [IO.File]::WriteAllText($temporaryPath,$json,[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Add-AtaraxiaRequest([string]$Path,[string]$Body,[switch]$ReplaceLatest) {
    if ([string]::IsNullOrWhiteSpace($Body)) { throw 'Request must not be empty.' }
    if($Body -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'){throw 'Request contains unsupported control characters.'}
    try{[Text.UTF8Encoding]::new($false,$true).GetByteCount($Body)|Out-Null}catch{throw 'Request contains invalid Unicode text.'}
    $conversation=Get-AtaraxiaConversation $Path
    $entries=@($conversation.entries)
    $latest=-1
    for($index=$entries.Count-1;$index -ge 0;$index--) { if($entries[$index].kind -eq 'user_query'){$latest=$index;break} }
    if($ReplaceLatest -and $latest -ge 0) {
        $entries=@($entries[0..$latest])
        $entries[$latest].body=$Body
        $entries[$latest].timestamp=[DateTime]::UtcNow.ToString('o')
    } else {
        $entries+=@([pscustomobject][ordered]@{kind='user_query';body=$Body;timestamp=[DateTime]::UtcNow.ToString('o')})
    }
    $conversation.entries=$entries
    Save-AtaraxiaConversation $Path $conversation
    return $conversation
}
