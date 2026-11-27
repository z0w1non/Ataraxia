Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'StructuredData.ps1')
. (Join-Path $PSScriptRoot 'JsonFileStore.ps1')

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

function Get-AtaraxiaProjectNames([string]$ProjectsRoot,[object]$Dependencies=$null) {
    if (-not (Test-AtaraxiaStorePath $ProjectsRoot 'Container' $Dependencies)) { return @() }
    return @(Get-AtaraxiaStoreDirectories $ProjectsRoot $Dependencies | Where-Object {
        $_.Name -match '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' -and ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
    } | Select-Object -ExpandProperty Name | Sort-Object)
}

function New-AtaraxiaProject([string]$ProjectsRoot,[string]$Name,[object]$Dependencies=$null) {
    $path=Get-AtaraxiaProjectPath $ProjectsRoot $Name
    if (Test-AtaraxiaStorePath $path 'Any' $Dependencies) { throw (Get-AppText 'project_already_exists' @($Name)) }
    Ensure-AtaraxiaJsonStoreDirectory $path $Dependencies
    return $path
}

function Rename-AtaraxiaProject([string]$ProjectsRoot,[string]$OldName,[string]$NewName,[object]$Dependencies=$null) {
    $source=Get-AtaraxiaProjectPath $ProjectsRoot $OldName
    $target=Get-AtaraxiaProjectPath $ProjectsRoot $NewName
    if (-not (Test-AtaraxiaStorePath $source 'Container' $Dependencies)) { throw (Get-AppText 'project_not_found' @($OldName)) }
    $sourceItem=Get-AtaraxiaStoreItem $source $Dependencies
    if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw (Get-AppText 'project_link_unsupported') }
    if (Test-AtaraxiaStorePath $target 'Any' $Dependencies) { throw (Get-AppText 'project_already_exists' @($NewName)) }
    Move-AtaraxiaStorePath $source $target $Dependencies
    return $target
}

function Set-AtaraxiaActiveProject([string]$ConfigPath,[string]$ProjectsRoot,[string]$Name,[object]$Dependencies=$null) {
    $projectPath=Get-AtaraxiaProjectPath $ProjectsRoot $Name
    $fileStore=if($null -ne $Dependencies -and $null -ne $Dependencies.PSObject.Properties['file_store']){$Dependencies.file_store}else{$Dependencies}
    if (-not (Test-AtaraxiaStorePath $projectPath 'Container' $fileStore)) { throw (Get-AppText 'project_not_found' @($Name)) }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw (Get-AppText 'config_file_missing' @($ConfigPath)) }
    $config=Read-AtaraxiaJsonStoreFile $ConfigPath $Dependencies
    $config | Add-Member -NotePropertyName project_name -NotePropertyValue $Name -Force
    Write-AtaraxiaJsonStoreFile $ConfigPath $config $Dependencies 50
    return $projectPath
}
