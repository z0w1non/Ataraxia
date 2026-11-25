Set-StrictMode -Version Latest

function Resolve-RoleContractSchema([object]$Contracts, [object]$ReferenceOrSchema) {
    if ($ReferenceOrSchema -is [string]) {
        $definition = $Contracts.schemas.PSObject.Properties[[string]$ReferenceOrSchema]
        if ($null -eq $definition) { throw "Role contract schema reference is undefined: $ReferenceOrSchema" }
        return $definition.Value
    }
    if ($null -eq $ReferenceOrSchema) { throw 'Role contract schema is missing.' }
    return $ReferenceOrSchema
}

function Assert-RoleMessageStructure([object]$Role, [string]$RoleId, [string]$Path) {
    $structureProperty = $Role.PSObject.Properties['message_structure']
    if ($null -eq $structureProperty -or $null -eq $structureProperty.Value.roles) { throw "Role '$RoleId' is missing message_structure.roles: $Path" }
    $messageRoles = @($structureProperty.Value.roles)
    if ($messageRoles -notcontains 'system' -or $messageRoles -notcontains 'user' -or @($messageRoles | Where-Object { $_ -notin @('system','user','assistant','developer') }).Count -gt 0) { throw "Role '$RoleId' has an invalid message structure: $Path" }
}

function Import-RoleContracts([object]$Config, [string]$ConfigPath = '') {
    $configuredProperty = if ($null -ne $Config.PSObject.Properties['role_contracts_path']) { [string]$Config.role_contracts_path } else { '' }
    if ([string]::IsNullOrWhiteSpace($configuredProperty)) { $path = [IO.Path]::GetFullPath((Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'configs') 'role-contracts.json')) }
    else {
        $baseDirectory = if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath)) } else { Join-Path (Split-Path -Parent $PSScriptRoot) 'configs' }
        $path = if ([IO.Path]::IsPathRooted($configuredProperty)) { [IO.Path]::GetFullPath($configuredProperty) } else { [IO.Path]::GetFullPath((Join-Path $baseDirectory $configuredProperty)) }
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Role contracts file does not exist: $path" }
    try { $contracts = Read-AgentJsonFile $path } catch { throw "Role contracts JSON is invalid: $path. $($_.Exception.Message)" }
    if ($null -eq $contracts.schemas -or $null -eq $contracts.generic_agent.roles) { throw "Role contracts file is incomplete: $path" }
    foreach ($role in @($contracts.generic_agent.roles)) {
        Assert-RoleMessageStructure $role ([string]$role.id) $path
        foreach ($direction in @('input','output')) {
            $reference = $role.PSObject.Properties["${direction}_schema_ref"]
            if ($null -eq $reference) { throw "Agent role '$($role.id)' is missing ${direction}_schema_ref: $path" }
            $schema = Resolve-RoleContractSchema $contracts $reference.Value
            if ([string]$schema.type -ne 'object') { throw "Agent role '$($role.id)' ${direction} schema must be an object: $path" }
        }
    }
    $contracts | Add-Member -NotePropertyName source_path -NotePropertyValue $path -Force
    return $contracts
}
