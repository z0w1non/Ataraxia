[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
$guiThemeDefinitions=Get-Content -LiteralPath (Join-Path $projectRoot 'configs/gui-themes.json') -Raw -Encoding UTF8|ConvertFrom-Json

function Assert-WpfControlTest([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}

if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'WPF control emulation tests require Windows.'}
if([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA){throw 'Run WPF control emulation with pwsh -STA.'}

$null=Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,UIAutomationClient,UIAutomationTypes
. (Join-Path $projectRoot 'scripts/GuiPresentationPort.ps1')
. (Join-Path $projectRoot 'scripts/GuiInputLayout.ps1')
. (Join-Path $projectRoot 'scripts/GuiModelParameters.ps1')
. (Join-Path $projectRoot 'scripts/GuiModelParameterEditorState.ps1')
. (Join-Path $projectRoot 'scripts/GuiTheme.ps1')
. (Join-Path $projectRoot 'scripts/GuiConversationModel.ps1')
. (Join-Path $projectRoot 'scripts/GuiPresentationPort.ps1')
. (Join-Path $projectRoot 'scripts/adapters/WpfGuiViewAdapter.ps1')
. (Join-Path $projectRoot 'scripts/adapters/WpfIconAssetAdapter.ps1')
. (Join-Path $projectRoot 'scripts/adapters/WpfModelParameterAdapter.ps1')
. (Join-Path $projectRoot 'scripts/adapters/WpfThemeAdapter.ps1')

[xml]$view=[IO.File]::ReadAllText((Join-Path $projectRoot 'scripts/presentation/AtaraxiaWindow.xaml'))
$window=[Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($view))
try{
    Assert-WpfControlTest (-not $window.IsVisible) 'The emulated WPF window must remain unshown.'
    $panel=$window.FindName('ParameterPanel')
    $state=New-AtaraxiaModelParameterEditorState
    $dirtyCalls=[pscustomobject]@{count=0};$saveCalls=[pscustomobject]@{count=0}
    $onDirty={$dirtyCalls.count++}.GetNewClosure();$onSave={$saveCalls.count++}.GetNewClosure()
    $handlers=New-AtaraxiaModelParameterEditorHandlers $state $onSave
    $port=New-AtaraxiaWpfGuiViewPort @{parameter_panel=$panel;dispatcher=$window.Dispatcher} @{} {param($Text)} ${function:Get-AtaraxiaGuiInputHeight}
    $values=[pscustomobject]@{max_tokens=1024;temperature=0.70;top_p=0.90;top_k=40;presence_penalty=0.0;frequency_penalty=0.0;repetition_penalty=1.0;seed=-1;stop=@('END')}
    $controls=New-AtaraxiaWpfModelParameterControls -Panel $panel -Definitions @(Get-AtaraxiaModelParameterDefinitions) -Values $values -Port $port -Owner $window -GetText {param($Key)$Key} -OnDirty $onDirty -OnSave $handlers.on_save -GetInputResult ${function:Get-AtaraxiaModelParameterInputResult} -GetStepValue ${function:Get-AtaraxiaModelParameterStepValue}

    $null=$window.ApplyTemplate();$window.Measure([Windows.Size]::new(1000,820));$window.Arrange([Windows.Rect]::new(0,0,1000,820));$window.UpdateLayout()
    $buttonNodes=@($view.SelectNodes('//*[local-name()="Button"][.//*[local-name()="Path"]]'))
    foreach($node in $buttonNodes){$name=$node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml');if([string]::IsNullOrWhiteSpace($name)){continue};$button=$window.FindName($name);$automationName=[Windows.Automation.AutomationProperties]::GetName($button);Assert-WpfControlTest ($automationName -eq [string]$button.ToolTip) "Icon button $name did not expose its tooltip as the UI Automation name."}
    Assert-WpfControlTest ($panel.Children.Count -eq 9 -and $controls.stop.Text -eq 'END') 'The parameter view adapter did not materialize all expected input controls.'
    $temperature=$controls.temperature;$temperatureSlider=$temperature.Tag;$increase=$temperatureSlider.Tag.increase_button;$decrease=$temperatureSlider.Tag.decrease_button
    Assert-WpfControlTest ([Windows.Automation.AutomationProperties]::GetName($increase) -eq [string]$increase.ToolTip -and [Windows.Automation.AutomationProperties]::GetName($decrease) -eq [string]$decrease.ToolTip) 'Generated spinner buttons do not expose their localized tooltips as UI Automation names.'
    $increase.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Assert-WpfControlTest ($temperature.Text -eq '0.71' -and [math]::Abs($temperatureSlider.Value-0.71) -lt 0.000001 -and $dirtyCalls.count -gt 0) 'An emulated spinner click did not update the parameter model and dirty state.'
    $stop=$controls.stop;$stop.Text="STOP`r`nEND"
    Assert-WpfControlTest ($stop.Text -match 'STOP' -and -not $window.IsVisible) 'An emulated text entry changed no value or caused a visible window.'

    $createBrush={param($Hex)([Windows.Media.BrushConverter]::new()).ConvertFromString($Hex)}
    $darkPalette=Get-AtaraxiaThemePalette $guiThemeDefinitions 'dark'
    Set-AtaraxiaWpfThemeResources $window.Resources $darkPalette $createBrush
    $brushColor={param($Brush)'#'+$Brush.Color.ToString().Substring(3)}
    Assert-WpfControlTest ((& $brushColor $stop.Background) -eq $darkPalette.surface -and (& $brushColor $stop.Foreground) -eq $darkPalette.primary_text -and (& $brushColor $stop.BorderBrush) -eq $darkPalette.border) 'The generated stop input did not receive the dark theme resources.'
    $lightPalette=Get-AtaraxiaThemePalette $guiThemeDefinitions 'light'
    Set-AtaraxiaWpfThemeResources $window.Resources $lightPalette $createBrush
    Assert-WpfControlTest ((& $brushColor $stop.Background) -eq $lightPalette.surface -and (& $brushColor $stop.Foreground) -eq $lightPalette.primary_text -and (& $brushColor $stop.BorderBrush) -eq $lightPalette.border) 'The generated stop input did not follow a later light theme switch.'

    $conversationControl=$window.FindName('Conversation')
    $themeSelector=$window.FindName('ThemeSelector');$modelSelector=$window.FindName('ModelFileSelector');$presetSelector=$window.FindName('ParameterPresetSelector');$scrollViewer=$window.FindName('ConversationScrollViewer');$scrollLatest=$window.FindName('ScrollToLatest')
    $valueProperties=@{theme_selector='SelectedValue';model_selector='SelectedValue';parameter_presets='SelectedValue';scroll_latest='Visibility'}
    $port=New-AtaraxiaWpfGuiViewPort @{parameter_panel=$panel;conversation=$conversationControl;theme_selector=$themeSelector;model_selector=$modelSelector;parameter_presets=$presetSelector;scroll_latest=$scrollLatest;conversation_scroll=$scrollViewer;dispatcher=$window.Dispatcher} $valueProperties {param($Text)} ${function:Get-AtaraxiaGuiInputHeight}
    $themeSelector.SelectedValuePath='key';$modelSelector.SelectedValuePath='path';$presetSelector.SelectedValuePath='id'
    $themeOptions=@([pscustomobject]@{key='system';label='System'},[pscustomobject]@{key='light';label='Light'},[pscustomobject]@{key='dark';label='Dark'})
    $modelOptions=@([pscustomobject]@{name='Qwen.gguf';path='models/Qwen.gguf'},[pscustomobject]@{name='Llama.gguf';path='models/Llama.gguf'})
    $presetOptions=@([pscustomobject]@{name='Balanced';id='balanced'},[pscustomobject]@{name='Creative';id='creative'})
    Set-AtaraxiaGuiViewItems $port 'theme_selector' $themeOptions;Set-AtaraxiaGuiViewItems $port 'model_selector' $modelOptions;Set-AtaraxiaGuiViewItems $port 'parameter_presets' $presetOptions
    Set-AtaraxiaGuiViewValue $port 'theme_selector' 'dark';Set-AtaraxiaGuiViewValue $port 'model_selector' 'models/Llama.gguf';Set-AtaraxiaGuiViewValue $port 'parameter_presets' 'creative'
    Assert-WpfControlTest ($themeSelector.SelectedItem.key -eq 'dark' -and $modelSelector.SelectedItem.name -eq 'Llama.gguf' -and $presetSelector.SelectedItem.name -eq 'Creative') 'Settings selectors did not apply their selected theme, model, and parameter preset through the view port.'
    $savePresetButton=$window.FindName('SaveParameterPreset');$deletePresetButton=$window.FindName('DeleteParameterPreset')
    $actionPort=New-AtaraxiaWpfGuiViewPort @{save_preset_enabled=$savePresetButton;delete_preset_enabled=$deletePresetButton;dispatcher=$window.Dispatcher} @{save_preset_enabled='IsEnabled';delete_preset_enabled='IsEnabled'} {param($Text)} ${function:Get-AtaraxiaGuiInputHeight}
    Set-AtaraxiaGuiViewValue $actionPort 'save_preset_enabled' $false;Set-AtaraxiaGuiViewValue $actionPort 'delete_preset_enabled' $false
    Assert-WpfControlTest (-not $savePresetButton.IsEnabled -and -not $deletePresetButton.IsEnabled -and -not $window.IsVisible) 'Built-in preset action values did not disable overwrite and delete on the unshown WPF controls.'
    Set-AtaraxiaGuiViewValue $actionPort 'save_preset_enabled' $true;Set-AtaraxiaGuiViewValue $actionPort 'delete_preset_enabled' $true
    Assert-WpfControlTest ($savePresetButton.IsEnabled -and $deletePresetButton.IsEnabled) 'User-owned preset action values did not enable overwrite and delete.'
    $longBody='Conversation content for scroll emulation. ' * 160
    $conversation=[pscustomobject]@{entries=@(
        [pscustomobject]@{body=$longBody;timestamp='2026-01-01T00:00:00Z'},
        [pscustomobject]@{body=$longBody;timestamp='2026-01-01T00:00:02Z'}
    )}
    $conversationState=[pscustomobject]@{history=@([pscustomobject]@{role='Planner';timestamp='2026-01-01T00:00:01Z';report=[pscustomobject]@{heading='Plan';body=$longBody}})}
    $conversationItems=@(ConvertTo-AtaraxiaConversationView $conversation $conversationState @{planner='M0,0 L10,10'})
    Set-AtaraxiaGuiViewItems $port 'conversation' $conversationItems
    $null=$conversationControl.ApplyTemplate();$conversationControl.Measure([Windows.Size]::new(900,500));$conversationControl.Arrange([Windows.Rect]::new(0,0,900,500));$conversationControl.UpdateLayout()
    $window.Measure([Windows.Size]::new(1000,820));$window.Arrange([Windows.Rect]::new(0,0,1000,820));$window.UpdateLayout()
    Assert-WpfControlTest ($conversationControl.Items.Count -eq 3 -and $conversationControl.Items[0].heading -eq 'You' -and $conversationControl.Items[1].heading -eq '[Planner] Plan' -and $conversationControl.Items[1].is_expanded -and -not $conversationControl.Items[0].is_expanded -and $conversationControl.Items[1].icon_geometry -eq 'M0,0 L10,10' -and -not $window.IsVisible) 'The conversation view model was not projected into the unshown WPF ItemsControl in timestamp order with its latest report expanded.'
    $firstConversationItem=$conversationControl.ItemContainerGenerator.ContainerFromIndex(0)
    Assert-WpfControlTest ($null -ne $firstConversationItem -and $firstConversationItem.Content.body -eq $longBody) 'WPF did not generate an item container for the emulated conversation view.'
    $overflowContent=[Windows.Controls.StackPanel]::new();for($index=0;$index -lt 40;$index++){$overflowContent.Children.Add([Windows.Controls.Border]::new())|Out-Null;$overflowContent.Children[$index].Height=30}
    $scrollViewer.Content=$overflowContent;$null=$scrollViewer.ApplyTemplate();$scrollViewer.Measure([Windows.Size]::new(900,360));$scrollViewer.Arrange([Windows.Rect]::new(0,0,900,360));$scrollViewer.UpdateLayout()
    Assert-WpfControlTest ($scrollViewer.ScrollableHeight -gt 8) "The emulated conversation did not produce a scrollable viewport (extent=$($scrollViewer.ExtentHeight), viewport=$($scrollViewer.ViewportHeight), height=$($scrollViewer.ActualHeight), items=$($conversationControl.Items.Count))."
    $scrollState=[pscustomobject]@{ScrollableHeight=[double]$scrollViewer.ScrollableHeight;VerticalOffset=0.0}
    Register-AtaraxiaGuiViewTarget $port 'conversation_scroll' $scrollState
    Set-AtaraxiaGuiViewValue $port 'scroll_latest' $false
    $scrollState.VerticalOffset=200.0
    Invoke-AtaraxiaGuiViewOperation $port sync_scroll_to_latest_visibility 'scroll_latest' 'conversation_scroll'
    Assert-WpfControlTest ($scrollLatest.Visibility -eq [Windows.Visibility]::Visible) 'The jump-to-latest control was not shown while the conversation was scrolled away from its end.'
    $scrollState.VerticalOffset=$scrollState.ScrollableHeight
    Invoke-AtaraxiaGuiViewOperation $port sync_scroll_to_latest_visibility 'scroll_latest' 'conversation_scroll'
    Assert-WpfControlTest ($scrollLatest.Visibility -eq [Windows.Visibility]::Collapsed -and [math]::Abs($scrollState.VerticalOffset-$scrollState.ScrollableHeight) -lt 1) 'The jump-to-latest control remained visible after the scroll state reached the end.'
    Write-Output 'PASS: WPF controls were emulated without displaying a window or starting an external process.'
}finally{
    if($window.IsVisible){$window.Close()}else{$window.Close()}
}
