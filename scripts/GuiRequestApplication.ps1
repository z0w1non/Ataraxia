Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'ConversationStore.ps1')

function New-AtaraxiaGuiRequestPersistenceDependencies([scriptblock]$ReadJson,[scriptblock]$WriteJson,[scriptblock]$TestFile,[scriptblock]$RemoveFile,[scriptblock]$UtcNow) {
    foreach($port in @($ReadJson,$WriteJson,$TestFile,$RemoveFile,$UtcNow)){if($port -isnot [scriptblock]){throw 'GUI request persistence requires read, write, existence, removal, and clock adapters.'}}
    return [pscustomobject]@{read_json=$ReadJson;write_json=$WriteJson;test_file=$TestFile;remove_file=$RemoveFile;utc_now=$UtcNow}
}

function Copy-AtaraxiaGuiRequestJsonValue([object]$Value) {
    if($null -eq $Value){return $null}
    return ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 100)
}

function Assert-AtaraxiaGuiRequestTransactionJournal([object]$Journal) {
    if($Journal -isnot [System.Management.Automation.PSCustomObject] -or $null -eq $Journal.PSObject.Properties['schema_version'] -or [int]$Journal.schema_version -ne 1 -or $null -eq $Journal.PSObject.Properties['state'] -or [string]$Journal.state -cne 'pending' -or $null -eq $Journal.PSObject.Properties['task_before'] -or $Journal.task_before -isnot [System.Management.Automation.PSCustomObject] -or $null -eq $Journal.task_before.PSObject.Properties['goal'] -or $null -eq $Journal.session_before -or $Journal.session_before -isnot [System.Management.Automation.PSCustomObject] -or $Journal.session_before.artifact_type -cne 'session' -or $null -eq $Journal.PSObject.Properties['conversation_existed'] -or $Journal.conversation_existed -isnot [bool] -or $null -eq $Journal.PSObject.Properties['conversation_before']){throw 'GUI request recovery journal has an invalid structure; no files were changed.'}
    if($Journal.conversation_existed -and ($Journal.conversation_before -isnot [System.Management.Automation.PSCustomObject] -or $Journal.conversation_before.artifact_type -cne 'conversation' -or $Journal.conversation_before.entries -isnot [array])){throw 'GUI request recovery journal contains an invalid previous conversation; no files were changed.'}
    if(-not $Journal.conversation_existed -and $null -ne $Journal.conversation_before){throw 'GUI request recovery journal has a conversation snapshot without an original file; no files were changed.'}
    return $Journal
}

function Resolve-AtaraxiaGuiRequestTransaction([string]$TaskPath,[string]$SessionMetadataPath,[string]$ConversationPath,[string]$JournalPath,[object]$Dependencies) {
    if($null -eq $Dependencies){throw 'GUI request persistence adapters are required.'}
    foreach($name in @('read_json','write_json','test_file','remove_file')){if($null -eq $Dependencies.PSObject.Properties[$name] -or $Dependencies.$name -isnot [scriptblock]){throw "GUI request persistence adapter '$name' is required."}}
    if(-not [bool](& $Dependencies.test_file $JournalPath)){return [pscustomobject]@{recovered=$false;reason='none'}}
    if($null -ne (Get-Command Register-AgentJsonRepairKind -ErrorAction SilentlyContinue)){Register-AgentJsonRepairKind $JournalPath 'journal'}
    $journal=Assert-AtaraxiaGuiRequestTransactionJournal (& $Dependencies.read_json $JournalPath)
    $restoreErrors=[System.Collections.Generic.List[string]]::new()
    foreach($operation in @(
        [pscustomobject]@{path=$ConversationPath;existed=[bool]$journal.conversation_existed;value=$journal.conversation_before},
        [pscustomobject]@{path=$SessionMetadataPath;existed=$true;value=$journal.session_before},
        [pscustomobject]@{path=$TaskPath;existed=$true;value=$journal.task_before}
    )){try{if($operation.existed){& $Dependencies.write_json $operation.path (Copy-AtaraxiaGuiRequestJsonValue $operation.value)|Out-Null}else{& $Dependencies.remove_file $operation.path|Out-Null}}catch{$restoreErrors.Add("$($operation.path): $($_.Exception.Message)")}}
    if($restoreErrors.Count -gt 0){throw "GUI request restart recovery could not restore $($restoreErrors -join '; '). The journal '$JournalPath' was retained for retry."}
    try{& $Dependencies.remove_file $JournalPath|Out-Null}catch{throw "GUI request data was restored, but its journal '$JournalPath' could not be removed: $($_.Exception.Message)"}
    return [pscustomobject]@{recovered=$true;reason='rolled_back_pending_request'}
}

