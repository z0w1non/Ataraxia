Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'StructuredData.ps1')

function Get-AtaraxiaSessionsRoot([string]$ProjectPath) {
    return Join-Path $ProjectPath 'sessions'
}

function Get-AtaraxiaSessions([string]$ProjectPath) {
    $root=Get-AtaraxiaSessionsRoot $ProjectPath
    if(-not(Test-Path -LiteralPath $root -PathType Container)){return @()}
    $sessions=[System.Collections.Generic.List[object]]::new()
    foreach($item in Get-ChildItem -LiteralPath $root -Directory){
        $metadataPath=Join-Path $item.FullName 'session.json'
        if(-not(Test-Path -LiteralPath $metadataPath -PathType Leaf)){continue}
        try{$metadata=Read-AgentJsonFile $metadataPath}catch{continue}
        if($metadata.artifact_type -ne 'session' -or [string]::IsNullOrWhiteSpace([string]$metadata.id)){continue}
        $metadata|Add-Member -NotePropertyName path -NotePropertyValue $item.FullName -Force
        $sessions.Add($metadata)
    }
    return @($sessions|Sort-Object {[string]$_.updated_at} -Descending)
}

function Get-AtaraxiaRecentSessions([string]$ProjectsRoot,[int]$Maximum=5) {
    if($Maximum -lt 1){return @()}
    $recent=[System.Collections.Generic.List[object]]::new()
    if(-not(Test-Path -LiteralPath $ProjectsRoot -PathType Container)){return @()}
    foreach($projectItem in Get-ChildItem -LiteralPath $ProjectsRoot -Directory){
        $projectName=$projectItem.Name
        if($projectName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'){continue}
        $projectPath=Join-Path $ProjectsRoot $projectName
        foreach($session in Get-AtaraxiaSessions $projectPath){
            $conversationPath=Join-Path ([string]$session.path) 'conversation.json'
            if(-not(Test-Path -LiteralPath $conversationPath -PathType Leaf)){continue}
            try{$conversation=Read-AgentJsonFile $conversationPath;$query=@($conversation.entries|Where-Object{$_.kind -eq 'user_query'}|Sort-Object {[string]$_.timestamp}|Select-Object -Last 1);if($query.Count -eq 0){continue};$requestedAt=[DateTime]::Parse([string]$query[0].timestamp).ToUniversalTime()}catch{continue}
            $session|Add-Member -NotePropertyName project_name -NotePropertyValue $projectName -Force
            $session|Add-Member -NotePropertyName last_request_at -NotePropertyValue $requestedAt -Force
            $recent.Add($session)
        }
    }
    return @($recent|Sort-Object last_request_at -Descending|Select-Object -First $Maximum)
}

function New-AtaraxiaSession([string]$ProjectPath,[object]$RoleContracts,[string]$Title='New session') {
    if(-not(Test-Path -LiteralPath $ProjectPath -PathType Container)){throw "Project directory was not found: $ProjectPath"}
    $sessionsRoot=Get-AtaraxiaSessionsRoot $ProjectPath
    New-Item -ItemType Directory -Force -Path $sessionsRoot|Out-Null
    $timestamp=[DateTime]::UtcNow
    $sessionId='session-'+$timestamp.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $sessionPath=Join-Path $sessionsRoot $sessionId
    New-Item -ItemType Directory -Path $sessionPath|Out-Null
    $workspace=Join-Path $sessionPath 'workspace'
    New-Item -ItemType Directory -Path $workspace|Out-Null
    $task=Agent-NewTaskTemplate $sessionId $RoleContracts
    $task.working_directory=$workspace
    $task.goal=''
    $taskPath=Join-Path $sessionPath ($sessionId+'.task.json')
    [IO.File]::WriteAllText($taskPath,($task|ConvertTo-Json -Depth 50),[Text.UTF8Encoding]::new($false))
    if([string]::IsNullOrWhiteSpace($Title)){$Title='New session'}
    $metadata=[pscustomobject][ordered]@{schema_version=1;artifact_type='session';id=$sessionId;title=$Title;title_generated=$false;title_source='pending';created_at=$timestamp.ToString('o');updated_at=$timestamp.ToString('o');task_file=(Split-Path -Leaf $taskPath)}
    [IO.File]::WriteAllText((Join-Path $sessionPath 'session.json'),($metadata|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    $metadata|Add-Member -NotePropertyName path -NotePropertyValue $sessionPath -Force
    return $metadata
}

function Touch-AtaraxiaSession([string]$SessionDirectory) {
    $metadataPath=Join-Path $SessionDirectory 'session.json'
    if(-not(Test-Path -LiteralPath $metadataPath -PathType Leaf)){return}
    $metadata=Read-AgentJsonFile $metadataPath
    $metadata.updated_at=[DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText($metadataPath,($metadata|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
}

function Set-AtaraxiaSessionTitle([string]$SessionDirectory,[string]$Title,[ValidateSet('user','agent')][string]$Source='user') {
    $cleanTitle=($Title -replace '\s+',' ').Trim()
    if([string]::IsNullOrWhiteSpace($cleanTitle) -or $cleanTitle.Length -gt 64 -or $cleanTitle -match '[\x00-\x1f\x7f]'){throw (Get-AppText 'session_title_invalid')}
    $metadataPath=Join-Path $SessionDirectory 'session.json'
    if(-not(Test-Path -LiteralPath $metadataPath -PathType Leaf)){throw "Session metadata was not found: $metadataPath"}
    $metadata=Read-AgentJsonFile $metadataPath
    $metadata.title=$cleanTitle;$metadata.title_generated=$true;$metadata.title_source=$Source;$metadata.updated_at=[DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText($metadataPath,($metadata|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    return $metadata
}
