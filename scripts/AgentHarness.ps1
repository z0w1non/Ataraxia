Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'StructuredData.ps1')
. (Join-Path $PSScriptRoot 'WorkspaceDiff.ps1')
. (Join-Path $PSScriptRoot 'WorkspaceReaderPort.ps1')
. (Join-Path $PSScriptRoot 'WorkspaceFileStorePort.ps1')
. (Join-Path $PSScriptRoot 'JsonFileStore.ps1')
. (Join-Path $PSScriptRoot 'ProcessRunnerPort.ps1')

function Import-AgentHarnessSettings([object]$Config, [string]$ConfigPath = '',[object]$Dependencies=$null) {
    $configuredPath = if ($null -ne $Config.PSObject.Properties['agent_harness_path'] -and -not [string]::IsNullOrWhiteSpace([string]$Config.agent_harness_path)) { [string]$Config.agent_harness_path } else { 'agent-harness.json' }
    $baseDirectory = if ([IO.Path]::IsPathRooted($configuredPath)) { '' } elseif ([string]::IsNullOrWhiteSpace($ConfigPath)) { Join-Path (Split-Path -Parent $PSScriptRoot) 'configs' } else { Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath)) }
    $path = if ([IO.Path]::IsPathRooted($configuredPath)) { [IO.Path]::GetFullPath($configuredPath) } else { [IO.Path]::GetFullPath((Join-Path $baseDirectory $configuredPath)) }
    if (-not (Test-AtaraxiaJsonStoreFile $path $Dependencies)) { throw "Agent harness settings file does not exist: $path" }
    try { $settings = Read-AtaraxiaJsonStoreFile $path $Dependencies } catch { throw "Agent harness settings JSON is invalid: $path. $($_.Exception.Message)" }
    foreach ($key in @('max_file_bytes','max_total_bytes')) {
        if ($null -eq $settings.workspace.PSObject.Properties[$key] -or [long]$settings.workspace.$key -lt 1) { throw "Agent harness workspace.$key must be positive: $path" }
    }
    foreach ($key in @('max_media_bytes','max_total_media_bytes')) {
        if ($null -ne $settings.workspace.PSObject.Properties[$key] -and [long]$settings.workspace.$key -lt 1) { throw "Agent harness workspace.$key must be positive: $path" }
    }
    if ($null -ne $settings.workspace.PSObject.Properties['media_extensions']) {
        foreach ($extension in $settings.workspace.media_extensions) { if ([string]$extension -notin @('.png','.jpg','.jpeg','.webp','.wav','.mp3')) { throw "Unsupported media extension in agent harness settings: $extension" } }
    }
    $seenIds = @()
    foreach ($rule in @($settings.allowed_commands)) {
        if ([string]::IsNullOrWhiteSpace([string]$rule.id) -or $seenIds -contains [string]$rule.id) { throw "Agent harness command IDs must be unique and non-empty: $path" }
        $seenIds += [string]$rule.id
        if ([string]::IsNullOrWhiteSpace([string]$rule.executable)) { throw "Command '$($rule.id)' has no executable: $path" }
        $pattern = [string]$rule.arguments_regex
        if (-not $pattern.StartsWith('^') -or -not $pattern.EndsWith('$')) { throw "Command '$($rule.id)' arguments_regex must use start and end anchors: $path" }
        try { [regex]::new($pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(1)) | Out-Null } catch { throw "Command '$($rule.id)' arguments_regex is invalid: $path. $($_.Exception.Message)" }
        if ([int]$rule.timeout_seconds -lt 1 -or [int]$rule.timeout_seconds -gt 3600) { throw "Command '$($rule.id)' timeout_seconds must be between 1 and 3600: $path" }
    }
    $settings | Add-Member -NotePropertyName source_path -NotePropertyValue $path -Force
    return $settings
}

function Resolve-AgentWorkspaceDirectory([string]$ConfiguredDirectory, [string]$TaskDirectory,[object]$Dependencies=(New-AgentWorkspaceFileSystemDependencies)) {
    if ([string]::IsNullOrWhiteSpace($ConfiguredDirectory)) { throw 'Task working_directory is required before execution.' }
    $candidate = if ([IO.Path]::IsPathRooted($ConfiguredDirectory)) { $ConfiguredDirectory } else { Join-Path $TaskDirectory $ConfiguredDirectory }
    $pathDependencies=$Dependencies.path_dependencies
    $resolved = Resolve-AgentWorkspaceExistingPath $pathDependencies $candidate
    if (-not (Test-AgentWorkspacePath $pathDependencies $resolved 'Container')) { throw "Task working_directory is not a directory: $resolved" }
    $rootItem = Get-AgentWorkspacePathInfo $pathDependencies $resolved
    if ($rootItem.is_reparse_point) { throw 'Task working_directory cannot be a symbolic link or reparse point.' }
    return [IO.Path]::GetFullPath($resolved)
}

