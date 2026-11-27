function Get-AtaraxiaModelParameterDefinitions {
    @(
        [pscustomobject]@{key='max_tokens';help_key='gui_param_help_max_tokens';kind='number';min=1.0;max=8191.0;step=1.0;slider_step=256.0;format='0';group='request'},
        [pscustomobject]@{key='temperature';help_key='gui_param_help_temperature';kind='number';min=0.0;max=2.0;step=0.01;slider_step=0.1;format='0.00';group='request'},
        [pscustomobject]@{key='top_p';help_key='gui_param_help_top_p';kind='number';min=0.0;max=1.0;step=0.01;slider_step=0.05;format='0.00';group='request'},
        [pscustomobject]@{key='top_k';help_key='gui_param_help_top_k';kind='number';min=0.0;max=200.0;step=1.0;slider_step=10.0;format='0';group='request'},
        [pscustomobject]@{key='presence_penalty';help_key='gui_param_help_presence_penalty';kind='number';min=-2.0;max=2.0;step=0.01;slider_step=0.2;format='0.00';group='request'},
        [pscustomobject]@{key='frequency_penalty';help_key='gui_param_help_frequency_penalty';kind='number';min=-2.0;max=2.0;step=0.01;slider_step=0.2;format='0.00';group='request'},
        [pscustomobject]@{key='repetition_penalty';help_key='gui_param_help_repetition_penalty';kind='number';min=0.0;max=2.0;step=0.01;slider_step=0.1;format='0.00';group='request'},
        [pscustomobject]@{key='seed';help_key='gui_param_help_seed';kind='number';min=-1.0;max=2147483647.0;step=1.0;slider_step=$null;input_width=104;format='0';group='request'},
        [pscustomobject]@{key='stop';help_key='gui_param_help_stop';kind='string';group='request';multiline=$true}
    )
}

function Get-AtaraxiaModelRelativePath([string]$ModelDirectory,[string]$ModelPath) {
    if([string]::IsNullOrWhiteSpace($ModelDirectory) -or [string]::IsNullOrWhiteSpace($ModelPath)){throw 'Model directory and model path are required.'}
    $root=[IO.Path]::GetFullPath($ModelDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $path=[IO.Path]::GetFullPath($ModelPath)
    $prefix=$root+[IO.Path]::DirectorySeparatorChar
    if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'The selected model must be inside the configured model directory.'}
    return $path.Substring($prefix.Length)
}

function Assert-AtaraxiaModelParameterValue {
    param([string]$Key,[object]$Value)
    $definition=@(Get-AtaraxiaModelParameterDefinitions|Where-Object{$_.key -ceq $Key}|Select-Object -First 1)
    if($definition.Count -eq 0){throw "Unknown editable model parameter: $Key"}
    $d=$definition[0]
    if($d.kind -eq 'string'){
        if($Key -eq 'stop'){
            if($Value -isnot [System.Array]){throw "Model parameter 'stop' must be an array of strings."}
            foreach($item in $Value){if($item -isnot [string]){throw "Model parameter 'stop' values must be text."}}
            return ,@($Value)
        }
        if($Value -isnot [string]){throw "Model parameter '$Key' must be text."};return $Value
    }
    $number=0.0
    if(-not [double]::TryParse([string]$Value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -or [double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt $d.min -or $number -gt $d.max){throw "Model parameter '$Key' must be between $($d.min) and $($d.max)."}
    if($d.step -eq 1.0 -and [Math]::Truncate($number) -ne $number){throw "Model parameter '$Key' must be an integer."}
    if($d.step -ne 1.0 -and [Math]::Abs(($number-$d.min)/$d.step-[Math]::Round(($number-$d.min)/$d.step)) -gt 0.000001){throw "Model parameter '$Key' must use increments of $($d.step)."}
    return $number
}

function Get-AtaraxiaModelParameterInputResult([string]$Key,[object]$InputValue) {
    try{$normalized=Assert-AtaraxiaModelParameterValue $Key $InputValue;return [pscustomobject]@{valid=$true;value=$normalized;error=''}}
    catch{return [pscustomobject]@{valid=$false;value=$null;error=$_.Exception.Message}}
}

function Get-AtaraxiaModelParameterStepValue([string]$Key,[object]$CurrentValue,[int]$Direction) {
    if($Direction -notin @(-1,1)){throw 'Model parameter step direction must be -1 or 1.'}
    $definition=@(Get-AtaraxiaModelParameterDefinitions|Where-Object{$_.key -ceq $Key}|Select-Object -First 1)
    if($definition.Count -eq 0 -or $definition[0].kind -ne 'number'){throw "Model parameter '$Key' does not support numeric stepping."}
    $d=$definition[0];$current=Assert-AtaraxiaModelParameterValue $Key $CurrentValue
    $value=[Math]::Max([double]$d.min,[Math]::Min([double]$d.max,([double]$current+([double]$d.step*$Direction))))
    $format=[string]$d.format;$decimalPoint=$format.IndexOf('.')
    $decimalPlaces=if($decimalPoint -ge 0){$format.Length-$decimalPoint-1}else{0}
    $value=[Math]::Round($value,$decimalPlaces,[MidpointRounding]::AwayFromZero)
    return Assert-AtaraxiaModelParameterValue $Key $value
}

function Get-AtaraxiaModelParameterValues([object]$Settings) {
    $values=[ordered]@{}
    $request=$Settings.request_parameters
    foreach($definition in Get-AtaraxiaModelParameterDefinitions){$property=$request.PSObject.Properties[$definition.key];if($null -ne $property){try{$values[$definition.key]=Assert-AtaraxiaModelParameterValue $definition.key $property.Value}catch{}}}
    return [pscustomobject]$values
}

function Set-AtaraxiaModelParameterValues([object]$Settings,[System.Collections.IDictionary]$Values) {
    foreach($key in $Values.Keys){$value=Assert-AtaraxiaModelParameterValue ([string]$key) $Values[$key];$Settings.request_parameters|Add-Member -NotePropertyName ([string]$key) -NotePropertyValue $value -Force}
    return $Settings
}
