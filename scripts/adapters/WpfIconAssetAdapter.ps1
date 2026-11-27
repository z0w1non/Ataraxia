Set-StrictMode -Version Latest

function Get-AtaraxiaSvgGeometryFromFile([string]$SvgPath) {
    if(-not(Test-Path -LiteralPath $SvgPath -PathType Leaf)){return ''}
    return ConvertFrom-AtaraxiaSvgGeometry ([IO.File]::ReadAllText($SvgPath))
}

function Get-AtaraxiaWpfUiIconGeometry([string]$ProjectRoot,[string]$IconName) {
    $iconPath=Join-Path (Join-Path (Join-Path $ProjectRoot 'assets') 'ui-icons') ($IconName+'.svg');$data=Get-AtaraxiaSvgGeometryFromFile $iconPath
    if([string]::IsNullOrWhiteSpace($data)){throw "Ataraxia SVG icon is missing or empty: $iconPath"}
    return [Windows.Media.Geometry]::Parse($data)
}

function Get-AtaraxiaRoleIconGeometry([string]$RoleIconDirectory) {
    $icons=@{}
    if(Test-Path -LiteralPath $RoleIconDirectory -PathType Container){foreach($file in Get-ChildItem -LiteralPath $RoleIconDirectory -Filter '*.svg' -File){$geometry=Get-AtaraxiaSvgGeometryFromFile $file.FullName;if(-not[string]::IsNullOrWhiteSpace($geometry)){$icons[$file.BaseName]=$geometry}}}
    return $icons
}

function Set-AtaraxiaWpfPathIcon([object]$Icon,[string]$AssetsRoot,[string]$IconName) {
    $Icon.Data=Get-AtaraxiaWpfUiIconGeometry $AssetsRoot $IconName;$Icon.Width=16;$Icon.Height=16;$Icon.Fill=[Windows.Media.Brushes]::Transparent
}

function Set-AtaraxiaWpfPathForeground([object]$Icon) {
    $Icon.Fill=[Windows.Media.Brushes]::Transparent;$binding=[Windows.Data.Binding]::new('Foreground');$relativeSource=[Windows.Data.RelativeSource]::new();$relativeSource.Mode=[Windows.Data.RelativeSourceMode]::FindAncestor;$relativeSource.AncestorType=[Windows.Controls.Primitives.ButtonBase];$binding.RelativeSource=$relativeSource;$null=$Icon.SetBinding([Windows.Shapes.Shape]::StrokeProperty,$binding)
}

function Set-AtaraxiaWpfAutomationName([Windows.UIElement]$Element,[string]$Name) {
    if($null -eq $Element -or [string]::IsNullOrWhiteSpace($Name)){throw 'Accessible icon control requires a non-empty automation name.'}
    [Windows.Automation.AutomationProperties]::SetName($Element,$Name)
}
