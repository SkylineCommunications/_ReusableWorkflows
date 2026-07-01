# Registers an Azure DevOps NuGet source by URL.
$ErrorActionPreference = 'Stop'

function ConvertTo-NuGetSourceName {
    param(
        [Parameter(Mandatory)] [string] $Value
    )

    $sourceName = $Value.Trim() -replace '^https?://', ''
    $sourceName = $sourceName -replace '/nuget/v3/index\.json$', ''
    $sourceName = $sourceName -replace '[^A-Za-z0-9_.-]+', '-'
    $sourceName = $sourceName.Trim('-')

    if ([string]::IsNullOrWhiteSpace($sourceName)) {
        return 'azure-nuget-source'
    }

    return "azure-$sourceName"
}

$url = ([string] $env:URL).Trim()
$token = ([string] $env:TOKEN).Trim()
$sourceName = ([string] $env:SOURCE_NAME).Trim()

if ([string]::IsNullOrWhiteSpace($url)) {
    throw 'Input url is required.'
}

if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'Input token is required.'
}

if ([string]::IsNullOrWhiteSpace($sourceName)) {
    $sourceName = ConvertTo-NuGetSourceName -Value $url
}

$username = 'az'

Write-Host "Checking source $sourceName..."
$existing = dotnet nuget list source | Select-String -Pattern $sourceName -SimpleMatch

if ($existing) {
    Write-Host "Updating existing source $sourceName."
    dotnet nuget update source $sourceName --source $url --username $username -p $token --store-password-in-clear-text
} else {
    Write-Host "Adding new source $sourceName."
    dotnet nuget add source $url --name $sourceName --username $username -p $token --store-password-in-clear-text
}