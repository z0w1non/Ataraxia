Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'WorkspaceFileStorePort.ps1')
. (Join-Path $PSScriptRoot 'WorkspaceReaderPort.ps1')

function New-AgentWorkspaceFileStoreDependencies {
    $test={param($Path)(Test-Path -LiteralPath $Path -PathType Leaf)}.GetNewClosure()
    $length={param($Path)(Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Length}.GetNewClosure()
    $read={param($Path)$bytes=[IO.File]::ReadAllBytes($Path);return ,$bytes}.GetNewClosure()
    $write={param($Path,$Bytes)[IO.File]::WriteAllBytes($Path,$Bytes)}.GetNewClosure()
    $delete={param($Path)Remove-Item -LiteralPath $Path -Force -ErrorAction Stop}.GetNewClosure()
    $ensure={param($Path)New-Item -ItemType Directory -Force -Path $Path|Out-Null}.GetNewClosure()
    $move={param($Source,$Destination,$Force)if($Force){Move-Item -LiteralPath $Source -Destination $Destination -Force}else{[IO.File]::Move($Source,$Destination)}}.GetNewClosure()
    $replace={param($Source,$Destination,$Backup)[IO.File]::Replace($Source,$Destination,$Backup)}.GetNewClosure()
    $pathDependencies=(New-AgentWorkspaceFileSystemDependencies).path_dependencies
    return New-AgentWorkspaceMutationDependencies -TestFile $test -GetLength $length -ReadBytes $read -WriteBytes $write -DeleteFile $delete -EnsureDirectory $ensure -MoveFile $move -ReplaceFile $replace -PathDependencies $pathDependencies
}
