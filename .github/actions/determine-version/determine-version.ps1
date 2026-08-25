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
$informationalVersion = $version

# The DataMiner package SDK accepts prerelease versions only in the form
# A.B.C-suffix. Normalize punctuation in the suffix and fold a fourth numeric
# field into the suffix so package creation accepts all valid build versions.
$packageVersion = $version
if ($version -match '^v?(\d+)\.(\d+)\.(\d+)\.(\d+)-(.+)$') {
    $normalizedSuffix = $Matches[5] -replace '[^0-9A-Za-z_]', '_'
    $packageVersion = "$($Matches[1]).$($Matches[2]).$($Matches[3])-$($Matches[4])_$normalizedSuffix"
} elseif ($version -match '^(.+?)-(.+)$') {
    $packageVersion = "$($Matches[1])-$($Matches[2] -replace '[^0-9A-Za-z_]', '_')"
}

# numeric-version: strip any pre-release/build suffix (-… / +…) down to the numeric core,
# then ensure 4 fields. A 3-field core (major.minor.patch — SemVer tags) gets the run
# number appended as the 4th field; a 4-field core (e.g. date-based tags like
# 2026.07.08.230) already carries its own 4th field, which is kept (run number unused).
# Assembly metadata restricts each version field to UInt16.MaxValue - 1 (65534) — every
# field must be strictly less than 65535 — so every field is wrapped into range by
# subtracting 65535 until it fits (value % 65535). A wrap-around, not a clamp, so the
# value keeps changing across runs instead of sticking at the ceiling. This also covers
# the legacy branch version 0.0.<run-number>, whose patch field is the (unbounded) run
# number.
$core = ($version -split '[-+]', 2)[0]
$match = [regex]::Match($core, '^v?(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?$')
if (-not $match.Success) {
    throw "Cannot derive numeric-version: '$version' does not start with a major.minor.patch[.build] core."
}

$fourthField = if ($match.Groups[4].Success) { [long]$match.Groups[4].Value } else { $runNumber }

$numericVersion = '{0}.{1}.{2}.{3}' -f `
    ([long]$match.Groups[1].Value % 65535), `
    ([long]$match.Groups[2].Value % 65535), `
    ([long]$match.Groups[3].Value % 65535), `
    ($fourthField % 65535)

# Windows Installer evaluates major.minor.build and ignores a fourth field. We retain
# that fourth field for prerelease/branch identification in our package conventions,
# while stable three-part tags use the natural three-field ProductVersion.
# MSI limits differ from assembly metadata: major/minor <= 255 and build <= 65535.
$productMajor = [long]$match.Groups[1].Value
$productMinor = [long]$match.Groups[2].Value
$productBuild = [long]$match.Groups[3].Value
$isStableThreePartTag = $refType -eq 'tag' -and -not $version.Contains('-') -and -not $match.Groups[4].Success
$productVersion = if ($isStableThreePartTag) {
    '{0}.{1}.{2}' -f $productMajor, $productMinor, $productBuild
} elseif ($refType -eq 'tag') {
    $numericFourthField = $numericVersion.Split('.')[3]
    '{0}.{1}.{2}.{3}' -f $productMajor, $productMinor, $productBuild, $numericFourthField
} else {
    $numericVersion
}
$productVersionValid = if ($refType -eq 'tag') {
    $productMajor -le 255 -and $productMinor -le 255 -and $productBuild -le 65535
} else {
    $true
}

Write-Host "Determined version '$version', informational-version '$informationalVersion', numeric-version '$numericVersion', and product-version '$productVersion' (valid: $($productVersionValid.ToString().ToLowerInvariant()), ref-type: $refType, run-number: $runNumber)."

@(
    "version=$version"
    "informational-version=$informationalVersion"
    "package-version=$packageVersion"
    "numeric-version=$numericVersion"
    "product-version=$productVersion"
    "product-version-valid=$($productVersionValid.ToString().ToLowerInvariant())"
) | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
