Set-StrictMode -Version Latest

function New-AgentTaskExecutionLockDependencies([scriptblock]$Acquire=$null,[scriptblock]$Release=$null) {
    if($null -eq $Acquire){$Acquire={param($Path)$fullPath=[IO.Path]::GetFullPath($Path);try{return [IO.File]::Open($fullPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch [IO.IOException]{$nativeError=$_.Exception.HResult -band 0xFFFF;if($nativeError -in @(32,33)){throw "This task is already being run or changed by another process: $fullPath"};throw}}.GetNewClosure()}
    if($null -eq $Release){$Release={param($Lock)if($null -ne $Lock){$Lock.Dispose()}}.GetNewClosure()}
    if($Acquire -isnot [scriptblock] -or $Release -isnot [scriptblock]){throw 'Task execution lock acquire and release adapters must be script blocks.'}
    return [pscustomobject]@{acquire=$Acquire;release=$Release}
}

function Enter-AgentTaskExecutionLock([string]$Path,[object]$Dependencies=(New-AgentTaskExecutionLockDependencies)) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Task lock path is required.' }
    if($null -eq $Dependencies -or $Dependencies.acquire -isnot [scriptblock]){throw 'Task execution lock adapter is not configured.'}
    return & $Dependencies.acquire ([IO.Path]::GetFullPath($Path))
}

function Exit-AgentTaskExecutionLock([object]$Lock,[object]$Dependencies=(New-AgentTaskExecutionLockDependencies)) {
    if($null -eq $Dependencies -or $Dependencies.release -isnot [scriptblock]){throw 'Task execution lock adapter is not configured.'}
    & $Dependencies.release $Lock
}
