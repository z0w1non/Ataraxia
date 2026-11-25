Set-StrictMode -Version Latest

function New-AppLogEvent([string]$Kind, [System.Collections.IDictionary]$Data, [string]$Level = 'info') {
    return [pscustomobject][ordered]@{
        timestamp = [DateTime]::UtcNow.ToString('o')
        level = $Level
        kind = $Kind
        data = $Data
    }
}

function Convert-AppLogEvent([object]$Event) {
    switch ([string]$Event.kind) {
        'run' { return [pscustomobject]@{ channel='host'; text="Run: $($Event.data.role)"; body=''; color='Yellow'; body_color='DarkYellow' } }
        'input' { return [pscustomobject]@{ channel='host'; text='Input:'; body=[string]$Event.data.content; color='Cyan'; body_color='DarkCyan' } }
        'output' { return [pscustomobject]@{ channel='host'; text='Output:'; body=[string]$Event.data.content; color='Magenta'; body_color='DarkMagenta' } }
        'diff' {
            $pairs = @($Event.data.Keys | ForEach-Object { "$_=$($Event.data[$_])" })
            return [pscustomobject]@{ channel='host'; text=('Diff: ' + ($pairs -join '; ')); body=''; color='Blue'; body_color='DarkBlue' }
        }
        'decision_summary' {
            $pairs = @($Event.data.Keys | ForEach-Object { $value=$Event.data[$_]; if ($value -is [bool]) { $value=$value.ToString().ToLowerInvariant() }; "$_=$value" })
            return [pscustomobject]@{ channel='host'; text=('Decision: ' + ($pairs -join '; ')); body=''; color='Green'; body_color='DarkGreen' }
        }
        'context_compression' {
            $pairs = @($Event.data.Keys | ForEach-Object { "$_=$($Event.data[$_])" })
            return [pscustomobject]@{ channel='host'; text=('Context: ' + ($pairs -join '; ')); body=''; color='DarkCyan'; body_color='DarkCyan' }
        }
        'result' {
            $pairs = @($Event.data.Keys | ForEach-Object {
                $value = $Event.data[$_]
                $renderedValue = if ($value -is [bool]) { $value.ToString().ToLowerInvariant() } elseif ($null -eq $value) { 'null' } else { [string]$value }
                "$_=$renderedValue"
            })
            return [pscustomobject]@{ channel='success'; text=('Result: ' + ($pairs -join '; ')); body=''; color=''; body_color='' }
        }
        default { throw "Unknown log event kind '$($Event.kind)'." }
    }
}

function Write-AppLogEvent([object]$Event) {
    $rendered = Convert-AppLogEvent $Event
    if ($rendered.channel -eq 'success') { Write-Output $rendered.text; return }
    Write-Host $rendered.text -ForegroundColor $rendered.color
    if (-not [string]::IsNullOrEmpty([string]$rendered.body)) { Write-Host $rendered.body -ForegroundColor $rendered.body_color }
}
