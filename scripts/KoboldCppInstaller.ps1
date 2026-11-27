Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'adapters/TcpConnectionAdapter.ps1')

function New-KoboldCppInstallerDependencies([scriptblock]$GetRelease=$null,[scriptblock]$Download=$null,[scriptblock]$EnsureDirectory=$null,[scriptblock]$TestFile=$null,[scriptblock]$GetHash=$null,[scriptblock]$DeleteFile=$null,[scriptblock]$MoveFile=$null,[scriptblock]$StartProcess=$null,[scriptblock]$GetProcessState=$null,[scriptblock]$TestEndpoint=$null,[scriptblock]$Sleep=$null,[scriptblock]$UtcNow=$null) {
    if($null -eq $GetRelease){$GetRelease={param($Uri)Invoke-RestMethod -Uri $Uri -Headers @{ 'User-Agent'='Ataraxia-Setup' } -ErrorAction Stop}.GetNewClosure()}
    if($null -eq $Download){$Download={param($Uri,$Path)Invoke-WebRequest -Uri $Uri -OutFile $Path -Headers @{ 'User-Agent'='Ataraxia-Setup' } -ErrorAction Stop}.GetNewClosure()}
    if($null -eq $EnsureDirectory){$EnsureDirectory={param($Path)New-Item -ItemType Directory -Force -Path $Path|Out-Null}.GetNewClosure()}
    if($null -eq $TestFile){$TestFile={param($Path)(Test-Path -LiteralPath $Path -PathType Leaf)}.GetNewClosure()}
    if($null -eq $GetHash){$GetHash={param($Path)(Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()}.GetNewClosure()}
    if($null -eq $DeleteFile){$DeleteFile={param($Path)Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue}.GetNewClosure()}
    if($null -eq $MoveFile){$MoveFile={param($Source,$Destination)Move-Item -LiteralPath $Source -Destination $Destination -Force}.GetNewClosure()}
    if($null -eq $StartProcess){$StartProcess={param($Executable,$Arguments,$WorkingDirectory)Start-Process -FilePath $Executable -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -PassThru}.GetNewClosure()}
    if($null -eq $GetProcessState){$GetProcessState={param($Process)$Process.Refresh();[pscustomobject]@{has_exited=[bool]$Process.HasExited;exit_code=if($Process.HasExited){[int]$Process.ExitCode}else{$null}}}.GetNewClosure()}
    if($null -eq $TestEndpoint){$TestEndpoint={param($HostName,$Port,$TimeoutMilliseconds)Test-AtaraxiaTcpEndpoint $HostName $Port $TimeoutMilliseconds}.GetNewClosure()}
    if($null -eq $Sleep){$Sleep={param($Seconds)Start-Sleep -Seconds $Seconds}.GetNewClosure()}
    if($null -eq $UtcNow){$UtcNow={ [DateTime]::UtcNow }.GetNewClosure()}
    foreach($adapter in @($GetRelease,$Download,$EnsureDirectory,$TestFile,$GetHash,$DeleteFile,$MoveFile,$StartProcess,$GetProcessState,$TestEndpoint,$Sleep,$UtcNow)){if($adapter -isnot [scriptblock]){throw 'KoboldCpp installer dependencies must be script blocks.'}}
    return [pscustomobject]@{get_release=$GetRelease;download=$Download;ensure_directory=$EnsureDirectory;test_file=$TestFile;get_hash=$GetHash;delete_file=$DeleteFile;move_file=$MoveFile;start_process=$StartProcess;get_process_state=$GetProcessState;test_endpoint=$TestEndpoint;sleep=$Sleep;utc_now=$UtcNow}
}

function Get-KoboldCppRelease([object]$Dependencies,[string]$Uri='https://api.github.com/repos/LostRuins/koboldcpp/releases/latest') {
    if($null -eq $Dependencies -or $Dependencies.get_release -isnot [scriptblock]){throw 'KoboldCpp release reader is not configured.'}
    $release=& $Dependencies.get_release $Uri
    if($null -eq $release -or $null -eq $release.PSObject.Properties['assets']){throw 'KoboldCpp release response has no assets.'}
    return $release
}

function Get-KoboldCppReleaseAsset([object]$Release,[ValidateSet('cuda','nocuda','oldpc')][string]$Build) {
    $assetName=switch($Build){'cuda'{'koboldcpp.exe'}'nocuda'{'koboldcpp-nocuda.exe'}'oldpc'{'koboldcpp-oldpc.exe'}}
    $asset=@($Release.assets|Where-Object{$_.name -ceq $assetName}|Select-Object -First 1)
    if($asset.Count -eq 0){throw (Get-AppText 'kobold_release_asset_missing' @($assetName))}
    $uri=$null
    if(-not [uri]::TryCreate([string]$asset[0].browser_download_url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host) -or -not [string]::IsNullOrEmpty($uri.UserInfo)){throw 'KoboldCpp release asset URL must be an HTTPS URI without credentials.'}
    return $asset[0]
}

function Install-KoboldCppReleaseAsset([object]$Asset,[string]$Destination,[object]$Dependencies) {
    if($null -eq $Asset -or [string]::IsNullOrWhiteSpace($Destination)){throw 'KoboldCpp asset and destination are required.'}
    if($null -eq $Dependencies -or $Dependencies.download -isnot [scriptblock] -or $Dependencies.get_hash -isnot [scriptblock] -or $Dependencies.move_file -isnot [scriptblock] -or $Dependencies.delete_file -isnot [scriptblock] -or $Dependencies.test_file -isnot [scriptblock]){throw 'KoboldCpp installer storage and download adapters are incomplete.'}
    $digestMatch=[regex]::Match([string]$Asset.digest,'^sha256:([0-9a-fA-F]{64})$')
    if(-not $digestMatch.Success){throw (Get-AppText 'kobold_release_digest_missing')}
    $expectedHash=$digestMatch.Groups[1].Value.ToLowerInvariant();$temporary=$Destination+'.download';$parent=Split-Path -Parent $Destination
    if($Dependencies.ensure_directory -is [scriptblock]){& $Dependencies.ensure_directory $parent|Out-Null}
    try{
        & $Dependencies.download ([string]$Asset.browser_download_url) $temporary
        if(-not [bool](& $Dependencies.test_file $temporary)){throw 'KoboldCpp download adapter did not produce the temporary asset.'}
        $actualHash=[string](& $Dependencies.get_hash $temporary)
        if($actualHash -notmatch '^[0-9a-fA-F]{64}$'){throw 'KoboldCpp hash adapter returned an invalid SHA-256 digest.'}
        $actualHash=$actualHash.ToLowerInvariant()
        if($actualHash -cne $expectedHash){throw (Get-AppText 'kobold_digest_mismatch')}
        & $Dependencies.move_file $temporary $Destination
        return $actualHash
    }finally{& $Dependencies.delete_file $temporary}
}

function Start-KoboldCppAndWait([string]$Executable,[string]$Arguments,[string]$WorkingDirectory,[uri]$ServerUri,[object]$Dependencies,[int]$TimeoutSeconds=60,[int]$ProbeTimeoutMilliseconds=1000,[int]$PollIntervalSeconds=1) {
    if([string]::IsNullOrWhiteSpace($Executable) -or [string]::IsNullOrWhiteSpace($Arguments) -or [string]::IsNullOrWhiteSpace($WorkingDirectory) -or $null -eq $ServerUri){throw 'KoboldCpp launch executable, arguments, directory, and server URI are required.'}
    if($TimeoutSeconds -lt 1 -or $ProbeTimeoutMilliseconds -lt 1 -or $PollIntervalSeconds -lt 1){throw 'KoboldCpp startup timeout and polling intervals must be positive.'}
    foreach($name in @('start_process','get_process_state','test_endpoint','sleep','utc_now')){if($null -eq $Dependencies -or $Dependencies.$name -isnot [scriptblock]){throw "KoboldCpp process adapter '$name' is not configured."}}
    $process=& $Dependencies.start_process $Executable $Arguments $WorkingDirectory
    if($null -eq $process){throw 'KoboldCpp process adapter did not return a process handle.'}
    $deadline=([DateTime](& $Dependencies.utc_now)).AddSeconds($TimeoutSeconds)
    while([DateTime](& $Dependencies.utc_now) -lt $deadline){
        if([bool](& $Dependencies.test_endpoint $ServerUri.Host $ServerUri.Port $ProbeTimeoutMilliseconds)){return [pscustomobject]@{process=$process;server_uri=[string]$ServerUri;ready=$true}}
        $state=& $Dependencies.get_process_state $process
        if($null -eq $state -or $state.has_exited -isnot [bool]){throw 'KoboldCpp process state adapter returned an invalid result.'}
        if($state.has_exited){throw (Get-AppText 'kobold_process_exited' @([int]$state.exit_code))}
        & $Dependencies.sleep $PollIntervalSeconds
    }
    if([bool](& $Dependencies.test_endpoint $ServerUri.Host $ServerUri.Port $ProbeTimeoutMilliseconds)){return [pscustomobject]@{process=$process;server_uri=[string]$ServerUri;ready=$true}}
    throw (Get-AppText 'kobold_startup_timeout' @([string]$ServerUri))
}
