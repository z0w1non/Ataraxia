function Test-AtaraxiaTcpEndpoint([string]$HostName,[int]$Port,[int]$TimeoutMilliseconds=250) {
    if([string]::IsNullOrWhiteSpace($HostName) -or $Port -lt 1 -or $Port -gt 65535 -or $TimeoutMilliseconds -lt 1){return $false}
    $client=$null;$waitHandle=$null
    try {
        $client=[Net.Sockets.TcpClient]::new()
        $pending=$client.BeginConnect($HostName,$Port,$null,$null)
        $waitHandle=$pending.AsyncWaitHandle
        if(-not $waitHandle.WaitOne($TimeoutMilliseconds,$false)){return $false}
        $client.EndConnect($pending)
        return $true
    } catch {return $false} finally {
        if($null -ne $waitHandle){$waitHandle.Close()}
        if($null -ne $client){$client.Dispose()}
    }
}