function Save-AtaraxiaGuiRequestTransaction([string]$TaskPath,[string]$SessionMetadataPath,[string]$ConversationPath,[string]$JournalPath,[string]$Body,[object]$Dependencies,[switch]$ReplaceLatest) {
    if($null -eq $Dependencies){throw 'GUI request persistence adapters are required.'}
    foreach($name in @('read_json','write_json','test_file','remove_file','utc_now')){if($null -eq $Dependencies.PSObject.Properties[$name] -or $Dependencies.$name -isnot [scriptblock]){throw "GUI request persistence adapter '$name' is required."}}
    if($null -ne (Get-Command Register-AgentJsonRepairKind -ErrorAction SilentlyContinue)){Register-AgentJsonRepairKind $JournalPath 'journal'}
    $null=Resolve-AtaraxiaGuiRequestTransaction $TaskPath $SessionMetadataPath $ConversationPath $JournalPath $Dependencies
    $task=& $Dependencies.read_json $TaskPath
    $session=& $Dependencies.read_json $SessionMetadataPath
    $conversation=if([bool](& $Dependencies.test_file $ConversationPath)){& $Dependencies.read_json $ConversationPath}else{$null}
    if($task -isnot [System.Management.Automation.PSCustomObject] -or $null -eq $task.PSObject.Properties['goal']){throw 'Task data has no goal field.'}
    if($session -isnot [System.Management.Automation.PSCustomObject] -or $session.artifact_type -cne 'session'){throw 'Session metadata is missing or invalid.'}
    $taskBefore=Copy-AtaraxiaGuiRequestJsonValue $task;$sessionBefore=Copy-AtaraxiaGuiRequestJsonValue $session
    $conversationExisted=$null -ne $conversation;$conversationBefore=if($conversationExisted){Copy-AtaraxiaGuiRequestJsonValue $conversation}else{$null}
    $now=& $Dependencies.utc_now
    if($now -isnot [DateTime]){throw 'GUI request persistence clock must return a DateTime.'}
    $timestamp=$now.ToUniversalTime().ToString('o')
    $task.goal=$Body;$session|Add-Member -NotePropertyName updated_at -NotePropertyValue $timestamp -Force
    $nextConversation=New-AtaraxiaRequestConversation $conversation $Body $timestamp -ReplaceLatest:$ReplaceLatest
    $journal=[pscustomobject][ordered]@{schema_version=1;state='pending';task_before=$taskBefore;session_before=$sessionBefore;conversation_existed=[bool]$conversationExisted;conversation_before=$conversationBefore}
    $writes=[System.Collections.Generic.List[object]]::new()
    $operations=@(
        [pscustomobject]@{path=$TaskPath;value=$task;existed=$true;before=$taskBefore},
        [pscustomobject]@{path=$SessionMetadataPath;value=$session;existed=$true;before=$sessionBefore},
        [pscustomobject]@{path=$ConversationPath;value=$nextConversation;existed=$conversationExisted;before=$conversationBefore}
    )
    try{
        & $Dependencies.write_json $JournalPath $journal|Out-Null
        foreach($operation in $operations){$writes.Add($operation);& $Dependencies.write_json $operation.path $operation.value|Out-Null}
        & $Dependencies.remove_file $JournalPath|Out-Null
    }
    catch{
        $operationError=$_;$rollbackErrors=[System.Collections.Generic.List[string]]::new();$journalRecreateError=''
        if($writes.Count -gt 0){$journalExists=$false;try{$journalExists=[bool](& $Dependencies.test_file $JournalPath)}catch{};if(-not $journalExists){try{& $Dependencies.write_json $JournalPath $journal|Out-Null}catch{$journalRecreateError=$_.Exception.Message}}}
        for($index=$writes.Count-1;$index -ge 0;$index--){$operation=$writes[$index];try{if($operation.existed){& $Dependencies.write_json $operation.path $operation.before|Out-Null}else{& $Dependencies.remove_file $operation.path|Out-Null}}catch{$rollbackErrors.Add("$($operation.path): $($_.Exception.Message)")}}
        if($rollbackErrors.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($journalRecreateError)){$rollbackErrors.Add("$JournalPath (journal recreation): $journalRecreateError")}
        if($rollbackErrors.Count -eq 0){try{& $Dependencies.remove_file $JournalPath|Out-Null}catch{$rollbackErrors.Add("$JournalPath (journal cleanup): $($_.Exception.Message)")}}
        if($rollbackErrors.Count -gt 0){throw [InvalidOperationException]::new("Request persistence failed: $($operationError.Exception.Message). Rollback also failed for $($rollbackErrors -join '; ')",$operationError.Exception)}
        throw $operationError
    }
    return [pscustomobject]@{task=$task;session=$session;conversation=$nextConversation;timestamp=$timestamp}
}
