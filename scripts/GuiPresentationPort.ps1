Set-StrictMode -Version Latest

function New-AtaraxiaGuiViewPort([scriptblock]$SetItems,[scriptblock]$SetValue,[scriptblock]$BindAction,[scriptblock]$ScheduleCallback,[scriptblock]$StartTimer,[scriptblock]$StopTimer,[scriptblock]$WaitDelay,[scriptblock]$RegisterTarget,[scriptblock]$SetClipboardText,[scriptblock]$InvokeViewOperation) {
    if($SetItems -isnot [scriptblock] -or $SetValue -isnot [scriptblock] -or $BindAction -isnot [scriptblock] -or $ScheduleCallback -isnot [scriptblock] -or $StartTimer -isnot [scriptblock] -or $StopTimer -isnot [scriptblock] -or $WaitDelay -isnot [scriptblock] -or $RegisterTarget -isnot [scriptblock] -or $SetClipboardText -isnot [scriptblock] -or $InvokeViewOperation -isnot [scriptblock]){throw 'GUI view port requires item, value, action, clipboard, view operation, target, scheduling, timer, and delay adapters.'}
    return [pscustomobject]@{set_items=$SetItems;set_value=$SetValue;bind_action=$BindAction;register_target=$RegisterTarget;set_clipboard_text=$SetClipboardText;invoke_view_operation=$InvokeViewOperation;schedule_callback=$ScheduleCallback;start_timer=$StartTimer;stop_timer=$StopTimer;wait_delay=$WaitDelay}
}

function Register-AtaraxiaGuiViewTarget([object]$Port,[string]$Target,[object]$Handle) {
    if($null -eq $Port -or $Port.register_target -isnot [scriptblock]){throw 'GUI view target adapter is not configured.'}
    if([string]::IsNullOrWhiteSpace($Target) -or $null -eq $Handle){throw 'GUI view target requires a key and a non-null view handle.'}
    $null=& $Port.register_target $Target $Handle
}

function Set-AtaraxiaGuiViewItems([object]$Port,[string]$Target,[object[]]$Items) {
    if($null -eq $Port -or $Port.set_items -isnot [scriptblock]){throw 'GUI view item adapter is not configured.'}
    $null=& $Port.set_items $Target @($Items)
}

function Set-AtaraxiaGuiViewValue([object]$Port,[string]$Target,[object]$Value) {
    if($null -eq $Port -or $Port.set_value -isnot [scriptblock]){throw 'GUI view value adapter is not configured.'}
    $null=& $Port.set_value $Target $Value
}

function Set-AtaraxiaGuiClipboardText([object]$Port,[AllowEmptyString()][string]$Text) {
    if($null -eq $Port -or $Port.set_clipboard_text -isnot [scriptblock]){throw 'GUI clipboard adapter is not configured.'}
    $null=& $Port.set_clipboard_text $Text
}

function Invoke-AtaraxiaGuiViewOperation([object]$Port,[ValidateSet('activate_window','focus','scroll_to_end','scroll_to_top','set_text_focus_end','toggle_expanded','open_context_menu','sync_scroll_to_latest_visibility','update_multiline_input_height')][string]$Operation,[string]$Target,[object]$Value) {
    if($null -eq $Port -or $Port.invoke_view_operation -isnot [scriptblock]){throw 'GUI view operation adapter is not configured.'}
    if([string]::IsNullOrWhiteSpace($Target)){throw 'GUI view operation requires a target.'}
    if($Operation -eq 'set_text_focus_end' -and $Value -isnot [string]){throw 'Setting focused input text requires a string value.'}
    if($Operation -eq 'sync_scroll_to_latest_visibility' -and $Value -isnot [string]){throw 'Scroll affordance synchronization requires a scroll target.'}
    $null=& $Port.invoke_view_operation $Operation $Target $Value
}

function Register-AtaraxiaGuiViewAction([object]$Port,[string]$Target,[ValidateSet('activate','selection_change','text_change','size_change','value_change','lost_focus','expanded_change','scroll','close','content_ready','submit')][string]$Action,[scriptblock]$Handler) {
    if($null -eq $Port -or $Port.bind_action -isnot [scriptblock]){throw 'GUI view action adapter is not configured.'}
    if($Handler -isnot [scriptblock]){throw 'GUI view action handler must be a script block.'}
    $null=& $Port.bind_action $Target $Action $Handler
}

function Schedule-AtaraxiaGuiViewCallback([object]$Port,[ValidateSet('normal','layout_idle')][string]$Priority,[scriptblock]$Callback) {
    if($null -eq $Port -or $Port.schedule_callback -isnot [scriptblock]){throw 'GUI view scheduler is not configured.'}
    if($Callback -isnot [scriptblock]){throw 'GUI view callback must be a script block.'}
    $null=& $Port.schedule_callback $Priority $Callback
}

function Start-AtaraxiaGuiViewTimer([object]$Port,[int]$IntervalMilliseconds,[scriptblock]$Callback) {
    if($null -eq $Port -or $Port.start_timer -isnot [scriptblock]){throw 'GUI view timer adapter is not configured.'}
    if($IntervalMilliseconds -lt 1){throw 'GUI view timer interval must be positive.'}
    if($Callback -isnot [scriptblock]){throw 'GUI view timer callback must be a script block.'}
    return & $Port.start_timer $IntervalMilliseconds $Callback
}

function Stop-AtaraxiaGuiViewTimer([object]$Port,[object]$Handle) {
    if($null -eq $Port -or $Port.stop_timer -isnot [scriptblock]){throw 'GUI view timer adapter is not configured.'}
    if($null -eq $Handle){return}
    $null=& $Port.stop_timer $Handle
}

function Wait-AtaraxiaGuiViewDelay([object]$Port,[int]$Milliseconds) {
    if($null -eq $Port -or $Port.wait_delay -isnot [scriptblock]){throw 'GUI view delay adapter is not configured.'}
    if($Milliseconds -lt 0){throw 'GUI view delay cannot be negative.'}
    if($Milliseconds -eq 0){return}
    $null=& $Port.wait_delay $Milliseconds
}
