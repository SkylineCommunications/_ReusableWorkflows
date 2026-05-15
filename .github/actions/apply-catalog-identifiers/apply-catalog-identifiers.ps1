# Rewrites `id:` in manifest.yml files according to $CATALOG_IDENTIFIERS.
# Each mapping is "<manifest path>=<GUID>", one per line. Comment lines (`# ...`)
# starting with '#' inside the manifest are preserved.
$ErrorActionPreference = 'Stop'

$rawMappings = $env:CATALOG_IDENTIFIERS
$mappings = $rawMappings -split '[\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

foreach ($mapping in $mappings) {
    $splitIndex = $mapping.IndexOf('=')
    if ($splitIndex -lt 1 -or $splitIndex -eq ($mapping.Length - 1)) {
        Write-Error "Invalid entry '$mapping'. Expected format: <manifest.yml path>=<id>."
        exit 1
    }

    $manifestPath = $mapping.Substring(0, $splitIndex).Trim()
    $identifier   = $mapping.Substring($splitIndex + 1).Trim()

    if ($identifier -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        Write-Error "Identifier '$identifier' is not a valid GUID."
        exit 1
    }

    if ([System.IO.Path]::GetFileName($manifestPath) -ne 'manifest.yml') {
        Write-Error "Manifest path '$manifestPath' must point to 'manifest.yml'."
        exit 1
    }

    if (-not (Test-Path -Path $manifestPath -PathType Leaf)) {
        Write-Error "Manifest file '$manifestPath' does not exist."
        exit 1
    }

    $content = Get-Content -Path $manifestPath -Raw
    $hasActiveIdLine = [regex]::IsMatch($content, '(?m)^(?!\s*#)\s*id:\s*.*$')

    if (-not $hasActiveIdLine) {
        Write-Error "No active id line found in '$manifestPath'."
        exit 1
    }

    $updatedContent = [regex]::Replace($content, '(?m)^(?!\s*#)\s*id:\s*.*$', "id: $identifier", 1)

    if ($updatedContent -eq $content) {
        Write-Host "'$manifestPath' already has id: $identifier"
    } else {
        Set-Content -Path $manifestPath -Value $updatedContent -NoNewline
        Write-Host "Updated '$manifestPath' to id: $identifier"
    }
}
