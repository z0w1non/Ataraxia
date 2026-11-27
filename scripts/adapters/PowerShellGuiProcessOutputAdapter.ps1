function New-AtaraxiaGuiProcessOutputPaths {
    $stdout=Join-Path ([IO.Path]::GetTempPath()) ('ataraxia-agent-'+[guid]::NewGuid().ToString('N')+'.out')
    return [pscustomobject][ordered]@{stdout=$stdout;stderr=$stdout+'.err'}
}

function Read-AtaraxiaGuiProcessOutput {
    param([string]$StdoutPath,[string]$StderrPath,[int]$StartIndex=0)
    $lines=@()
    if(Test-Path -LiteralPath $StdoutPath){$lines=@(Get-Content -LiteralPath $StdoutPath -ErrorAction SilentlyContinue)}
    $safeStart=[Math]::Max(0,[Math]::Min($StartIndex,$lines.Count))
    $newLines=@($lines | Select-Object -Skip $safeStart)
    $errorText=''
    if(Test-Path -LiteralPath $StderrPath){$errorText=Get-Content -LiteralPath $StderrPath -Raw -ErrorAction SilentlyContinue}
    return [pscustomobject][ordered]@{lines=$newLines;next_index=$lines.Count;error_text=[string]$errorText}
}

function Remove-AtaraxiaGuiProcessOutputFiles {
    param([string]$StdoutPath,[string]$StderrPath)
    foreach($file in @($StdoutPath,$StderrPath)){
        if(-not [string]::IsNullOrWhiteSpace($file) -and (Test-Path -LiteralPath $file)){Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue}
    }
}
