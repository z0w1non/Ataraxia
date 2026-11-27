Set-StrictMode -Version Latest

function Invoke-AtaraxiaGuiDialog([object]$Contract,[scriptblock]$Renderer) {
    $result=Invoke-AtaraxiaDialogContract $Contract $Renderer
    return ConvertTo-AtaraxiaGuiDialogResult $Contract $result
}

function ConvertTo-AtaraxiaGuiDialogResult([object]$Contract,[object]$result) {
    switch([string]$Contract.kind){
        'confirm' {return [bool]$result.outputs.confirmed}
        {$_ -in @('input','multiline')} {if($result.outputs.cancelled){return $null};return [string]$result.outputs.value}
        {$_ -in @('file_picker','folder_picker')} {if($result.outputs.cancelled){return $null};return [string]$result.outputs.path}
        default {return $null}
    }
}

function New-AtaraxiaGuiDialogService([object]$Definitions,[scriptblock]$CreateContract,[scriptblock]$ResolveResult,[scriptblock]$TextResolver,[scriptblock]$Renderer,[scriptblock]$PathPicker) {
    if($null -eq $Definitions){throw 'Dialog definitions are required.'}
    foreach($dependency in @($CreateContract,$ResolveResult,$TextResolver,$Renderer,$PathPicker)){if($dependency -isnot [scriptblock]){throw 'Dialog contract, result, text, renderer, and path picker adapters must be explicit.'}}
    return [pscustomobject][ordered]@{definitions=$Definitions;create_contract=$CreateContract;resolve_result=$ResolveResult;text_resolver=$TextResolver;renderer=$Renderer;path_picker=$PathPicker}
}

function Invoke-AtaraxiaGuiDialogService([object]$Service,[ValidateSet('message','input','multiline','project_name','common_prompt','path_picker')][string]$Operation,[object[]]$Arguments) {
    if($null -eq $Service){throw 'Dialog service is required.'}
    $create=$Service.create_contract;$text=$Service.text_resolver;$resolve=$Service.resolve_result
    switch($Operation){
        'message' {
            $Title=[string]$Arguments[0];$Kind=[string]$Arguments[1];$Message=[string]$Arguments[2];$Confirm=[bool]$Arguments[3];$PrimaryLabel=[string]$Arguments[4];$SecondaryLabel=[string]$Arguments[5]
            if([string]::IsNullOrWhiteSpace($Title)){$Title=& $text 'gui_title'}
            $icon=switch($Kind){'warning'{'dialog-warning'}'error'{'dialog-error'}'question'{'dialog-question'}default{'dialog-info'}};$kindName=if($Confirm){'confirm'}else{'message'}
            if($Confirm){if([string]::IsNullOrWhiteSpace($PrimaryLabel)){$PrimaryLabel=& $text 'gui_yes'};if([string]::IsNullOrWhiteSpace($SecondaryLabel)){$SecondaryLabel=& $text 'gui_no'}}else{if([string]::IsNullOrWhiteSpace($PrimaryLabel)){$PrimaryLabel=& $text 'gui_ok'};if($Kind -eq 'error'){$SecondaryLabel=& $text 'gui_copy_error'}elseif([string]::IsNullOrWhiteSpace($SecondaryLabel)){$SecondaryLabel=& $text 'gui_cancel'}}
            $contract=& $create $Service.definitions $kindName $Title $Message '' $icon $PrimaryLabel $SecondaryLabel
            $raw=& $Service.renderer $contract
            $normalized=ConvertTo-AtaraxiaDialogContractResult $contract $raw
            return & $resolve $contract $normalized
        }
        {$_ -in @('input','multiline','project_name','common_prompt')} {
            $kind=if($Operation -in @('multiline','common_prompt')){'multiline'}else{'input'};$Title=[string]$Arguments[0];$InitialValue=if($Arguments.Count -gt 1){[string]$Arguments[1]}else{''};$Message=if($Arguments.Count -gt 2){[string]$Arguments[2]}else{''}
            $contract=& $create $Service.definitions $kind $Title $Message $InitialValue $(if($kind -eq 'input'){'dialog-input'}else{'dialog-text'}) (& $text 'gui_confirm') (& $text 'gui_cancel')
            $raw=& $Service.renderer $contract
            $normalized=ConvertTo-AtaraxiaDialogContractResult $contract $raw
            return & $resolve $contract $normalized
        }
        'path_picker' {
            $Kind=[string]$Arguments[0];$Title=[string]$Arguments[1];$InitialDirectory=[string]$Arguments[2];$Patterns=[string[]]$Arguments[3]
            $folder=($Kind -eq 'folder');$contractKind=if($folder){'folder_picker'}else{'file_picker'};$icon=if($folder){'dialog-folder'}else{'dialog-file'};$primary=if($folder){& $text 'gui_choose_folder'}else{& $text 'gui_open_file'}
            $contract=& $create $Service.definitions $contractKind $Title '' '' $icon $primary (& $text 'gui_cancel')
            $raw=& $Service.path_picker $contract $InitialDirectory $Patterns
            $normalized=ConvertTo-AtaraxiaDialogContractResult $contract $raw
            return & $resolve $contract $normalized
        }
    }
}
