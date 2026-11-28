Set-StrictMode -Version Latest

function New-AtaraxiaGuiStartupPlan([string]$ScriptPath,[string]$ConfigPath='',[switch]$NoSplash) {
    if([string]::IsNullOrWhiteSpace($ScriptPath)){throw 'GUI script path is required.'}
    $quote={param([string]$Value) return '"'+$Value.Replace('"','\"')+'"'}.GetNewClosure()
    $arguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',(& $quote $ScriptPath))
    if(-not [string]::IsNullOrWhiteSpace($ConfigPath)){$arguments+=@('-ConfigPath',(& $quote $ConfigPath))}
    if($NoSplash){$arguments+='-NoSplash'}
    return [pscustomobject][ordered]@{show_splash=(-not [bool]$NoSplash);argument_text=($arguments -join ' ');arguments=$arguments}
}

function Test-AtaraxiaGuiPollingIntervalElapsed([datetime]$Now,[datetime]$LastPoll,[int]$IntervalMilliseconds=2000) {
    if($IntervalMilliseconds -lt 0){throw 'GUI polling interval cannot be negative.'}
    return $Now.Subtract($LastPoll).TotalMilliseconds -ge $IntervalMilliseconds
}

function New-AtaraxiaGuiSessionSelectionState {
    return [pscustomobject]@{is_synchronizing=$false}
}

function Set-AtaraxiaGuiSessionSelectionSynchronization([object]$State,[bool]$IsSynchronizing) {
    if($null -eq $State){throw 'Session selection state is required.'}
    return [pscustomobject]@{state=[pscustomobject]@{is_synchronizing=$IsSynchronizing};selection_requested=(-not $IsSynchronizing)}
}

