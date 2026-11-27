Set-StrictMode -Version Latest

function ConvertFrom-AgentJsonText([string]$Text,[string]$Source='JSON input',[long]$MaximumBytes=4194304) {
    if($null -eq $Text){throw "$Source is empty."}
    if([Text.Encoding]::UTF8.GetByteCount($Text) -gt $MaximumBytes){throw "$Source exceeds the $MaximumBytes byte safety limit."}
    try{[Text.UTF8Encoding]::new($false,$true).GetByteCount($Text)|Out-Null}catch{throw "$Source contains invalid Unicode text."}
    try{return ConvertFrom-Json -InputObject $Text -ErrorAction Stop}catch{throw "$Source is not valid JSON. $($_.Exception.Message)"}
}

function New-AgentJsonFileSystemPort([scriptblock]$ReadBytes=$null,[scriptblock]$WriteBytes=$null,[scriptblock]$GetItem=$null,[scriptblock]$TestLeaf=$null,[scriptblock]$CreateBackup=$null,[scriptblock]$Replace=$null,[scriptblock]$Remove=$null) {
    if($null -eq $ReadBytes){$ReadBytes={param($Path)[IO.File]::ReadAllBytes($Path)}}
    if($null -eq $WriteBytes){$WriteBytes={param($Path,$Bytes)$stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}}}
    if($null -eq $GetItem){$GetItem={param($Path)Get-Item -LiteralPath $Path -Force}}
    if($null -eq $TestLeaf){$TestLeaf={param($Path)Test-Path -LiteralPath $Path -PathType Leaf}}
    if($null -eq $CreateBackup){$CreateBackup={param($Path,$Bytes)$stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}}}
    if($null -eq $Replace){$Replace={param($Temporary,$Destination)[IO.File]::Move($Temporary,$Destination,$true)}}
    if($null -eq $Remove){$Remove={param($Path)if(Test-Path -LiteralPath $Path){Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue}}}
    return [pscustomobject]@{read_bytes=$ReadBytes;write_bytes=$WriteBytes;get_item=$GetItem;test_leaf=$TestLeaf;create_backup=$CreateBackup;replace=$Replace;remove=$Remove}
}

function Read-AgentJsonFile([string]$Path,[long]$MaximumBytes=4194304,[scriptblock]$RepairHandler=$null,[object]$FileSystem=$null) {
    if($null -eq $FileSystem){$FileSystem=New-AgentJsonFileSystemPort}
    if(-not [bool](& $FileSystem.test_leaf $Path)){throw "JSON file was not found: $Path"}
    $info=& $FileSystem.get_item $Path
    if($info.Length -gt $MaximumBytes){throw "JSON file exceeds the $MaximumBytes byte safety limit: $Path"}
    $bytes=[byte[]](& $FileSystem.read_bytes $Path)
    try{$text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)}catch{$text=[Text.Encoding]::UTF8.GetString($bytes)}
    if($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF){$text=$text.Substring(1)}
    $parsed=$null;$parseError=''
    try{$parsed=ConvertFrom-AgentJsonText $text $Path $MaximumBytes;$shape=Test-AgentJsonDocumentShape $Path $parsed;if(-not $shape.valid){$parseError=$shape.reason}}catch{$parseError=$_.Exception.Message}
    if([string]::IsNullOrEmpty($parseError)){return $parsed}else{
        if($RepairHandler -is [scriptblock]){
            $proposal=New-AgentJsonRepairProposal $Path $bytes $MaximumBytes
            if($proposal.kind -eq 'resource'){throw $parseError}
            $result=& $RepairHandler $proposal $FileSystem
            if($null -ne $result -and $result.applied -and [bool](& $FileSystem.test_leaf $Path)){
                $repairedBytes=[byte[]](& $FileSystem.read_bytes $Path);$repairedText=[Text.UTF8Encoding]::new($false,$true).GetString($repairedBytes)
                $repaired=ConvertFrom-AgentJsonText $repairedText $Path $MaximumBytes;$repairedShape=Test-AgentJsonDocumentShape $Path $repaired;if(-not $repairedShape.valid){throw $repairedShape.reason};return $repaired
            }
        }
        throw $parseError
    }
}

$script:AgentJsonRepairKinds=@{}
function Register-AgentJsonRepairKind([string]$Path,[ValidateSet('config','kobold_settings','model_parameter_presets','object')][string]$Kind){$script:AgentJsonRepairKinds[[IO.Path]::GetFullPath($Path)]=$Kind}

