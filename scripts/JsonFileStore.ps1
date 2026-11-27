Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'StructuredData.ps1')

function New-AtaraxiaJsonFileStoreDependencies([scriptblock]$ReadJson=$null,[scriptblock]$WriteJson=$null,[scriptblock]$TestFile=$null,[scriptblock]$EnsureDirectory=$null,[scriptblock]$TestPath=$null,[scriptblock]$ListDirectories=$null,[scriptblock]$GetItem=$null,[scriptblock]$MovePath=$null) {
    if($null -eq $TestFile){$TestFile={param($Path)(Test-Path -LiteralPath $Path -PathType Leaf)}.GetNewClosure()}
    if($null -eq $TestPath){$TestPath={param($Path,$Type='Any')(Test-Path -LiteralPath $Path -PathType $Type)}.GetNewClosure()}
    if($null -eq $EnsureDirectory){$EnsureDirectory={param($Path)New-Item -ItemType Directory -Force -Path $Path|Out-Null}.GetNewClosure()}
    if($null -eq $ListDirectories){$ListDirectories={param($Path)@(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue)}.GetNewClosure()}
    if($null -eq $GetItem){$GetItem={param($Path)Get-Item -LiteralPath $Path -Force -ErrorAction Stop}.GetNewClosure()}
    if($null -eq $MovePath){$MovePath={param($Source,$Destination,$Force)if($Force){Move-Item -LiteralPath $Source -Destination $Destination -Force}else{Move-Item -LiteralPath $Source -Destination $Destination}}.GetNewClosure()}
    return [pscustomobject]@{read_json=$ReadJson;write_json=$WriteJson;test_file=$TestFile;test_path=$TestPath;ensure_directory=$EnsureDirectory;list_directories=$ListDirectories;get_item=$GetItem;move_path=$MovePath}
}

function Test-AtaraxiaStorePath([string]$Path,[string]$Type='Any',[object]$Dependencies=$null) { if($null -ne $Dependencies -and $Dependencies -isnot [scriptblock] -and $null -ne $Dependencies.PSObject.Properties['test_path'] -and $Dependencies.test_path -is [scriptblock]){return [bool](& $Dependencies.test_path $Path $Type)};return Test-Path -LiteralPath $Path -PathType $Type }
function Get-AtaraxiaStoreDirectories([string]$Path,[object]$Dependencies=$null) { if($null -ne $Dependencies -and $Dependencies -isnot [scriptblock] -and $null -ne $Dependencies.PSObject.Properties['list_directories'] -and $Dependencies.list_directories -is [scriptblock]){return @(& $Dependencies.list_directories $Path)};return @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue) }
function Get-AtaraxiaStoreItem([string]$Path,[object]$Dependencies=$null) { if($null -ne $Dependencies -and $null -ne $Dependencies.PSObject.Properties['get_item'] -and $Dependencies.get_item -is [scriptblock]){return & $Dependencies.get_item $Path};return Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
function Move-AtaraxiaStorePath([string]$Source,[string]$Destination,[object]$Dependencies=$null,[switch]$Force) { if($null -ne $Dependencies -and $null -ne $Dependencies.PSObject.Properties['move_path'] -and $Dependencies.move_path -is [scriptblock]){& $Dependencies.move_path $Source $Destination ([bool]$Force);return};if($Force){Move-Item -LiteralPath $Source -Destination $Destination -Force}else{Move-Item -LiteralPath $Source -Destination $Destination} }

function Read-AtaraxiaJsonStoreFile([string]$Path,[object]$Dependencies=$null,[long]$MaximumBytes=4194304,[scriptblock]$RepairHandler=$null) {
    if($Dependencies -is [scriptblock]){return & $Dependencies $Path $MaximumBytes}
    if($null -ne $Dependencies -and $Dependencies.read_json -is [scriptblock]){return & $Dependencies.read_json $Path $MaximumBytes}
    return Read-AgentJsonFile $Path $MaximumBytes $RepairHandler
}

function Write-AtaraxiaJsonStoreFile([string]$Path,[object]$Value,[object]$Dependencies=$null,[int]$Depth=50) {
    if($null -ne $Dependencies -and $Dependencies.write_json -is [scriptblock]){& $Dependencies.write_json $Path $Value $Depth|Out-Null;return}
    $directory=Split-Path -Parent $Path
    if(-not [string]::IsNullOrWhiteSpace($directory) -and -not(Test-Path -LiteralPath $directory -PathType Container)){
        if($null -ne $Dependencies -and $Dependencies.ensure_directory -is [scriptblock]){& $Dependencies.ensure_directory $directory|Out-Null}else{New-Item -ItemType Directory -Force -Path $directory|Out-Null}
    }
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    $backup=$Path+'.'+[guid]::NewGuid().ToString('N')+'.bak'
    try{
        $json=ConvertTo-Json -InputObject $Value -Depth $Depth
        [IO.File]::WriteAllText($temporary,$json,[Text.UTF8Encoding]::new($false))
        $null=ConvertFrom-AgentJsonText ([IO.File]::ReadAllText($temporary,[Text.UTF8Encoding]::new($false,$true))) $temporary
        if(Test-Path -LiteralPath $Path -PathType Leaf){[IO.File]::Replace($temporary,$Path,$backup);if(Test-Path -LiteralPath $backup){Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue}}else{[IO.File]::Move($temporary,$Path)}
    }finally{foreach($stagingPath in @($temporary,$backup)){if(Test-Path -LiteralPath $stagingPath){Remove-Item -LiteralPath $stagingPath -Force -ErrorAction SilentlyContinue}}}
}

function Test-AtaraxiaStoreFile([string]$Path,[object]$Dependencies=$null) {
    if($null -ne $Dependencies -and $Dependencies.test_file -is [scriptblock]){return [bool](& $Dependencies.test_file $Path)}
    return Test-Path -LiteralPath $Path -PathType Leaf
}

function Test-AtaraxiaJsonStoreFile([string]$Path,[object]$Dependencies=$null) { return Test-AtaraxiaStoreFile $Path $Dependencies }

function Ensure-AtaraxiaJsonStoreDirectory([string]$Path,[object]$Dependencies=$null) {
    if($null -ne $Dependencies -and $Dependencies.ensure_directory -is [scriptblock]){& $Dependencies.ensure_directory $Path|Out-Null;return}
    New-Item -ItemType Directory -Force -Path $Path|Out-Null
}
