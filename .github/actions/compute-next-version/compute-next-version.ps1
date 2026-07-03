$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    throw 'GITHUB_OUTPUT must be set.'
}

$changeTypeRaw = if ([string]::IsNullOrWhiteSpace($env:CHANGE_TYPE)) { 'Patch' } else { $env:CHANGE_TYPE.Trim() }
$mode = if ([string]::IsNullOrWhiteSpace($env:MODE)) { 'release' } else { $env:MODE.Trim().ToLowerInvariant() }
$suffix = if ($null -eq $env:SUFFIX) { '' } else { $env:SUFFIX.Trim() }

switch -Regex ($changeTypeRaw) {
    '^(?i)patch$' { $changeType = 'Patch' }
    '^(?i)minor$' { $changeType = 'Minor' }
    '^(?i)major$' { $changeType = 'Major' }
    default { throw "Unsupported change-type '$changeTypeRaw' (expected Patch, Minor, or Major)." }
}

if ($mode -ne 'release' -and $mode -ne 'prerelease') {
    throw "Unsupported mode '$mode' (expected release or prerelease)."
}

# TAGS_OVERRIDE (newline-separated) lets the unit tests inject a tag corpus without a git
# repository. When it is unset the tags are read from the checked-out repository instead.
function Get-Tags {
    if ($null -ne $env:TAGS_OVERRIDE) {
        return @([System.Text.RegularExpressions.Regex]::Split($env:TAGS_OVERRIDE, "`r?`n") |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    git fetch --tags --force --quiet 2>$null | Out-Null
    $tags = git tag --list 2>$null
    if ($null -eq $tags) {
        return @()
    }

    return @($tags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

# The latest FINAL tag is the highest X.Y.Z with no pre-release suffix. An optional leading
# 'v' is tolerated, but pre-release tags (anything containing '-') are ignored on purpose.
$finalPattern = '^v?(\d+)\.(\d+)\.(\d+)$'
$latestTag = ''
$latestVersion = $null

foreach ($tag in (Get-Tags)) {
    $candidate = $tag.Trim()
    $match = [regex]::Match($candidate, $finalPattern)
    if (-not $match.Success) {
        continue
    }

    $version = [version]::new([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
    if ($null -eq $latestVersion -or $version -gt $latestVersion) {
        $latestVersion = $version
        $latestTag = $candidate
    }
}

if ($null -eq $latestVersion) {
    $major = 0
    $minor = 0
    $patch = 0
} else {
    $major = $latestVersion.Major
    $minor = $latestVersion.Minor
    $patch = $latestVersion.Build
}

switch ($changeType) {
    'Major' { $major += 1; $minor = 0; $patch = 0 }
    'Minor' { $minor += 1; $patch = 0 }
    'Patch' { $patch += 1 }
}

$computed = "$major.$minor.$patch"
if ($mode -eq 'prerelease' -and -not [string]::IsNullOrWhiteSpace($suffix)) {
    $computed = "$computed-$suffix"
}

$baseDescription = if ([string]::IsNullOrWhiteSpace($latestTag)) { '<none>' } else { $latestTag }
Write-Host "Computed version '$computed' (base final tag: $baseDescription, change-type: $changeType, mode: $mode)."

@(
    "version=$computed"
    "latest-tag=$latestTag"
) | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