function Test-AgentJsonDocumentShape([string]$Path,[object]$Value) {
    $kind=Get-AgentJsonRepairKind $Path
    if($Value -isnot [pscustomobject]){return [pscustomobject]@{valid=$false;reason='JSON document root must be an object.'}}
    if($kind -eq 'model_parameter_presets'){$version=Get-StructuredProperty $Value 'schema_version';$active=Get-StructuredProperty $Value 'active_preset_id';$presets=Get-StructuredProperty $Value 'presets';$overrides=Get-StructuredProperty $Value 'overrides';if(-not $version.exists -or [int]$version.value -ne 1 -or -not $active.exists -or $active.value -isnot [string] -or -not $presets.exists -or $presets.value -isnot [System.Collections.IEnumerable] -or $presets.value -is [string] -or $presets.value -is [System.Collections.IDictionary] -or -not $overrides.exists -or $overrides.value -isnot [System.Collections.IEnumerable] -or $overrides.value -is [string] -or $overrides.value -is [System.Collections.IDictionary]){return [pscustomobject]@{valid=$false;reason='Model parameter preset catalog fields have invalid types.'}};foreach($preset in $presets.value){if($preset -isnot [pscustomobject] -or [string]::IsNullOrWhiteSpace([string]$preset.id) -or $preset.name -isnot [string] -or $preset.request_parameters -isnot [pscustomobject]){return [pscustomobject]@{valid=$false;reason='A personal model preset has invalid fields.'}}};foreach($override in $overrides.value){if($override -isnot [pscustomobject] -or [string]::IsNullOrWhiteSpace([string]$override.id) -or ($null -ne $override.PSObject.Properties['request_parameters'] -and $override.request_parameters -isnot [pscustomobject])){return [pscustomobject]@{valid=$false;reason='A built-in preset override has invalid fields.'}}}}
    if($kind -eq 'conversation'){
        $artifact=Get-StructuredProperty $Value 'artifact_type';$entries=Get-StructuredProperty $Value 'entries'
        if(-not $artifact.exists -or [string]$artifact.value -cne 'conversation'){return [pscustomobject]@{valid=$false;reason='Conversation artifact_type is missing or invalid.'}}
        if(-not $entries.exists -or $entries.value -isnot [System.Collections.IEnumerable] -or $entries.value -is [string] -or $entries.value -is [System.Collections.IDictionary]){return [pscustomobject]@{valid=$false;reason='Conversation entries must be an array.'}}
    }
    if($kind -eq 'session'){$artifact=Get-StructuredProperty $Value 'artifact_type';$id=Get-StructuredProperty $Value 'id';if(-not $artifact.exists -or [string]$artifact.value -cne 'session' -or -not $id.exists -or [string]::IsNullOrWhiteSpace([string]$id.value)){return [pscustomobject]@{valid=$false;reason='Session artifact_type or id is missing or invalid.'}}}
    if($kind -eq 'project'){$artifact=Get-StructuredProperty $Value 'artifact_type';$prompt=Get-StructuredProperty $Value 'common_prompt';if(-not $artifact.exists -or [string]$artifact.value -cne 'project' -or -not $prompt.exists -or $prompt.value -isnot [string]){return [pscustomobject]@{valid=$false;reason='Project metadata structure is incomplete.'}}}
    if($kind -eq 'task'){
        foreach($name in @('name','goal','working_directory')){$property=Get-StructuredProperty $Value $name;if(-not $property.exists -or $property.value -isnot [string]){return [pscustomobject]@{valid=$false;reason="Task $name must be a string."}}}
        $roles=Get-StructuredProperty $Value 'roles';$workflow=Get-StructuredProperty $Value 'workflow';if(-not $roles.exists -or $roles.value -is [string] -or $roles.value -is [System.Collections.IDictionary] -or $roles.value -isnot [System.Collections.IEnumerable] -or @($roles.value).Count -eq 0 -or -not $workflow.exists -or $workflow.value -isnot [pscustomobject]){return [pscustomobject]@{valid=$false;reason='Task roles and workflow are incomplete.'}}
        $stages=Get-StructuredProperty $workflow.value 'stages';$initial=Get-StructuredProperty $workflow.value 'initial_stage';if(-not $stages.exists -or $stages.value -is [string] -or @($stages.value).Count -eq 0 -or -not $initial.exists -or $initial.value -isnot [string]){return [pscustomobject]@{valid=$false;reason='Task workflow stages or initial_stage are incomplete.'}}
    }
    if($kind -eq 'state'){
        if($Value.cycle -isnot [int] -and $Value.cycle -isnot [long]){return [pscustomobject]@{valid=$false;reason='State cycle must be an integer.'}}
        if($Value.phase -isnot [string]){return [pscustomobject]@{valid=$false;reason='State phase must be a string.'}}
        if($Value.history -isnot [System.Collections.IEnumerable] -or $Value.history -is [string]){return [pscustomobject]@{valid=$false;reason='State history must be an array.'}}
        if($Value.results -isnot [pscustomobject]){return [pscustomobject]@{valid=$false;reason='State results must be an object.'}}
    }
    if($kind -eq 'kobold_settings'){
        foreach($name in @('server','paths','request_parameters')){$property=Get-StructuredProperty $Value $name;if(-not $property.exists -or $property.value -isnot [pscustomobject]){return [pscustomobject]@{valid=$false;reason="KoboldCpp $name must be an object."}}}
        $startup=Get-StructuredProperty $Value 'startup_parameters';if(-not $startup.exists -or $startup.value -is [string] -or $startup.value -is [System.Collections.IDictionary] -or $startup.value -isnot [System.Collections.IEnumerable]){return [pscustomobject]@{valid=$false;reason='KoboldCpp startup_parameters must be an array.'}}
    }
    return [pscustomobject]@{valid=$true;reason=''}
}

