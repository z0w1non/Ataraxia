Set-StrictMode -Version Latest

function Get-KoboldCppTokenCount([object]$Config, [object]$Value) {
    $uri = New-AgentHttpUri ([string]$Config.api_server) '/api/extra/tokencount'
    $request = if ($Value -is [string]) { @{ prompt=$Value } } else { @{ messages=@($Value) } }
    $body = $request | ConvertTo-Json -Depth 40 -Compress
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 60 -MaximumRedirection 0
    } catch {
        throw "KoboldCpp token counting request failed: $($_.Exception.Message)"
    }
    $countProperty = if ($null -ne $response -and $null -ne $response.PSObject.Properties['value']) { $response.PSObject.Properties['value'] } else { $null }
    if ($null -eq $countProperty -or $countProperty.Value -isnot [ValueType] -or [int]$countProperty.Value -lt 0) {
        throw 'KoboldCpp token counting response did not contain a valid non-negative value.'
    }
    return [int]$countProperty.Value
}

