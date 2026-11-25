Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'StructuredData.ps1')
. (Join-Path $PSScriptRoot 'WorkspaceDiff.ps1')

function Import-AgentHarnessSettings([object]$Config, [string]$ConfigPath = '') {
    $configuredPath = if ($null -ne $Config.PSObject.Properties['agent_harness_path'] -and -not [string]::IsNullOrWhiteSpace([string]$Config.agent_harness_path)) { [string]$Config.agent_harness_path } else { 'agent-harness.json' }
    $baseDirectory = if ([IO.Path]::IsPathRooted($configuredPath)) { '' } elseif ([string]::IsNullOrWhiteSpace($ConfigPath)) { Join-Path (Split-Path -Parent $PSScriptRoot) 'configs' } else { Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath)) }
    $path = if ([IO.Path]::IsPathRooted($configuredPath)) { [IO.Path]::GetFullPath($configuredPath) } else { [IO.Path]::GetFullPath((Join-Path $baseDirectory $configuredPath)) }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Agent harness settings file does not exist: $path" }
    try { $settings = Read-AgentJsonFile $path } catch { throw "Agent harness settings JSON is invalid: $path. $($_.Exception.Message)" }
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

function Resolve-AgentWorkspaceDirectory([string]$ConfiguredDirectory, [string]$TaskDirectory) {
    if ([string]::IsNullOrWhiteSpace($ConfiguredDirectory)) { throw 'Task working_directory is required before execution.' }
    $candidate = if ([IO.Path]::IsPathRooted($ConfiguredDirectory)) { $ConfiguredDirectory } else { Join-Path $TaskDirectory $ConfiguredDirectory }
    $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { throw "Task working_directory is not a directory: $resolved" }
    $rootItem = Get-Item -LiteralPath $resolved -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Task working_directory cannot be a symbolic link or reparse point.' }
    return [IO.Path]::GetFullPath($resolved)
}