function Get-AgentJsonRepairKind([string]$Path) {
    $fullPath=[IO.Path]::GetFullPath($Path);if($script:AgentJsonRepairKinds.ContainsKey($fullPath)){return [string]$script:AgentJsonRepairKinds[$fullPath]}
    $leaf=[IO.Path]::GetFileName($Path).ToLowerInvariant()
    if($leaf -in @('config.example.json','role-contracts.json','gui-dialog-contracts.json','agent-harness.json')){return 'resource'}
    if($leaf -eq 'conversation.json' -or $leaf -match '-conversation\.json$'){return 'conversation'}
    if($leaf -eq 'state.json'){return 'state'}
    if($leaf -eq 'run-changes.json'){return 'journal'}
    if($leaf -eq 'session.json'){return 'session'}
    if($leaf -eq 'project.json'){return 'project'}
    if($leaf -match '\.task\.json$'){return 'task'}
    if($leaf -match '(^|-)config(uration)?\.json$'){return 'config'}
    if($leaf -match 'koboldcpp-settings\.json$'){return 'kobold_settings'}
    if($leaf -match '\.json$'){return 'object'}
    return 'unknown'
}

function Get-AgentJsonRepairSeed([string]$Kind,[string]$Path) {
    $root=Split-Path -Parent $PSScriptRoot
    switch($Kind){
        'conversation'{return [pscustomobject][ordered]@{schema_version=1;artifact_type='conversation';entries=@()}}
        'state'{$phase='Core';$directory=Split-Path -Parent $Path;$task=Get-ChildItem -LiteralPath $directory -Filter '*.task.json' -File -ErrorAction SilentlyContinue|Select-Object -First 1;if($null -ne $task){try{$taskValue=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($task.FullName)) -ErrorAction Stop;if(-not [string]::IsNullOrWhiteSpace([string]$taskValue.workflow.initial_stage)){$phase=[string]$taskValue.workflow.initial_stage}}catch{}};return [pscustomobject][ordered]@{cycle=0;phase=$phase;history=@();results=[pscustomobject]@{}}}
        'session'{
            $now=[DateTime]::UtcNow.ToString('o');$directory=Split-Path -Parent $Path;$task=Get-ChildItem -LiteralPath $directory -Filter '*.task.json' -File -ErrorAction SilentlyContinue|Select-Object -First 1
            return [pscustomobject][ordered]@{schema_version=1;artifact_type='session';id=(Split-Path -Leaf $directory);title=(Split-Path -Leaf $directory);title_generated=$false;title_source='recovered';created_at=$now;updated_at=$now;task_file=if($null -ne $task){$task.Name}else{''}}
        }
        'project'{return [pscustomobject][ordered]@{schema_version=1;artifact_type='project';common_prompt=''}}
        'config'{$template=Join-Path (Join-Path $root 'configs') 'config.example.json';if(Test-Path -LiteralPath $template){try{return [IO.File]::ReadAllText($template)|ConvertFrom-Json -ErrorAction Stop}catch{}};return [pscustomobject][ordered]@{api_type='koboldcpp';project_name='Ataraxia';interface_language='Japanese'}}
        'kobold_settings'{$template=Join-Path (Join-Path $root 'configs') 'koboldcpp-settings.json';if(Test-Path -LiteralPath $template){try{return [IO.File]::ReadAllText($template)|ConvertFrom-Json -ErrorAction Stop}catch{}};return [pscustomobject][ordered]@{server=[pscustomobject]@{host='127.0.0.1';port=5001;generate_path='/v1/chat/completions'};paths=[pscustomobject]@{install_directory='runtime/koboldcpp';model_directory='models';model_file='';executable='runtime/koboldcpp/koboldcpp.exe'};request_parameters=[pscustomobject]@{context_size=8192;max_tokens=1024};startup_parameters=@()}}
        'model_parameter_presets'{return [pscustomobject][ordered]@{schema_version=1;active_preset_id='';presets=@();overrides=@()}}
        'task'{return [pscustomobject][ordered]@{name=[IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($Path));goal='';context='';constraints=@();working_directory=(Join-Path (Split-Path -Parent $Path) 'workspace');roles=@();workflow=[pscustomobject][ordered]@{initial_stage='';terminal_state='Complete';stages=@()}}}
        'object'{return [pscustomobject][ordered]@{}}
        default{return $null}
    }
}

