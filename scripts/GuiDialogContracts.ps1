Set-StrictMode -Version Latest

function New-AtaraxiaDialogContract {
    param(
        [Parameter(Mandatory)][object]$Definitions,
        [Parameter(Mandatory)][string]$Kind,
        [string]$Title,
        [string]$Message='',
        [string]$Value='',
        [string]$Icon='',
        [string]$PrimaryLabel='',
        [string]$SecondaryLabel=''
    )
    if($Definitions.schema_version -ne 1 -or [string]::IsNullOrWhiteSpace([string]$Definitions.contract_id)){throw 'GUI dialog contract definition is invalid.'}
    $definitionProperty=$Definitions.kinds.PSObject.Properties[$Kind]
    if($null -eq $definitionProperty){throw "Unsupported dialog contract kind: $Kind"}
    $definition=$definitionProperty.Value
    if([string]::IsNullOrWhiteSpace($Icon)){$Icon=[string]$definition.default_icon}
    return [pscustomobject][ordered]@{
        contract_id=[string]$Definitions.contract_id
        schema_version=[int]$Definitions.schema_version
        kind=$Kind
        title=$Title
        message=$Message
        value=$Value
        icon=$Icon
        primary_label=$PrimaryLabel
        secondary_label=$SecondaryLabel
        inputs=@($definition.inputs)
        outputs=@($definition.outputs)
        actions=@($definition.actions)
    }
}

function Invoke-AtaraxiaDialogContract([object]$Contract,[scriptblock]$Renderer) {
    if($null -eq $Contract -or [string]::IsNullOrWhiteSpace([string]$Contract.contract_id) -or [int]$Contract.schema_version -ne 1){throw 'Dialog contract is invalid.'}
    if($Contract.kind -notin @('message','confirm','input','multiline','file_picker','folder_picker')){throw "Unsupported dialog contract kind: $($Contract.kind)"}
    if($Renderer -isnot [scriptblock]){throw 'Dialog renderer adapter must be provided.'}
    $raw=& $Renderer $Contract
    return ConvertTo-AtaraxiaDialogContractResult $Contract $raw
}

function ConvertTo-AtaraxiaDialogContractResult([object]$Contract,[object]$raw) {
    if($null -eq $Contract -or [string]::IsNullOrWhiteSpace([string]$Contract.contract_id) -or [int]$Contract.schema_version -ne 1){throw 'Dialog contract is invalid.'}
    if($Contract.kind -notin @('message','confirm','input','multiline','file_picker','folder_picker')){throw "Unsupported dialog contract kind: $($Contract.kind)"}
    $outputs=[ordered]@{}
    switch([string]$Contract.kind){
        'confirm' {if($null -ne $raw -and $raw -isnot [bool]){throw 'Confirm dialog renderer must return a boolean or null.'};$outputs.confirmed=[bool]$raw}
        {$_ -in @('input','multiline')} {if($null -ne $raw -and $raw -isnot [string]){throw 'Input dialog renderer must return text or null.'};$outputs.value=if($null -eq $raw){''}else{[string]$raw};$outputs.cancelled=($null -eq $raw)}
        {$_ -in @('file_picker','folder_picker')} {if($null -ne $raw -and $raw -isnot [string]){throw 'Path dialog renderer must return a path or null.'};$outputs.path=if($null -eq $raw){''}else{[string]$raw};$outputs.cancelled=($null -eq $raw)}
        'message' {}
    }
    $declaredOutputs=@($Contract.outputs)
    foreach($name in $declaredOutputs){if(-not $outputs.Contains([string]$name)){throw "Dialog renderer did not produce the declared output: $name"}}
    foreach($name in $outputs.Keys){if($name -notin $declaredOutputs){throw "Dialog renderer produced an undeclared output: $name"}}
    return [pscustomobject][ordered]@{contract_id=[string]$Contract.contract_id;schema_version=[int]$Contract.schema_version;kind=[string]$Contract.kind;outputs=[pscustomobject]$outputs}
}

function Resolve-AtaraxiaDialogAction([object]$Contract,[string]$Action,[string]$Value='') {
    if($null -eq $Contract -or [string]::IsNullOrWhiteSpace([string]$Contract.kind)){throw 'Dialog action requires a valid contract.'}
    if($Action -notin @($Contract.actions)){throw "Dialog action is not declared for $($Contract.kind): $Action"}
    $outputs=[ordered]@{};$completed=$true
    switch([string]$Contract.kind){
        'message' {}
        'confirm' {$outputs.confirmed=($Action -eq 'primary')}
        {$_ -in @('input','multiline')} {$outputs.value=if($Action -eq 'confirm'){$Value}else{''};$outputs.cancelled=($Action -ne 'confirm')}
        {$_ -in @('file_picker','folder_picker')} {
            $completed=($Action -ne 'navigate' -and ($Action -eq 'cancel' -or -not [string]::IsNullOrWhiteSpace($Value)))
            $outputs.path=if($Action -eq 'cancel'){''}else{$Value};$outputs.cancelled=($Action -eq 'cancel')
        }
    }
    return [pscustomobject][ordered]@{contract_id=[string]$Contract.contract_id;kind=[string]$Contract.kind;action=$Action;completed=$completed;outputs=[pscustomobject]$outputs}
}
