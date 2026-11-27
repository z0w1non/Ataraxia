Set-StrictMode -Version Latest

function Enter-AtaraxiaGuiInstance([object]$Identity) {
    if($null -eq $Identity -or $null -eq $Identity.PSObject.Properties['mutex_name'] -or $null -eq $Identity.PSObject.Properties['activation_event_name']){throw 'GUI instance identity is invalid.'}
    $mutexName=[string]$Identity.mutex_name;$eventName=[string]$Identity.activation_event_name
    if([string]::IsNullOrWhiteSpace($mutexName) -or [string]::IsNullOrWhiteSpace($eventName)){throw 'GUI instance synchronization names are required.'}
    $activationEvent=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::AutoReset,$eventName)
    $mutex=[Threading.Mutex]::new($false,$mutexName)
    try{
        $ownsMutex=$false
        try{$ownsMutex=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$ownsMutex=$true}
        if($ownsMutex){return [pscustomobject]@{is_primary=$true;is_disposed=$false;mutex=$mutex;activation_event=$activationEvent}}
        $null=$activationEvent.Set()
        $mutex.Dispose();$activationEvent.Dispose()
        return [pscustomobject]@{is_primary=$false;is_disposed=$true;mutex=$null;activation_event=$null}
    }catch{
        $mutex.Dispose();$activationEvent.Dispose();throw
    }
}

function Test-AtaraxiaGuiActivationRequested([object]$Instance) {
    if($null -eq $Instance -or $null -eq $Instance.PSObject.Properties['is_primary'] -or $null -eq $Instance.PSObject.Properties['is_disposed']){throw 'GUI instance handle is invalid.'}
    if(-not [bool]$Instance.is_primary -or [bool]$Instance.is_disposed){return $false}
    if($null -eq $Instance.activation_event){throw 'Primary GUI instance activation event is unavailable.'}
    return [bool]$Instance.activation_event.WaitOne(0)
}

function Exit-AtaraxiaGuiInstance([object]$Instance) {
    if($null -eq $Instance -or $null -eq $Instance.PSObject.Properties['is_primary'] -or $null -eq $Instance.PSObject.Properties['is_disposed']){throw 'GUI instance handle is invalid.'}
    if([bool]$Instance.is_disposed){return}
    try{if([bool]$Instance.is_primary -and $null -ne $Instance.mutex){$Instance.mutex.ReleaseMutex()|Out-Null}}
    finally{
        if($null -ne $Instance.mutex){$Instance.mutex.Dispose()}
        if($null -ne $Instance.activation_event){$Instance.activation_event.Dispose()}
        $Instance.is_primary=$false;$Instance.is_disposed=$true;$Instance.mutex=$null;$Instance.activation_event=$null
    }
}
