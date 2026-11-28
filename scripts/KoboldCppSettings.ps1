Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'StructuredData.ps1')
. (Join-Path $PSScriptRoot 'JsonFileStore.ps1')
. (Join-Path $PSScriptRoot 'GuiModelParameters.ps1')
. (Join-Path $PSScriptRoot 'ModelParameterPresets.ps1')

function Get-KoboldCppSettingsPath([object]$Config, [string]$ConfigPath) {
    $configuredPath = if ($null -ne $Config.PSObject.Properties['koboldcpp_settings_path'] -and -not [string]::IsNullOrWhiteSpace([string]$Config.koboldcpp_settings_path)) { [string]$Config.koboldcpp_settings_path } else { 'koboldcpp-settings.json' }
    if ([IO.Path]::IsPathRooted($configuredPath)) { $resolved=[IO.Path]::GetFullPath($configuredPath);Register-AgentJsonRepairKind $resolved 'kobold_settings';return $resolved }
    $baseDirectory = if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath)) } else { Join-Path (Split-Path -Parent $PSScriptRoot) 'configs' }
    $resolved=[IO.Path]::GetFullPath((Join-Path $baseDirectory $configuredPath));Register-AgentJsonRepairKind $resolved 'kobold_settings';return $resolved
}

function Resolve-KoboldCppBuild([ValidateSet('auto','cuda','nocuda','oldpc')][string]$Build,[string[]]$VideoControllerNames=@()) {
    if($Build -ne 'auto'){return $Build}
    if(@($VideoControllerNames|Where-Object{[string]$_ -match '(?i)NVIDIA|GeForce|Quadro|Tesla'}).Count -gt 0){return 'cuda'}
    return 'nocuda'
}

function Get-KoboldCppBuildSelection([ValidateSet('auto','cuda','nocuda','oldpc')][string]$RequestedBuild,[scriptblock]$ReadVideoControllerNames) {
    $names=@();$detection_succeeded=$true
    if($RequestedBuild -eq 'auto'){
        if($ReadVideoControllerNames -isnot [scriptblock]){throw 'Automatic KoboldCpp build selection requires a hardware information adapter.'}
        try{$names=@(& $ReadVideoControllerNames|ForEach-Object{[string]$_})}catch{$detection_succeeded=$false;$names=@()}
    }
    return [pscustomobject][ordered]@{requested_build=$RequestedBuild;build=(Resolve-KoboldCppBuild $RequestedBuild $names);video_controller_names=[string[]]$names;detection_succeeded=[bool]$detection_succeeded}
}

function New-LegacyKoboldCppSettings([object]$Config) {
    $legacy = if ($null -ne $Config.PSObject.Properties['koboldcpp']) { $Config.koboldcpp } else { [pscustomobject]@{} }
    $serverUri = if ($null -ne $Config.PSObject.Properties['api_server']) { [uri][string]$Config.api_server } else { [uri]'http://127.0.0.1:5001' }
    $requestParameters = if ($null -ne $Config.PSObject.Properties['override']) { $Config.override } else { [pscustomobject]@{ context_size=8192; max_tokens=1024 } }
    return [pscustomobject][ordered]@{
        server=[pscustomobject][ordered]@{ host=$serverUri.Host; port=$serverUri.Port; generate_path=if ($null -ne $Config.PSObject.Properties['generate_path']) { [string]$Config.generate_path } else { '/v1/chat/completions' } }
        paths=[pscustomobject][ordered]@{ install_directory=if ($null -ne $legacy.PSObject.Properties['install_directory']) { [string]$legacy.install_directory } else { 'runtime/koboldcpp' }; model_directory=if ($null -ne $legacy.PSObject.Properties['model_directory']) { [string]$legacy.model_directory } else { 'models' }; model_file=if ($null -ne $legacy.PSObject.Properties['model_file']) { [string]$legacy.model_file } else { '' }; executable=if ($null -ne $legacy.PSObject.Properties['executable']) { [string]$legacy.executable } else { 'runtime/koboldcpp/koboldcpp.exe' } }
        startup_parameters=@()
        request_parameters=$requestParameters
        release_tag=if ($null -ne $legacy.PSObject.Properties['release_tag']) { [string]$legacy.release_tag } else { '' }
        sha256=if ($null -ne $legacy.PSObject.Properties['sha256']) { [string]$legacy.sha256 } else { '' }
    }
}

