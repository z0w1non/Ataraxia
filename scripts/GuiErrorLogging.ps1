Set-StrictMode -Version Latest

function New-AtaraxiaGuiErrorLogDependencies([scriptblock]$AppendText=$null) {
    if($null -eq $AppendText){
        $AppendText={param($Path,$Contents)$directory=Split-Path -Parent $Path;if(-not [string]::IsNullOrWhiteSpace($directory)){[IO.Directory]::CreateDirectory($directory)|Out-Null};[IO.File]::AppendAllText($Path,$Contents,[Text.UTF8Encoding]::new($false))}.GetNewClosure()
    }
    if($AppendText -isnot [scriptblock]){throw 'GUI error log writer must be a script block.'}
    return [pscustomobject]@{append_text=$AppendText}
}

function Get-AtaraxiaGuiErrorLogPath([string]$Path='') {
    if(-not [string]::IsNullOrWhiteSpace($Path)){return [IO.Path]::GetFullPath($Path)}
    $configured=[Environment]::GetEnvironmentVariable('ATARAXIA_ERROR_LOG_PATH')
    if(-not [string]::IsNullOrWhiteSpace($configured)){return [IO.Path]::GetFullPath($configured)}
    $root=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if([string]::IsNullOrWhiteSpace($root)){$root=[IO.Path]::GetTempPath()}
    $file='gui-error-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'-'+[guid]::NewGuid().ToString('N')+'.log'
    return Join-Path (Join-Path $root 'Ataraxia/logs') $file
}

function Format-AtaraxiaGuiErrorLogEntry([object]$ErrorRecord,[string]$Context) {
    $exception=if($ErrorRecord -is [Management.Automation.ErrorRecord]){$ErrorRecord.Exception}else{$ErrorRecord}
    $details=if($null -ne $exception -and $null -ne $exception.PSObject.Methods['ToString']){$exception.ToString()}else{[string]$ErrorRecord}
    $lines=[System.Collections.Generic.List[string]]::new()
    $lines.Add('=== Ataraxia GUI error ===');$lines.Add('Timestamp (UTC): '+[DateTime]::UtcNow.ToString('o'));$lines.Add('Context: '+$Context);$lines.Add('PowerShell: '+$PSVersionTable.PSVersion.ToString());$lines.Add('Exception:');$lines.Add($details)
    if($ErrorRecord -is [Management.Automation.ErrorRecord]){
        if(-not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.InvocationInfo.PositionMessage)){$lines.Add('Invocation:');$lines.Add([string]$ErrorRecord.InvocationInfo.PositionMessage)}
        if(-not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.ScriptStackTrace)){$lines.Add('Script stack trace:');$lines.Add([string]$ErrorRecord.ScriptStackTrace)}
        $lines.Add('Category: '+[string]$ErrorRecord.CategoryInfo);$lines.Add('Error ID: '+[string]$ErrorRecord.FullyQualifiedErrorId)
    }
    $lines.Add('=== End error ===');return ($lines -join [Environment]::NewLine)+[Environment]::NewLine+[Environment]::NewLine
}

function Write-AtaraxiaGuiErrorLog([object]$ErrorRecord,[string]$Context='GUI',[string]$Path='',[object]$Dependencies=$null) {
    if($null -eq $ErrorRecord){throw 'GUI error log requires an error record or exception.'}
    if($null -eq $Dependencies){$Dependencies=New-AtaraxiaGuiErrorLogDependencies}
    if($null -eq $Dependencies.append_text -or $Dependencies.append_text -isnot [scriptblock]){throw 'GUI error log append adapter is not configured.'}
    $resolvedPath=Get-AtaraxiaGuiErrorLogPath $Path;$contents=Format-AtaraxiaGuiErrorLogEntry $ErrorRecord $Context
    try{& $Dependencies.append_text $resolvedPath $contents;return [pscustomobject]@{written=$true;path=$resolvedPath;error=''}}catch{$writeError=$_.Exception.Message}
    if(-not [string]::IsNullOrWhiteSpace($Path)){return [pscustomobject]@{written=$false;path=$resolvedPath;error=$writeError}}
    $fallbackRoot=[IO.Path]::GetTempPath();$fallbackName='gui-error-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'-'+[guid]::NewGuid().ToString('N')+'.log';$fallbackPath=Join-Path (Join-Path $fallbackRoot 'Ataraxia/logs') $fallbackName
    try{& $Dependencies.append_text $fallbackPath $contents;$env:ATARAXIA_ERROR_LOG_PATH=$fallbackPath;return [pscustomobject]@{written=$true;path=$fallbackPath;error=''}}catch{return [pscustomobject]@{written=$false;path=$fallbackPath;error=($writeError+'; '+$_.Exception.Message)}}
}