function Merge-AgentJsonRepairObjects([object]$Seed,[object]$Recovered) {
    if($Seed -isnot [pscustomobject] -or $Recovered -isnot [pscustomobject]){return $Recovered}
    $merged=[ordered]@{}
    foreach($property in $Seed.PSObject.Properties){$existing=$Recovered.PSObject.Properties[$property.Name];if($null -eq $existing){$merged[$property.Name]=$property.Value}elseif($property.Value -is [pscustomobject] -and $existing.Value -is [pscustomobject]){$merged[$property.Name]=Merge-AgentJsonRepairObjects $property.Value $existing.Value}elseif($property.Value -is [pscustomobject] -and $existing.Value -isnot [pscustomobject]){$merged[$property.Name]=$property.Value}elseif($property.Value -is [System.Collections.IEnumerable] -and $property.Value -isnot [string] -and ($existing.Value -is [string] -or $existing.Value -is [System.Collections.IDictionary])){$merged[$property.Name]=$property.Value}elseif($property.Value -is [string] -and $existing.Value -isnot [string]){$merged[$property.Name]=$property.Value}else{$merged[$property.Name]=$existing.Value}}
    foreach($property in $Recovered.PSObject.Properties){if(-not $merged.Contains($property.Name)){$merged[$property.Name]=$property.Value}}
    return [pscustomobject]$merged
}

