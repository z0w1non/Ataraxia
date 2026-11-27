Set-StrictMode -Version Latest

function New-AgentHarnessDependencies([scriptblock]$RunCommand) {
    if($null -eq $RunCommand){throw 'A process runner adapter is required.'}
    return [pscustomobject]@{run_command=$RunCommand}
}

function Invoke-AgentProcessRunner([object]$Dependencies,[object]$Resolved,[string]$WorkspaceDirectory) {
    if($null -eq $Dependencies -or $null -eq $Dependencies.PSObject.Properties['run_command'] -or $Dependencies.run_command -isnot [scriptblock]){throw 'The process runner port is not configured.'}
    if($null -eq $Resolved){throw 'Resolved command does not satisfy the process runner input contract.'}
    foreach($name in @('id','executable','argument_text','timeout_seconds')){if($null -eq $Resolved.PSObject.Properties[$name]){throw "Resolved command is missing '$name'."}}
    if([string]::IsNullOrWhiteSpace([string]$Resolved.id) -or [string]::IsNullOrWhiteSpace([string]$Resolved.executable) -or $Resolved.timeout_seconds -isnot [int] -or [int]$Resolved.timeout_seconds -lt 1){throw 'Resolved command does not satisfy the process runner input contract.'}
    if([string]::IsNullOrWhiteSpace($WorkspaceDirectory) -or -not [IO.Path]::IsPathRooted($WorkspaceDirectory)){throw 'Process runner workspace must be an absolute path.'}
    $result=& $Dependencies.run_command $Resolved $WorkspaceDirectory
    if($null -eq $result){throw 'Process runner returned no result.'}
    foreach($name in @('exit_code','timed_out','duration_ms','stdout','stderr')){if($null -eq $result.PSObject.Properties[$name]){throw "Process runner result is missing '$name'."}}
    if($result.exit_code -isnot [int] -and $result.exit_code -isnot [long] -and $result.exit_code -isnot [short]){throw 'Process runner exit_code must be an integer.'}
    if($result.timed_out -isnot [bool]){throw 'Process runner timed_out must be a Boolean.'}
    if($result.duration_ms -isnot [int] -and $result.duration_ms -isnot [long] -and $result.duration_ms -isnot [short]){throw 'Process runner duration_ms must be an integer.'}
    if([long]$result.duration_ms -lt 0){throw 'Process runner duration_ms must not be negative.'}
    if($result.stdout -isnot [string] -or $result.stderr -isnot [string]){throw 'Process runner stdout and stderr must be strings.'}
    return [pscustomobject][ordered]@{exit_code=[int]$result.exit_code;timed_out=[bool]$result.timed_out;duration_ms=[long]$result.duration_ms;stdout=[string]$result.stdout;stderr=[string]$result.stderr}
}
