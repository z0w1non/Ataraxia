Set-StrictMode -Version Latest

function Get-AtaraxiaGuiInputHeight([int]$LineCount,[double]$FontSize,[double]$VerticalPadding,[double]$MinimumHeight,[double]$MaximumHeight) {
    foreach($value in @($FontSize,$VerticalPadding,$MinimumHeight,$MaximumHeight)){if([double]::IsNaN($value) -or [double]::IsInfinity($value)){throw 'Input height values must be finite.'}}
    if($VerticalPadding -lt 0){throw 'Input vertical padding cannot be negative.'}
    if($MinimumHeight -le 0 -or $MaximumHeight -lt $MinimumHeight){throw 'Input height bounds are invalid.'}
    $lineHeight=if($FontSize -gt 0){$FontSize*1.45}else{20}
    $desired=[Math]::Ceiling([Math]::Max(1,$LineCount)*$lineHeight+$VerticalPadding+2)
    return [double][Math]::Min($MaximumHeight,[Math]::Max($MinimumHeight,$desired))
}
