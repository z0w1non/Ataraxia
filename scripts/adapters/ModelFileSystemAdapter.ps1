Set-StrictMode -Version Latest

function New-AtaraxiaModelFileSystemDependencies([scriptblock]$ListDirectory=$null) {
    if($null -eq $ListDirectory){$ListDirectory={param($Path)@(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)}.GetNewClosure()}
    if($ListDirectory -isnot [scriptblock]){throw 'Model file directory listing adapter must be a script block.'}
    return [pscustomobject]@{list_directory=$ListDirectory}
}

function Get-AtaraxiaModelFiles([string]$Directory,[object]$Dependencies) {
    if($null -eq $Dependencies -or $Dependencies.list_directory -isnot [scriptblock]){throw 'Model file directory listing adapter is not configured.'}
    if(-not (Test-Path -LiteralPath $Directory -PathType Container)){return @()}
    $root=[IO.Path]::GetFullPath($Directory).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $pending=[System.Collections.Generic.Stack[string]]::new();$pending.Push($root);$models=[System.Collections.Generic.List[object]]::new()
    while($pending.Count -gt 0){
        $current=$pending.Pop()
        foreach($entry in @(& $Dependencies.list_directory $current)){
            if(($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){continue}
            if($entry.PSIsContainer){$pending.Push([string]$entry.FullName);continue}
            if([string]$entry.Extension -ine '.gguf'){continue}
            $fullPath=[IO.Path]::GetFullPath([string]$entry.FullName)
            if(-not $fullPath.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){continue}
            $relative=$fullPath.Substring($root.Length).TrimStart([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
            $models.Add([pscustomobject][ordered]@{name=$relative;path=$fullPath})
        }
    }
    return @($models|Sort-Object name)
}
