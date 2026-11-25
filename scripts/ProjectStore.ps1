Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'StructuredData.ps1')

function Assert-AtaraxiaProjectName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { throw (Get-AppText 'project_name_invalid') }
}

function Get-AtaraxiaProjectPath([string]$ProjectsRoot,[string]$Name) {
    Assert-AtaraxiaProjectName $Name
    $root=[IO.Path]::GetFullPath($ProjectsRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $path=[IO.Path]::GetFullPath((Join-Path $root $Name))
    if (-not $path.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw (Get-AppText 'project_path_outside_root') }
    return $path
}

function Get-AtaraxiaProjectNames([string]$ProjectsRoot) {
    if (-not (Test-Path -LiteralPath $ProjectsRoot -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $ProjectsRoot -Directory -Force | Where-Object {
        $_.Name -match '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' -and ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
    } | Select-Object -ExpandProperty Name | Sort-Object)
}

function New-AtaraxiaProject([string]$ProjectsRoot,[string]$Name) {
    $path=Get-AtaraxiaProjectPath $ProjectsRoot $Name
    if (Test-Path -LiteralPath $path) { throw (Get-AppText 'project_already_exists' @($Name)) }
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

function Rename-AtaraxiaProject([string]$ProjectsRoot,[string]$OldName,[string]$NewName) {
    $source=Get-AtaraxiaProjectPath $ProjectsRoot $OldName
    $target=Get-AtaraxiaProjectPath $ProjectsRoot $NewName
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw (Get-AppText 'project_not_found' @($OldName)) }
    $sourceItem=Get-Item -LiteralPath $source -Force
    if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw (Get-AppText 'project_link_unsupported') }
    if (Test-Path -LiteralPath $target) { throw (Get-AppText 'project_already_exists' @($NewName)) }
    Move-Item -LiteralPath $source -Destination $target
    return $target
}

function Set-AtaraxiaActiveProject([string]$ConfigPath,[string]$ProjectsRoot,[string]$Name) {
    $projectPath=Get-AtaraxiaProjectPath $ProjectsRoot $Name
    if (-not (Test-Path -LiteralPath $projectPath -PathType Container)) { throw (Get-AppText 'project_not_found' @($Name)) }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw (Get-AppText 'config_file_missing' @($ConfigPath)) }
    $config=Read-AgentJsonFile $ConfigPath
    $config | Add-Member -NotePropertyName project_name -NotePropertyValue $Name -Force
    $temporaryPath="$ConfigPath.tmp"
    $json=$config | ConvertTo-Json -Depth 50
    [IO.File]::WriteAllText($temporaryPath,$json,[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $ConfigPath -Force
    return $projectPath
}
