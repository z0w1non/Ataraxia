Set-StrictMode -Version Latest

function Get-AtaraxiaWorkspaceDirectoryEntries([string]$DirectoryPath) {
    $entries=[System.Collections.Generic.List[object]]::new()
    foreach($item in Get-ChildItem -LiteralPath $DirectoryPath -Force -ErrorAction Stop){
        $entries.Add([pscustomobject][ordered]@{full_path=[string]$item.FullName;name=[string]$item.Name;extension=[string]$item.Extension;is_directory=[bool]$item.PSIsContainer;is_reparse_point=(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0);length=if($item.PSIsContainer){[long]0}else{[long]$item.Length}})
    }
    return @($entries)
}

function Read-AtaraxiaWorkspaceFileBytes([string]$Path) {
    return ,([IO.File]::ReadAllBytes($Path))
}

function Get-AtaraxiaWorkspaceFileHash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}
