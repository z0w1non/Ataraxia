Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'StructuredData.ps1')
. (Join-Path $PSScriptRoot 'JsonFileStore.ps1')

function New-AtaraxiaSessionStoreDependencies([scriptblock]$PathExists=$null,[scriptblock]$CreateDirectory=$null,[scriptblock]$WriteJson=$null,[scriptblock]$UtcNow=$null,[scriptblock]$NewId=$null,[scriptblock]$ReadJson=$null,[scriptblock]$RemoveDirectory=$null,[object]$FileStore=$null) {
    return [pscustomobject]@{ path_exists=$PathExists; create_directory=$CreateDirectory; write_json=$WriteJson; utc_now=$UtcNow; new_id=$NewId; read_json=$ReadJson; remove_directory=$RemoveDirectory; file_store=$FileStore }
}

function Test-AtaraxiaSessionPath([string]$Path,[object]$Dependencies) {
    if($null -ne $Dependencies -and $Dependencies.path_exists -is [scriptblock]) { return [bool](& $Dependencies.path_exists $Path) }
    if($null -ne $Dependencies -and $null -ne $Dependencies.PSObject.Properties['file_store']){return Test-AtaraxiaStorePath $Path 'Container' $Dependencies.file_store}
    return Test-Path -LiteralPath $Path -PathType Container
}

function New-AtaraxiaSessionDirectory([string]$Path,[object]$Dependencies,[switch]$Force) {
    if($null -ne $Dependencies -and $Dependencies.create_directory -is [scriptblock]) { & $Dependencies.create_directory $Path ([bool]$Force) | Out-Null; return }
    if($null -ne $Dependencies -and $null -ne $Dependencies.PSObject.Properties['file_store']){Ensure-AtaraxiaJsonStoreDirectory $Path $Dependencies.file_store;return}
    New-Item -ItemType Directory -Force:$Force -Path $Path | Out-Null
}

function Remove-AtaraxiaCreatedSessionDirectory([string]$Path,[string]$SessionsRoot,[object]$Dependencies,[switch]$EmptyOnly) {
    $root=[IO.Path]::GetFullPath($SessionsRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $target=[IO.Path]::GetFullPath($Path)
    if(-not $target.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw "Session cleanup target escaped its sessions directory: $target"}
    if($null -ne $Dependencies -and $Dependencies.remove_directory -is [scriptblock]){& $Dependencies.remove_directory $target ([bool]$EmptyOnly)|Out-Null;return}
    if(-not [IO.Directory]::Exists($target)){return}
    $item=Get-Item -LiteralPath $target -Force -ErrorAction Stop
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "Session cleanup refuses to recurse through a reparse point: $target"}
    [IO.Directory]::Delete($target,(-not [bool]$EmptyOnly))
}

function Write-AtaraxiaSessionJson([string]$Path,[object]$Value,[object]$Dependencies) {
    if($null -ne $Dependencies -and $Dependencies.write_json -is [scriptblock]) { & $Dependencies.write_json $Path $Value | Out-Null; return }
    if($null -ne $Dependencies -and $null -ne $Dependencies.PSObject.Properties['file_store']){Write-AtaraxiaJsonStoreFile $Path $Value $Dependencies.file_store 50;return}
    Write-AtaraxiaJsonStoreFile $Path $Value $Dependencies 50
}

function Get-AtaraxiaSessionClock([object]$Dependencies) {
    if($null -ne $Dependencies -and $Dependencies.utc_now -is [scriptblock]) { return (& $Dependencies.utc_now) }
    return [DateTime]::UtcNow
}

function Get-AtaraxiaSessionsRoot([string]$ProjectPath) {
    return Join-Path $ProjectPath 'sessions'
}

