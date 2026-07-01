# Registers a GitHub Packages NuGet source for a GitHub organization.
$ErrorActionPreference = 'Stop'

function ConvertTo-NuGetSourceName {
    param(
        [Parameter(Mandatory)] [string] $Value
    )

    $sourceName = $Value.Trim() -replace '[^A-Za-z0-9_.-]+', '-'
    $sourceName = $sourceName.Trim('-')

    if ([string]::IsNullOrWhiteSpace($sourceName)) {
        return 'github-nuget-source'
    }

    return "github-$sourceName"
}

$organization = ([string] $env:ORGANIZATION).Trim()
$token = ([string] $env:TOKEN).Trim()
$sourceName = ([string] $env:SOURCE_NAME).Trim()

if ([string]::IsNullOrWhiteSpace($organization)) {
    throw 'Input organization is required.'
}

if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'Input token is required.'
}

if ([string]::IsNullOrWhiteSpace($sourceName)) {
    $sourceName = ConvertTo-NuGetSourceName -Value $organization
}

$url = "https://nuget.pkg.github.com/$organization/index.json"
$username = 'USERNAME'

Write-Host "Checking source $sourceName..."
$existing = dotnet nuget list source | Select-String -Pattern $sourceName -SimpleMatch

if ($existing) {
    Write-Host "Updating existing source $sourceName."
    dotnet nuget update source $sourceName --source $url --username $username -p $token --store-password-in-clear-text
} else {
    Write-Host "Adding new source $sourceName."
    dotnet nuget add source $url --name $sourceName --username $username -p $token --store-password-in-clear-text
}