Set-StrictMode -Version Latest

function Get-ArtifactTextLines([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return ,@() }
    return @($Text -split "`r`n|`n|`r")
}

function Get-ArtifactTextHash([string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function New-TextPatch([string]$Before, [string]$After) {
    $beforeLines = @(Get-ArtifactTextLines $Before)
    $afterLines = @(Get-ArtifactTextLines $After)
    $prefix = 0
    while ($prefix -lt $beforeLines.Count -and $prefix -lt $afterLines.Count -and $beforeLines[$prefix] -ceq $afterLines[$prefix]) { $prefix++ }
    $suffix = 0
    while ($suffix -lt ($beforeLines.Count - $prefix) -and $suffix -lt ($afterLines.Count - $prefix) -and $beforeLines[$beforeLines.Count - 1 - $suffix] -ceq $afterLines[$afterLines.Count - 1 - $suffix]) { $suffix++ }
    $operations = @()
    if ($prefix -gt 0) { $operations += [pscustomobject][ordered]@{ op='retain'; count=$prefix } }
    $deleteCount = $beforeLines.Count - $prefix - $suffix
    if ($deleteCount -gt 0) { $operations += [pscustomobject][ordered]@{ op='delete'; lines=[string[]]@($beforeLines[$prefix..($prefix + $deleteCount - 1)]) } }
    $insertCount = $afterLines.Count - $prefix - $suffix
    if ($insertCount -gt 0) { $operations += [pscustomobject][ordered]@{ op='insert'; lines=[string[]]@($afterLines[$prefix..($prefix + $insertCount - 1)]) } }
    if ($suffix -gt 0) { $operations += [pscustomobject][ordered]@{ op='retain'; count=$suffix } }
    return [pscustomobject][ordered]@{ schema_version=1; base_hash=(Get-ArtifactTextHash $Before); result_hash=(Get-ArtifactTextHash $After); base_line_count=$beforeLines.Count; result_line_count=$afterLines.Count; operations=@($operations) }
}

function Apply-TextPatch([string]$Before, [object]$Patch) {
    if ((Get-ArtifactTextHash $Before) -cne [string]$Patch.base_hash) { throw 'Patch base hash does not match.' }
    $source = @(Get-ArtifactTextLines $Before)
    if ($source.Count -ne [int]$Patch.base_line_count) { throw 'Patch base line count does not match.' }
    $result = [System.Collections.Generic.List[string]]::new()
    $cursor = 0
    foreach ($operation in @($Patch.operations)) {
        switch ([string]$operation.op) {
            'retain' {
                $count = [int]$operation.count
                if ($count -lt 0 -or $cursor + $count -gt $source.Count) { throw 'Invalid retain operation.' }
                for ($index = 0; $index -lt $count; $index++) { $result.Add($source[$cursor++]) }
            }
            'delete' {
                $lines = @($operation.lines)
                foreach ($line in $lines) {
                    if ($cursor -ge $source.Count -or $source[$cursor] -cne [string]$line) { throw 'Delete operation does not match base text.' }
                    $cursor++
                }
            }
            'insert' { foreach ($line in @($operation.lines)) { $result.Add([string]$line) } }
            default { throw "Unknown patch operation: $($operation.op)" }
        }
    }
    if ($cursor -ne $source.Count) { throw 'Patch did not consume the complete base text.' }
    $text = $result -join "`r`n"
    if ($result.Count -ne [int]$Patch.result_line_count -or (Get-ArtifactTextHash $text) -cne [string]$Patch.result_hash) { throw 'Patch result verification failed.' }
    return $text
}
