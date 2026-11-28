function Get-AtaraxiaThemePalette {
    param([Parameter(Mandatory)][object]$Definitions,[ValidateSet('light','dark')][string]$Mode)
    $keys=@('app_background','surface','panel','drawer','primary_text','secondary_text','border','accent','accent_text','icon')
    $definitionKeys=@($Definitions.PSObject.Properties|ForEach-Object{$_.Name}|Sort-Object)
    if(($definitionKeys -join ',') -cne 'schema_version,themes'){throw 'GUI theme palette definitions have an unexpected root structure.'}
    if([int]$Definitions.schema_version -ne 1){throw 'Unsupported GUI theme palette schema version.'}
    $themesProperty=$Definitions.PSObject.Properties['themes'];if($null -eq $themesProperty){throw 'GUI theme palette definitions must contain themes.'}
    $themeNames=@($themesProperty.Value.PSObject.Properties|ForEach-Object{$_.Name}|Sort-Object)
    if(($themeNames -join ',') -cne 'dark,light'){throw 'GUI theme palette definitions must contain exactly light and dark themes.'}
    $themeProperty=$themesProperty.Value.PSObject.Properties[$Mode];if($null -eq $themeProperty){throw "GUI theme palette is missing '$Mode'."}
    $palette=$themeProperty.Value;$paletteKeys=@($palette.PSObject.Properties|ForEach-Object{$_.Name}|Sort-Object);$expectedKeys=@($keys|Sort-Object)
    if(($paletteKeys -join ',') -cne ($expectedKeys -join ',')){throw "GUI theme palette '$Mode' has an unexpected structure."}
    $result=[ordered]@{}
    foreach($key in $keys){$color=[string]$palette.($key);if($color -notmatch '^#[0-9A-Fa-f]{6}$'){throw "GUI theme palette '$Mode/$key' must be a six-digit hexadecimal color."};$result[$key]=$color.ToUpperInvariant()}
    return [pscustomobject]$result
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


