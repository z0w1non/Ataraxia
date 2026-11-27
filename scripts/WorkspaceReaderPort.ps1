Set-StrictMode -Version Latest

function New-AgentWorkspacePathDependencies([scriptblock]$TestPath,[scriptblock]$ResolvePath,[scriptblock]$GetPathInfo) {
    foreach($adapter in @($TestPath,$ResolvePath,$GetPathInfo)){if($adapter -isnot [scriptblock]){throw 'Workspace path existence, resolution, and metadata adapters are required.'}}
    return [pscustomobject]@{test_path=$TestPath;resolve_path=$ResolvePath;get_path_info=$GetPathInfo}
}

function Test-AgentWorkspacePath([object]$Dependencies,[string]$Path,[string]$Type='Any') {
    if($null -eq $Dependencies -or $Dependencies.test_path -isnot [scriptblock]){throw 'Workspace path existence port is not configured.'}
    return [bool](& $Dependencies.test_path $Path $Type)
}

function Resolve-AgentWorkspaceExistingPath([object]$Dependencies,[string]$Path) {
    if($null -eq $Dependencies -or $Dependencies.resolve_path -isnot [scriptblock]){throw 'Workspace path resolution port is not configured.'}
    $resolved=[string](& $Dependencies.resolve_path $Path)
    if(-not [IO.Path]::IsPathRooted($resolved)){throw 'Workspace path resolver must return an absolute path.'}
    return [IO.Path]::GetFullPath($resolved)
}

function Get-AgentWorkspacePathInfo([object]$Dependencies,[string]$Path) {
    if($null -eq $Dependencies -or $Dependencies.get_path_info -isnot [scriptblock]){throw 'Workspace path metadata port is not configured.'}
    $info=& $Dependencies.get_path_info $Path
    foreach($field in @('is_directory','is_reparse_point')){if($null -eq $info.PSObject.Properties[$field] -or $info.$field -isnot [bool]){throw "Workspace path metadata must include Boolean '$field'."}}
    return $info
}

function New-AgentWorkspaceReaderDependencies([scriptblock]$ListDirectory,[scriptblock]$ReadBytes,[scriptblock]$HashFile,[object]$PathDependencies=$null) {
    if($ListDirectory -isnot [scriptblock] -or $ReadBytes -isnot [scriptblock]){throw 'Workspace reader directory and byte adapters are required.'}
    if($null -ne $HashFile -and $HashFile -isnot [scriptblock]){throw 'Workspace reader hash adapter must be a script block when provided.'}
    if($null -eq $HashFile){$readAdapter=$ReadBytes;$HashFile={param($Path)$bytes=& $readAdapter $Path; $sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}finally{$sha.Dispose()}}.GetNewClosure()}
    if($null -eq $PathDependencies){$test={param($Path,$Type='Any')(Test-Path -LiteralPath $Path -PathType $Type)}.GetNewClosure();$resolve={param($Path)(Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path}.GetNewClosure();$info={param($Path)$item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop;[pscustomobject]@{is_directory=[bool]$item.PSIsContainer;is_reparse_point=(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)}}.GetNewClosure();$PathDependencies=New-AgentWorkspacePathDependencies $test $resolve $info}
    if($null -eq $PathDependencies.PSObject.Properties['test_path'] -or $null -eq $PathDependencies.PSObject.Properties['resolve_path'] -or $null -eq $PathDependencies.PSObject.Properties['get_path_info']){throw 'Workspace reader requires a complete path dependency.'}
    return [pscustomobject]@{list_directory=$ListDirectory;read_bytes=$ReadBytes;hash_file=$HashFile;path_dependencies=$PathDependencies}
}

function Get-AgentWorkspaceDirectoryEntries([object]$Dependencies,[string]$DirectoryPath) {
    if($null -eq $Dependencies -or $Dependencies.list_directory -isnot [scriptblock]){throw 'Workspace directory listing port is not configured.'}
    if(-not [IO.Path]::IsPathRooted($DirectoryPath)){throw 'Workspace directory port requires an absolute path.'}
    $entries=@(& $Dependencies.list_directory $DirectoryPath)
    $entries=@($entries)
    foreach($entry in $entries){
        foreach($name in @('full_path','name','extension','is_directory','is_reparse_point','length')){if($null -eq $entry.PSObject.Properties[$name]){throw "Workspace directory entry is missing '$name'."}}
        if($entry.full_path -isnot [string] -or -not [IO.Path]::IsPathRooted([string]$entry.full_path) -or $entry.name -isnot [string] -or $entry.extension -isnot [string] -or $entry.is_directory -isnot [bool] -or $entry.is_reparse_point -isnot [bool] -or ($entry.length -isnot [int] -and $entry.length -isnot [long] -and $entry.length -isnot [short]) -or [long]$entry.length -lt 0){throw 'Workspace directory entry does not satisfy the reader contract.'}
    }
    return ,@($entries)
}

function Read-AgentWorkspaceBytes([object]$Dependencies,[string]$Path) {
    if($null -eq $Dependencies -or $Dependencies.read_bytes -isnot [scriptblock]){throw 'Workspace byte reader port is not configured.'}
    if(-not [IO.Path]::IsPathRooted($Path)){throw 'Workspace byte reader requires an absolute path.'}
    $bytes=& $Dependencies.read_bytes $Path
    if($bytes -isnot [byte[]]){throw 'Workspace byte reader must return a byte array.'}
    return ,$bytes
}

function Get-AgentWorkspaceFileHash([object]$Dependencies,[string]$Path) {
    if($null -eq $Dependencies -or $Dependencies.hash_file -isnot [scriptblock]){throw 'Workspace file hash port is not configured.'}
    if(-not [IO.Path]::IsPathRooted($Path)){throw 'Workspace file hash port requires an absolute path.'}
    $hash=[string](& $Dependencies.hash_file $Path)
    if($hash -notmatch '^[0-9a-fA-F]{64}$'){throw 'Workspace file hash adapter must return a SHA-256 hexadecimal digest.'}
    return $hash.ToLowerInvariant()
}

function New-AgentWorkspaceFileSystemDependencies {
    . (Join-Path $PSScriptRoot 'WorkspaceFileSystem.ps1')
    $list={param($Path)Get-AtaraxiaWorkspaceDirectoryEntries $Path}.GetNewClosure()
    $read={param($Path)Read-AtaraxiaWorkspaceFileBytes $Path}.GetNewClosure()
    $hash={param($Path)Get-AtaraxiaWorkspaceFileHash $Path}.GetNewClosure()
    $test={param($Path,$Type='Any')(Test-Path -LiteralPath $Path -PathType $Type)}.GetNewClosure()
    $resolve={param($Path)(Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path}.GetNewClosure()
    $info={param($Path)$item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop;[pscustomobject]@{is_directory=[bool]$item.PSIsContainer;is_reparse_point=(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)}}.GetNewClosure()
    $pathDependencies=New-AgentWorkspacePathDependencies $test $resolve $info
    return New-AgentWorkspaceReaderDependencies -ListDirectory $list -ReadBytes $read -HashFile $hash -PathDependencies $pathDependencies
}
