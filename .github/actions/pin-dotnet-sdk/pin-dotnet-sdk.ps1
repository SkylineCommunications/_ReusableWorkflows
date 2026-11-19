$ErrorActionPreference = 'Stop'

if ($env:DOTNET_SDK_VERSION -notmatch '^10\.0\.\d+$') {
    throw "Expected a stable .NET 10 SDK, but setup-dotnet reported '$env:DOTNET_SDK_VERSION'."
}

$globalJsonPath = Join-Path $env:GITHUB_WORKSPACE 'global.json'
$globalJson = @{}
if (Test-Path -LiteralPath $globalJsonPath) {
    $globalJson = Get-Content -LiteralPath $globalJsonPath -Raw | ConvertFrom-Json -AsHashtable
}

$globalJson['sdk'] = [ordered]@{
    version = $env:DOTNET_SDK_VERSION
    rollForward = 'disable'
    allowPrerelease = $false
}

$globalJson | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $globalJsonPath -Encoding utf8
