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
. (Join-Path $PSScriptRoot 'KoboldCppInstaller.ps1')
. (Join-Path $PSScriptRoot 'adapters/WindowsHardwareInfoAdapter.ps1')

$installerDependencies=New-KoboldCppInstallerDependencies
$jsonStore=New-AtaraxiaJsonFileStoreDependencies
if (-not (Test-AtaraxiaJsonStoreFile $ConfigPath $jsonStore)) { throw (Get-AppText 'kobold_config_missing' @($ConfigPath)) }
$configFullPath = [IO.Path]::GetFullPath($ConfigPath)
$config = Read-AtaraxiaJsonStoreFile $configFullPath $jsonStore
if (-not [string]::IsNullOrWhiteSpace([string]$config.interface_language)) { Set-AppLanguage ([string]$config.interface_language) }
$hardwareInfo=New-AtaraxiaWindowsHardwareInfoDependencies
$buildSelection=Get-KoboldCppBuildSelection $Build $hardwareInfo.get_video_controller_names
$Build=$buildSelection.build
Write-Output (Get-AppText 'kobold_build_selected' @($Build,$buildSelection.requested_build))
$settings = Import-KoboldCppSettings $config $configFullPath $jsonStore
$settingsPath = [string]$config.koboldcpp_settings_path
if (-not [IO.Path]::IsPathRooted($settingsPath)) { $settingsPath = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $configFullPath) $settingsPath)) }
$paths = $settings.paths
$installDirectory = [string]$paths.install_directory
$modelDirectory = [string]$paths.model_directory
$modelFile = [string]$paths.model_file
$installDirectory = if ([IO.Path]::IsPathRooted($installDirectory)) { [IO.Path]::GetFullPath($installDirectory) } else { [IO.Path]::GetFullPath((Join-Path $projectRoot $installDirectory)) }
$modelDirectory = if ([IO.Path]::IsPathRooted($modelDirectory)) { [IO.Path]::GetFullPath($modelDirectory) } else { [IO.Path]::GetFullPath((Join-Path $projectRoot $modelDirectory)) }
& $installerDependencies.ensure_directory $installDirectory | Out-Null
& $installerDependencies.ensure_directory $modelDirectory | Out-Null
$modelFullPath = if ([IO.Path]::IsPathRooted($modelFile)) { [IO.Path]::GetFullPath($modelFile) } else { [IO.Path]::GetFullPath((Join-Path $modelDirectory $modelFile)) }
$paths | Add-Member -NotePropertyName install_directory -NotePropertyValue $installDirectory -Force
$paths | Add-Member -NotePropertyName model_directory -NotePropertyValue $modelDirectory -Force
$paths | Add-Member -NotePropertyName model_file -NotePropertyValue ([IO.Path]::GetFileName($modelFile)) -Force
$paths | Add-Member -NotePropertyName executable -NotePropertyValue (Join-Path $installDirectory 'koboldcpp.exe') -Force

$release = Get-KoboldCppRelease $installerDependencies
$asset = Get-KoboldCppReleaseAsset $release $Build
$downloadPath = Join-Path $installDirectory 'koboldcpp.exe'
if ($PSCmdlet.ShouldProcess($downloadPath, "Download official KoboldCpp $($release.tag_name) and verify GitHub SHA-256")) {
    $actualHash=Install-KoboldCppReleaseAsset $asset $downloadPath $installerDependencies
    $settings | Add-Member -NotePropertyName release_tag -NotePropertyValue ([string]$release.tag_name) -Force
    $settings | Add-Member -NotePropertyName sha256 -NotePropertyValue $actualHash -Force
}

Save-KoboldCppSettings $settingsPath $settings $jsonStore

Write-Output (Get-AppText 'kobold_release_label' @([string]$release.tag_name))
Write-Output (Get-AppText 'kobold_install_folder_label' @($installDirectory))
Write-Output (Get-AppText 'kobold_model_folder_label' @($modelDirectory))
if ($Launch) {
    if ([string]::IsNullOrWhiteSpace($modelFile)) { throw (Get-AppText 'kobold_model_name_required') }
    if (-not [bool](& $installerDependencies.test_file $modelFullPath)) { throw (Get-AppText 'kobold_model_file_missing' @($modelFullPath)) }
    if ($PSCmdlet.ShouldProcess($downloadPath, 'Launch KoboldCpp with the configured local model')) {
        $effectiveSettings = Get-KoboldCppEffectiveSettings $settings
        $launchArguments = @(Get-KoboldCppLaunchArguments $effectiveSettings $modelFullPath) -join ' '
        $serverUri = [uri][string]$config.api_server
        $null=Start-KoboldCppAndWait ([string]$paths.executable) $launchArguments $installDirectory $serverUri $installerDependencies 60 1000 1
        Write-Output (Get-AppText 'kobold_ready' @([string]$serverUri))
    }
}
