Set-StrictMode -Version Latest

function Invoke-AtaraxiaGuiProcessPoll([object]$State,[string]$StdoutPath,[string]$StderrPath,[scriptblock]$ReadOutput) {
    if($null -eq $State -or $State.phase -ne 'running'){throw 'A running GUI process state is required for polling.'}
    if($ReadOutput -isnot [scriptblock]){throw 'A process output reader adapter is required.'}
    $output=& $ReadOutput $StdoutPath $StderrPath ([int]$State.output_line_count)
    if($null -eq $output -or $null -eq $output.PSObject.Properties['lines'] -or $null -eq $output.PSObject.Properties['next_index'] -or $null -eq $output.PSObject.Properties['error_text']){throw 'Process output reader returned an invalid result.'}
    $update=Get-AtaraxiaGuiProcessUpdate -Lines @($output.lines) -ErrorText ([string]$output.error_text)
    $update|Add-Member -NotePropertyName next_index -NotePropertyValue $output.next_index -Force
    $nextState=Update-AtaraxiaGuiProcessState $State $update
    $presentation=if(-not [string]::IsNullOrWhiteSpace([string]$update.error_text)){[pscustomobject]@{kind='error';text=[string]$update.error_text;role=''}}elseif($update.role_events.Count -gt 0){[pscustomobject]@{kind='role';text='';role=[string]$nextState.current_role}}else{[pscustomobject]@{kind='none';text='';role=''}}
    return [pscustomobject][ordered]@{state=$nextState;presentation=$presentation}
}

function Complete-AtaraxiaGuiProcess([object]$State,[int]$ExitCode,[string]$TaskPath='') {
    $completed=Complete-AtaraxiaGuiProcessState $State $ExitCode
    $presentation=if($ExitCode -eq 0){[pscustomobject]@{kind='ready';text='';exit_code=$ExitCode}}else{[pscustomobject]@{kind='failure';text="Agent exited with code $ExitCode.";exit_code=$ExitCode}}
    return [pscustomobject][ordered]@{state=$completed;presentation=$presentation;refresh_session=(-not [string]::IsNullOrWhiteSpace($TaskPath))}
}

function New-AtaraxiaGuiRollbackRequest([string]$TaskPath,[string]$ConfigPath) {
    if([string]::IsNullOrWhiteSpace($TaskPath)){return [pscustomobject][ordered]@{required=$false;task_path='';config_path=''}}
    if([string]::IsNullOrWhiteSpace($ConfigPath)){throw 'Rollback requires a configuration path.'}
    return [pscustomobject][ordered]@{required=$true;task_path=[IO.Path]::GetFullPath($TaskPath);config_path=[IO.Path]::GetFullPath($ConfigPath)}
}

function New-AtaraxiaGuiAgentLaunchRequest([string]$Executable,[string]$RunnerPath,[string]$TaskPath,[string]$ConfigPath,[string]$WorkingDirectory,[string]$StdoutPath,[string]$StderrPath) {
    foreach($path in @($Executable,$RunnerPath,$TaskPath,$ConfigPath,$WorkingDirectory,$StdoutPath,$StderrPath)){if([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathRooted($path)){throw 'GUI agent launch paths must be absolute.'}}
    $quote={param([string]$Value)'"'+$Value.Replace('"','\"')+'"'}.GetNewClosure()
    $arguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(& $quote $RunnerPath),'-Run',(& $quote $TaskPath),'-Step','-1','-ConfigPath',(& $quote $ConfigPath)) -join ' '
    return [pscustomobject][ordered]@{executable=[IO.Path]::GetFullPath($Executable);arguments=$arguments;working_directory=[IO.Path]::GetFullPath($WorkingDirectory);stdout_path=[IO.Path]::GetFullPath($StdoutPath);stderr_path=[IO.Path]::GetFullPath($StderrPath)}
}

function New-AtaraxiaGuiChildProcessRequest([string]$Executable,[string]$Arguments,[string]$WorkingDirectory,[string]$StdoutPath='',[string]$StderrPath='') {
    foreach($path in @($Executable,$WorkingDirectory)){if([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathRooted($path)){throw 'GUI child process executable and working directory must be absolute.'}}
    if([string]::IsNullOrWhiteSpace($Arguments)){throw 'GUI child process arguments are required.'}
    if([string]::IsNullOrWhiteSpace($StdoutPath) -xor [string]::IsNullOrWhiteSpace($StderrPath)){throw 'GUI child process output paths must be provided together.'}
    if(-not [string]::IsNullOrWhiteSpace($StdoutPath)){foreach($path in @($StdoutPath,$StderrPath)){if(-not [IO.Path]::IsPathRooted($path)){throw 'GUI child process output paths must be absolute.'}}}
    return [pscustomobject][ordered]@{executable=[IO.Path]::GetFullPath($Executable);arguments=$Arguments;working_directory=[IO.Path]::GetFullPath($WorkingDirectory);stdout_path=if($StdoutPath){[IO.Path]::GetFullPath($StdoutPath)}else{''};stderr_path=if($StderrPath){[IO.Path]::GetFullPath($StderrPath)}else{''}}
}

function New-AtaraxiaGuiStartupRelaunchRequest([string]$Executable,[object]$StartupPlan,[string]$WorkingDirectory) {
    if($null -eq $StartupPlan -or $null -eq $StartupPlan.PSObject.Properties['argument_text']){throw 'GUI startup plan is required for STA relaunch.'}
    return New-AtaraxiaGuiChildProcessRequest $Executable ([string]$StartupPlan.argument_text) $WorkingDirectory
}

function New-AtaraxiaGuiRollbackLaunchRequest([string]$Executable,[string]$RunnerPath,[string]$TaskPath,[string]$ConfigPath,[string]$WorkingDirectory,[string]$StdoutPath,[string]$StderrPath) {
    $rollback=New-AtaraxiaGuiRollbackRequest $TaskPath $ConfigPath
    if(-not $rollback.required){return [pscustomobject][ordered]@{required=$false;executable='';arguments='';working_directory='';stdout_path='';stderr_path=''}}
    foreach($path in @($Executable,$RunnerPath,$WorkingDirectory,$StdoutPath,$StderrPath)){if([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathRooted($path)){throw 'GUI rollback launch paths must be absolute.'}}
    $quote={param([string]$Value)'"'+$Value.Replace('"','\"')+'"'}.GetNewClosure()
    $arguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(& $quote $RunnerPath),'-Rollback',(& $quote $rollback.task_path),'-ConfigPath',(& $quote $rollback.config_path)) -join ' '
    return [pscustomobject][ordered]@{required=$true;executable=[IO.Path]::GetFullPath($Executable);arguments=$arguments;working_directory=[IO.Path]::GetFullPath($WorkingDirectory);stdout_path=[IO.Path]::GetFullPath($StdoutPath);stderr_path=[IO.Path]::GetFullPath($StderrPath)}
}
