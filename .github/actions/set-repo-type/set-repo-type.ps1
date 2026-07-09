$ErrorActionPreference = 'Stop'

# The enterprise custom property `Workflow-Repo-Type` is a multi-select whose value is an array.
# These are the only values it accepts; input is matched case-insensitively and normalised to these.
$script:AllowedRepoTypes = @('DxM', 'NuGet', 'Connector', 'AppPackage')

# Parse the raw `repo-types` input (a JSON array or a comma-separated list) into a normalised,
# de-duplicated set of canonical values, ordered by $AllowedRepoTypes for a stable, comparable result.
# An empty / whitespace input yields an empty set (the caller then leaves the property unchanged).
function ConvertTo-RepoTypeSet {
    param([AllowNull()][AllowEmptyString()][string]$Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return @()
    }

    $trimmed = $Raw.Trim()
    if ($trimmed.StartsWith('[')) {
        $tokens = @($trimmed | ConvertFrom-Json)
    }
    else {
        $tokens = $trimmed -split ','
    }

    $canonicalByLower = @{}
    foreach ($allowed in $script:AllowedRepoTypes) {
        $canonicalByLower[$allowed.ToLowerInvariant()] = $allowed
    }

    $selected = @{}
    foreach ($token in $tokens) {
        if ($null -eq $token) { continue }
        $value = ([string]$token).Trim()
        if ($value -eq '') { continue }

        $key = $value.ToLowerInvariant()
        if (-not $canonicalByLower.ContainsKey($key)) {
            throw "Invalid repo type '$value'. Allowed values: $($script:AllowedRepoTypes -join ', ')."
        }
        $selected[$canonicalByLower[$key]] = $true
    }

    return @($script:AllowedRepoTypes | Where-Object { $selected.ContainsKey($_) })
}

# Order-insensitive comparison of two value sets, so re-ordering alone never triggers a PATCH.
function Test-RepoTypeSetEqual {
    param(
        [AllowNull()][string[]]$First,
        [AllowNull()][string[]]$Second
    )

    $a = @(@($First) | Sort-Object -CaseSensitive)
    $b = @(@($Second) | Sort-Object -CaseSensitive)
    if ($a.Count -ne $b.Count) { return $false }
    for ($i = 0; $i -lt $a.Count; $i++) {
        if ($a[$i] -ne $b[$i]) { return $false }
    }
    return $true
}

# Build the PATCH body for the per-repo custom-property-values endpoint. `value` is always an array
# (multi-select) — even for a single element (PowerShell 7 preserves single-element arrays).
function ConvertTo-PropertyPatchBody {
    param(
        [Parameter(Mandatory)][string]$PropertyName,
        [Parameter(Mandatory)][string[]]$Value
    )

    $payload = [ordered]@{
        properties = @(
            [ordered]@{
                property_name = $PropertyName
                value         = @($Value)
            }
        )
    }

    return ($payload | ConvertTo-Json -Depth 5)
}

function Invoke-Main {
    if ([string]::IsNullOrWhiteSpace($env:REPOSITORY)) {
        throw 'REPOSITORY must be set (owner/repo).'
    }
    if ([string]::IsNullOrWhiteSpace($env:TOKEN)) {
        throw 'TOKEN must be set. The default GITHUB_TOKEN cannot write custom-property values.'
    }

    $propertyName = if ([string]::IsNullOrWhiteSpace($env:PROPERTY_NAME)) { 'Workflow-Repo-Type' } else { $env:PROPERTY_NAME.Trim() }
    $apiUrl = if ([string]::IsNullOrWhiteSpace($env:GITHUB_API_URL)) { 'https://api.github.com' } else { $env:GITHUB_API_URL.TrimEnd('/') }

    $desired = ConvertTo-RepoTypeSet -Raw $env:REPO_TYPES
    if ($desired.Count -eq 0) {
        Write-Host "No repo type detected; leaving '$propertyName' unchanged."
        return
    }

    $headers = @{
        Authorization          = "Bearer $($env:TOKEN)"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $endpoint = "$apiUrl/repos/$($env:REPOSITORY)/properties/values"

    # Read-before-write: GET returns [] when no value is set yet, so an unset property reads as empty.
    Write-Host "Reading current custom property values from $endpoint ..."
    $current = Invoke-RestMethod -Method Get -Uri $endpoint -Headers $headers
    $currentEntry = @($current) | Where-Object { $_.property_name -eq $propertyName }
    $currentValue = @()
    if ($null -ne $currentEntry -and $null -ne $currentEntry.value) {
        $currentValue = @($currentEntry.value)
    }

    if (Test-RepoTypeSetEqual -First $currentValue -Second $desired) {
        Write-Host "'$propertyName' is already [$($desired -join ', ')]; no update needed."
        return
    }

    Write-Host "Updating '$propertyName' from [$($currentValue -join ', ')] to [$($desired -join ', ')] ..."
    $body = ConvertTo-PropertyPatchBody -PropertyName $propertyName -Value $desired
    Invoke-RestMethod -Method Patch -Uri $endpoint -Headers $headers -Body $body -ContentType 'application/json' | Out-Null
    Write-Host "Updated '$propertyName'."
}

# Run the network logic only when executed directly; test.ps1 dot-sources this file to unit-test the
# pure helper functions (parsing / comparison / body building) without any API calls.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main
}
