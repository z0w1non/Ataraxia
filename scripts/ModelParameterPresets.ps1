Set-StrictMode -Version Latest

function Copy-AtaraxiaModelParameterPresetValue([object]$Value) {
    if($null -eq $Value){return $null}
    return (ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 60))
}

function Assert-AtaraxiaModelParameterPresetName([string]$Name) {
    $normalized=$Name.Trim()
    if([string]::IsNullOrWhiteSpace($normalized) -or $normalized.Length -gt 64 -or $normalized -match '[\x00-\x1F\x7F]'){throw 'Preset name must contain 1 to 64 visible characters.'}
    return $normalized
}

function Get-AtaraxiaUserModelParameterPresetPath([string]$DataDirectory='') {
    if([string]::IsNullOrWhiteSpace($DataDirectory)){$DataDirectory=[string]$env:ATARAXIA_USER_DATA_DIRECTORY}
    if([string]::IsNullOrWhiteSpace($DataDirectory)){$DataDirectory=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Ataraxia'}
    $path=[IO.Path]::GetFullPath((Join-Path $DataDirectory 'model-parameter-presets.json'));if($null -ne (Get-Command Register-AgentJsonRepairKind -ErrorAction SilentlyContinue)){Register-AgentJsonRepairKind $path 'model_parameter_presets'};return $path
}

function Initialize-AtaraxiaModelParameterPresetCatalog([object]$Settings,[object[]]$BuiltInPresets,[object]$UserData=$null) {
    if($null -eq $Settings -or $null -eq $Settings.request_parameters -or $Settings.request_parameters -isnot [System.Management.Automation.PSCustomObject]){throw 'KoboldCpp request_parameters must be an object before a preset catalog can be initialized.'}
    if(@($BuiltInPresets).Count -eq 0){throw 'At least one Git-managed model parameter preset is required.'}
    $legacyPresets=@();if($null -ne $Settings.PSObject.Properties['parameter_presets']){$legacyPresets=@($Settings.parameter_presets)}
    $legacyActive='';if($null -ne $Settings.PSObject.Properties['active_parameter_preset_id']){$legacyActive=[string]$Settings.active_parameter_preset_id}
    if($null -eq $UserData){$UserData=[pscustomobject][ordered]@{schema_version=1;active_preset_id='';presets=@();overrides=@()}}
    if([int]$UserData.schema_version -ne 1 -or $UserData.presets -isnot [array] -or $UserData.overrides -isnot [array]){throw 'User model parameter preset data has an unsupported or malformed structure.'}
    $builtins=@();foreach($source in $BuiltInPresets){if($null -eq $source -or [string]::IsNullOrWhiteSpace([string]$source.id) -or [string]::IsNullOrWhiteSpace([string]$source.name) -or $null -eq $source.request_parameters -or $source.request_parameters -isnot [System.Management.Automation.PSCustomObject]){throw 'A built-in preset requires id, name, and request_parameters fields.'};$preset=Copy-AtaraxiaModelParameterPresetValue $source;$preset|Add-Member -NotePropertyName origin -NotePropertyValue 'builtin' -Force;$preset|Add-Member -NotePropertyName has_user_override -NotePropertyValue $false -Force;$preset|Add-Member -NotePropertyName source_name -NotePropertyValue ([string]$source.name) -Force;$preset|Add-Member -NotePropertyName source_name_en -NotePropertyValue ([string]$source.name_en) -Force;$preset|Add-Member -NotePropertyName source_request_parameters -NotePropertyValue (Copy-AtaraxiaModelParameterPresetValue $source.request_parameters) -Force;$builtins+=@($preset)}
    $users=@(foreach($source in $UserData.presets){if($null -eq $source -or [string]::IsNullOrWhiteSpace([string]$source.id) -or [string]$source.id -match '^builtin:'){throw 'User preset IDs must be non-empty and must not use the builtin namespace.'};if($null -eq $source.request_parameters -or $source.request_parameters -isnot [System.Management.Automation.PSCustomObject]){throw 'A user preset request_parameters value must be an object.'};$preset=Copy-AtaraxiaModelParameterPresetValue $source;$preset.name=Assert-AtaraxiaModelParameterPresetName ([string]$preset.name);$preset|Add-Member -NotePropertyName origin -NotePropertyValue 'user' -Force;$preset})
    $overrides=@($UserData.overrides);foreach($override in $overrides){$target=@($builtins|Where-Object{[string]$_.id -ceq [string]$override.id}|Select-Object -First 1);if($target.Count -eq 0){throw "User override references unknown built-in preset '$($override.id)'."};if($null -ne $override.PSObject.Properties['name']){$target[0].name=Assert-AtaraxiaModelParameterPresetName ([string]$override.name);if($null -ne $target[0].PSObject.Properties['name_en']){$target[0].name_en=[string]$target[0].name}};if($null -ne $override.PSObject.Properties['request_parameters']){if($override.request_parameters -isnot [System.Management.Automation.PSCustomObject]){throw 'A built-in preset override request_parameters value must be an object.'};$target[0].request_parameters=Copy-AtaraxiaModelParameterPresetValue $override.request_parameters};$target[0].has_user_override=$true}
    if($UserData.presets.Count -eq 0 -and $legacyPresets.Count -gt 0){foreach($legacy in $legacyPresets){if($null -eq $legacy.request_parameters -or $legacy.request_parameters -isnot [System.Management.Automation.PSCustomObject]){continue};$match=@($builtins|Where-Object{(ConvertTo-Json -InputObject $_.request_parameters -Depth 60 -Compress) -ceq (ConvertTo-Json -InputObject $legacy.request_parameters -Depth 60 -Compress)}|Select-Object -First 1);if($match.Count -gt 0){if([string]$legacy.id -ceq $legacyActive){$UserData.active_preset_id=[string]$match[0].id};continue};$id='legacy-'+([guid]::NewGuid().ToString('N'));$name=([string]$legacy.name).Trim();if([string]::IsNullOrWhiteSpace($name) -or @($builtins+$users|Where-Object{$_.name -ieq $name}).Count -gt 0){$name='移行したプリセット'};while(@($builtins+$users|Where-Object{$_.name -ieq $name}).Count -gt 0){$name='移行 '+$name;if($name.Length -gt 64){$name='移行済み '+$id.Substring(0,8)}};$migrated=[pscustomobject][ordered]@{id=$id;name=$name;request_parameters=(Copy-AtaraxiaModelParameterPresetValue $legacy.request_parameters);origin='user'};$users+=@($migrated);if([string]$legacy.id -ceq $legacyActive){$UserData.active_preset_id=$id}}}
    if($UserData.presets.Count -eq 0 -and $legacyPresets.Count -eq 0){$match=@($builtins|Where-Object{(ConvertTo-Json -InputObject $_.request_parameters -Depth 60 -Compress) -ceq (ConvertTo-Json -InputObject $Settings.request_parameters -Depth 60 -Compress)}|Select-Object -First 1);if($match.Count -gt 0){$UserData.active_preset_id=[string]$match[0].id}else{$id='legacy-current';$name='以前の共有設定';if(@($builtins|Where-Object{$_.name -ieq $name}).Count -gt 0){$name='以前の共有設定（移行）'};$users+=@([pscustomobject][ordered]@{id=$id;name=$name;request_parameters=(Copy-AtaraxiaModelParameterPresetValue $Settings.request_parameters);origin='user'});$UserData.active_preset_id=$id}}
    $all=@($builtins+$users);$ids=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$names=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($preset in $all){if(-not $ids.Add([string]$preset.id)){throw "Duplicate model parameter preset ID '$($preset.id)'."};if(-not $names.Add([string]$preset.name)){throw "Duplicate model parameter preset name '$($preset.name)'."}}
    $activeId=[string]$UserData.active_preset_id;if([string]::IsNullOrWhiteSpace($activeId)){$activeId=$legacyActive};$active=@($all|Where-Object{[string]$_.id -ceq $activeId}|Select-Object -First 1);if($active.Count -eq 0){$active=@($builtins|Select-Object -First 1);$activeId=[string]$active[0].id}
    $Settings|Add-Member -NotePropertyName parameter_presets -NotePropertyValue $all -Force;$Settings|Add-Member -NotePropertyName active_parameter_preset_id -NotePropertyValue $activeId -Force;$Settings|Add-Member -NotePropertyName request_parameters -NotePropertyValue (Copy-AtaraxiaModelParameterPresetValue $active[0].request_parameters) -Force;$Settings|Add-Member -NotePropertyName user_preset_data -NotePropertyValue $UserData -Force
    return $Settings
}

function Initialize-AtaraxiaModelParameterPresets([object]$Settings) {
    if($null -eq $Settings -or $null -eq $Settings.PSObject.Properties['request_parameters'] -or $Settings.request_parameters -isnot [System.Management.Automation.PSCustomObject]){throw 'KoboldCpp request_parameters must be an object before presets can be initialized.'}
    $presetsProperty=$Settings.PSObject.Properties['parameter_presets']
    if($null -eq $presetsProperty -or @($presetsProperty.Value).Count -eq 0){
        $presets=@([pscustomobject][ordered]@{id='default';name='Default';request_parameters=(Copy-AtaraxiaModelParameterPresetValue $Settings.request_parameters);origin='user'})
        $Settings|Add-Member -NotePropertyName parameter_presets -NotePropertyValue $presets -Force
        $Settings|Add-Member -NotePropertyName active_parameter_preset_id -NotePropertyValue 'default' -Force
    }else{
        $presets=@($presetsProperty.Value);foreach($preset in $presets){if($null -eq $preset.PSObject.Properties['origin']){$preset|Add-Member -NotePropertyName origin -NotePropertyValue 'user' -Force}}
        $Settings|Add-Member -NotePropertyName parameter_presets -NotePropertyValue $presets -Force
    }
    $presets=@($Settings.parameter_presets)
    if($null -eq $Settings.PSObject.Properties['user_preset_data']){$users=@(foreach($preset in $presets){[pscustomobject][ordered]@{id=[string]$preset.id;name=[string]$preset.name;request_parameters=(Copy-AtaraxiaModelParameterPresetValue $preset.request_parameters)}});$data=[pscustomobject][ordered]@{schema_version=1;active_preset_id=[string]$Settings.active_parameter_preset_id;presets=$users;overrides=@()};$Settings|Add-Member -NotePropertyName user_preset_data -NotePropertyValue $data -Force}
    $ids=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$names=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($preset in $presets){
        if($preset -isnot [System.Management.Automation.PSCustomObject] -or $null -eq $preset.PSObject.Properties['id'] -or $null -eq $preset.PSObject.Properties['name'] -or $null -eq $preset.PSObject.Properties['request_parameters'] -or $preset.request_parameters -isnot [System.Management.Automation.PSCustomObject]){throw 'A model parameter preset must have id, name, and request_parameters object fields.'}
        $id=[string]$preset.id;if([string]::IsNullOrWhiteSpace($id) -or $id.Length -gt 128 -or $id -match '[\x00-\x1F\x7F]' -or -not $ids.Add($id)){throw 'Model parameter preset IDs must be unique, non-empty, and at most 128 characters.'}
        $preset.name=Assert-AtaraxiaModelParameterPresetName ([string]$preset.name)
        if(-not $names.Add([string]$preset.name)){throw "Model parameter preset name '$($preset.name)' is duplicated."}
    }
    $activeProperty=$Settings.PSObject.Properties['active_parameter_preset_id'];$activeId=if($null -ne $activeProperty){[string]$activeProperty.Value}else{''}
    $active=@($presets|Where-Object{[string]$_.id -ceq $activeId}|Select-Object -First 1)
    if($active.Count -eq 0){$active=@($presets|Select-Object -First 1);$activeId=[string]$active[0].id}
    $Settings|Add-Member -NotePropertyName parameter_presets -NotePropertyValue $presets -Force
    $Settings|Add-Member -NotePropertyName active_parameter_preset_id -NotePropertyValue $activeId -Force
    $Settings|Add-Member -NotePropertyName request_parameters -NotePropertyValue (Copy-AtaraxiaModelParameterPresetValue $active[0].request_parameters) -Force
    return $Settings
}

function Get-AtaraxiaModelParameterPreset([object]$Settings,[string]$Id) {
    if($null -eq $Settings -or $null -eq $Settings.PSObject.Properties['parameter_presets']){throw 'Model parameter presets are not initialized.'}
    $matches=@($Settings.parameter_presets|Where-Object{[string]$_.id -ceq $Id}|Select-Object -First 1)
    if($matches.Count -eq 0){throw "Model parameter preset '$Id' was not found."}
    return $matches[0]
}

function Get-AtaraxiaModelParameterPresetCapabilities([object]$Preset) {
    if($null -eq $Preset -or $null -eq $Preset.PSObject.Properties['origin']){throw 'A model parameter preset with an origin is required.'}
    $userOwned=[string]$Preset.origin -eq 'user'
    return [pscustomobject][ordered]@{can_overwrite=$userOwned;can_delete=$userOwned;can_save_as=$true}
}

function Assert-AtaraxiaModelParameterPresetNameAvailable([object]$Settings,[string]$Name,[string]$ExceptId='') {
    $normalized=Assert-AtaraxiaModelParameterPresetName $Name
    if(@($Settings.parameter_presets|Where-Object{[string]$_.id -cne $ExceptId -and [string]$_.name -ieq $normalized}).Count -gt 0){throw "Model parameter preset name '$normalized' is already in use."}
    return $normalized
}

function New-AtaraxiaModelParameterPreset([object]$Settings,[string]$Name,[string]$Id) {
    Initialize-AtaraxiaModelParameterPresets $Settings|Out-Null
    $normalized=Assert-AtaraxiaModelParameterPresetNameAvailable $Settings $Name
    if([string]::IsNullOrWhiteSpace($Id) -or $Id.Length -gt 128 -or $Id -match '[\x00-\x1F\x7F]' -or @($Settings.parameter_presets|Where-Object{[string]$_.id -ceq $Id}).Count -gt 0){throw 'A new model parameter preset requires an unused ID.'}
    $current=Copy-AtaraxiaModelParameterPresetValue $Settings.request_parameters
    $preset=[pscustomobject][ordered]@{id=$Id;name=$normalized;request_parameters=$current;origin='user'}
    $Settings.parameter_presets=@($Settings.parameter_presets)+@($preset)
    if($null -ne $Settings.PSObject.Properties['user_preset_data']){$Settings.user_preset_data.presets=@($Settings.user_preset_data.presets)+@([pscustomobject][ordered]@{id=$Id;name=$normalized;request_parameters=(Copy-AtaraxiaModelParameterPresetValue $current)})}
    $Settings.active_parameter_preset_id=$Id
    $Settings.request_parameters=Copy-AtaraxiaModelParameterPresetValue $current
    return $preset
}

function Save-AtaraxiaModelParameterPresetValues([object]$Settings,[string]$Id,[System.Collections.IDictionary]$Values) {
    $preset=Get-AtaraxiaModelParameterPreset $Settings $Id
    if([string]$preset.origin -eq 'builtin'){throw 'Built-in model parameter presets cannot be overwritten. Use Save As to create a user preset.'}
    $request=Copy-AtaraxiaModelParameterPresetValue $preset.request_parameters
    foreach($key in $Values.Keys){$value=Assert-AtaraxiaModelParameterValue ([string]$key) $Values[$key];$request|Add-Member -NotePropertyName ([string]$key) -NotePropertyValue $value -Force}
    $preset.request_parameters=$request;$saved=@($Settings.user_preset_data.presets|Where-Object{[string]$_.id -ceq $Id}|Select-Object -First 1);if($saved.Count -eq 0){$Settings.user_preset_data.presets=@($Settings.user_preset_data.presets)+@([pscustomobject][ordered]@{id=$Id;name=[string]$preset.name;request_parameters=$request})}else{$saved[0].request_parameters=$request}
    if([string]$Settings.active_parameter_preset_id -ceq $Id){$Settings.request_parameters=Copy-AtaraxiaModelParameterPresetValue $request}
    return $preset
}

function Rename-AtaraxiaModelParameterPreset([object]$Settings,[string]$Id,[string]$Name) {
    $preset=Get-AtaraxiaModelParameterPreset $Settings $Id;$normalized=Assert-AtaraxiaModelParameterPresetNameAvailable $Settings $Name $Id
    if([string]$preset.origin -eq 'builtin'){$override=@($Settings.user_preset_data.overrides|Where-Object{[string]$_.id -ceq $Id}|Select-Object -First 1);if($override.Count -eq 0){$override=[pscustomobject][ordered]@{id=$Id;name=$normalized};$Settings.user_preset_data.overrides=@($Settings.user_preset_data.overrides)+@($override)}else{$override[0].name=$normalized};$preset.has_user_override=$true;if($null -ne $preset.PSObject.Properties['name_en']){$preset.name_en=$normalized}}else{$saved=@($Settings.user_preset_data.presets|Where-Object{[string]$_.id -ceq $Id}|Select-Object -First 1);if($saved.Count -gt 0){$saved[0].name=$normalized}};$preset.name=$normalized;return $preset
}

function Select-AtaraxiaModelParameterPreset([object]$Settings,[string]$Id) {
    $preset=Get-AtaraxiaModelParameterPreset $Settings $Id;$Settings.active_parameter_preset_id=$Id;$Settings.user_preset_data.active_preset_id=$Id;$Settings.request_parameters=Copy-AtaraxiaModelParameterPresetValue $preset.request_parameters;return $preset
}

function Remove-AtaraxiaModelParameterPreset([object]$Settings,[string]$Id) {
    $preset=Get-AtaraxiaModelParameterPreset $Settings $Id
    if([string]$preset.origin -eq 'builtin'){throw 'Built-in model parameter presets cannot be deleted.'}
    if(@($Settings.parameter_presets).Count -le 1){throw 'At least one model parameter preset must remain.'}
    $Settings.parameter_presets=@($Settings.parameter_presets|Where-Object{[string]$_.id -cne $Id});$Settings.user_preset_data.presets=@($Settings.user_preset_data.presets|Where-Object{[string]$_.id -cne $Id})
    if([string]$Settings.active_parameter_preset_id -ceq $Id){$replacement=$Settings.parameter_presets[0];$Settings.active_parameter_preset_id=[string]$replacement.id;$Settings.request_parameters=Copy-AtaraxiaModelParameterPresetValue $replacement.request_parameters}
    return $Settings
}

function Get-AtaraxiaUserModelParameterPresetData([object]$Settings) {
    if($null -eq $Settings.user_preset_data){throw 'User model parameter preset data is not initialized.'}
    $presets=@(foreach($preset in $Settings.parameter_presets|Where-Object{[string]$_.origin -eq 'user'}){[pscustomobject][ordered]@{id=[string]$preset.id;name=[string]$preset.name;request_parameters=(Copy-AtaraxiaModelParameterPresetValue $preset.request_parameters)}})
    $data=[pscustomobject][ordered]@{schema_version=1;active_preset_id=[string]$Settings.active_parameter_preset_id;presets=$presets;overrides=@($Settings.user_preset_data.overrides)}
    if($null -ne $Settings.user_preset_data.PSObject.Properties['pending_shared_settings']){$data|Add-Member -NotePropertyName pending_shared_settings -NotePropertyValue (Copy-AtaraxiaModelParameterPresetValue $Settings.user_preset_data.pending_shared_settings)}
    return $data
}

function Save-AtaraxiaUserModelParameterPresetData([string]$Path,[object]$Settings,[object]$Dependencies=$null) {
    $data=Get-AtaraxiaUserModelParameterPresetData $Settings;Write-AtaraxiaJsonStoreFile $Path $data $Dependencies 60;return $data
}

