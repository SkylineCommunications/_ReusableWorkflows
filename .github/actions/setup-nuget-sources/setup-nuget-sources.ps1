# Registers the NuGet sources required by Skyline reusable workflows.
# Idempotent: existing sources with the same name are updated in place.
#
# Inputs (via env vars):
#   REPO_OWNER       — the repository owner (used in the GitHub feed URL).
#   GH_TOKEN         — GitHub token for the GitHub Packages feed.
#   AZURE_TOKEN      — PAT for the Skyline Azure DevOps feeds. Optional.
#   INCLUDE_SKYLINE  — 'true' | 'false' | 'auto'. 'auto' enables Skyline feeds
#                      only when REPO_OWNER == 'SkylineCommunications'.
$ErrorActionPreference = 'Stop'

function Register-NuGetSource {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Username,
        [Parameter(Mandatory)] [string] $Password
    )

    if ([string]::IsNullOrEmpty($Password)) {
        Write-Host "Skipping $Name because the password is not set."
        return
    }

    Write-Host "Checking source $Name..."
    $existing = dotnet nuget list source | Select-String -Pattern $Name

    if ($existing) {
        Write-Host "Updating existing source $Name."
        dotnet nuget update source $Name --source $Url --username $Username --password $Password --store-password-in-clear-text
    } else {
        Write-Host "Adding new source $Name."
        dotnet nuget add source $Url --name $Name --username $Username --password $Password --store-password-in-clear-text
    }
}

Register-NuGetSource -Name 'PrivateGitHubNugets' `
    -Url "https://nuget.pkg.github.com/$env:REPO_OWNER/index.json" `
    -Username 'USERNAME' -Password $env:GH_TOKEN

$includeSkyline = switch ($env:INCLUDE_SKYLINE) {
    'true'  { $true }
    'false' { $false }
    default { $env:REPO_OWNER -eq 'SkylineCommunications' }
}

if ($includeSkyline) {
    Register-NuGetSource -Name 'CloudNuGets' `
        -Url 'https://pkgs.dev.azure.com/skyline-cloud/Cloud_NuGets/_packaging/CloudNuGet/nuget/v3/index.json' `
        -Username 'az' -Password $env:AZURE_TOKEN

    Register-NuGetSource -Name 'PrivateAzureNuGets' `
        -Url 'https://pkgs.dev.azure.com/skyline-cloud/_packaging/skyline-private-nugets/nuget/v3/index.json' `
        -Username 'az' -Password $env:AZURE_TOKEN
}
