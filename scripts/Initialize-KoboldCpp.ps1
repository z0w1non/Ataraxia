[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$ConfigPath = (Join-Path (Join-Path $PSScriptRoot '..\configs') 'config.json'),
    [ValidateSet('auto','cuda','nocuda','oldpc')]
    [string]$Build = 'auto',
    [switch]$Launch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Localization.ps1')
. (Join-Path $PSScriptRoot 'StructuredData.ps1')
. (Join-Path $PSScriptRoot 'KoboldCppSettings.ps1')

function Test-KoboldCppReady([uri]$ServerUri) {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $pending = $client.BeginConnect($ServerUri.Host, $ServerUri.Port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(1000, $false)) { return $false }
        $client.EndConnect($pending)
        return $true
    } catch { return $false }
    finally { $client.Dispose() }
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw (Get-AppText 'kobold_config_missing' @($ConfigPath)) }
$configFullPath = [IO.Path]::GetFullPath($ConfigPath)
$config = Read-AgentJsonFile $configFullPath
if (-not [string]::IsNullOrWhiteSpace([string]$config.interface_language)) { Set-AppLanguage ([string]$config.interface_language) }
$videoControllerNames=@()
if($Build -eq 'auto'){try{$videoControllerNames=@(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop|Select-Object -ExpandProperty Name)}catch{$videoControllerNames=@()}}
$requestedBuild=$Build
$Build=Resolve-KoboldCppBuild $Build $videoControllerNames
Write-Output (Get-AppText 'kobold_build_selected' @($Build,$requestedBuild))
$settings = Import-KoboldCppSettings $config $configFullPath
$settingsPath = [string]$config.koboldcpp_settings_path
if (-not [IO.Path]::IsPathRooted($settingsPath)) { $settingsPath = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $configFullPath) $settingsPath)) }
$paths = $settings.paths
$installDirectory = [string]$paths.install_directory
$modelDirectory = [string]$paths.model_directory
$modelFile = [string]$paths.model_file
$installDirectory = if ([IO.Path]::IsPathRooted($installDirectory)) { [IO.Path]::GetFullPath($installDirectory) } else { [IO.Path]::GetFullPath((Join-Path $projectRoot $installDirectory)) }
$modelDirectory = if ([IO.Path]::IsPathRooted($modelDirectory)) { [IO.Path]::GetFullPath($modelDirectory) } else { [IO.Path]::GetFullPath((Join-Path $projectRoot $modelDirectory)) }
New-Item -ItemType Directory -Force -Path $installDirectory, $modelDirectory | Out-Null
$modelFullPath = if ([IO.Path]::IsPathRooted($modelFile)) { [IO.Path]::GetFullPath($modelFile) } else { [IO.Path]::GetFullPath((Join-Path $modelDirectory $modelFile)) }
$paths | Add-Member -NotePropertyName install_directory -NotePropertyValue $installDirectory -Force
$paths | Add-Member -NotePropertyName model_directory -NotePropertyValue $modelDirectory -Force
$paths | Add-Member -NotePropertyName model_file -NotePropertyValue ([IO.Path]::GetFileName($modelFile)) -Force
$paths | Add-Member -NotePropertyName executable -NotePropertyValue (Join-Path $installDirectory 'koboldcpp.exe') -Force

$apiUri = 'https://api.github.com/repos/LostRuins/koboldcpp/releases/latest'
$release = Invoke-RestMethod -Uri $apiUri -Headers @{ 'User-Agent'='Ataraxia-Setup' }
$assetName = switch ($Build) { 'cuda' { 'koboldcpp.exe' } 'nocuda' { 'koboldcpp-nocuda.exe' } 'oldpc' { 'koboldcpp-oldpc.exe' } }
$asset = @($release.assets | Where-Object { $_.name -eq $assetName }) | Select-Object -First 1
if ($null -eq $asset) { throw (Get-AppText 'kobold_release_asset_missing' @($assetName)) }
$downloadPath = Join-Path $installDirectory 'koboldcpp.exe'
$temporaryDownload = "$downloadPath.download"
if ($PSCmdlet.ShouldProcess($downloadPath, "Download official KoboldCpp $($release.tag_name) and verify GitHub SHA-256")) {
    Invoke-WebRequest -Uri ([string]$asset.browser_download_url) -OutFile $temporaryDownload -Headers @{ 'User-Agent'='Ataraxia-Setup' }
    if ($null -eq $asset.digest -or [string]$asset.digest -notmatch '^sha256:([0-9a-fA-F]{64})$') { Remove-Item -LiteralPath $temporaryDownload -Force; throw (Get-AppText 'kobold_release_digest_missing') }
    $expectedHash = $Matches[1].ToLowerInvariant()
    $actualHash = (Get-FileHash -LiteralPath $temporaryDownload -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $expectedHash) { Remove-Item -LiteralPath $temporaryDownload -Force; throw (Get-AppText 'kobold_digest_mismatch') }
    Move-Item -LiteralPath $temporaryDownload -Destination (Join-Path $installDirectory 'koboldcpp.exe') -Force
    $settings | Add-Member -NotePropertyName release_tag -NotePropertyValue ([string]$release.tag_name) -Force
    $settings | Add-Member -NotePropertyName sha256 -NotePropertyValue $actualHash -Force
}

Save-KoboldCppSettings $settingsPath $settings

Write-Output (Get-AppText 'kobold_release_label' @([string]$release.tag_name))
Write-Output (Get-AppText 'kobold_install_folder_label' @($installDirectory))
Write-Output (Get-AppText 'kobold_model_folder_label' @($modelDirectory))
if ($Launch) {
    if ([string]::IsNullOrWhiteSpace($modelFile)) { throw (Get-AppText 'kobold_model_name_required') }
    if (-not (Test-Path -LiteralPath $modelFullPath -PathType Leaf)) { throw (Get-AppText 'kobold_model_file_missing' @($modelFullPath)) }
    if ($PSCmdlet.ShouldProcess($downloadPath, 'Launch KoboldCpp with the configured local model')) {
        $effectiveSettings = Get-KoboldCppModelSettings $settings $modelFullPath
        $launchArguments = @(Get-KoboldCppLaunchArguments $effectiveSettings $modelFullPath) -join ' '
        $process = Start-Process -FilePath ([string]$paths.executable) -ArgumentList $launchArguments -WorkingDirectory $installDirectory -WindowStyle Hidden -PassThru
        $serverUri = [uri][string]$config.api_server
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while ([DateTime]::UtcNow -lt $deadline) {
            if (Test-KoboldCppReady $serverUri) { Write-Output (Get-AppText 'kobold_ready' @([string]$serverUri)); break }
            $process.Refresh()
            if ($process.HasExited) { throw (Get-AppText 'kobold_process_exited' @([int]$process.ExitCode)) }
            Start-Sleep -Seconds 1
        }
        if (-not (Test-KoboldCppReady $serverUri)) { throw (Get-AppText 'kobold_startup_timeout' @([string]$serverUri)) }
    }
}
