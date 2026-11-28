Set-StrictMode -Version Latest

function Set-AtaraxiaWpfThemeResources([System.Collections.IDictionary]$Resources,[object]$Palette,[scriptblock]$CreateBrush) {
    if($null -eq $Resources){throw 'WPF theme resource dictionary is required.'}
    if($null -eq $Palette){throw 'A validated theme palette is required.'}
    if($CreateBrush -isnot [scriptblock]){throw 'Theme brush factory must be provided.'}
    $keys=@{app_background='AppBackgroundBrush';surface='SurfaceBrush';panel='PanelBrush';drawer='DrawerBrush';primary_text='PrimaryTextBrush';secondary_text='SecondaryTextBrush';border='BorderBrush';accent='AccentBrush';accent_text='AccentTextBrush';icon='IconBrush'}
    foreach($name in $keys.Keys){$property=$Palette.PSObject.Properties[[string]$name];if($null -eq $property){throw "Theme palette is missing '$name'."};$resourceKey=[string]$keys[$name];$Resources[$resourceKey]=& $CreateBrush ([string]$property.Value)}
}
