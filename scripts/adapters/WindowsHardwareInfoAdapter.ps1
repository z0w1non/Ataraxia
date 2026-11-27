Set-StrictMode -Version Latest

function New-AtaraxiaWindowsHardwareInfoDependencies([scriptblock]$GetVideoControllerNames=$null) {
    if($null -eq $GetVideoControllerNames){$GetVideoControllerNames={@(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop|Select-Object -ExpandProperty Name)}.GetNewClosure()}
    if($GetVideoControllerNames -isnot [scriptblock]){throw 'Video controller information adapter must be a script block.'}
    return [pscustomobject]@{get_video_controller_names=$GetVideoControllerNames}
}

function Get-AtaraxiaWindowsVideoControllerNames([object]$Dependencies) {
    if($null -eq $Dependencies -or $Dependencies.get_video_controller_names -isnot [scriptblock]){throw 'Video controller information adapter is not configured.'}
    $names=@(& $Dependencies.get_video_controller_names)
    foreach($name in $names){if($name -isnot [string]){throw 'Video controller adapter must return only names as strings.'}}
    return ,([string[]]$names)
}