function Get-AgentWorkspaceHash([string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function ConvertFrom-AgentWorkspaceBytes([byte[]]$Bytes) {
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
    if($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF){$text=$text.Substring(1)}
    return $text
}

function Read-AgentWorkspaceText([string]$Path,[object]$Dependencies=(New-AgentWorkspaceFileSystemDependencies)) {
    $bytes=Read-AgentWorkspaceBytes $Dependencies $Path
    return ConvertFrom-AgentWorkspaceBytes $bytes
}

function Get-AgentWorkspaceFileEntries([string]$WorkspaceDirectory,[object]$Settings,[object]$Dependencies) {
    $root=[IO.Path]::GetFullPath($WorkspaceDirectory)
    $workspaceSettings=$Settings.workspace
    $ignored=if($null -ne $workspaceSettings.PSObject.Properties['ignored_directories']){@($workspaceSettings.ignored_directories|ForEach-Object{[string]$_})}else{@('.git','.svn')}
    $directories=[System.Collections.Generic.Stack[string]]::new();$directories.Push($root);$files=[System.Collections.Generic.List[object]]::new()
    while($directories.Count -gt 0){$directory=$directories.Pop();foreach($entry in (Get-AgentWorkspaceDirectoryEntries $Dependencies $directory)){if($entry.is_reparse_point){continue};if($entry.is_directory){if($ignored -notcontains $entry.name){$directories.Push($entry.full_path)};continue};$files.Add($entry)}}
    return @($files|Sort-Object full_path)
}

function Get-AgentWorkspaceSnapshot([string]$WorkspaceDirectory, [object]$Settings, [object]$Dependencies=(New-AgentWorkspaceFileSystemDependencies),[object[]]$FileEntries=$null) {
    $root = [IO.Path]::GetFullPath($WorkspaceDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $maxFileBytes = [long]$Settings.workspace.max_file_bytes
    $maxTotalBytes = [long]$Settings.workspace.max_total_bytes
    $ignored = @($Settings.workspace.ignored_directories | ForEach-Object { [string]$_ })
    $files = [System.Collections.Generic.List[object]]::new()
    $fileEntries=if($null -eq $FileEntries){Get-AgentWorkspaceFileEntries $root $Settings $Dependencies}else{@($FileEntries)}
    $includedBytes = [long]0
    foreach($item in $fileEntries){
            $rootPrefix=$root.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+'\'
            if(-not $item.full_path.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)){continue}
            $relativePath = $item.full_path.Substring($rootPrefix.Length).Replace('\','/')
            try{$null=Resolve-AgentWorkspacePath $root $relativePath $Dependencies.path_dependencies}catch{continue}
            $available = $false
            $content = ''
            if ($item.length -le $maxFileBytes -and $includedBytes + $item.length -le $maxTotalBytes) {
                try {
                    $bytes=Read-AgentWorkspaceBytes $Dependencies $item.full_path
                    $content = (New-Object Text.UTF8Encoding($false,$true)).GetString($bytes)
                    if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) { $content = $content.Substring(1) }
                    $available = ($content.IndexOf([char]0) -lt 0)
                    if ($available) { $includedBytes += [long]$item.length } else { $content = '' }
                } catch [System.Text.DecoderFallbackException] { $content = '' }
            }
            $fileHash = Get-AgentWorkspaceFileHash $Dependencies $item.full_path
            $files.Add([pscustomobject][ordered]@{ path=$relativePath; sha256=$fileHash; byte_length=[long]$item.length; content_available=$available; content=$content })
    }
    return @($files | Sort-Object path)
}

function Get-AgentWorkspaceMedia([string]$WorkspaceDirectory, [object]$Settings, [object]$Dependencies=(New-AgentWorkspaceFileSystemDependencies),[object[]]$FileEntries=$null) {
    $workspaceSettings = $Settings.workspace
    $maxFileBytes = if ($null -ne $workspaceSettings.PSObject.Properties['max_media_bytes']) { [long]$workspaceSettings.max_media_bytes } else { 2097152 }
    $maxTotalBytes = if ($null -ne $workspaceSettings.PSObject.Properties['max_total_media_bytes']) { [long]$workspaceSettings.max_total_media_bytes } else { 8388608 }
    $extensions = if ($null -ne $workspaceSettings.PSObject.Properties['media_extensions']) { @($workspaceSettings.media_extensions | ForEach-Object { ([string]$_).ToLowerInvariant() }) } else { @('.png','.jpg','.jpeg','.webp','.wav','.mp3') }
    $ignoredDirectories = if ($null -ne $workspaceSettings.PSObject.Properties['ignored_directories']) { @($workspaceSettings.ignored_directories | ForEach-Object { [string]$_ }) } else { @('.git','.svn') }
    $mimeTypes = @{ '.png'='image/png'; '.jpg'='image/jpeg'; '.jpeg'='image/jpeg'; '.webp'='image/webp'; '.wav'='audio/wav'; '.mp3'='audio/mpeg' }
    $root = [IO.Path]::GetFullPath($WorkspaceDirectory)
    $media = [System.Collections.Generic.List[object]]::new()
    $totalBytes = [long]0
    $imageCount = 0
    $audioCount = 0
    $mediaFiles=if($null -eq $FileEntries){Get-AgentWorkspaceFileEntries $root $Settings $Dependencies}else{@($FileEntries)}
    foreach ($item in @($mediaFiles | Sort-Object full_path)) {
        $extension = $item.extension.ToLowerInvariant()
        if ($extensions -notcontains $extension -or -not $mimeTypes.ContainsKey($extension)) { continue }
        $rootPrefix=$root.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+'\'
        if(-not $item.full_path.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)){continue}
        $relativePath = $item.full_path.Substring($rootPrefix.Length).Replace('\','/')
        try{$null=Resolve-AgentWorkspacePath $root $relativePath $Dependencies.path_dependencies}catch{continue}
        if (@($relativePath -split '/' | Where-Object { $ignoredDirectories -contains $_ }).Count -gt 0) { continue }
        if ($item.length -gt $maxFileBytes -or $totalBytes + $item.length -gt $maxTotalBytes) { continue }
        if ($mimeTypes[$extension].StartsWith('image/')) { if ($imageCount -ge 64) { continue }; $imageCount++ }
        else { if ($audioCount -ge 64) { continue }; $audioCount++ }
        $bytes = Read-AgentWorkspaceBytes $Dependencies $item.full_path
        $media.Add([pscustomobject][ordered]@{ path=$relativePath; mime_type=$mimeTypes[$extension]; sha256=(Get-AgentWorkspaceFileHash $Dependencies $item.full_path); byte_length=[long]$bytes.Length; data_base64=[Convert]::ToBase64String($bytes) })
        $totalBytes += [long]$bytes.Length
    }
    return @($media)
}

function Get-AgentWorkspaceContext([string]$WorkspaceDirectory,[object]$Settings,[object]$Dependencies=(New-AgentWorkspaceFileSystemDependencies)) {
    $entries=Get-AgentWorkspaceFileEntries $WorkspaceDirectory $Settings $Dependencies
    return [pscustomobject][ordered]@{files=(Get-AgentWorkspaceSnapshot $WorkspaceDirectory $Settings $Dependencies $entries);media=(Get-AgentWorkspaceMedia $WorkspaceDirectory $Settings $Dependencies $entries)}
}

function ConvertTo-AgentMessageContent([string]$Text, [object[]]$Media = @()) {
    $parts = [System.Collections.Generic.List[object]]::new()
    $parts.Add([pscustomobject][ordered]@{ type='text'; text=$Text })
    foreach ($item in $Media) {
        if ([string]$item.mime_type -like 'image/*') {
            $url = "data:$($item.mime_type);base64,$($item.data_base64)"
            $parts.Add([pscustomobject][ordered]@{ type='image_url'; image_url=[pscustomobject][ordered]@{ url=$url } })
        } elseif ([string]$item.mime_type -like 'audio/*') {
            $audioFormat = if ([string]$item.mime_type -eq 'audio/wav') { 'wav' } else { 'mp3' }
            $parts.Add([pscustomobject][ordered]@{ type='input_audio'; input_audio=[pscustomobject][ordered]@{ data=$item.data_base64; format=$audioFormat } })
        }
    }
    return ,@($parts)
}

function Resolve-AgentWorkspacePath([string]$WorkspaceDirectory, [string]$RelativePath,[object]$PathDependencies=(New-AgentWorkspaceFileSystemDependencies).path_dependencies) {
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '[\x00-\x1F\x7F<>:"|?*]' -or $RelativePath -match '(^|[\\/])\.\.?([\\/]|$)') { throw "Workspace path must be a safe relative path: $RelativePath" }
    foreach($segment in ($RelativePath -split '[\\/]')){if([string]::IsNullOrWhiteSpace($segment) -or $segment.EndsWith('.') -or $segment.EndsWith(' ') -or $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$'){throw "Workspace path contains an invalid or reserved segment: $RelativePath"}}
    $root = [IO.Path]::GetFullPath($WorkspaceDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $target = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Workspace path escapes the selected directory: $RelativePath" }
    $cursor = $root
    $segments = $RelativePath -split '[\\/]'
    for ($index = 0; $index -lt ($segments.Count - 1); $index++) {
        $cursor = Join-Path $cursor $segments[$index]
        if (Test-AgentWorkspacePath $PathDependencies $cursor 'Any') {
            $item = Get-AgentWorkspacePathInfo $PathDependencies $cursor
            if ($item.is_reparse_point -or -not $item.is_directory) { throw "Workspace path traverses a link or non-directory: $RelativePath" }
        }
    }
    if (Test-AgentWorkspacePath $PathDependencies $target 'Any') {
        $targetItem = Get-AgentWorkspacePathInfo $PathDependencies $target
        if ($targetItem.is_reparse_point -or $targetItem.is_directory) { throw "Workspace target must be a regular file: $RelativePath" }
    }
    return $target
}

function Convert-AgentOperationsToText([string]$Before, [object[]]$Operations) {
    if ([string]::IsNullOrEmpty($Before)) { $sourceLines = [string[]]@() } else { $sourceLines = [string[]](Get-ArtifactTextLines $Before) }
    $outputLines = [System.Collections.Generic.List[string]]::new()
    $cursor = 0
    foreach ($operation in $Operations) {
        $op = [string]$operation.op
        $lines = @($operation.lines | ForEach-Object { [string]$_ })
        switch ($op) {
            'retain' {
                $count = [int]$operation.count
                if ($count -lt 1 -or $lines.Count -ne 0 -or $cursor + $count -gt $sourceLines.Count) { throw 'Invalid retain operation in workspace diff.' }
                for ($index=0; $index -lt $count; $index++) { $outputLines.Add($sourceLines[$cursor++]) }
            }
            'delete' {
                if ([int]$operation.count -ne 0 -or $lines.Count -eq 0) { throw 'Invalid delete operation in workspace diff.' }
                foreach ($line in $lines) {
                    if ($cursor -ge $sourceLines.Count -or $sourceLines[$cursor] -cne $line) { throw 'Workspace diff delete lines do not match the current file.' }
                    $cursor++
                }
            }
            'insert' {
                if ([int]$operation.count -ne 0) { throw 'Invalid insert operation in workspace diff.' }
                foreach ($line in $lines) { $outputLines.Add($line) }
            }
            default { throw "Unsupported workspace diff operation: $op" }
        }
    }
    if ($cursor -ne $sourceLines.Count) { throw 'Workspace diff does not cover the complete base file.' }
    return $outputLines -join "`r`n"
}

function Write-AgentWorkspaceAtomicText([string]$Path, [string]$Text,[object]$Dependencies) {
    $parent = Split-Path -Parent $Path
    Ensure-AgentWorkspaceStoreDirectory $Dependencies $parent
    $temporary = "$Path.agent-$([guid]::NewGuid().ToString('N')).tmp"
    $backup = "$Path.agent-$([guid]::NewGuid().ToString('N')).bak"
    Write-AgentWorkspaceStoreBytes $Dependencies $temporary ([Text.UTF8Encoding]::new($false).GetBytes($Text))
    try {
        if (Test-AgentWorkspaceStoreFile $Dependencies $Path) { Replace-AgentWorkspaceStoreFile $Dependencies $temporary $Path $backup }
        else { Move-AgentWorkspaceStoreFile $Dependencies $temporary $Path }
    } finally {
        if (Test-AgentWorkspaceStoreFile $Dependencies $temporary) { Remove-AgentWorkspaceStoreFile $Dependencies $temporary }
        if (Test-AgentWorkspaceStoreFile $Dependencies $backup) { Remove-AgentWorkspaceStoreFile $Dependencies $backup }
    }
}

function Get-AgentByteHash([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Save-AgentChangeJournal([string]$Path,[object]$Journal,[object]$Dependencies) {
    $temporaryPath="$Path.tmp"
    Ensure-AgentWorkspaceStoreDirectory $Dependencies (Split-Path -Parent $Path)
    $json=$Journal | ConvertTo-Json -Depth 50
    if([Text.Encoding]::UTF8.GetByteCount($json) -gt 8388608){throw 'Run change journal exceeds the 8 MiB safety limit.'}
    Write-AgentWorkspaceStoreBytes $Dependencies $temporaryPath ([Text.UTF8Encoding]::new($false).GetBytes($json))
    Move-AgentWorkspaceStoreFile $Dependencies $temporaryPath $Path -Force
}

function New-AgentChangeJournal([string]$JournalPath,[string]$WorkspaceDirectory,[string]$StatePath,[object]$Dependencies) {
    if(Test-AgentWorkspaceStoreFile $Dependencies $JournalPath){throw 'An uncommitted run journal already exists; restore or resolve it before starting another run.'}
    $stateExists=Test-AgentWorkspaceStoreFile $Dependencies $StatePath
    if($stateExists -and (Get-AgentWorkspaceStoreLength $Dependencies $StatePath) -gt 2097152){throw 'Task state exceeds the 2 MiB safety limit.'}
    $stateBytes=if($stateExists){Read-AgentWorkspaceStoreBytes $Dependencies $StatePath}else{,[byte[]]@()}
    $journal=[pscustomobject][ordered]@{
        schema_version=1;status='active';workspace_root=[IO.Path]::GetFullPath($WorkspaceDirectory)
        state_before_exists=$stateExists;state_before_base64=[Convert]::ToBase64String($stateBytes);state_before_hash=if($stateExists){Get-AgentByteHash $stateBytes}else{''}
        state_after_exists=$stateExists;state_after_hash=if($stateExists){Get-AgentByteHash $stateBytes}else{''};entries=@()
    }
    Save-AgentChangeJournal $JournalPath $journal $Dependencies
    return $journal
}

function Update-AgentChangeJournalState([string]$JournalPath,[string]$StateText,[object]$Dependencies) {
    if(-not(Test-AgentWorkspaceStoreFile $Dependencies $JournalPath)){return}
    $journal=Read-AgentJsonFile $JournalPath 8388608
    $stateBytes=[Text.UTF8Encoding]::new($false).GetBytes($StateText)
    $journal.state_after_exists=$true;$journal.state_after_hash=Get-AgentByteHash $stateBytes
    Save-AgentChangeJournal $JournalPath $journal $Dependencies
}

function Add-AgentChangeJournalEntries([string]$JournalPath,[string]$WorkspaceDirectory,[object[]]$Plan,[object]$Dependencies) {
    if([string]::IsNullOrWhiteSpace($JournalPath)){return}
    $journal=Read-AgentJsonFile $JournalPath 8388608
    foreach($item in $Plan){
        $entry=@($journal.entries|Where-Object{[string]$_.path -ieq [string]$item.path}|Select-Object -First 1)
        $afterBytes=if($item.action -eq 'delete'){,[byte[]]@()}else{[Text.UTF8Encoding]::new($false).GetBytes([string]$item.content)}
        if($entry.Count -eq 0){
            $beforeExists=Test-AgentWorkspaceStoreFile $Dependencies $item.full_path
            $beforeBytes=if($beforeExists){Read-AgentWorkspaceStoreBytes $Dependencies $item.full_path}else{,[byte[]]@()}
            $entry=[pscustomobject][ordered]@{path=[string]$item.path;before_exists=$beforeExists;before_base64=[Convert]::ToBase64String($beforeBytes);before_hash=if($beforeExists){Get-AgentByteHash $beforeBytes}else{''};after_exists=($item.action -ne 'delete');after_hash=if($item.action -eq 'delete'){''}else{Get-AgentByteHash $afterBytes}}
            $journal.entries=@($journal.entries)+@($entry)
        } else {
            $entry[0].after_exists=($item.action -ne 'delete')
            $entry[0].after_hash=if($item.action -eq 'delete'){''}else{Get-AgentByteHash $afterBytes}
        }
    }
    Save-AgentChangeJournal $JournalPath $journal $Dependencies
}

function Sync-AgentChangeJournal([string]$JournalPath,[string]$WorkspaceDirectory,[object]$Dependencies) {
    if(-not(Test-AgentWorkspaceStoreFile $Dependencies $JournalPath)){return}
    $journal=Read-AgentJsonFile $JournalPath 8388608
    foreach($entry in @($journal.entries)){
        $pathDependencies=if($null -ne $Dependencies.PSObject.Properties['path_dependencies'] -and $null -ne $Dependencies.path_dependencies){$Dependencies.path_dependencies}else{(New-AgentWorkspaceFileSystemDependencies).path_dependencies}
        $target=Resolve-AgentWorkspacePath $WorkspaceDirectory ([string]$entry.path) $pathDependencies
        $exists=Test-AgentWorkspaceStoreFile $Dependencies $target
        $entry.after_exists=$exists
        $entry.after_hash=if($exists){Get-AgentByteHash (Read-AgentWorkspaceStoreBytes $Dependencies $target)}else{''}
    }
    Save-AgentChangeJournal $JournalPath $journal $Dependencies
}

function Write-AgentWorkspaceBytes([string]$Path,[byte[]]$Bytes,[object]$Dependencies) {
    $parent=Split-Path -Parent $Path;Ensure-AgentWorkspaceStoreDirectory $Dependencies $parent
    $temporary="$Path.rollback-$([guid]::NewGuid().ToString('N')).tmp"
    Write-AgentWorkspaceStoreBytes $Dependencies $temporary $Bytes
    Move-AgentWorkspaceStoreFile $Dependencies $temporary $Path -Force
}

function Restore-AgentRunChanges([string]$WorkspaceDirectory,[string]$JournalPath,[string]$StatePath,[object]$Dependencies) {
    if(-not(Test-AgentWorkspaceStoreFile $Dependencies $JournalPath)){return [pscustomobject]@{restored_files=@();state_restored=$false}}
    $journal=Read-AgentJsonFile $JournalPath 8388608
    $workspace=[IO.Path]::GetFullPath($WorkspaceDirectory)
    if($journal.status -ne 'active' -or [IO.Path]::GetFullPath([string]$journal.workspace_root) -ine $workspace){throw 'Run journal does not match the assigned workspace.'}
    $stateExists=Test-AgentWorkspaceStoreFile $Dependencies $StatePath
    $stateHash=if($stateExists){Get-AgentByteHash (Read-AgentWorkspaceStoreBytes $Dependencies $StatePath)}else{''}
    $stateBeforeMatches=($stateExists -eq [bool]$journal.state_before_exists) -and (-not $stateExists -or $stateHash -ceq [string]$journal.state_before_hash)
    $stateAfterMatches=($stateExists -eq [bool]$journal.state_after_exists) -and (-not $stateExists -or $stateHash -ceq [string]$journal.state_after_hash)
    if(-not $stateBeforeMatches -and -not $stateAfterMatches){throw 'Task state changed outside the active run; rollback was stopped to protect it.'}
    $restorePlan=[System.Collections.Generic.List[object]]::new()
    foreach($entry in @($journal.entries)){
        $pathDependencies=if($null -ne $Dependencies.PSObject.Properties['path_dependencies'] -and $null -ne $Dependencies.path_dependencies){$Dependencies.path_dependencies}else{(New-AgentWorkspaceFileSystemDependencies).path_dependencies}
        $target=Resolve-AgentWorkspacePath $workspace ([string]$entry.path) $pathDependencies
        $exists=Test-AgentWorkspaceStoreFile $Dependencies $target
        $currentHash=if($exists){Get-AgentByteHash (Read-AgentWorkspaceStoreBytes $Dependencies $target)}else{''}
        $beforeMatches=($exists -eq [bool]$entry.before_exists) -and (-not $exists -or $currentHash -ceq [string]$entry.before_hash)
        $afterMatches=($exists -eq [bool]$entry.after_exists) -and (-not $exists -or $currentHash -ceq [string]$entry.after_hash)
        if(-not $beforeMatches -and -not $afterMatches){throw "Workspace file changed outside the active run; rollback was stopped: $($entry.path)"}
        $restorePlan.Add([pscustomobject]@{path=[string]$entry.path;target=$target;already_restored=$beforeMatches;before_exists=[bool]$entry.before_exists;before_bytes=[Convert]::FromBase64String([string]$entry.before_base64)})
    }
    for($index=$restorePlan.Count-1;$index -ge 0;$index--){
        $item=$restorePlan[$index]
        if($item.already_restored){continue}
        if($item.before_exists){Write-AgentWorkspaceBytes $item.target $item.before_bytes $Dependencies}
        elseif(Test-AgentWorkspaceStoreFile $Dependencies $item.target){Remove-AgentWorkspaceStoreFile $Dependencies $item.target}
    }
    if(-not $stateBeforeMatches){
        if([bool]$journal.state_before_exists){Write-AgentWorkspaceBytes $StatePath ([Convert]::FromBase64String([string]$journal.state_before_base64)) $Dependencies}
        elseif(Test-AgentWorkspaceStoreFile $Dependencies $StatePath){Remove-AgentWorkspaceStoreFile $Dependencies $StatePath}
    }
    Remove-AgentWorkspaceStoreFile $Dependencies $JournalPath
    return [pscustomobject]@{restored_files=@($restorePlan|Where-Object{-not $_.already_restored}|ForEach-Object{$_.path});state_restored=(-not $stateBeforeMatches)}
}

function Apply-AgentWorkspaceChanges([string]$WorkspaceDirectory, [object[]]$Changes,[string]$JournalPath='',[object]$Dependencies) {
    if(@($Changes).Count -gt 100){throw 'A role may change at most 100 files in one stage.'}
    $plan = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($change in $Changes) {
        $relative = [string]$change.path
        $pathDependencies=if($null -ne $Dependencies.PSObject.Properties['path_dependencies'] -and $null -ne $Dependencies.path_dependencies){$Dependencies.path_dependencies}else{(New-AgentWorkspaceFileSystemDependencies).path_dependencies}
        $target = Resolve-AgentWorkspacePath $WorkspaceDirectory $relative $pathDependencies
        if (-not $seen.Add($target)) { throw "Workspace change contains a duplicate path: $relative" }
        $action = [string]$change.action
        if ($action -notin @('create','modify','delete')) { throw "Unsupported workspace change action: $action" }
        if([string]$change.base_hash -notmatch '^[0-9a-fA-F]{64}$'){throw "Workspace change has an invalid base hash: $relative"}
        $exists = Test-AgentWorkspaceStoreFile $Dependencies $target
        if ($exists -and (Get-AgentWorkspaceStoreLength $Dependencies $target) -gt 1048576){throw "Workspace file exceeds the 1 MiB change safety limit: $relative"}
        if ($action -eq 'create' -and $exists) { throw "Workspace create target already exists: $relative" }
        if ($action -in @('modify','delete') -and -not $exists) { throw "Workspace change target does not exist: $relative" }
        $beforeBytes=if($exists -and $action -ne 'delete'){Read-AgentWorkspaceStoreBytes $Dependencies $target}else{,[byte[]]@()}
        $before=if($exists -and $action -ne 'delete'){ConvertFrom-AgentWorkspaceBytes $beforeBytes}else{''}
        if ($exists -and $action -ne 'delete' -and (Get-AgentByteHash $beforeBytes) -cne [string]$change.base_hash) { throw "Workspace base hash does not match: $relative" }
        if ($action -eq 'create' -and (Get-AgentWorkspaceHash '') -cne [string]$change.base_hash) { throw "Workspace create base hash is invalid: $relative" }
        if ($action -eq 'delete') {
            if ((Get-AgentByteHash (Read-AgentWorkspaceStoreBytes $Dependencies $target)) -cne [string]$change.base_hash) { throw "Workspace delete base hash does not match: $relative" }
            $after = $null
        } else {
            if(@($change.operations).Count -gt 5000){throw "Workspace diff contains too many operations: $relative"}
            $after = Convert-AgentOperationsToText $before @($change.operations)
            Assert-AgentPlainText $after "Workspace content '$relative'" 1048576 -AllowMultiline
            $canonicalPatch = New-TextPatch $before $after
            if ((Apply-TextPatch $before $canonicalPatch) -cne $after) { throw "Workspace diff verification failed: $relative" }
        }
        $plan.Add([pscustomobject]@{ path=$relative; full_path=$target; action=$action; content=$after })
    }
    Add-AgentChangeJournalEntries $JournalPath $WorkspaceDirectory @($plan) $Dependencies
    foreach ($item in $plan) {
        if ($item.action -eq 'delete') { Remove-AgentWorkspaceStoreFile $Dependencies $item.full_path }
        else { Write-AgentWorkspaceAtomicText $item.full_path ([string]$item.content) $Dependencies }
    }
    Sync-AgentChangeJournal $JournalPath $WorkspaceDirectory $Dependencies
    return [pscustomobject][ordered]@{ changed_files=@($plan | ForEach-Object { [string]$_.path }); change_count=$plan.Count }
}

function ConvertTo-AgentArgumentText([string[]]$Arguments) {
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -notmatch '[\s"]') { $argument; continue }
        $builder = [Text.StringBuilder]::new()
        [void]$builder.Append('"')
        $slashes = 0
        foreach ($character in $argument.ToCharArray()) {
            if ($character -eq '\') { $slashes++; continue }
            if ($character -eq '"') { [void]$builder.Append(('\' * (($slashes * 2) + 1))); [void]$builder.Append('"'); $slashes=0; continue }
            if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)); $slashes=0 }
            [void]$builder.Append($character)
        }
        if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
        [void]$builder.Append('"')
        $builder.ToString()
    }
    return @($quoted) -join ' '
}

function Resolve-AgentAllowedCommand([object]$Settings, [object]$Command) {
    if($null -eq $Command -or $null -eq $Command.PSObject.Properties['command_id'] -or $null -eq $Command.PSObject.Properties['arguments']){throw 'Command must contain command_id and arguments.'}
    $rule = @($Settings.allowed_commands | Where-Object { [string]$_.id -ceq [string]$Command.command_id }) | Select-Object -First 1
    if ($null -eq $rule) { throw "Command is not allowlisted: $($Command.command_id)" }
    if ($Command.arguments -is [string] -or ($Command.arguments -isnot [System.Array] -and $Command.arguments -isnot [System.Collections.IList])) { throw 'Command arguments must be an array of strings.' }
    if(@($Command.arguments|Where-Object{$_ -isnot [string]}).Count -gt 0){throw 'Command arguments must be an array of strings.'}
    $arguments = @($Command.arguments | ForEach-Object { [string]$_ })
    if ($arguments.Count -gt 64 -or @($arguments | Where-Object { $_.Length -gt 4096 -or $_ -match '[\x00\r\n]' }).Count -gt 0) { throw 'Command argument count or content is invalid.' }
    $argumentText = ConvertTo-AgentArgumentText $arguments
    try { $allowed = [regex]::IsMatch($argumentText, [string]$rule.arguments_regex, [Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromSeconds(1)) } catch { throw "Command allowlist regex failed: $($_.Exception.Message)" }
    if (-not $allowed) { throw "Command arguments are not allowlisted for '$($Command.command_id)'." }
    return [pscustomobject]@{ id=[string]$rule.id; executable=[string]$rule.executable; arguments=$arguments; argument_text=$argumentText; timeout_seconds=[int]$rule.timeout_seconds }
}

function Invoke-AgentAllowedCommand([object]$Settings, [string]$WorkspaceDirectory, [object]$Command,[object]$Dependencies=$null) {
    $resolved = Resolve-AgentAllowedCommand $Settings $Command
    $workspace=[IO.Path]::GetFullPath($WorkspaceDirectory)
    $raw=Invoke-AgentProcessRunner $Dependencies $resolved $workspace
    $limit=20000
    $stdout=[regex]::Replace([string]$raw.stdout,'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))','') -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]',''
    $stderr=[regex]::Replace([string]$raw.stderr,'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))','') -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]',''
    return [pscustomobject][ordered]@{ command_id=$resolved.id; command="$($resolved.executable) $($resolved.argument_text)".Trim(); exit_code=[int]$raw.exit_code; timed_out=[bool]$raw.timed_out; duration_ms=[long]$raw.duration_ms; stdout=if ($stdout.Length -gt $limit) { $stdout.Substring(0,$limit) } else { $stdout }; stderr=if ($stderr.Length -gt $limit) { $stderr.Substring(0,$limit) } else { $stderr.Substring(0,[Math]::Min($stderr.Length,$limit)) } }
}

function Invoke-AgentCommandBatch([object]$Settings, [string]$WorkspaceDirectory, [object[]]$Commands,[object]$Dependencies=$null) {
    if(@($Commands).Count -gt 64){throw 'A role may run at most 64 allowlisted commands in one stage.'}
    $resolvedCommands = @($Commands | ForEach-Object { Resolve-AgentAllowedCommand $Settings $_ })
    $results = @()
    foreach ($command in $Commands) { $results += Invoke-AgentAllowedCommand $Settings $WorkspaceDirectory $command $Dependencies }
    return $results
}