function Get-AgentJsonClosingText([string]$Text) {
    $stack=[System.Collections.Generic.List[char]]::new();$quoted=$false;$escaped=$false
    foreach($character in $Text.ToCharArray()){
        if($quoted){if($escaped){$escaped=$false}elseif($character -eq '\'){$escaped=$true}elseif($character -eq '"'){$quoted=$false};continue}
        if($character -eq '"'){$quoted=$true;continue}
        if($character -eq '{'){$stack.Add('}')}
        elseif($character -eq '['){$stack.Add(']')}
        elseif($character -in @('}',']')){if($stack.Count -eq 0 -or $stack[$stack.Count-1] -ne $character){return $null};$stack.RemoveAt($stack.Count-1)}
    }
    $closing='';for($index=$stack.Count-1;$index -ge 0;$index--){$closing+=$stack[$index]};return $closing
}

function Get-AgentJsonRecoverableProperties([string]$Text) {
    $lines=@($Text -split "`r?`n");$starts=[System.Collections.Generic.List[object]]::new()
    for($index=0;$index -lt $lines.Count;$index++){
        $match=[regex]::Match($lines[$index],'^(?<indent> {0,2})"(?<key>(?:\\.|[^"\\])*)"\s*:\s*(?<value>.*)$')
        if($match.Success){try{$key=ConvertFrom-Json -InputObject ('"'+$match.Groups['key'].Value+'"') -ErrorAction Stop}catch{continue};$starts.Add([pscustomobject]@{line=$index;key=[string]$key;value=$match.Groups['value'].Value})}
    }
    $properties=[ordered]@{}
    for($item=0;$item -lt $starts.Count;$item++){
        $start=$starts[$item];$end=if($item+1 -lt $starts.Count){$starts[$item+1].line}else{$lines.Count};$parts=[System.Collections.Generic.List[string]]::new();$parts.Add($start.value)
        for($line=$start.line+1;$line -lt $end;$line++){if($lines[$line] -match '^\s{0,2}[}]\s*,?\s*$'){break};$parts.Add($lines[$line].Trim())}
        $fragment=($parts -join "`n").Trim() -replace ',\s*$','';$closing=Get-AgentJsonClosingText $fragment
        if($null -eq $closing){continue}
        try{$entry=ConvertFrom-Json -InputObject ('{"'+$start.key+'":'+$fragment+$closing+'}') -ErrorAction Stop;$properties[$start.key]=$entry.PSObject.Properties[$start.key].Value}catch{continue}
    }
    return $properties
}

function New-AgentJsonRepairProposal([string]$Path,[byte[]]$OriginalBytes,[long]$MaximumBytes=4194304) {
    $kind=Get-AgentJsonRepairKind $Path;$hash=[BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($OriginalBytes)).Replace('-','').ToLowerInvariant()
    $backupPath=$Path+'.corrupt.'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'.'+[guid]::NewGuid().ToString('N')+'.bak'
    $raw=[Text.Encoding]::UTF8.GetString($OriginalBytes);if($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF){$raw=$raw.Substring(1)}
    $seed=Get-AgentJsonRepairSeed $kind $Path
    if($null -eq $seed -or $kind -eq 'journal'){return [pscustomobject][ordered]@{repairable=$false;kind=$kind;path=$Path;reason='このファイル種別は安全に自動修復できません。原本を保全して手動確認してください。';original_hash=$hash;backup_path='';value=$null;json='';recovered=@();defaulted=@()}}
    $recovered=[ordered]@{}
    try{$parsed=ConvertFrom-Json -InputObject $raw -ErrorAction Stop;if($parsed -is [pscustomobject]){foreach($property in $parsed.PSObject.Properties){$recovered[$property.Name]=$property.Value}}}catch{$recovered=Get-AgentJsonRecoverableProperties $raw}
    $merged=Merge-AgentJsonRepairObjects $seed ([pscustomobject]$recovered);$value=[ordered]@{};foreach($property in $merged.PSObject.Properties){$value[$property.Name]=$property.Value}
    if($kind -eq 'conversation'){
        if($value.artifact_type -ne 'conversation'){$value.artifact_type='conversation'}
        if($value.entries -isnot [System.Collections.IEnumerable] -or $value.entries -is [string] -or $value.entries -is [System.Collections.IDictionary]){$value.entries=@()}
        $value.entries=@($value.entries|Where-Object{$null -ne $_ -and $_ -is [pscustomobject]})
    }
    if($kind -eq 'session'){
        if([string]$value.artifact_type -cne 'session'){$value.artifact_type='session'}
        if([string]::IsNullOrWhiteSpace([string]$value.id)){$value.id=Split-Path -Leaf (Split-Path -Parent $Path)}
    }
    if($kind -eq 'state'){
        if($null -eq $value.history -or $value.history -is [string] -or $value.history -is [System.Collections.IDictionary]){$value.history=@()}
        if($null -eq $value.results -or $value.results -isnot [pscustomobject]){$value.results=[pscustomobject]@{}}
        if($value.cycle -isnot [int] -and $value.cycle -isnot [long]){$value.cycle=0}
    }
    if($kind -eq 'model_parameter_presets'){$value.schema_version=1;if($value.active_preset_id -isnot [string]){$value.active_preset_id=''};if($value.presets -isnot [System.Collections.IEnumerable] -or $value.presets -is [string] -or $value.presets -is [System.Collections.IDictionary]){$value.presets=@()};$value.presets=@($value.presets|Where-Object{$null -ne $_ -and $_ -is [pscustomobject] -and -not [string]::IsNullOrWhiteSpace([string]$_.id) -and $_.name -is [string] -and $_.request_parameters -is [pscustomobject]});if($value.overrides -isnot [System.Collections.IEnumerable] -or $value.overrides -is [string] -or $value.overrides -is [System.Collections.IDictionary]){$value.overrides=@()};$value.overrides=@($value.overrides|Where-Object{$null -ne $_ -and $_ -is [pscustomobject] -and -not [string]::IsNullOrWhiteSpace([string]$_.id) -and ($null -eq $_.PSObject.Properties['request_parameters'] -or $_.request_parameters -is [pscustomobject])})}
    if($kind -eq 'kobold_settings'){$settingsSeed=Get-AgentJsonRepairSeed 'kobold_settings' $Path;$mergedSettings=Merge-AgentJsonRepairObjects $settingsSeed ([pscustomobject]$value);$value=[ordered]@{};foreach($property in $mergedSettings.PSObject.Properties){$value[$property.Name]=$property.Value}}
    $json=ConvertTo-Json -InputObject ([pscustomobject]$value) -Depth 100
    $defaulted=[System.Collections.Generic.List[string]]::new();foreach($seedProperty in $seed.PSObject.Properties){if(-not $recovered.Contains($seedProperty.Name)){$defaulted.Add($seedProperty.Name)}}
    $validation=''
    try{$null=ConvertFrom-AgentJsonText $json $Path $MaximumBytes;$candidate=ConvertFrom-Json -InputObject $json -ErrorAction Stop;$shape=Test-AgentJsonDocumentShape $Path $candidate;if(-not $shape.valid){throw $shape.reason}}catch{$validation=$_.Exception.Message}
    return [pscustomobject][ordered]@{repairable=[string]::IsNullOrEmpty($validation);kind=$kind;path=$Path;reason=$validation;original_hash=$hash;backup_path=$backupPath;value=[pscustomobject]$value;json=$json;recovered=@($recovered.Keys);defaulted=@($defaulted)}
}

function Invoke-AgentJsonRepairProposal([object]$Proposal,[string]$Path,[scriptblock]$Confirm,[object]$FileSystem=$null) {
    if($null -eq $Proposal -or -not $Proposal.repairable){return [pscustomobject]@{applied=$false;reason='unrepairable';backup_path=''}}
    if($Confirm -isnot [scriptblock]){throw 'JSON repair approval callback is required.'}
    if($null -eq $FileSystem){$FileSystem=New-AgentJsonFileSystemPort}
    if(-not [bool](& $FileSystem.test_leaf $Path)){throw "JSON file changed or disappeared before repair: $Path"}
    $fileItem=& $FileSystem.get_item $Path;if(($fileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'JSON repair refuses to replace a reparse-point file.'}
    $current=[byte[]](& $FileSystem.read_bytes $Path);$currentHash=[BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($current)).Replace('-','').ToLowerInvariant()
    if($currentHash -cne $Proposal.original_hash){throw 'JSON file changed after the repair proposal was prepared; reload before repairing.'}
    if(-not [bool](& $Confirm $Proposal)){return [pscustomobject]@{applied=$false;reason='declined';backup_path=''}}
    $current=[byte[]](& $FileSystem.read_bytes $Path);$currentHash=[BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($current)).Replace('-','').ToLowerInvariant()
    if($currentHash -cne $Proposal.original_hash){throw 'JSON file changed while repair approval was pending; reload before repairing.'}
    $backup=[string]$Proposal.backup_path;if([string]::IsNullOrWhiteSpace($backup)){throw 'JSON repair proposal has no backup destination.'};$temporary=$Path+'.repair.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        & $FileSystem.create_backup $backup $current
        $saved=[byte[]](& $FileSystem.read_bytes $backup);$savedHash=[BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($saved)).Replace('-','').ToLowerInvariant();if($savedHash -cne $Proposal.original_hash){throw 'JSON repair backup verification failed.'}
        $candidateBytes=[Text.UTF8Encoding]::new($false).GetBytes([string]$Proposal.json);& $FileSystem.write_bytes $temporary $candidateBytes;$candidate=[Text.UTF8Encoding]::new($false,$true).GetString([byte[]](& $FileSystem.read_bytes $temporary));$null=ConvertFrom-AgentJsonText $candidate $Path
        $parsed=ConvertFrom-Json -InputObject $candidate -ErrorAction Stop;$shape=Test-AgentJsonDocumentShape $Path $parsed;if(-not $shape.valid){throw $shape.reason}
        $finalBytes=[byte[]](& $FileSystem.read_bytes $Path);$finalHash=[BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($finalBytes)).Replace('-','').ToLowerInvariant();if($finalHash -cne $Proposal.original_hash){throw 'JSON file changed during repair staging; the original was preserved.'}
        & $FileSystem.replace $temporary $Path
        return [pscustomobject]@{applied=$true;reason='';backup_path=$backup}
    }finally{& $FileSystem.remove $temporary}
}

function New-AgentHttpUri([string]$BaseUri,[string]$Path='') {
    $base=$null
    if(-not [uri]::TryCreate($BaseUri,[UriKind]::Absolute,[ref]$base) -or $base.Scheme -notin @('http','https') -or [string]::IsNullOrWhiteSpace($base.Host) -or -not [string]::IsNullOrEmpty($base.UserInfo) -or -not [string]::IsNullOrEmpty($base.Query) -or -not [string]::IsNullOrEmpty($base.Fragment)){throw 'API server must be an absolute HTTP(S) URI without credentials, query, or fragment.'}
    if([string]::IsNullOrEmpty($Path)){return $base}
    if($Path -notmatch '^/[A-Za-z0-9._~!$&''()*+,;=:@%/-]*$' -or $Path -match '(^|/)\.\.(/|$)'){throw 'API endpoint path contains unsupported characters or traversal segments.'}
    return [uri]::new($base,$Path)
}

function Assert-AgentPlainText([string]$Value,[string]$Name,[int]$MaximumLength=0,[switch]$AllowMultiline) {
    if($null -eq $Value){throw "$Name must be text."}
    if($MaximumLength -gt 0 -and $Value.Length -gt $MaximumLength){throw "$Name exceeds the $MaximumLength character limit."}
    $forbidden=if($AllowMultiline){'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'}else{'[\x00-\x1F\x7F]'}
    if($Value -match $forbidden){throw "$Name contains unsupported control characters."}
    try{[Text.UTF8Encoding]::new($false,$true).GetByteCount($Value)|Out-Null}catch{throw "$Name contains invalid Unicode text."}
}

function Get-StructuredProperty([object]$Value, [string]$Name) {
    if ([string]::IsNullOrEmpty($Name)) { return [pscustomobject]@{ exists=$false; value=$null } }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return [pscustomobject]@{ exists=$true; value=$Value[$Name] } }
        return [pscustomobject]@{ exists=$false; value=$null }
    }
    if ($null -eq $Value) { return [pscustomobject]@{ exists=$false; value=$null } }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) { return [pscustomobject]@{ exists=$false; value=$null } }
    return [pscustomobject]@{ exists=$true; value=$property.Value }
}

