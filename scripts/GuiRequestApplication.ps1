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

function Save-AtaraxiaGuiRequestTransaction([string]$TaskPath,[string]$SessionMetadataPath,[string]$ConversationPath,[string]$Body,[object]$Dependencies,[switch]$ReplaceLatest) {
    if($null -eq $Dependencies){throw 'GUI request persistence adapters are required.'}
    foreach($name in @('read_json','write_json','test_file','remove_file','utc_now')){if($null -eq $Dependencies.PSObject.Properties[$name] -or $Dependencies.$name -isnot [scriptblock]){throw "GUI request persistence adapter '$name' is required."}}
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
    $writes=[System.Collections.Generic.List[object]]::new()
    $operations=@(
        [pscustomobject]@{path=$TaskPath;value=$task;existed=$true;before=$taskBefore},
        [pscustomobject]@{path=$SessionMetadataPath;value=$session;existed=$true;before=$sessionBefore},
        [pscustomobject]@{path=$ConversationPath;value=$nextConversation;existed=$conversationExisted;before=$conversationBefore}
    )
    try{foreach($operation in $operations){$writes.Add($operation);& $Dependencies.write_json $operation.path $operation.value|Out-Null}}
    catch{
        $operationError=$_;$rollbackErrors=[System.Collections.Generic.List[string]]::new()
        for($index=$writes.Count-1;$index -ge 0;$index--){$operation=$writes[$index];try{if($operation.existed){& $Dependencies.write_json $operation.path $operation.before|Out-Null}else{& $Dependencies.remove_file $operation.path|Out-Null}}catch{$rollbackErrors.Add("$($operation.path): $($_.Exception.Message)")}}
        if($rollbackErrors.Count -gt 0){throw [InvalidOperationException]::new("Request persistence failed: $($operationError.Exception.Message). Rollback also failed for $($rollbackErrors -join '; ')",$operationError.Exception)}
        throw $operationError
    }
    return [pscustomobject]@{task=$task;session=$session;conversation=$nextConversation;timestamp=$timestamp}
}
