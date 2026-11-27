function Get-AtaraxiaWindowsSystemTheme([scriptblock]$ReadPreference=$null) {
    if($ReadPreference -isnot [scriptblock]){
        $ReadPreference={
            (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme
        }
    }
    try {
        $value=& $ReadPreference
        if($null -ne $value){if([int]$value -eq 0){return 'dark'};if([int]$value -eq 1){return 'light'}}
    } catch {}
    return 'light'
}
