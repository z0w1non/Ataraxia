Set-StrictMode -Version Latest

function Invoke-AtaraxiaPowerShellProcess([object]$Resolved,[string]$WorkspaceDirectory) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = [string]$Resolved.executable
    $start.Arguments = [string]$Resolved.argument_text
    $start.WorkingDirectory = [IO.Path]::GetFullPath($WorkspaceDirectory)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) { throw "Command failed to start: $($Resolved.id)" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit([int]$Resolved.timeout_seconds * 1000)
        if ($timedOut) { $process.Kill(); $process.WaitForExit() }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $clock.Stop()
        return [pscustomobject]@{exit_code=if($timedOut){-1}else{[int]$process.ExitCode};timed_out=[bool]$timedOut;duration_ms=[long]$clock.ElapsedMilliseconds;stdout=[string]$stdout;stderr=[string]$stderr}
    } finally { $process.Dispose() }
}
