Set-StrictMode -Version Latest

function Assert-AtaraxiaGuiChildProcessRequest([object]$Request,[switch]$RequireOutput) {
    if($null -eq $Request){throw 'GUI child process request is required.'}
    foreach($name in @('executable','arguments','working_directory','stdout_path','stderr_path')){if($null -eq $Request.PSObject.Properties[$name]){throw "GUI child process request is missing '$name'."}}
    foreach($name in @('executable','working_directory')){if([string]::IsNullOrWhiteSpace([string]$Request.$name) -or -not [IO.Path]::IsPathRooted([string]$Request.$name)){throw "GUI child process path must be absolute: $name"}}
    if([string]::IsNullOrWhiteSpace([string]$Request.arguments)){throw 'GUI child process arguments are required.'}
    $hasStdout=-not [string]::IsNullOrWhiteSpace([string]$Request.stdout_path);$hasStderr=-not [string]::IsNullOrWhiteSpace([string]$Request.stderr_path)
    if($hasStdout -xor $hasStderr){throw 'GUI child process output paths must be provided together.'}
    if($RequireOutput -and -not $hasStdout){throw 'Synchronous GUI child process requests require output paths.'}
    if($hasStdout){foreach($name in @('stdout_path','stderr_path')){if(-not [IO.Path]::IsPathRooted([string]$Request.$name)){throw "GUI child process path must be absolute: $name"}}}
}

function Start-AtaraxiaGuiChildProcess([object]$Request) {
    Assert-AtaraxiaGuiChildProcessRequest $Request
    $parameters=@{FilePath=[string]$Request.executable;ArgumentList=[string]$Request.arguments;WorkingDirectory=[IO.Path]::GetFullPath([string]$Request.working_directory);WindowStyle='Hidden';PassThru=$true}
    if(-not [string]::IsNullOrWhiteSpace([string]$Request.stdout_path)){$parameters.RedirectStandardOutput=[string]$Request.stdout_path;$parameters.RedirectStandardError=[string]$Request.stderr_path}
    return Start-Process @parameters
}

function Get-AtaraxiaGuiChildProcessStatus([object]$Process) {
    if($null -eq $Process -or $null -eq $Process.PSObject.Methods['Refresh']){throw 'GUI child process handle is required.'}
    $Process.Refresh();$exited=[bool]$Process.HasExited
    return [pscustomobject][ordered]@{has_exited=$exited;exit_code=if($exited){[int]$Process.ExitCode}else{$null}}
}

function Close-AtaraxiaGuiChildProcess([object]$Process) {
    if($null -eq $Process -or $null -eq $Process.PSObject.Methods['Dispose']){throw 'GUI child process handle is required.'}
    $Process.Dispose()
}

function Stop-AtaraxiaGuiChildProcess([object]$Process,[int]$WaitMilliseconds=5000) {
    if($null -eq $Process -or $null -eq $Process.PSObject.Methods['Refresh']){throw 'GUI child process handle is required.'}
    if($WaitMilliseconds -lt 0){throw 'GUI process wait duration cannot be negative.'}
    $wasRunning=$false;$hasExited=$false
    try{$Process.Refresh();$wasRunning=-not [bool]$Process.HasExited;if($wasRunning){$Process.Kill();$null=$Process.WaitForExit($WaitMilliseconds)};$hasExited=[bool]$Process.HasExited}finally{$Process.Dispose()}
    return [pscustomobject][ordered]@{was_running=$wasRunning;has_exited=$hasExited}
}

function Invoke-AtaraxiaGuiChildProcess([object]$Request) {
    Assert-AtaraxiaGuiChildProcessRequest $Request -RequireOutput
    $process=Start-Process -FilePath ([string]$Request.executable) -ArgumentList ([string]$Request.arguments) -WorkingDirectory ([IO.Path]::GetFullPath([string]$Request.working_directory)) -WindowStyle Hidden -PassThru -Wait -RedirectStandardOutput ([string]$Request.stdout_path) -RedirectStandardError ([string]$Request.stderr_path)
    try{return [pscustomobject][ordered]@{exit_code=[int]$process.ExitCode}}finally{$process.Dispose()}
}
