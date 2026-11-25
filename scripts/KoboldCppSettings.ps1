Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'StructuredData.ps1')

function Get-KoboldCppSettingsPath([object]$Config, [string]$ConfigPath) {
    $configuredPath = if ($null -ne $Config.PSObject.Properties['koboldcpp_settings_path'] -and -not [string]::IsNullOrWhiteSpace([string]$Config.koboldcpp_settings_path)) { [string]$Config.koboldcpp_settings_path } else { 'koboldcpp-settings.json' }
    if ([IO.Path]::IsPathRooted($configuredPath)) { return [IO.Path]::GetFullPath($configuredPath) }
    $baseDirectory = if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath)) } else { Join-Path (Split-Path -Parent $PSScriptRoot) 'configs' }
    return [IO.Path]::GetFullPath((Join-Path $baseDirectory $configuredPath))
}

function Resolve-KoboldCppBuild([ValidateSet('auto','cuda','nocuda','oldpc')][string]$Build,[string[]]$VideoControllerNames=@()) {
    if($Build -ne 'auto'){return $Build}
    if(@($VideoControllerNames|Where-Object{[string]$_ -match '(?i)NVIDIA|GeForce|Quadro|Tesla'}).Count -gt 0){return 'cuda'}
    return 'nocuda'
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

function Import-KoboldCppSettings([object]$Config, [string]$ConfigPath) {
    $settingsPath = Get-KoboldCppSettingsPath $Config $ConfigPath
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        $settings = Read-AgentJsonFile $settingsPath
    } else {
        $settings = New-LegacyKoboldCppSettings $Config
    }
    if ($null -eq $settings.server -or $null -eq $settings.paths -or $null -eq $settings.request_parameters -or $null -eq $settings.startup_parameters) { throw "KoboldCpp settings are incomplete: $settingsPath" }
    $server = [string]$settings.server.host
    $port = [int]$settings.server.port
    if ([string]::IsNullOrWhiteSpace($server) -or $port -lt 1 -or $port -gt 65535 -or [uri]::CheckHostName($server) -eq [UriHostNameType]::Unknown) { throw "KoboldCpp server host or port is invalid: $settingsPath" }
    try{$null=New-AgentHttpUri "http://${server}:$port" ([string]$settings.server.generate_path)}catch{throw "KoboldCpp server endpoint is invalid: $settingsPath. $($_.Exception.Message)"}
    $contextSize = Get-StructuredProperty $settings.request_parameters 'context_size'
    if (-not $contextSize.exists -or [int]$contextSize.value -lt 1) { throw "KoboldCpp request_parameters.context_size must be positive: $settingsPath" }
    $modelPath = [string]$settings.paths.model_file
    if (-not [string]::IsNullOrWhiteSpace($modelPath) -and -not [IO.Path]::IsPathRooted($modelPath)) { $modelPath = Join-Path (Split-Path -Parent $PSScriptRoot) (Join-Path ([string]$settings.paths.model_directory) $modelPath) }
    $effectiveSettings = Get-KoboldCppModelSettings $settings $modelPath
    $Config | Add-Member -NotePropertyName api_server -NotePropertyValue "http://${server}:$port" -Force
    $Config | Add-Member -NotePropertyName generate_path -NotePropertyValue ([string]$settings.server.generate_path) -Force
    $Config | Add-Member -NotePropertyName override -NotePropertyValue $effectiveSettings.request_parameters -Force
    $Config | Add-Member -NotePropertyName koboldcpp -NotePropertyValue $settings.paths -Force
    $Config | Add-Member -NotePropertyName koboldcpp_settings_path -NotePropertyValue $settingsPath -Force
    $Config | Add-Member -NotePropertyName koboldcpp_settings -NotePropertyValue $effectiveSettings -Force
    $Config | Add-Member -NotePropertyName koboldcpp_base_settings -NotePropertyValue $settings -Force
    return $settings
}