function Import-KoboldCppSettings([object]$Config, [string]$ConfigPath,[object]$Dependencies=$null) {
    $settingsPath = Get-KoboldCppSettingsPath $Config $ConfigPath
    if (Test-AtaraxiaJsonStoreFile $settingsPath $Dependencies) {
        $settings = Read-AtaraxiaJsonStoreFile $settingsPath $Dependencies
    } else {
        $settings = New-LegacyKoboldCppSettings $Config
    }
    if ($null -eq $settings.server -or $null -eq $settings.paths -or $null -eq $settings.request_parameters -or $null -eq $settings.startup_parameters) { throw "KoboldCpp settings are incomplete: $settingsPath" }
    $catalogPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'configs/model-parameter-presets.json'
    $catalog=Read-AtaraxiaJsonStoreFile $catalogPath $Dependencies
    $presetPath=Get-AtaraxiaUserModelParameterPresetPath
    $hasPresetData=Test-AtaraxiaJsonStoreFile $presetPath $Dependencies
    $presetData=if($hasPresetData){Read-AtaraxiaJsonStoreFile $presetPath $Dependencies}else{$null}
    Initialize-AtaraxiaModelParameterPresetCatalog $settings @($catalog.presets) $presetData|Out-Null
    if(-not $hasPresetData){Save-AtaraxiaUserModelParameterPresetData $presetPath $settings $Dependencies|Out-Null}
    if($hasPresetData -and $null -ne $settings.user_preset_data.PSObject.Properties['pending_shared_settings']){
        . (Join-Path $PSScriptRoot 'GuiModelParameterApplication.ps1')
        $saveShared={param($value)Save-KoboldCppSettings $settingsPath $value $Dependencies}
        $savePresets={param($value)Save-AtaraxiaUserModelParameterPresetData $presetPath $value $Dependencies}
        $null=Resolve-AtaraxiaPendingSharedModelParameterSettings $settings $saveShared $savePresets
    }
    $server = [string]$settings.server.host
    $port = [int]$settings.server.port
    if ([string]::IsNullOrWhiteSpace($server) -or $port -lt 1 -or $port -gt 65535 -or [uri]::CheckHostName($server) -eq [UriHostNameType]::Unknown) { throw "KoboldCpp server host or port is invalid: $settingsPath" }
    try{$null=New-AgentHttpUri "http://${server}:$port" ([string]$settings.server.generate_path)}catch{throw "KoboldCpp server endpoint is invalid: $settingsPath. $($_.Exception.Message)"}
    $contextSize = Get-StructuredProperty $settings.request_parameters 'context_size'
    if (-not $contextSize.exists -or [int]$contextSize.value -lt 1) { throw "KoboldCpp request_parameters.context_size must be positive: $settingsPath" }
    $effectiveSettings = Get-KoboldCppEffectiveSettings $settings
    $Config | Add-Member -NotePropertyName api_server -NotePropertyValue "http://${server}:$port" -Force
    $Config | Add-Member -NotePropertyName generate_path -NotePropertyValue ([string]$settings.server.generate_path) -Force
    $Config | Add-Member -NotePropertyName override -NotePropertyValue $effectiveSettings.request_parameters -Force
    $Config | Add-Member -NotePropertyName koboldcpp -NotePropertyValue $settings.paths -Force
    $Config | Add-Member -NotePropertyName koboldcpp_settings_path -NotePropertyValue $settingsPath -Force
    $Config | Add-Member -NotePropertyName koboldcpp_settings -NotePropertyValue $effectiveSettings -Force
    $Config | Add-Member -NotePropertyName koboldcpp_base_settings -NotePropertyValue $settings -Force
    return $settings
}

function Get-KoboldCppEffectiveSettings([object]$Settings) {
    $json = $Settings | ConvertTo-Json -Depth 60
    return ($json | ConvertFrom-Json)
}

function Get-KoboldCppLaunchArguments([object]$Settings, [string]$ModelPath) {
    if ([string]::IsNullOrWhiteSpace($ModelPath)) { throw 'A model path is required to build KoboldCpp launch arguments.' }
    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('--model')
    $arguments.Add(('"{0}"' -f $ModelPath))
    $arguments.Add('--port')
    $arguments.Add([string][int]$Settings.server.port)
    $contextSize = Get-StructuredProperty $Settings.request_parameters 'context_size'
    if (-not $contextSize.exists -or [int]$contextSize.value -lt 1) { throw 'KoboldCpp request_parameters.context_size must be a positive integer.' }
    $arguments.Add('--contextsize')
    $arguments.Add([string][int]$contextSize.value)
    foreach ($parameter in @($Settings.startup_parameters)) {
        if ($null -eq $parameter -or [string]$parameter.name -notmatch '^[A-Za-z][A-Za-z0-9_-]*$') { throw 'Invalid KoboldCpp startup parameter.' }
        if ([string]$parameter.name -in @('model','port','contextsize')) { throw "Startup parameter '$($parameter.name)' is managed by shared settings." }
        $arguments.Add("--$($parameter.name)")
        if ($null -ne $parameter.PSObject.Properties['value']) {
            $value = if ($parameter.value -is [bool]) { $parameter.value.ToString().ToLowerInvariant() } else { [string]$parameter.value }
            if ($value -match '\s') { $value = '"{0}"' -f $value }
            $arguments.Add($value)
        }
    }
    return $arguments.ToArray()
}

function Save-KoboldCppSettings([string]$Path, [object]$Settings,[object]$Dependencies=$null) {
    $persisted=Copy-AtaraxiaModelParameterPresetValue $Settings
    foreach($runtimeField in @('parameter_presets','active_parameter_preset_id','user_preset_data','preset_catalog_needs_save')){$persisted.PSObject.Properties.Remove($runtimeField)}
    Write-AtaraxiaJsonStoreFile $Path $persisted $Dependencies 60
}
