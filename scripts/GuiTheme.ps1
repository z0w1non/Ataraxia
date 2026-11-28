function Get-AtaraxiaThemePalette {
    param([ValidateSet('light','dark')][string]$Mode)
    if($Mode -eq 'light'){
        return [pscustomobject][ordered]@{app_background='#F5F5F5';surface='#FFFFFF';panel='#E8E8E8';drawer='#EEEEEE';primary_text='#171717';secondary_text='#505050';border='#B8B8B8';accent='#303030';accent_text='#FFFFFF';icon='#505050'}
    }
    return [pscustomobject][ordered]@{app_background='#171717';surface='#242424';panel='#303030';drawer='#1D1D1D';primary_text='#F5F5F5';secondary_text='#C2C2C2';border='#666666';accent='#D0D0D0';accent_text='#171717';icon='#D0D0D0'}
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