function Get-AtaraxiaSessions([string]$ProjectPath,[object]$Dependencies=$null) {
    if($Dependencies -is [scriptblock]){$Dependencies=[pscustomobject]@{read_json=$Dependencies;file_store=$null}}
    $root=Get-AtaraxiaSessionsRoot $ProjectPath
    $fileStore=if($null -ne $Dependencies -and $null -ne $Dependencies.PSObject.Properties['file_store']){$Dependencies.file_store}else{$Dependencies}
    if(-not(Test-AtaraxiaStorePath $root 'Container' $fileStore)){return @()}
    $sessions=[System.Collections.Generic.List[object]]::new()
    foreach($item in Get-AtaraxiaStoreDirectories $root $fileStore){
        $metadataPath=Join-Path $item.FullName 'session.json'
        if(-not(Test-AtaraxiaStorePath $metadataPath 'Leaf' $fileStore)){continue}
        try{$metadata=Read-AtaraxiaJsonStoreFile $metadataPath $Dependencies}catch{continue}
        if($metadata.artifact_type -ne 'session' -or [string]::IsNullOrWhiteSpace([string]$metadata.id)){continue}
        $metadata|Add-Member -NotePropertyName path -NotePropertyValue $item.FullName -Force
        $sessions.Add($metadata)
    }
    return @($sessions|Sort-Object {[string]$_.updated_at} -Descending)
}

