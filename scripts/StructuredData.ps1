Set-StrictMode -Version Latest

function ConvertFrom-AgentJsonText([string]$Text,[string]$Source='JSON input',[long]$MaximumBytes=4194304) {
    if($null -eq $Text){throw "$Source is empty."}
    if([Text.Encoding]::UTF8.GetByteCount($Text) -gt $MaximumBytes){throw "$Source exceeds the $MaximumBytes byte safety limit."}
    try{[Text.UTF8Encoding]::new($false,$true).GetByteCount($Text)|Out-Null}catch{throw "$Source contains invalid Unicode text."}
    try{return ConvertFrom-Json -InputObject $Text -ErrorAction Stop}catch{throw "$Source is not valid JSON. $($_.Exception.Message)"}
}

function Read-AgentJsonFile([string]$Path,[long]$MaximumBytes=4194304) {
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "JSON file was not found: $Path"}
    $info=Get-Item -LiteralPath $Path -Force
    if($info.Length -gt $MaximumBytes){throw "JSON file exceeds the $MaximumBytes byte safety limit: $Path"}
    try{$text=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($Path))}catch{throw "JSON file is not valid UTF-8: $Path"}
    if($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF){$text=$text.Substring(1)}
    return ConvertFrom-AgentJsonText $text $Path $MaximumBytes
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
