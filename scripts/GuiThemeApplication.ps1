Set-StrictMode -Version Latest

function Invoke-AtaraxiaGuiThemePreferenceSave([object]$State,[string]$Preference,[string]$SystemMode,[scriptblock]$SavePreference) {
    if($SavePreference -isnot [scriptblock]){throw 'A theme preference persistence adapter is required.'}
    $transition=Set-AtaraxiaGuiThemeState $State $Preference $SystemMode
    if(-not $transition.accepted){return $transition}
    & $SavePreference $Preference
    return $transition
}
