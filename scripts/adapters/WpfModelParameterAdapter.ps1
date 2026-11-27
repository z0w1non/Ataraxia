Set-StrictMode -Version Latest

function New-AtaraxiaWpfModelParameterControls {
    param(
        [Parameter(Mandatory)][Windows.Controls.Panel]$Panel,
        [Parameter(Mandatory)][object[]]$Definitions,
        [Parameter(Mandatory)][object]$Values,
        [Parameter(Mandatory)][object]$Port,
        [Parameter(Mandatory)][Windows.Window]$Owner,
        [Parameter(Mandatory)][scriptblock]$GetText,
        [Parameter(Mandatory)][scriptblock]$OnDirty,
        [Parameter(Mandatory)][scriptblock]$OnSave,
        [Parameter(Mandatory)][scriptblock]$GetInputResult,
        [Parameter(Mandatory)][scriptblock]$GetStepValue
    )
    $Panel.Children.Clear();$controls=@{}
    foreach($definition in $Definitions){
        $row=[Windows.Controls.Grid]::new();$row.Margin=[Windows.Thickness]::new(0,3,0,3);$row.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$row.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$row.ColumnDefinitions[0].Width=[Windows.GridLength]::new(145);$row.ColumnDefinitions[1].Width=[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)
        $labelHost=[Windows.Controls.StackPanel]::new();$labelHost.Orientation='Horizontal';$labelHost.VerticalAlignment='Center'
        $label=[Windows.Controls.TextBlock]::new();$label.Text=[string]$definition.key;$label.VerticalAlignment='Center';$labelHost.Children.Add($label)|Out-Null
        $label.ToolTip=& $GetText $definition.help_key;[Windows.Controls.ToolTipService]::SetPlacement($label,[Windows.Controls.Primitives.PlacementMode]::Mouse);[Windows.Controls.ToolTipService]::SetHorizontalOffset($label,12);[Windows.Controls.ToolTipService]::SetVerticalOffset($label,16);[Windows.Controls.ToolTipService]::SetInitialShowDelay($label,300);[Windows.Controls.ToolTipService]::SetShowDuration($label,30000)
        [Windows.Controls.Grid]::SetColumn($labelHost,0);$row.Children.Add($labelHost)|Out-Null
        $value=if($null -ne $Values.PSObject.Properties[$definition.key]){$Values.($definition.key)}elseif($definition.kind -eq 'string'){''}elseif($definition.key -eq 'max_tokens'){1024}else{0}
        if($definition.kind -eq 'number'){
            $controlHost=[Windows.Controls.Grid]::new();$hasSlider=$null -ne $definition.slider_step;$inputWidth=if($null -ne $definition.PSObject.Properties['input_width']){[double]$definition.input_width}else{74.0};$numericColumnWidth=130.0
            $controlHost.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$controlHost.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$controlHost.ColumnDefinitions[0].Width=[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star);$controlHost.ColumnDefinitions[1].Width=[Windows.GridLength]::new($numericColumnWidth)
            $slider=$null;$sliderTarget=$null
            if($hasSlider){
                $slider=[Windows.Controls.Slider]::new();$slider.Minimum=$definition.min;$slider.Maximum=$definition.max;$slider.SmallChange=$definition.slider_step;$slider.LargeChange=$definition.slider_step;$slider.TickFrequency=$definition.slider_step;$slider.IsSnapToTickEnabled=$true;$slider.Value=[Math]::Max($definition.min,[Math]::Min($definition.max,[double]$value));$slider.VerticalAlignment='Center';[Windows.Controls.Grid]::SetColumn($slider,0);$controlHost.Children.Add($slider)|Out-Null
                $numericHost=[Windows.Controls.Grid]::new();$numericHost.Width=$inputWidth+18;$numericHost.HorizontalAlignment='Right';$numericHost.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$numericHost.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$numericHost.ColumnDefinitions[0].Width=[Windows.GridLength]::new($inputWidth);$numericHost.ColumnDefinitions[1].Width=[Windows.GridLength]::new(18)
                $sliderTarget='parameter-slider:'+ [string]$definition.key;Register-AtaraxiaGuiViewTarget $Port $sliderTarget $slider
            }else{$numericHost=[Windows.Controls.Grid]::new();$numericHost.Width=$inputWidth+18;$numericHost.HorizontalAlignment='Right';$numericHost.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$numericHost.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$numericHost.ColumnDefinitions[0].Width=[Windows.GridLength]::new($inputWidth);$numericHost.ColumnDefinitions[1].Width=[Windows.GridLength]::new(18)}
            $initialNumber=if($hasSlider){[double]$slider.Value}else{[double]$value};$input=[Windows.Controls.TextBox]::new();$input.Text=$initialNumber.ToString([string]$definition.format,[Globalization.CultureInfo]::InvariantCulture);$input.MinWidth=$inputWidth;$input.Width=$inputWidth;$input.VerticalContentAlignment='Center';[Windows.Controls.Grid]::SetColumn($input,0);$numericHost.Children.Add($input)|Out-Null
            $spinButtons=[Windows.Controls.StackPanel]::new();$spinButtons.Orientation='Vertical';$spinButtons.VerticalAlignment='Center';[Windows.Controls.Grid]::SetColumn($spinButtons,1);$numericHost.Children.Add($spinButtons)|Out-Null
            if($hasSlider){$slider.Tag=[pscustomobject]@{input=$input;definition=$definition;increase_button=$null;decrease_button=$null};$input.Tag=$slider}else{$input.Tag=[pscustomobject]@{definition=$definition;increase_button=$null;decrease_button=$null}}
            foreach($spin in @(@{direction=1;geometry='M4,12 L10,6 L16,12';tooltip_key='gui_param_increase';name='increase'},@{direction=-1;geometry='M4,8 L10,14 L16,8';tooltip_key='gui_param_decrease';name='decrease'})){
                $button=[Windows.Controls.Button]::new();$button.Width=18;$button.Height=14;$button.Padding=[Windows.Thickness]::new(0);$button.BorderThickness=[Windows.Thickness]::new(0);$button.Focusable=$false;$button.IsTabStop=$false;$button.ToolTip=& $GetText $spin.tooltip_key;Set-AtaraxiaWpfAutomationName $button ([string]$button.ToolTip);$button.Style=$Owner.Resources['IconButtonHover']
                $arrow=[Windows.Shapes.Path]::new();$arrow.Data=[Windows.Media.Geometry]::Parse([string]$spin.geometry);$arrow.Width=10;$arrow.Height=8;$arrow.Stretch='Uniform';$arrow.Stroke=$Owner.Resources['IconBrush'];$arrow.StrokeThickness=1.5;$arrow.StrokeStartLineCap='Round';$arrow.StrokeEndLineCap='Round';$button.Content=$arrow
                $button.Tag=[pscustomobject]@{slider=$slider;input=$input;key=[string]$definition.key;direction=[int]$spin.direction};$buttonTarget='parameter-spin:'+ [string]$definition.key+':'+[string]$spin.name;Register-AtaraxiaGuiViewTarget $Port $buttonTarget $button;$spinButtons.Children.Add($button)|Out-Null
                Register-AtaraxiaGuiViewAction $Port $buttonTarget 'activate' {param($sender,$eventArgs)$binding=$sender.Tag;$current=if($null -ne $binding.slider){[double]$binding.slider.Value}else{[double](& $GetInputResult $binding.key $binding.input.Text).value};$next=& $GetStepValue $binding.key $current $binding.direction;if($null -ne $binding.slider){$binding.slider.Value=$next;$binding.input.Text=([double]$binding.slider.Value).ToString([string]$binding.slider.Tag.definition.format,[Globalization.CultureInfo]::InvariantCulture)}else{$binding.input.Text=([double]$next).ToString([string]$binding.input.Tag.definition.format,[Globalization.CultureInfo]::InvariantCulture);& $OnDirty}}.GetNewClosure()
                $buttonSlot=if($hasSlider){$slider.Tag}else{$input.Tag};if($spin.name -eq 'increase'){$buttonSlot.increase_button=$button}else{$buttonSlot.decrease_button=$button}
            }
            [Windows.Controls.Grid]::SetColumn($numericHost,1);$controlHost.Children.Add($numericHost)|Out-Null
            if($hasSlider){Register-AtaraxiaGuiViewAction $Port $sliderTarget 'value_change' {param($sender,$eventArgs)$binding=$sender.Tag;$binding.input.Text=([double]$sender.Value).ToString([string]$binding.definition.format,[Globalization.CultureInfo]::InvariantCulture)}.GetNewClosure()}
            $inputTarget='parameter-input:'+ [string]$definition.key;Register-AtaraxiaGuiViewTarget $Port $inputTarget $input
            Register-AtaraxiaGuiViewAction $Port $inputTarget 'text_change' {param($sender,$eventArgs)$model=if($hasSlider){$sender.Tag.Tag.definition}else{$sender.Tag.definition};$inputResult=& $GetInputResult ([string]$model.key) $sender.Text;if($inputResult.valid){$sender.BorderBrush=[Windows.Media.Brushes]::Gray;& $OnDirty;if($hasSlider){$slider=$sender.Tag;$normalized=[double]$inputResult.value;if([Math]::Abs($slider.Value-$normalized) -gt [double]::Epsilon){$slider.Value=$normalized}}}else{$sender.BorderBrush=[Windows.Media.Brushes]::Red}}.GetNewClosure()
            Register-AtaraxiaGuiViewAction $Port $inputTarget 'lost_focus' {& $OnSave}.GetNewClosure()
            $controls[$definition.key]=$input;$panelControl=$controlHost
        }else{
            $input=[Windows.Controls.TextBox]::new();$input.Text=if($definition.key -eq 'stop'){@($value) -join "`r`n"}else{[string]$value};$input.AcceptsReturn=$true;$input.TextWrapping='Wrap';$input.VerticalScrollBarVisibility='Auto';$input.MinHeight=48;$input.MaxHeight=90;$input.SetResourceReference([Windows.Controls.Control]::BackgroundProperty,'SurfaceBrush');$input.SetResourceReference([Windows.Controls.Control]::ForegroundProperty,'PrimaryTextBrush');$input.SetResourceReference([Windows.Controls.Control]::BorderBrushProperty,'BorderBrush');$inputTarget='parameter-input:'+ [string]$definition.key;Register-AtaraxiaGuiViewTarget $Port $inputTarget $input
            Register-AtaraxiaGuiViewAction $Port $inputTarget 'text_change' {param($sender,$eventArgs)& $OnDirty}.GetNewClosure();Register-AtaraxiaGuiViewAction $Port $inputTarget 'lost_focus' {& $OnSave}.GetNewClosure();$controls[$definition.key]=$input;$panelControl=$input
        }
        [Windows.Controls.Grid]::SetColumn($panelControl,1);$row.Children.Add($panelControl)|Out-Null;$Panel.Children.Add($row)|Out-Null
    }
    return $controls
}

