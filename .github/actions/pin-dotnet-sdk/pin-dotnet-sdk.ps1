$ErrorActionPreference = 'Stop'

if ($env:DOTNET_SDK_VERSION -notmatch '^10\.0\.\d+$') {
    throw "Expected a stable .NET 10 SDK, but setup-dotnet reported '$env:DOTNET_SDK_VERSION'."
}

$globalJsonPath = Join-Path $env:GITHUB_WORKSPACE 'global.json'
$previousJson = $null
$globalJson = @{}
if (Test-Path -LiteralPath $globalJsonPath) {
    $previousJson = Get-Content -LiteralPath $globalJsonPath -Raw
    $globalJson = $previousJson | ConvertFrom-Json -AsHashtable
}

$globalJson['sdk'] = [ordered]@{
    version = $env:DOTNET_SDK_VERSION
    rollForward = 'disable'
    allowPrerelease = $false
}

$globalJson | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $globalJsonPath -Encoding utf8

if ($null -eq $previousJson) {
    Write-Host 'Created global.json.'
} elseif ($previousJson -ceq (Get-Content -LiteralPath $globalJsonPath -Raw)) {
    Write-Host 'global.json is unchanged.'
} else {
    Write-Host 'Updated global.json.'
}

$loggedConfig = @{ sdk = $globalJson['sdk'] } | ConvertTo-Json -Depth 3
Write-Host "global.json (SDK settings):`n$loggedConfig"
