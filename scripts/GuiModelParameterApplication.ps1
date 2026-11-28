Set-StrictMode -Version Latest

function Save-AtaraxiaGuiModelParameterSettings([object]$Settings,[scriptblock]$SaveUserPresets,[scriptblock]$SaveSharedSettings) {
    if($null -eq $Settings){throw 'GUI model parameter settings are required.'}
    foreach($writer in @($SaveUserPresets,$SaveSharedSettings)){if($writer -isnot [scriptblock]){throw 'GUI model parameter persistence requires both user-preset and shared-settings writers.'}}
    try{& $SaveUserPresets $Settings|Out-Null}catch{throw [InvalidOperationException]::new('Could not save user model parameter presets: '+$_.Exception.Message,$_.Exception)}
    try{& $SaveSharedSettings $Settings|Out-Null}catch{
        $original=$_.Exception
        try{Set-AtaraxiaPendingSharedModelParameterSettings $Settings $SaveUserPresets}catch{throw [InvalidOperationException]::new('Shared KoboldCpp settings could not be saved and the recovery journal could not be written: '+$original.Message+'; '+$_.Exception.Message,$_.Exception)}
        throw [InvalidOperationException]::new('User model parameter presets were saved, but shared KoboldCpp settings could not be saved. A recovery journal was retained: '+$original.Message,$original)
    }
    try{Clear-AtaraxiaPendingSharedModelParameterSettings $Settings $SaveUserPresets}catch{throw [InvalidOperationException]::new('Shared KoboldCpp settings were saved, but the recovery journal could not be cleared: '+$_.Exception.Message,$_.Exception)}
    return $Settings
}

function Set-AtaraxiaPendingSharedModelParameterSettings([object]$Settings,[scriptblock]$SaveUserPresets) {
    if($null -eq $Settings -or $Settings.request_parameters -isnot [System.Management.Automation.PSCustomObject]){throw 'A valid request_parameters object is required to create a recovery journal.'}
    if($null -eq $Settings.PSObject.Properties['user_preset_data']){throw 'User model parameter data is required to create a recovery journal.'}
    $Settings.user_preset_data|Add-Member -NotePropertyName pending_shared_settings -NotePropertyValue ([pscustomobject][ordered]@{schema_version=1;request_parameters=(Copy-AtaraxiaModelParameterPresetValue $Settings.request_parameters)}) -Force
    & $SaveUserPresets $Settings|Out-Null
    return $Settings.user_preset_data.pending_shared_settings
}

function Clear-AtaraxiaPendingSharedModelParameterSettings([object]$Settings,[scriptblock]$SaveUserPresets) {
    if($null -eq $Settings -or $null -eq $Settings.PSObject.Properties['user_preset_data']){return $false}
    if($null -eq $Settings.user_preset_data.PSObject.Properties['pending_shared_settings']){return $false}
    $previous=$Settings.user_preset_data.pending_shared_settings
    $Settings.user_preset_data.PSObject.Properties.Remove('pending_shared_settings')
    try{& $SaveUserPresets $Settings|Out-Null}catch{$Settings.user_preset_data|Add-Member -NotePropertyName pending_shared_settings -NotePropertyValue $previous -Force;throw}
    return $true
}

function Resolve-AtaraxiaPendingSharedModelParameterSettings([object]$Settings,[scriptblock]$SaveSharedSettings,[scriptblock]$SaveUserPresets) {
    if($null -eq $Settings -or $null -eq $Settings.PSObject.Properties['user_preset_data'] -or $null -eq $Settings.user_preset_data.PSObject.Properties['pending_shared_settings']){return [pscustomobject]@{recovered=$false;reason='none'}}
    $journal=$Settings.user_preset_data.pending_shared_settings
    if($journal -isnot [System.Management.Automation.PSCustomObject] -or $null -eq $journal.PSObject.Properties['schema_version'] -or [int]$journal.schema_version -ne 1 -or $null -eq $journal.PSObject.Properties['request_parameters'] -or $journal.request_parameters -isnot [System.Management.Automation.PSCustomObject]){throw 'Pending shared-settings recovery journal has an invalid structure; the original user data was preserved.'}
    $Settings.request_parameters=Copy-AtaraxiaModelParameterPresetValue $journal.request_parameters
    & $SaveSharedSettings $Settings|Out-Null
    $null=Clear-AtaraxiaPendingSharedModelParameterSettings $Settings $SaveUserPresets
    return [pscustomobject]@{recovered=$true;reason='applied_pending_settings'}
}