function Resolve-AtaraxiaGuiSessionTaskPath([string]$ProjectPath,[string]$SessionPath,[scriptblock]$ReadMetadata) {
    if($null -eq $ReadMetadata){throw 'A session metadata reader must be provided.'}
    $project=[IO.Path]::GetFullPath($ProjectPath).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $sessionsRoot=[IO.Path]::GetFullPath((Join-Path $project 'sessions')).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $session=[IO.Path]::GetFullPath($SessionPath)
    if(-not $session.StartsWith($sessionsRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'The selected session is outside its project.'}
    $metadataPath=Join-Path $session 'session.json'
    $metadata=& $ReadMetadata $metadataPath
    $taskFile=[string]$metadata.task_file
    if([string]::IsNullOrWhiteSpace($taskFile) -or [IO.Path]::GetFileName($taskFile) -cne $taskFile -or $taskFile.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0){throw 'Session task file name is invalid.'}
    return [pscustomobject][ordered]@{project_path=$project;session_path=$session;metadata_path=$metadataPath;task_path=(Join-Path $session $taskFile)}
}

function Open-AtaraxiaGuiProjectSession([string]$ProjectPath,[string]$SessionPath,[string]$ActiveProjectName,[scriptblock]$ReadMetadata,[scriptblock]$ActivateProject) {
    if($ActivateProject -isnot [scriptblock]){throw 'A project activation adapter must be provided.'}
    $resolved=Resolve-AtaraxiaGuiSessionTaskPath $ProjectPath $SessionPath $ReadMetadata
    $projectName=Split-Path -Leaf $resolved.project_path
    $activated=($projectName -ine $ActiveProjectName)
    if($activated){& $ActivateProject $projectName}
    return [pscustomobject][ordered]@{project_name=$projectName;project_path=$resolved.project_path;session_path=$resolved.session_path;task_path=$resolved.task_path;activated_project=$activated}
}

function Build-AtaraxiaGuiProjectSessionOverview([string]$ProjectsRoot,[string]$ActiveProjectName,[int]$RecentLimit,[scriptblock]$ListProjects,[scriptblock]$ResolveProjectPath,[scriptblock]$ListSessions,[scriptblock]$ListRecentSessions,[scriptblock]$JsonReader=$null) {
    foreach($port in @($ListProjects,$ResolveProjectPath,$ListSessions,$ListRecentSessions)){if($port -isnot [scriptblock]){throw 'Project/session overview requires all store adapters.'}}
    if($null -ne $JsonReader -and $JsonReader -isnot [scriptblock]){throw 'Project/session overview JSON reader must be a script block.'}
    $projects=[System.Collections.Generic.List[object]]::new()
    foreach($name in @(& $ListProjects $ProjectsRoot)){
        $path=[string](& $ResolveProjectPath $ProjectsRoot ([string]$name))
        $sessionItems=[System.Collections.Generic.List[object]]::new()
        if($null -ne $JsonReader){foreach($session in & $ListSessions $path $JsonReader){$sessionItems.Add($session)|Out-Null}}else{foreach($session in & $ListSessions $path){$sessionItems.Add($session)|Out-Null}}
        $projects.Add([pscustomobject][ordered]@{name=[string]$name;path=$path;is_active=([string]$name -ieq $ActiveProjectName);sessions=$sessionItems.ToArray()})
    }
    $recentItems=[System.Collections.Generic.List[object]]::new()
    if($null -ne $JsonReader){foreach($session in & $ListRecentSessions $ProjectsRoot ([Math]::Max(0,$RecentLimit)) $JsonReader){$recentItems.Add($session)|Out-Null}}else{foreach($session in & $ListRecentSessions $ProjectsRoot ([Math]::Max(0,$RecentLimit))){$recentItems.Add($session)|Out-Null}}
    return [pscustomobject][ordered]@{projects=$projects.ToArray();recent_sessions=$recentItems.ToArray()}
}

function New-AtaraxiaGuiProjectSessionDependencies([scriptblock]$ListProjects,[scriptblock]$ResolveProjectPath,[scriptblock]$ListSessions,[scriptblock]$ListRecentSessions,[scriptblock]$ProjectExists,[scriptblock]$CreateProject,[scriptblock]$RenameProject,[scriptblock]$CreateSession,[scriptblock]$RenameSession,[scriptblock]$ActivateProject) {
    foreach($port in @($ListProjects,$ResolveProjectPath,$ListSessions,$ListRecentSessions,$ProjectExists,$CreateProject,$RenameProject,$CreateSession,$RenameSession,$ActivateProject)){if($port -isnot [scriptblock]){throw 'Project/session application dependencies must be explicit adapters.'}}
    return [pscustomobject]@{list_projects=$ListProjects;resolve_project_path=$ResolveProjectPath;list_sessions=$ListSessions;list_recent_sessions=$ListRecentSessions;project_exists=$ProjectExists;create_project=$CreateProject;rename_project=$RenameProject;create_session=$CreateSession;rename_session=$RenameSession;activate_project=$ActivateProject}
}

function Get-AtaraxiaGuiProjectSessionOverview([object]$Dependencies,[string]$ProjectsRoot,[string]$ActiveProjectName,[int]$RecentLimit) {
    if($null -eq $Dependencies){throw 'Project/session application dependencies are required.'}
    $jsonReaderProperty=$Dependencies.PSObject.Properties['json_reader'];$jsonReader=if($null -ne $jsonReaderProperty){$jsonReaderProperty.Value}else{$null}
    return Build-AtaraxiaGuiProjectSessionOverview $ProjectsRoot $ActiveProjectName $RecentLimit $Dependencies.list_projects $Dependencies.resolve_project_path $Dependencies.list_sessions $Dependencies.list_recent_sessions $jsonReader
}

function Get-AtaraxiaGuiSessions([object]$Dependencies,[string]$ProjectPath) {
    if($null -eq $Dependencies -or $Dependencies.list_sessions -isnot [scriptblock]){throw 'Session listing adapter is not configured.'}
    return @(& $Dependencies.list_sessions $ProjectPath)
}

function New-AtaraxiaGuiSessionForProject([object]$Dependencies,[string]$ProjectsRoot,[string]$ProjectName,[string]$ActiveProjectName,[object]$RoleContracts,[string]$Title='New session') {
    if($null -eq $Dependencies){throw 'Project/session application dependencies are required.'}
    $path=[string](& $Dependencies.resolve_project_path $ProjectsRoot $ProjectName)
    if(-not [bool](& $Dependencies.project_exists $path)){& $Dependencies.create_project $ProjectsRoot $ProjectName|Out-Null}
    if($ProjectName -ine $ActiveProjectName){& $Dependencies.activate_project $ProjectName|Out-Null}
    $session=& $Dependencies.create_session $path $RoleContracts $Title
    return [pscustomobject][ordered]@{project_name=$ProjectName;project_path=$path;session=$session;task_path=(Join-Path ([string]$session.path) ([string]$session.task_file))}
}

function Prepare-AtaraxiaGuiProject([object]$Dependencies,[string]$ProjectsRoot,[string]$ProjectName,[string]$ActiveProjectName) {
    if($null -eq $Dependencies){throw 'Project/session application dependencies are required.'}
    $path=[string](& $Dependencies.resolve_project_path $ProjectsRoot $ProjectName)
    $created= -not [bool](& $Dependencies.project_exists $path)
    if($created){& $Dependencies.create_project $ProjectsRoot $ProjectName|Out-Null}
    $activated=($ProjectName -ine $ActiveProjectName)
    if($activated){& $Dependencies.activate_project $ProjectName|Out-Null}
    return [pscustomobject][ordered]@{project_name=$ProjectName;project_path=$path;created_project=$created;activated_project=$activated}
}

function Rename-AtaraxiaGuiProject([object]$Dependencies,[string]$ProjectsRoot,[string]$OldName,[string]$NewName,[string]$ActiveProjectName) {
    if($null -eq $Dependencies){throw 'Project/session application dependencies are required.'}
    $path=[string](& $Dependencies.rename_project $ProjectsRoot $OldName $NewName)
    $active=($OldName -ieq $ActiveProjectName)
    if($active){
        try{& $Dependencies.activate_project $NewName|Out-Null}
        catch{
            $activationError=$_;$compensationErrors=[System.Collections.Generic.List[string]]::new();$nameRestored=$false
            try{$path=[string](& $Dependencies.rename_project $ProjectsRoot $NewName $OldName);$nameRestored=$true}catch{$compensationErrors.Add('restore project name: '+$_.Exception.Message)}
            if($nameRestored){try{& $Dependencies.activate_project $OldName|Out-Null}catch{$compensationErrors.Add('restore active project: '+$_.Exception.Message)}}
            if($compensationErrors.Count -gt 0){throw "Project rename activation failed: $($activationError.Exception.Message). Compensation also failed: $($compensationErrors -join '; ')"}
            throw $activationError.Exception
        }
    }
    return [pscustomobject][ordered]@{project_name=$NewName;project_path=$path;active_project_changed=$active}
}

function Rename-AtaraxiaGuiSession([object]$Dependencies,[string]$SessionPath,[string]$Title,[string]$Source='user') {
    if($null -eq $Dependencies -or $Dependencies.rename_session -isnot [scriptblock]){throw 'Session rename adapter is not configured.'}
    return & $Dependencies.rename_session $SessionPath $Title $Source
}

function ConvertFrom-AtaraxiaGuiRunOutput([string]$Line) {
    $match=[regex]::Match($Line,'^\s*Run:\s*(?<role>\S.*?)\s*$')
    if(-not $match.Success){return $null}
    return [pscustomobject]@{kind='role';role=$match.Groups['role'].Value.Trim()}
}

function Get-AtaraxiaGuiProcessUpdate([string[]]$Lines,[string]$ErrorText='') {
    $events=[System.Collections.Generic.List[object]]::new()
    for($index=0;$index -lt $Lines.Count;$index++){
        $event=ConvertFrom-AtaraxiaGuiRunOutput ([string]$Lines[$index])
        if($null -ne $event){$events.Add($event)}
    }
    $cleanError=[regex]::Replace($ErrorText,'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))','') -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]',''
    return [pscustomobject][ordered]@{role_events=@($events);error_text=$cleanError.Trim()}
}

