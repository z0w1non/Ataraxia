Set-StrictMode -Version Latest
$script:AppLanguageTable = $null
$script:AppLanguageCode = 'ja'

function Set-AppLanguage([string]$Language = 'Japanese') {
    $languageCode = switch -Regex ($Language.Trim().ToLowerInvariant()) {
        '^(ja|japanese|日本語)$' { 'ja'; break }
        '^(en|english|英語)$' { 'en'; break }
        default {
            $fallbackPath = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'locales') 'ja.json'
            $script:AppLanguageTable = Get-Content -LiteralPath $fallbackPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:AppLanguageCode = 'ja'
            throw (Get-AppText 'unsupported_language')
        }
    }
    $localePath = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'locales') "$languageCode.json"
    if (-not (Test-Path -LiteralPath $localePath -PathType Leaf)) { throw "Language definition file is missing: $localePath" }
    $script:AppLanguageTable = Get-Content -LiteralPath $localePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:AppLanguageCode = $languageCode
}

function Get-AppText([string]$Key, [object[]]$FormatArgs = @()) {
    $property = if ($null -ne $script:AppLanguageTable) { $script:AppLanguageTable.PSObject.Properties[$Key] } else { $null }
    if ($null -eq $property) { throw "Missing localization key '$Key' for language '$script:AppLanguageCode'." }
    if ($FormatArgs.Count -eq 0) { return [string]$property.Value }
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, [string]$property.Value, $FormatArgs)
}

Set-AppLanguage 'Japanese'
