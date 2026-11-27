function Get-AtaraxiaThemePalette {
    param([ValidateSet('light','dark')][string]$Mode)
    if($Mode -eq 'light'){
        return [pscustomobject][ordered]@{app_background='#F5F7FB';surface='#FFFFFF';panel='#EAF0FA';drawer='#EEF2F8';primary_text='#172033';secondary_text='#526078';border='#D7DFEC';accent='#4059C7';accent_text='#FFFFFF';icon='#5F5F5F'}
    }
    return [pscustomobject][ordered]@{app_background='#111827';surface='#1D2B40';panel='#263750';drawer='#151F30';primary_text='#F1F5FC';secondary_text='#B5C1D4';border='#42536D';accent='#93AAFF';accent_text='#1C1C1C';icon='#C7C7C7'}
}
function Get-AtaraxiaContrastRatio {
    param([string]$Foreground,[string]$Background)
    function Get-Luminance([string]$Hex){$rgb=$Hex.TrimStart('#');$channels=@(foreach($offset in @(0,2,4)){$v=[Convert]::ToInt32($rgb.Substring($offset,2),16)/255;if($v -le .04045){$v/12.92}else{[Math]::Pow(($v+.055)/1.055,2.4)}});return .2126*$channels[0]+.7152*$channels[1]+.0722*$channels[2]}
    $a=Get-Luminance $Foreground;$b=Get-Luminance $Background
    return ([Math]::Max($a,$b)+.05)/([Math]::Min($a,$b)+.05)
}
function Resolve-AtaraxiaThemeMode {
    param([ValidateSet('system','light','dark')][string]$Preference,[ValidateSet('light','dark')][string]$SystemMode)
    if($Preference -eq 'system') { return $SystemMode }; return $Preference
}
function New-AtaraxiaGuiThemeState {
    return [pscustomobject]@{preference='system';effective=''}
}
function Set-AtaraxiaGuiThemeState {
    param([Parameter(Mandatory)][object]$State,[string]$Preference,[ValidateSet('light','dark')][string]$SystemMode)
    if($Preference -notin @('system','light','dark')){return [pscustomobject]@{accepted=$false;state=$State;apply_theme=$false;sync_selector=$false}}
    $effective=Resolve-AtaraxiaThemeMode $Preference $SystemMode
    $next=[pscustomobject]@{preference=$Preference;effective=$effective}
    return [pscustomobject]@{accepted=$true;state=$next;apply_theme=($State.effective -ne $effective);sync_selector=($State.preference -ne $Preference)}
}


