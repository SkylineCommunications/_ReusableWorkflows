# Fills in an empty `source_code_url:` field in every manifest.yml under a
# CatalogInformation directory with https://github.com/$REPO.
$ErrorActionPreference = 'Stop'

$manifestFiles = Get-ChildItem -Recurse -Filter 'manifest.yml' |
    Where-Object { $_.FullName -match '[\\/]CatalogInformation[\\/]' }

foreach ($file in $manifestFiles) {
    $lines = Get-Content -Path $file.FullName
    $updated = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*source_code_url:\s*$') {
            $indent = ($lines[$i] -match '^(\s*)source_code_url:')[1]
            $lines[$i] = "$indent" + "source_code_url: 'https://github.com/$env:REPO'"
            $updated = $true
            break
        }
    }

    if ($updated) {
        Write-Host "Updating: $($file.FullName) with 'source_code_url: https://github.com/$env:REPO'"
        Set-Content -Path $file.FullName -Value $lines -Encoding UTF8
    }
}
