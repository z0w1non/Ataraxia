Set-StrictMode -Version Latest

function Test-AtaraxiaDialogDirectory([string]$Path) {
    if([string]::IsNullOrWhiteSpace($Path)){return $false}
    return Test-Path -LiteralPath $Path -PathType Container
}

function Resolve-AtaraxiaDialogDirectory([string]$Path,[string]$InvalidPathMessage='Dialog directory is invalid.') {
    try{$fullPath=[IO.Path]::GetFullPath($Path)}catch{throw $InvalidPathMessage}
    if(-not (Test-AtaraxiaDialogDirectory $fullPath)){throw $InvalidPathMessage}
    return $fullPath
}

function Get-AtaraxiaDialogPathEntries([string]$Directory,[ValidateSet('file','folder')][string]$Kind,[string[]]$Patterns=@('*')) {
    $fullDirectory=Resolve-AtaraxiaDialogDirectory $Directory
    $entries=Get-ChildItem -LiteralPath $fullDirectory -Force -ErrorAction Stop | Where-Object {
        if($_.PSIsContainer){return $true}
        if($Kind -eq 'folder'){return $false}
        foreach($pattern in $Patterns){if($_.Name -like $pattern){return $true}}
        return $false
    } | Sort-Object @{Expression={if($_.PSIsContainer){0}else{1}}},Name
    return @($entries)
}
