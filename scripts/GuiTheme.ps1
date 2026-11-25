function Get-AtaraxiaThemePalette {
    param([ValidateSet('light','dark')][string]$Mode)
    if($Mode -eq 'light'){
        return [pscustomobject][ordered]@{app_background='#FAFAFA';surface='#FFFFFF';panel='#F0F0F0';drawer='#F7F7F7';primary_text='#141414';secondary_text='#555555';border='#D0D0D0';accent='#303030';accent_text='#FFFFFF';icon='#303030'}
    }
    return [pscustomobject][ordered]@{app_background='#181818';surface='#202020';panel='#2C2C2C';drawer='#1D1D1D';primary_text='#F5F5F5';secondary_text='#B8B8B8';border='#505050';accent='#E5E5E5';accent_text='#111111';icon='#E0E0E0'}
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
function Get-AtaraxiaSystemTheme {
    try{$value=(Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme;if($null -ne $value){if([int]$value -eq 0){return 'dark'};if([int]$value -eq 1){return 'light'}}}catch{}
    return 'light'
}


