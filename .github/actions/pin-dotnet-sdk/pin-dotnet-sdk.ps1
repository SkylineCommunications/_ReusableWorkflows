param([switch]$Detect)

$ErrorActionPreference = 'Stop'

$globalJsonPath = Join-Path $env:GITHUB_WORKSPACE 'global.json'
$previousJson = $null
$globalJson = @{}
if (Test-Path -LiteralPath $globalJsonPath) {
    $previousJson = Get-Content -LiteralPath $globalJsonPath -Raw
    $globalJson = $previousJson | ConvertFrom-Json -AsHashtable
}

$sdkVersion = $globalJson.sdk.version
if ($null -ne $sdkVersion) {
    if ($sdkVersion -isnot [string] -or $sdkVersion -cnotmatch '\A[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?\z') {
        throw 'global.json sdk.version must be a full .NET SDK version (for example 10.0.404 or 11.0.100-preview.1).'
    }

    Write-Host "Leaving global.json unchanged; using its requested SDK version $sdkVersion."
    if ($Detect) {
        "version=$sdkVersion" >> $env:GITHUB_OUTPUT
    }
    return
}

if ($Detect) {
    Write-Host 'No SDK version specified in global.json; defaulting to .NET 10.'
    return
}

if ($env:DOTNET_SDK_VERSION -notmatch '^10\.0\.\d+$') {
    throw "Expected a stable .NET 10 SDK, but setup-dotnet reported '$env:DOTNET_SDK_VERSION'."
}

$globalJson['sdk'] = [ordered]@{
    version = $env:DOTNET_SDK_VERSION
    rollForward = 'disable'
    allowPrerelease = $false
}

$globalJson | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $globalJsonPath -Encoding utf8

if ($null -eq $previousJson) {
    Write-Host 'Created global.json.'
} else {
    Write-Host 'Updated global.json.'
}

$loggedConfig = @{ sdk = $globalJson['sdk'] } | ConvertTo-Json -Depth 3
Write-Host "global.json (SDK settings):`n$loggedConfig"
