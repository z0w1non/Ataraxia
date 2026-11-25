[CmdletBinding()]
param([string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Ataraxia.exe'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$null = Add-Type -AssemblyName System.Drawing
$compilerCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compiler = @($compilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
if ($compiler.Count -eq 0) { throw 'The Windows .NET Framework C# compiler was not found.' }
$sourcePath = Join-Path $projectRoot 'launcher/AtaraxiaLauncher.cs'
$iconPngPath = Join-Path $projectRoot 'assets/branding/ataraxia-app-icon.png'
$iconPath = Join-Path $projectRoot 'assets/branding/ataraxia-app-icon.ico'
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
if (-not (Test-Path -LiteralPath $iconPngPath -PathType Leaf)) { throw "Launcher icon image was not found: $iconPngPath" }
$sourceImage = [Drawing.Bitmap]::new($iconPngPath)
$iconPayloads = [System.Collections.Generic.List[object]]::new()
try {
    foreach ($size in @(16,24,32,48,64,128,256)) {
        $bitmap = [Drawing.Bitmap]::new($size,$size,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([Drawing.Color]::Transparent)
            $graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.PixelOffsetMode=[Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.DrawImage($sourceImage,0,0,$size,$size)
            $memory=[IO.MemoryStream]::new()
            try{$bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png);$iconPayloads.Add([pscustomobject]@{size=$size;bytes=$memory.ToArray()})}finally{$memory.Dispose()}
        } finally {$graphics.Dispose();$bitmap.Dispose()}
    }
    $iconStream=[IO.File]::Create($iconPath);$writer=[IO.BinaryWriter]::new($iconStream)
    try {
        $writer.Write([UInt16]0);$writer.Write([UInt16]1);$writer.Write([UInt16]$iconPayloads.Count)
        $offset=6+(16*$iconPayloads.Count)
        foreach($image in $iconPayloads){$dimension=if($image.size -eq 256){[byte]0}else{[byte]$image.size};$writer.Write($dimension);$writer.Write($dimension);$writer.Write([byte]0);$writer.Write([byte]0);$writer.Write([UInt16]1);$writer.Write([UInt16]32);$writer.Write([UInt32]$image.bytes.Length);$writer.Write([UInt32]$offset);$offset+=$image.bytes.Length}
        foreach($image in $iconPayloads){$writer.Write([byte[]]$image.bytes)}
    } finally {$writer.Dispose();$iconStream.Dispose()}
} finally {$sourceImage.Dispose()}
& $compiler[0] /nologo /target:winexe "/out:$resolvedOutput" "/win32icon:$iconPath" /reference:System.Windows.Forms.dll $sourcePath
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $resolvedOutput -PathType Leaf)) { throw 'Ataraxia launcher compilation failed.' }
Write-Output "Launcher built: $resolvedOutput"
Write-Output "Icon built: $iconPath"