function Get-KoboldCppModelSettings([object]$Settings, [string]$ModelPath) {
    $json = $Settings | ConvertTo-Json -Depth 60
    $effective = $json | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($ModelPath)) { return $effective }
    $sidecarPath = [IO.Path]::ChangeExtension($ModelPath, '.json')
    if (-not (Test-Path -LiteralPath $sidecarPath -PathType Leaf)) { return $effective }
    try { $sidecar = Read-AgentJsonFile $sidecarPath } catch { throw "Model sidecar JSON is invalid: $sidecarPath. $($_.Exception.Message)" }
    if ($sidecar -isnot [System.Management.Automation.PSCustomObject]) { throw "Model sidecar must be a JSON object: $sidecarPath" }
    $allowedRootKeys = @('startup_parameters','request_parameters')
    foreach ($property in $sidecar.PSObject.Properties) { if ($allowedRootKeys -notcontains $property.Name) { throw "Unsupported model sidecar property '$($property.Name)': $sidecarPath" } }
    if ($null -ne $sidecar.PSObject.Properties['startup_parameters']) {
        if ($sidecar.startup_parameters -is [string]) { throw "Model sidecar startup_parameters must be an array: $sidecarPath" }
        $seenNames = @()
        foreach ($override in @($sidecar.startup_parameters)) {
            if ($override -isnot [System.Management.Automation.PSCustomObject] -or $null -eq $override.PSObject.Properties['name'] -or $null -eq $override.PSObject.Properties['value']) { throw "Each model startup override requires name and value: $sidecarPath" }
            $name = [string]$override.name
            if ($name -notmatch '^[A-Za-z][A-Za-z0-9_-]*$' -or $name -in @('model','port','contextsize')) { throw "Invalid or reserved model startup parameter '$name': $sidecarPath" }
            if ($seenNames -contains $name) { throw "Duplicate model startup parameter '$name': $sidecarPath" }
            $seenNames += $name
            if ($override.value -is [System.Management.Automation.PSCustomObject] -or $override.value -is [System.Array] -or $null -eq $override.value) { throw "Model startup parameter '$name' must have a scalar value: $sidecarPath" }
            $existing = @($effective.startup_parameters | Where-Object { [string]$_.name -ieq $name }) | Select-Object -First 1
            if ($null -ne $existing) { $existing.value = $override.value }
            else { $effective.startup_parameters = @($effective.startup_parameters) + @([pscustomobject][ordered]@{ name=$name; value=$override.value }) }
        }
    }
    if ($null -ne $sidecar.PSObject.Properties['request_parameters']) {
        if ($sidecar.request_parameters -isnot [System.Management.Automation.PSCustomObject]) { throw "Model sidecar request_parameters must be an object: $sidecarPath" }
        foreach ($property in $sidecar.request_parameters.PSObject.Properties) {
            if ($property.Name -notmatch '^[A-Za-z][A-Za-z0-9_]*$' -or $property.Name -in @('messages','stream','response_format')) { throw "Invalid model request parameter '$($property.Name)': $sidecarPath" }
            if ($property.Value -is [System.Management.Automation.PSCustomObject] -or $property.Value -is [System.Array] -or $null -eq $property.Value) { throw "Model request parameter '$($property.Name)' must have a scalar value: $sidecarPath" }
            $effective.request_parameters | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
        }
    }
    $effectiveContext = Get-StructuredProperty $effective.request_parameters 'context_size'
    if (-not $effectiveContext.exists -or [int]$effectiveContext.value -lt 1) { throw "Model sidecar context_size must be positive: $sidecarPath" }
    return $effective
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

function Save-KoboldCppSettings([string]$Path, [object]$Settings) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $temporaryPath = "$Path.tmp"
    $json = $Settings | ConvertTo-Json -Depth 60
    [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::Replace($temporaryPath, $Path, $null) }
    else { [IO.File]::Move($temporaryPath, $Path) }
}
