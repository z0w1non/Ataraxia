Set-StrictMode -Version Latest

function New-AtaraxiaModelParameterEditorState {
    return [pscustomobject][ordered]@{initialized=$false;dirty=$false;loading=$false;active_preset_id='';active_preset_origin=''}
}

function Assert-AtaraxiaModelParameterEditorState([object]$State) {
    if($null -eq $State -or $null -eq $State.PSObject.Properties['initialized'] -or $null -eq $State.PSObject.Properties['dirty'] -or $null -eq $State.PSObject.Properties['loading']){throw 'Model parameter editor state is invalid.'}
}

function Set-AtaraxiaModelParameterEditorLoading([object]$State,[bool]$Loading) {
    Assert-AtaraxiaModelParameterEditorState $State
    $State.loading=$Loading
    return $State
}

function Set-AtaraxiaModelParameterEditorDirty([object]$State,[bool]$Dirty) {
    Assert-AtaraxiaModelParameterEditorState $State
    $State.dirty=$Dirty
    return $State
}

function Set-AtaraxiaModelParameterEditorPreset([object]$State,[string]$PresetId,[ValidateSet('user','builtin')][string]$Origin='user') {
    Assert-AtaraxiaModelParameterEditorState $State
    if([string]::IsNullOrWhiteSpace($PresetId)){throw 'An active model parameter preset ID is required.'}
    $State.active_preset_id=$PresetId
    $State.active_preset_origin=$Origin
    return $State
}

function Test-AtaraxiaModelParameterEditorOverwriteAllowed([object]$State) {
    Assert-AtaraxiaModelParameterEditorState $State
    return ([string]$State.active_preset_origin -ne 'builtin')
}

function Set-AtaraxiaModelParameterEditorInitialized([object]$State,[bool]$Initialized) {
    Assert-AtaraxiaModelParameterEditorState $State
    $State.initialized=$Initialized
    return $State
}

function Test-AtaraxiaModelParameterEditorChangeAllowed([object]$State) {
    Assert-AtaraxiaModelParameterEditorState $State
    return (-not [bool]$State.loading)
}

function New-AtaraxiaModelParameterEditorHandlers([object]$State,[scriptblock]$Save) {
    Assert-AtaraxiaModelParameterEditorState $State
    if($Save -isnot [scriptblock]){throw 'Model parameter editor save action must be a script block.'}
    $capturedState=$State;$saveAction=$Save
    return [pscustomobject]@{
        on_dirty={ $capturedState.dirty=$true }.GetNewClosure()
        on_save={ if([bool]$capturedState.dirty){& $saveAction} }.GetNewClosure()
    }
}
