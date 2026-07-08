$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    throw 'GITHUB_OUTPUT must be set.'
}

$refType = if ($null -eq $env:REF_TYPE) { '' } else { $env:REF_TYPE.Trim().ToLowerInvariant() }
$refName = if ($null -eq $env:REF_NAME) { '' } else { $env:REF_NAME.Trim() }

if ([string]::IsNullOrWhiteSpace($env:RUN_NUMBER)) {
    throw 'RUN_NUMBER must be set.'
}
$runNumber = [long]$env:RUN_NUMBER.Trim()
if ($runNumber -lt 0) {
    throw "RUN_NUMBER must be non-negative, got '$runNumber'."
}

# Tag builds use the tag name verbatim; branch builds keep the legacy 0.0.<run-number>.
if ($refType -eq 'tag') {
    if ([string]::IsNullOrWhiteSpace($refName)) {
        throw 'REF_NAME must be set for tag builds.'
    }
    $version = $refName
} else {
    $version = "0.0.$runNumber"
}

# numeric-version: strip any pre-release/build suffix (-… / +…) down to major.minor.patch,
# then append the run number as the 4th field. Assembly metadata restricts each version
# field to UInt16.MaxValue - 1 (65534) — every field must be strictly less than 65535 — so
# every field is wrapped into range by subtracting 65535 until it fits (value % 65535).
# A wrap-around, not a clamp, so the value keeps changing across runs instead of sticking
# at the ceiling. This also covers the legacy branch version 0.0.<run-number>, whose patch
# field is the (unbounded) run number.
$core = ($version -split '[-+]', 2)[0]
$match = [regex]::Match($core, '^v?(\d+)\.(\d+)\.(\d+)$')
if (-not $match.Success) {
    throw "Cannot derive numeric-version: '$version' does not start with a major.minor.patch core."
}

$numericVersion = '{0}.{1}.{2}.{3}' -f `
    ([long]$match.Groups[1].Value % 65535), `
    ([long]$match.Groups[2].Value % 65535), `
    ([long]$match.Groups[3].Value % 65535), `
    ($runNumber % 65535)

Write-Host "Determined version '$version' and numeric-version '$numericVersion' (ref-type: $refType, run-number: $runNumber)."

@(
    "version=$version"
    "numeric-version=$numericVersion"
) | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