function Get-AgentWorkspaceHash([string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Read-AgentWorkspaceText([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $text = $encoding.GetString($bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return $text
}

function Get-AgentWorkspaceSnapshot([string]$WorkspaceDirectory, [object]$Settings) {
    $root = [IO.Path]::GetFullPath($WorkspaceDirectory)
    $maxFileBytes = [long]$Settings.workspace.max_file_bytes
    $maxTotalBytes = [long]$Settings.workspace.max_total_bytes
    $ignored = @($Settings.workspace.ignored_directories | ForEach-Object { [string]$_ })
    $files = [System.Collections.Generic.List[object]]::new()
    $directories = [System.Collections.Generic.Stack[string]]::new()
    $directories.Push($root)
    $includedBytes = [long]0
    while ($directories.Count -gt 0) {
        $directory = $directories.Pop()
        foreach ($item in (Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop | Sort-Object FullName)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($item.PSIsContainer) {
                if ($ignored -notcontains $item.Name) { $directories.Push($item.FullName) }
                continue
            }
            $rootPrefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            $relativePath = $item.FullName.Substring($rootPrefix.Length).Replace('\','/')
            try{$null=Resolve-AgentWorkspacePath $root $relativePath}catch{continue}
            $available = $false
            $content = ''
            if ($item.Length -le $maxFileBytes -and $includedBytes + $item.Length -le $maxTotalBytes) {
                try {
                    $content = Read-AgentWorkspaceText $item.FullName
                    $available = ($content.IndexOf([char]0) -lt 0)
                    if ($available) { $includedBytes += [long]$item.Length } else { $content = '' }
                } catch [System.Text.DecoderFallbackException] { $content = '' }
            }
            $fileHash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $files.Add([pscustomobject][ordered]@{ path=$relativePath; sha256=$fileHash; byte_length=[long]$item.Length; content_available=$available; content=$content })
        }
    }
    return @($files | Sort-Object path)
}

function Get-AgentWorkspaceMedia([string]$WorkspaceDirectory, [object]$Settings) {
    $workspaceSettings = $Settings.workspace
    $maxFileBytes = if ($null -ne $workspaceSettings.PSObject.Properties['max_media_bytes']) { [long]$workspaceSettings.max_media_bytes } else { 2097152 }
    $maxTotalBytes = if ($null -ne $workspaceSettings.PSObject.Properties['max_total_media_bytes']) { [long]$workspaceSettings.max_total_media_bytes } else { 8388608 }
    $extensions = if ($null -ne $workspaceSettings.PSObject.Properties['media_extensions']) { @($workspaceSettings.media_extensions | ForEach-Object { ([string]$_).ToLowerInvariant() }) } else { @('.png','.jpg','.jpeg','.webp','.wav','.mp3') }
    $ignoredDirectories = if ($null -ne $workspaceSettings.PSObject.Properties['ignored_directories']) { @($workspaceSettings.ignored_directories | ForEach-Object { [string]$_ }) } else { @('.git','.svn') }
    $mimeTypes = @{ '.png'='image/png'; '.jpg'='image/jpeg'; '.jpeg'='image/jpeg'; '.webp'='image/webp'; '.wav'='audio/wav'; '.mp3'='audio/mpeg' }
    $root = [IO.Path]::GetFullPath($WorkspaceDirectory)
    $rootPrefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $media = [System.Collections.Generic.List[object]]::new()
    $totalBytes = [long]0
    $imageCount = 0
    $audioCount = 0
    foreach ($item in (Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction Stop | Sort-Object FullName)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $extension = $item.Extension.ToLowerInvariant()
        if ($extensions -notcontains $extension -or -not $mimeTypes.ContainsKey($extension)) { continue }
        $relativePath = $item.FullName.Substring($rootPrefix.Length).Replace('\','/')
        try{$null=Resolve-AgentWorkspacePath $root $relativePath}catch{continue}
        if (@($relativePath -split '/' | Where-Object { $ignoredDirectories -contains $_ }).Count -gt 0) { continue }
        if ($item.Length -gt $maxFileBytes -or $totalBytes + $item.Length -gt $maxTotalBytes) { continue }
        if ($mimeTypes[$extension].StartsWith('image/')) { if ($imageCount -ge 64) { continue }; $imageCount++ }
        else { if ($audioCount -ge 64) { continue }; $audioCount++ }
        $bytes = [IO.File]::ReadAllBytes($item.FullName)
        $media.Add([pscustomobject][ordered]@{ path=$relativePath; mime_type=$mimeTypes[$extension]; sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant(); byte_length=[long]$bytes.Length; data_base64=[Convert]::ToBase64String($bytes) })
        $totalBytes += [long]$bytes.Length
    }
    return @($media)
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

function Resolve-AgentWorkspacePath([string]$WorkspaceDirectory, [string]$RelativePath) {
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
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not $item.PSIsContainer) { throw "Workspace path traverses a link or non-directory: $RelativePath" }
        }
    }
    if (Test-Path -LiteralPath $target) {
        $targetItem = Get-Item -LiteralPath $target -Force
        if (($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $targetItem.PSIsContainer) { throw "Workspace target must be a regular file: $RelativePath" }
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

function Write-AgentWorkspaceText([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporary = "$Path.agent-$([guid]::NewGuid().ToString('N')).tmp"
    $backup = "$Path.agent-$([guid]::NewGuid().ToString('N')).bak"
    [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($false))
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::Replace($temporary, $Path, $backup) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
    }
}

function Get-AgentByteHash([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Save-AgentChangeJournal([string]$Path,[object]$Journal) {
    $temporaryPath="$Path.tmp"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $json=$Journal | ConvertTo-Json -Depth 50
    if([Text.Encoding]::UTF8.GetByteCount($json) -gt 8388608){throw 'Run change journal exceeds the 8 MiB safety limit.'}
    [IO.File]::WriteAllText($temporaryPath,$json,[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function New-AgentChangeJournal([string]$JournalPath,[string]$WorkspaceDirectory,[string]$StatePath) {
    if(Test-Path -LiteralPath $JournalPath){throw 'An uncommitted run journal already exists; restore or resolve it before starting another run.'}
    $stateExists=Test-Path -LiteralPath $StatePath -PathType Leaf
    if($stateExists -and (Get-Item -LiteralPath $StatePath -Force).Length -gt 2097152){throw 'Task state exceeds the 2 MiB safety limit.'}
    $stateBytes=if($stateExists){[IO.File]::ReadAllBytes($StatePath)}else{[byte[]]@()}
    $journal=[pscustomobject][ordered]@{
        schema_version=1;status='active';workspace_root=[IO.Path]::GetFullPath($WorkspaceDirectory)
        state_before_exists=$stateExists;state_before_base64=[Convert]::ToBase64String($stateBytes);state_before_hash=if($stateExists){Get-AgentByteHash $stateBytes}else{''}
        state_after_exists=$stateExists;state_after_hash=if($stateExists){Get-AgentByteHash $stateBytes}else{''};entries=@()
    }
    Save-AgentChangeJournal $JournalPath $journal
    return $journal
}

function Update-AgentChangeJournalState([string]$JournalPath,[string]$StateText) {
    if(-not(Test-Path -LiteralPath $JournalPath -PathType Leaf)){return}
    $journal=Read-AgentJsonFile $JournalPath 8388608
    $stateBytes=[Text.UTF8Encoding]::new($false).GetBytes($StateText)
    $journal.state_after_exists=$true;$journal.state_after_hash=Get-AgentByteHash $stateBytes
    Save-AgentChangeJournal $JournalPath $journal
}

function Add-AgentChangeJournalEntries([string]$JournalPath,[string]$WorkspaceDirectory,[object[]]$Plan) {
    if([string]::IsNullOrWhiteSpace($JournalPath)){return}
    $journal=Read-AgentJsonFile $JournalPath 8388608
    foreach($item in $Plan){
        $entry=@($journal.entries|Where-Object{[string]$_.path -ieq [string]$item.path}|Select-Object -First 1)
        $afterBytes=if($item.action -eq 'delete'){[byte[]]@()}else{[Text.UTF8Encoding]::new($false).GetBytes([string]$item.content)}
        if($entry.Count -eq 0){
            $beforeExists=Test-Path -LiteralPath $item.full_path -PathType Leaf
            $beforeBytes=if($beforeExists){,[IO.File]::ReadAllBytes($item.full_path)}else{,[byte[]]@()}
            $entry=[pscustomobject][ordered]@{path=[string]$item.path;before_exists=$beforeExists;before_base64=[Convert]::ToBase64String($beforeBytes);before_hash=if($beforeExists){Get-AgentByteHash $beforeBytes}else{''};after_exists=($item.action -ne 'delete');after_hash=if($item.action -eq 'delete'){''}else{Get-AgentByteHash $afterBytes}}
            $journal.entries=@($journal.entries)+@($entry)
        } else {
            $entry[0].after_exists=($item.action -ne 'delete')
            $entry[0].after_hash=if($item.action -eq 'delete'){''}else{Get-AgentByteHash $afterBytes}
        }
    }
    Save-AgentChangeJournal $JournalPath $journal
}

function Sync-AgentChangeJournal([string]$JournalPath,[string]$WorkspaceDirectory) {
    if(-not(Test-Path -LiteralPath $JournalPath -PathType Leaf)){return}
    $journal=Read-AgentJsonFile $JournalPath 8388608
    foreach($entry in @($journal.entries)){
        $target=Resolve-AgentWorkspacePath $WorkspaceDirectory ([string]$entry.path)
        $exists=Test-Path -LiteralPath $target -PathType Leaf
        $entry.after_exists=$exists
        $entry.after_hash=if($exists){Get-AgentByteHash ([IO.File]::ReadAllBytes($target))}else{''}
    }
    Save-AgentChangeJournal $JournalPath $journal
}

function Write-AgentWorkspaceBytes([string]$Path,[byte[]]$Bytes) {
    $parent=Split-Path -Parent $Path;New-Item -ItemType Directory -Force -Path $parent|Out-Null
    $temporary="$Path.rollback-$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllBytes($temporary,$Bytes)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Restore-AgentRunChanges([string]$WorkspaceDirectory,[string]$JournalPath,[string]$StatePath) {
    if(-not(Test-Path -LiteralPath $JournalPath -PathType Leaf)){return [pscustomobject]@{restored_files=@();state_restored=$false}}
    $journal=Read-AgentJsonFile $JournalPath 8388608
    $workspace=[IO.Path]::GetFullPath($WorkspaceDirectory)
    if($journal.status -ne 'active' -or [IO.Path]::GetFullPath([string]$journal.workspace_root) -ine $workspace){throw 'Run journal does not match the assigned workspace.'}
    $stateExists=Test-Path -LiteralPath $StatePath -PathType Leaf
    $stateHash=if($stateExists){Get-AgentByteHash ([IO.File]::ReadAllBytes($StatePath))}else{''}
    $stateBeforeMatches=($stateExists -eq [bool]$journal.state_before_exists) -and (-not $stateExists -or $stateHash -ceq [string]$journal.state_before_hash)
    $stateAfterMatches=($stateExists -eq [bool]$journal.state_after_exists) -and (-not $stateExists -or $stateHash -ceq [string]$journal.state_after_hash)
    if(-not $stateBeforeMatches -and -not $stateAfterMatches){throw 'Task state changed outside the active run; rollback was stopped to protect it.'}
    $restorePlan=[System.Collections.Generic.List[object]]::new()
    foreach($entry in @($journal.entries)){
        $target=Resolve-AgentWorkspacePath $workspace ([string]$entry.path)
        $exists=Test-Path -LiteralPath $target -PathType Leaf
        $currentHash=if($exists){Get-AgentByteHash ([IO.File]::ReadAllBytes($target))}else{''}
        $beforeMatches=($exists -eq [bool]$entry.before_exists) -and (-not $exists -or $currentHash -ceq [string]$entry.before_hash)
        $afterMatches=($exists -eq [bool]$entry.after_exists) -and (-not $exists -or $currentHash -ceq [string]$entry.after_hash)
        if(-not $beforeMatches -and -not $afterMatches){throw "Workspace file changed outside the active run; rollback was stopped: $($entry.path)"}
        $restorePlan.Add([pscustomobject]@{path=[string]$entry.path;target=$target;already_restored=$beforeMatches;before_exists=[bool]$entry.before_exists;before_bytes=[Convert]::FromBase64String([string]$entry.before_base64)})
    }
    for($index=$restorePlan.Count-1;$index -ge 0;$index--){
        $item=$restorePlan[$index]
        if($item.already_restored){continue}
        if($item.before_exists){Write-AgentWorkspaceBytes $item.target $item.before_bytes}
        elseif(Test-Path -LiteralPath $item.target -PathType Leaf){Remove-Item -LiteralPath $item.target -Force}
    }
    if(-not $stateBeforeMatches){
        if([bool]$journal.state_before_exists){Write-AgentWorkspaceBytes $StatePath ([Convert]::FromBase64String([string]$journal.state_before_base64))}
        elseif(Test-Path -LiteralPath $StatePath -PathType Leaf){Remove-Item -LiteralPath $StatePath -Force}
    }
    Remove-Item -LiteralPath $JournalPath -Force
    return [pscustomobject]@{restored_files=@($restorePlan|Where-Object{-not $_.already_restored}|ForEach-Object{$_.path});state_restored=(-not $stateBeforeMatches)}
}

function Apply-AgentWorkspaceChanges([string]$WorkspaceDirectory, [object[]]$Changes,[string]$JournalPath='') {
    if(@($Changes).Count -gt 100){throw 'A role may change at most 100 files in one stage.'}
    $plan = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($change in $Changes) {
        $relative = [string]$change.path
        $target = Resolve-AgentWorkspacePath $WorkspaceDirectory $relative
        if (-not $seen.Add($target)) { throw "Workspace change contains a duplicate path: $relative" }
        $action = [string]$change.action
        if ($action -notin @('create','modify','delete')) { throw "Unsupported workspace change action: $action" }
        if([string]$change.base_hash -notmatch '^[0-9a-fA-F]{64}$'){throw "Workspace change has an invalid base hash: $relative"}
        $exists = Test-Path -LiteralPath $target -PathType Leaf
        if ($exists -and (Get-Item -LiteralPath $target -Force).Length -gt 1048576){throw "Workspace file exceeds the 1 MiB change safety limit: $relative"}
        if ($action -eq 'create' -and $exists) { throw "Workspace create target already exists: $relative" }
        if ($action -in @('modify','delete') -and -not $exists) { throw "Workspace change target does not exist: $relative" }
        $before = if ($exists -and $action -ne 'delete') { Read-AgentWorkspaceText $target } else { '' }
        if ($exists -and $action -ne 'delete' -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$change.base_hash) { throw "Workspace base hash does not match: $relative" }
        if ($action -eq 'create' -and (Get-AgentWorkspaceHash '') -cne [string]$change.base_hash) { throw "Workspace create base hash is invalid: $relative" }
        if ($action -eq 'delete') {
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$change.base_hash) { throw "Workspace delete base hash does not match: $relative" }
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
    Add-AgentChangeJournalEntries $JournalPath $WorkspaceDirectory @($plan)
    foreach ($item in $plan) {
        if ($item.action -eq 'delete') { Remove-Item -LiteralPath $item.full_path -Force }
        else { Write-AgentWorkspaceText $item.full_path ([string]$item.content) }
    }
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

function Invoke-AgentAllowedCommand([object]$Settings, [string]$WorkspaceDirectory, [object]$Command) {
    $resolved = Resolve-AgentAllowedCommand $Settings $Command
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $resolved.executable
    $start.Arguments = $resolved.argument_text
    $start.WorkingDirectory = [IO.Path]::GetFullPath($WorkspaceDirectory)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) { throw "Command failed to start: $($resolved.id)" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($resolved.timeout_seconds * 1000)
        if ($timedOut) { $process.Kill(); $process.WaitForExit() }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $clock.Stop()
        $limit = 20000
        $stdout=[regex]::Replace($stdout,'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))','') -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]',''
        $stderr=[regex]::Replace($stderr,'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))','') -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]',''
        return [pscustomobject][ordered]@{ command_id=$resolved.id; command="$($resolved.executable) $($resolved.argument_text)".Trim(); exit_code=if ($timedOut) { -1 } else { [int]$process.ExitCode }; timed_out=$timedOut; duration_ms=[long]$clock.ElapsedMilliseconds; stdout=if ($stdout.Length -gt $limit) { $stdout.Substring(0,$limit) } else { $stdout }; stderr=if ($stderr.Length -gt $limit) { $stderr.Substring(0,$limit) } else { $stderr } }
    } finally { $process.Dispose() }
}

function Invoke-AgentCommandBatch([object]$Settings, [string]$WorkspaceDirectory, [object[]]$Commands) {
    if(@($Commands).Count -gt 64){throw 'A role may run at most 64 allowlisted commands in one stage.'}
    $resolvedCommands = @($Commands | ForEach-Object { Resolve-AgentAllowedCommand $Settings $_ })
    $results = @()
    foreach ($command in $Commands) { $results += Invoke-AgentAllowedCommand $Settings $WorkspaceDirectory $command }
    return $results
}