function Resolve-AtaraxiaGuiKoboldStatus([bool]$ApiReachable,[bool]$ManagedProcessRunning,[bool]$SetupProcessRunning) {
    if($SetupProcessRunning){return 'starting'}
    if($ApiReachable){return 'connected'}
    if($ManagedProcessRunning){return 'starting'}
    return 'disconnected'
}

function Test-AtaraxiaGuiServiceConnection([string]$Endpoint,[scriptblock]$Probe,[int]$TimeoutMilliseconds=250) {
    if($Probe -isnot [scriptblock]){throw 'A service connection probe adapter is required.'}
    if($TimeoutMilliseconds -lt 1){throw 'Service connection timeout must be positive.'}
    try {
        $uri=$null
        if(-not [uri]::TryCreate($Endpoint,[UriKind]::Absolute,[ref]$uri) -or [string]::IsNullOrWhiteSpace($uri.Host)){return $false}
        return [bool](& $Probe $uri.Host $uri.Port $TimeoutMilliseconds)
    } catch {return $false}
}

function Invoke-AtaraxiaGuiKoboldRestart([bool]$ManagedProcessRunning,[scriptblock]$SaveSettings,[scriptblock]$StopManagedProcess,[scriptblock]$ProbeConnection,[scriptblock]$Wait,[scriptblock]$UtcNow,[scriptblock]$StartManagedProcess,[int]$TimeoutSeconds=10,[int]$PollIntervalMilliseconds=250) {
    foreach($dependency in @($SaveSettings,$StopManagedProcess,$ProbeConnection,$Wait,$UtcNow,$StartManagedProcess)){if($dependency -isnot [scriptblock]){throw 'KoboldCpp restart dependencies must be explicit adapters.'}}
    if($TimeoutSeconds -lt 0 -or $PollIntervalMilliseconds -lt 1){throw 'KoboldCpp restart timing values are invalid.'}
    if(-not $ManagedProcessRunning){return [pscustomobject][ordered]@{restarted=$false;reason='managed_process_required'}}
    & $SaveSettings
    & $StopManagedProcess
    $deadline=([datetime](& $UtcNow)).AddSeconds($TimeoutSeconds)
    while([bool](& $ProbeConnection) -and ([datetime](& $UtcNow) -lt $deadline)){& $Wait $PollIntervalMilliseconds}
    if([bool](& $ProbeConnection)){return [pscustomobject][ordered]@{restarted=$false;reason='port_busy'}}
    & $StartManagedProcess
    return [pscustomobject][ordered]@{restarted=$true;reason=''}
}