function Get-AtaraxiaRecentSessions([string]$ProjectsRoot,[int]$Maximum=5,[object]$Dependencies=$null) {
    if($Dependencies -is [scriptblock]){$Dependencies=[pscustomobject]@{read_json=$Dependencies;file_store=$null}}
    if($Maximum -lt 1){return @()}
    $recent=[System.Collections.Generic.List[object]]::new()
    $fileStore=if($null -ne $Dependencies -and $null -ne $Dependencies.PSObject.Properties['file_store']){$Dependencies.file_store}else{$Dependencies}
    if(-not(Test-AtaraxiaStorePath $ProjectsRoot 'Container' $fileStore)){return @()}
    foreach($projectItem in Get-AtaraxiaStoreDirectories $ProjectsRoot $fileStore){
        $projectName=$projectItem.Name
        if($projectName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'){continue}
        $projectPath=Join-Path $ProjectsRoot $projectName
        foreach($session in Get-AtaraxiaSessions $projectPath $Dependencies){
            $conversationPath=Join-Path ([string]$session.path) 'conversation.json'
            if(-not(Test-AtaraxiaStorePath $conversationPath 'Leaf' $fileStore)){continue}
            try{$conversation=Read-AtaraxiaJsonStoreFile $conversationPath $Dependencies;$query=@($conversation.entries|Where-Object{$_.kind -eq 'user_query'}|Sort-Object {[string]$_.timestamp}|Select-Object -Last 1);if($query.Count -eq 0){continue};$requestedAt=[DateTime]::Parse([string]$query[0].timestamp).ToUniversalTime()}catch{continue}
            $session|Add-Member -NotePropertyName project_name -NotePropertyValue $projectName -Force
            $session|Add-Member -NotePropertyName last_request_at -NotePropertyValue $requestedAt -Force
            $recent.Add($session)
        }
    }
    return @($recent|Sort-Object last_request_at -Descending|Select-Object -First $Maximum)
}

function New-AtaraxiaSession([string]$ProjectPath,[object]$RoleContracts,[string]$Title='New session',[object]$Dependencies=$null) {
    if(-not(Test-AtaraxiaSessionPath $ProjectPath $Dependencies)){throw "Project directory was not found: $ProjectPath"}
    $sessionsRoot=Get-AtaraxiaSessionsRoot $ProjectPath
    $sessionsRootCreated=-not(Test-AtaraxiaSessionPath $sessionsRoot $Dependencies)
    $timestamp=Get-AtaraxiaSessionClock $Dependencies
    $guid=if($null -ne $Dependencies -and $Dependencies.new_id -is [scriptblock]){[string](& $Dependencies.new_id)}else{[guid]::NewGuid().ToString('N')}
    if($guid -notmatch '^[0-9a-fA-F]{32}$'){throw 'Session id provider must return 32 hexadecimal characters.'}
    $sessionId='session-'+$timestamp.ToString('yyyyMMdd-HHmmss')+'-'+$guid.Substring(0,8)
    $sessionPath=Join-Path $sessionsRoot $sessionId
    $sessionDirectoryCreated=$false
    try{
        New-AtaraxiaSessionDirectory $sessionsRoot $Dependencies -Force
        New-AtaraxiaSessionDirectory $sessionPath $Dependencies;$sessionDirectoryCreated=$true
        $workspace=Join-Path $sessionPath 'workspace';New-AtaraxiaSessionDirectory $workspace $Dependencies
        $task=Agent-NewTaskTemplate $sessionId $RoleContracts;$task.working_directory=$workspace;$task.goal=''
        $taskPath=Join-Path $sessionPath ($sessionId+'.task.json');Write-AtaraxiaSessionJson $taskPath $task $Dependencies
        if([string]::IsNullOrWhiteSpace($Title)){$Title='New session'}
        $metadata=[pscustomobject][ordered]@{schema_version=1;artifact_type='session';id=$sessionId;title=$Title;title_generated=$false;title_source='pending';created_at=$timestamp.ToString('o');updated_at=$timestamp.ToString('o');task_file=(Split-Path -Leaf $taskPath)}
        Write-AtaraxiaSessionJson (Join-Path $sessionPath 'session.json') $metadata $Dependencies
        $metadata|Add-Member -NotePropertyName path -NotePropertyValue $sessionPath -Force
        return $metadata
    }catch{
        $creationError=$_
        $cleanupErrors=[System.Collections.Generic.List[string]]::new()
        if($sessionDirectoryCreated){try{Remove-AtaraxiaCreatedSessionDirectory $sessionPath $sessionsRoot $Dependencies}catch{$cleanupErrors.Add("session directory '$sessionPath': $($_.Exception.Message)")}}
        if($sessionsRootCreated -and $cleanupErrors.Count -eq 0){try{Remove-AtaraxiaCreatedSessionDirectory $sessionsRoot $ProjectPath $Dependencies -EmptyOnly}catch{$cleanupErrors.Add("sessions directory '$sessionsRoot': $($_.Exception.Message)")}}
        if($cleanupErrors.Count -gt 0){throw [InvalidOperationException]::new("Session creation failed: $($creationError.Exception.Message). Cleanup also failed; inspect $($cleanupErrors -join '; ')",$creationError.Exception)}
        throw $creationError
    }
}

function Touch-AtaraxiaSession([string]$SessionDirectory,[object]$Dependencies=$null) {
    $metadataPath=Join-Path $SessionDirectory 'session.json'
    if(-not(Test-Path -LiteralPath $metadataPath -PathType Leaf)){return}
    $metadata=Read-AtaraxiaJsonStoreFile $metadataPath $Dependencies
    $metadata.updated_at=[DateTime]::UtcNow.ToString('o')
    Write-AtaraxiaJsonStoreFile $metadataPath $metadata $Dependencies 10
}

function Set-AtaraxiaSessionTitle([string]$SessionDirectory,[string]$Title,[ValidateSet('user','agent')][string]$Source='user',[object]$Dependencies=$null) {
    $cleanTitle=($Title -replace '\s+',' ').Trim()
    if([string]::IsNullOrWhiteSpace($cleanTitle) -or $cleanTitle.Length -gt 64 -or $cleanTitle -match '[\x00-\x1f\x7f]'){throw (Get-AppText 'session_title_invalid')}
    $metadataPath=Join-Path $SessionDirectory 'session.json'
    if(-not(Test-Path -LiteralPath $metadataPath -PathType Leaf)){throw "Session metadata was not found: $metadataPath"}
    $metadata=Read-AtaraxiaJsonStoreFile $metadataPath $Dependencies
    $metadata.title=$cleanTitle;$metadata.title_generated=$true;$metadata.title_source=$Source;$metadata.updated_at=[DateTime]::UtcNow.ToString('o')
    Write-AtaraxiaJsonStoreFile $metadataPath $metadata $Dependencies 10
    return $metadata
}
