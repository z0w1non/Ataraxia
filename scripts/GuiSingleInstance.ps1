Set-StrictMode -Version Latest

function Get-AtaraxiaGuiInstanceIdentity([string]$ConfigPath) {
    if([string]::IsNullOrWhiteSpace($ConfigPath)){throw 'GUI instance identity requires a config path.'}
    $canonicalPath=[IO.Path]::GetFullPath($ConfigPath)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$digest=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonicalPath.ToUpperInvariant()))).Replace('-','')}
    finally{$sha.Dispose()}
    return [pscustomobject][ordered]@{
        config_path=$canonicalPath
        mutex_name=('Local\Ataraxia.Gui.'+$digest)
        activation_event_name=('Local\Ataraxia.Gui.Activate.'+$digest)
    }
}