function Assert-JsonSchema([object]$Result, [object]$Schema, [string]$Path = '$') {
    if([regex]::Matches($Path,'\.').Count -gt 64){throw (Get-AppText 'result_schema_violation' @($Path,'maximum nesting depth exceeded'))}
    if ($null -eq $Schema) { throw (Get-AppText 'result_schema_violation' @($Path, 'schema is missing')) }
    $anyOfProperty = Get-StructuredProperty $Schema 'anyOf'
    if ($anyOfProperty.exists) {
        foreach ($candidateSchema in @($anyOfProperty.value)) {
            try { Assert-JsonSchema $Result $candidateSchema $Path; return } catch { }
        }
        throw (Get-AppText 'result_schema_violation' @($Path, 'value does not match any allowed schema'))
    }
    $schemaTypeProperty = Get-StructuredProperty $Schema 'type'
    if (-not $schemaTypeProperty.exists) { throw (Get-AppText 'result_schema_violation' @($Path, 'schema type is missing')) }
    $schemaType = [string]$schemaTypeProperty.value
    $validType = switch ($schemaType) {
        'object' { $Result -is [System.Management.Automation.PSCustomObject] -or $Result -is [System.Collections.IDictionary] }
        'array' { $Result -is [System.Collections.IEnumerable] -and $Result -isnot [string] -and $Result -isnot [System.Collections.IDictionary] }
        'string' { $Result -is [string] }
        'boolean' { $Result -is [bool] }
        'integer' { $Result -is [byte] -or $Result -is [int16] -or $Result -is [int] -or $Result -is [long] -or $Result -is [System.Numerics.BigInteger] }
        'number' { $Result -is [byte] -or $Result -is [int16] -or $Result -is [int] -or $Result -is [long] -or $Result -is [single] -or $Result -is [double] -or $Result -is [decimal] }
        'null' { $null -eq $Result }
        default { throw (Get-AppText 'result_schema_violation' @($Path, "unsupported schema type '$schemaType'")) }
    }
    if (-not $validType) { throw (Get-AppText 'result_schema_violation' @($Path, "expected $schemaType")) }
    if($schemaType -eq 'string'){
        if($Result -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'){throw (Get-AppText 'result_schema_violation' @($Path,'unsupported control character'))}
        if($Result.Length -gt 1048576){throw (Get-AppText 'result_schema_violation' @($Path,'string exceeds the 1 MiB character safety limit'))}
        $minimum=Get-StructuredProperty $Schema 'minLength';$maximum=Get-StructuredProperty $Schema 'maxLength'
        if($minimum.exists -and $Result.Length -lt [int]$minimum.value){throw (Get-AppText 'result_schema_violation' @($Path,'string is shorter than minLength'))}
        if($maximum.exists -and $Result.Length -gt [int]$maximum.value){throw (Get-AppText 'result_schema_violation' @($Path,'string exceeds maxLength'))}
        $pattern=Get-StructuredProperty $Schema 'pattern';if($pattern.exists){try{$matches=[regex]::IsMatch($Result,[string]$pattern.value,[Text.RegularExpressions.RegexOptions]::CultureInvariant,[TimeSpan]::FromSeconds(1))}catch{throw (Get-AppText 'result_schema_violation' @($Path,'invalid schema pattern'))};if(-not $matches){throw (Get-AppText 'result_schema_violation' @($Path,'string does not match pattern'))}}
        try{[Text.UTF8Encoding]::new($false,$true).GetByteCount($Result)|Out-Null}catch{throw (Get-AppText 'result_schema_violation' @($Path,'invalid Unicode text'))}
    }
    $enumProperty = Get-StructuredProperty $Schema 'enum'
    if ($enumProperty.exists) {
        $found = $false
        foreach ($allowedValue in $enumProperty.value) {
            if ($Result -is [bool] -and $allowedValue -is [bool]) { if ($Result -eq $allowedValue) { $found = $true; break } }
            elseif ([string]$Result -ceq [string]$allowedValue) { $found = $true; break }
        }
        if (-not $found) { throw (Get-AppText 'result_schema_violation' @($Path, 'value is not in enum')) }
    }
    if ($schemaType -eq 'object') {
        $maxProperties=Get-StructuredProperty $Schema 'maxProperties';$objectPropertyCount=if($Result -is [System.Collections.IDictionary]){@($Result.Keys).Count}else{@($Result.PSObject.Properties).Count};if($maxProperties.exists -and $objectPropertyCount -gt [int]$maxProperties.value){throw (Get-AppText 'result_schema_violation' @($Path,'object exceeds maxProperties'))}
        $requiredProperty = Get-StructuredProperty $Schema 'required'
        if ($requiredProperty.exists) {
            foreach ($requiredName in @($requiredProperty.value)) {
                $requiredValue = Get-StructuredProperty $Result ([string]$requiredName)
                if (-not $requiredValue.exists) { throw (Get-AppText 'result_schema_violation' @("$Path.$requiredName", 'required property is missing')) }
            }
        }
        $propertyNames = if ($Result -is [System.Collections.IDictionary]) { @($Result.Keys | ForEach-Object { [string]$_ }) } else { @($Result.PSObject.Properties | ForEach-Object { $_.Name }) }
        $schemaPropertiesProperty = Get-StructuredProperty $Schema 'properties'
        $schemaProperties = if ($schemaPropertiesProperty.exists) { $schemaPropertiesProperty.value } else { [pscustomobject]@{} }
        foreach ($propertyName in $propertyNames) {
            $definition = Get-StructuredProperty $schemaProperties $propertyName
            if (-not $definition.exists) {
                $additionalProperties = Get-StructuredProperty $Schema 'additionalProperties'
                if ($additionalProperties.exists -and $additionalProperties.value -eq $false) { throw (Get-AppText 'result_schema_violation' @("$Path.$propertyName", 'additional property is not allowed')) }
                continue
            }
            $propertyValue = Get-StructuredProperty $Result $propertyName
            Assert-JsonSchema $propertyValue.value $definition.value "$Path.$propertyName"
        }
    } elseif ($schemaType -eq 'array') {
        $minimum=Get-StructuredProperty $Schema 'minItems';$maximum=Get-StructuredProperty $Schema 'maxItems'
        if($minimum.exists -and @($Result).Count -lt [int]$minimum.value){throw (Get-AppText 'result_schema_violation' @($Path,'array is shorter than minItems'))}
        if($maximum.exists -and @($Result).Count -gt [int]$maximum.value){throw (Get-AppText 'result_schema_violation' @($Path,'array exceeds maxItems'))}
        $itemsProperty = Get-StructuredProperty $Schema 'items'
        if ($itemsProperty.exists) {
            $index = 0
            foreach ($item in $Result) { Assert-JsonSchema $item $itemsProperty.value "$Path`[$index`]"; $index++ }
        }
    } elseif ($schemaType -in @('integer','number')) {
        $minimum=Get-StructuredProperty $Schema 'minimum';$maximum=Get-StructuredProperty $Schema 'maximum'
        if($minimum.exists -and [double]$Result -lt [double]$minimum.value){throw (Get-AppText 'result_schema_violation' @($Path,'number is below minimum'))}
        if($maximum.exists -and [double]$Result -gt [double]$maximum.value){throw (Get-AppText 'result_schema_violation' @($Path,'number exceeds maximum'))}
    }
}
