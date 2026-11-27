Set-StrictMode -Version Latest

function Set-AtaraxiaWpfThemeResources([System.Collections.IDictionary]$Resources,[ValidateSet('light','dark')][string]$Mode,[scriptblock]$CreateBrush) {
    if($null -eq $Resources){throw 'WPF theme resource dictionary is required.'}
    if($CreateBrush -isnot [scriptblock]){throw 'Theme brush factory must be provided.'}
    $palette=Get-AtaraxiaThemePalette $Mode
    $keys=@{app_background='AppBackgroundBrush';surface='SurfaceBrush';panel='PanelBrush';drawer='DrawerBrush';primary_text='PrimaryTextBrush';secondary_text='SecondaryTextBrush';border='BorderBrush';accent='AccentBrush';accent_text='AccentTextBrush';icon='IconBrush'}
    foreach($name in $keys.Keys){$resourceKey=[string]$keys[$name];$color=[string]$palette.($name);$Resources[$resourceKey]=& $CreateBrush $color}
}