function New-AtaraxiaGuiKoboldLaunchPlan([object]$Settings,[string]$ApplicationRoot,[scriptblock]$PathExists,[scriptblock]$ResolveSettings,[scriptblock]$BuildArguments) {
    foreach($dependency in @($PathExists,$ResolveSettings,$BuildArguments)){if($dependency -isnot [scriptblock]){throw 'KoboldCpp launch plan dependencies must be explicit adapters.'}}
    if($null -eq $Settings -or $null -eq $Settings.paths){throw 'KoboldCpp launch settings are required.'}
    $paths=$Settings.paths
    $installDirectory=if([IO.Path]::IsPathRooted([string]$paths.install_directory)){[IO.Path]::GetFullPath([string]$paths.install_directory)}else{[IO.Path]::GetFullPath((Join-Path $ApplicationRoot ([string]$paths.install_directory)))}
    $executable=if([IO.Path]::IsPathRooted([string]$paths.executable)){[IO.Path]::GetFullPath([string]$paths.executable)}else{[IO.Path]::GetFullPath((Join-Path $ApplicationRoot ([string]$paths.executable)))}
    if(-not [bool](& $PathExists $executable)){return [pscustomobject][ordered]@{ready=$false;reason='missing_executable';executable=$executable;working_directory=$installDirectory;model_path='';arguments=@()}}
    $modelFile=[string]$paths.model_file
    if([string]::IsNullOrWhiteSpace($modelFile)){return [pscustomobject][ordered]@{ready=$false;reason='model_required';executable=$executable;working_directory=$installDirectory;model_path='';arguments=@()}}
    $modelDirectory=if([IO.Path]::IsPathRooted([string]$paths.model_directory)){[IO.Path]::GetFullPath([string]$paths.model_directory)}else{[IO.Path]::GetFullPath((Join-Path $ApplicationRoot ([string]$paths.model_directory)))}
    $modelPath=if([IO.Path]::IsPathRooted($modelFile)){[IO.Path]::GetFullPath($modelFile)}else{[IO.Path]::GetFullPath((Join-Path $modelDirectory $modelFile))}
    if(-not [bool](& $PathExists $modelPath)){return [pscustomobject][ordered]@{ready=$false;reason='missing_model';executable=$executable;working_directory=$installDirectory;model_path=$modelPath;arguments=@()}}
    $effective=& $ResolveSettings $Settings
    $arguments=@(& $BuildArguments $effective $modelPath)
    return [pscustomobject][ordered]@{ready=$true;reason='';executable=$executable;working_directory=$installDirectory;model_path=$modelPath;arguments=$arguments}
}
