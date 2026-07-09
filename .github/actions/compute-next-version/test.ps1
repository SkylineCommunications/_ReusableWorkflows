$ErrorActionPreference = 'Stop'

$actionDirectory = Split-Path -Parent $PSCommandPath
$scriptPath = Join-Path -Path $actionDirectory -ChildPath 'compute-next-version.ps1'
$temporaryDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "compute-next-version-$([System.Guid]::NewGuid())"
New-Item -Path $temporaryDirectory -ItemType Directory | Out-Null

function Get-OutputValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path
    )

    $prefix = "${Name}="
    $line = Get-Content -Path $Path | Where-Object { $_.StartsWith($prefix, [System.StringComparison]::Ordinal) } | Select-Object -Last 1
    if ($null -eq $line) {
        return ''
    }

    return $line.Substring($prefix.Length)
}

function Assert-Equal {
    param(
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected,
        [Parameter(Mandatory)][string]$Label
    )

    if ($Actual -ne $Expected) {
        throw "${Label}: expected '${Expected}', got '${Actual}'."
    }
}

$failures = 0

function Invoke-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyCollection()][string[]]$Tags,
        [AllowEmptyString()][string]$ChangeType,
        [Parameter(Mandatory)][string]$Mode,
        [AllowEmptyString()][string]$Suffix,
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedLatestTag
    )

    $outputFile = Join-Path -Path $script:temporaryDirectory -ChildPath "$([System.Guid]::NewGuid()).txt"
    New-Item -Path $outputFile -ItemType File | Out-Null

    $env:GITHUB_OUTPUT = $outputFile
    $env:TAGS_OVERRIDE = ($Tags -join "`n")
    $env:CHANGE_TYPE = $ChangeType
    $env:MODE = $Mode
    $env:SUFFIX = $Suffix

    try {
        & $script:scriptPath | Out-Null

        $version = Get-OutputValue -Name 'version' -Path $outputFile
        $latestTag = Get-OutputValue -Name 'latest-tag' -Path $outputFile

        Assert-Equal -Actual $version -Expected $ExpectedVersion -Label "${Name} (version)"
        Assert-Equal -Actual $latestTag -Expected $ExpectedLatestTag -Label "${Name} (latest-tag)"

        Write-Host "PASS: ${Name}"
    } catch {
        $script:failures++
        Write-Host "FAIL: ${Name} -> $($_.Exception.Message)"
    } finally {
        Remove-Item Env:\TAGS_OVERRIDE -ErrorAction SilentlyContinue
        Remove-Item Env:\CHANGE_TYPE -ErrorAction SilentlyContinue
        Remove-Item Env:\MODE -ErrorAction SilentlyContinue
        Remove-Item Env:\SUFFIX -ErrorAction SilentlyContinue
    }
}

try {
    # Corpus from Auto-Tagging-Technical-Plan.md §Test plan (rows 1-7; rows 8-9 are e2e and need the App).
    Invoke-Case -Name 'Patch bump on 1.3.5'              -Tags @('1.3.5')                -ChangeType 'Patch' -Mode 'release'    -Suffix ''         -ExpectedVersion '1.3.6'            -ExpectedLatestTag '1.3.5'
    Invoke-Case -Name 'Minor bump on 1.3.5'              -Tags @('1.3.5')                -ChangeType 'Minor' -Mode 'release'    -Suffix ''         -ExpectedVersion '1.4.0'            -ExpectedLatestTag '1.3.5'
    Invoke-Case -Name 'Major bump on 1.3.5'              -Tags @('1.3.5')                -ChangeType 'Major' -Mode 'release'    -Suffix ''         -ExpectedVersion '2.0.0'            -ExpectedLatestTag '1.3.5'
    Invoke-Case -Name 'Patch bump, no tags'              -Tags @()                       -ChangeType 'Patch' -Mode 'release'    -Suffix ''         -ExpectedVersion '0.0.1'            -ExpectedLatestTag ''
    Invoke-Case -Name 'Minor bump ignores pre-release'   -Tags @('1.3.5', '1.4.0-dev.1') -ChangeType 'Minor' -Mode 'release'    -Suffix ''         -ExpectedVersion '1.4.0'            -ExpectedLatestTag '1.3.5'
    Invoke-Case -Name 'Minor pre-release with suffix'    -Tags @('1.3.5')                -ChangeType 'Minor' -Mode 'prerelease' -Suffix 'dev-x.42' -ExpectedVersion '1.4.0-dev-x.42'   -ExpectedLatestTag '1.3.5'
    Invoke-Case -Name 'Empty change-type defaults Patch' -Tags @('1.3.5')                -ChangeType ''      -Mode 'release'    -Suffix ''         -ExpectedVersion '1.3.6'            -ExpectedLatestTag '1.3.5'

    # Extra guards beyond the plan corpus.
    Invoke-Case -Name 'Numeric (not lexical) tag sort'   -Tags @('1.9.0', '1.10.0')      -ChangeType 'Patch' -Mode 'release'    -Suffix ''         -ExpectedVersion '1.10.1'           -ExpectedLatestTag '1.10.0'
    Invoke-Case -Name 'Leading v prefix tolerated'       -Tags @('v2.1.0')               -ChangeType 'Minor' -Mode 'release'    -Suffix ''         -ExpectedVersion '2.2.0'            -ExpectedLatestTag 'v2.1.0'
    Invoke-Case -Name 'Release ignores stray suffix'     -Tags @('1.3.5')                -ChangeType 'Patch' -Mode 'release'    -Suffix 'ignored'  -ExpectedVersion '1.3.6'            -ExpectedLatestTag '1.3.5'
    Invoke-Case -Name 'Only pre-release tags exist'      -Tags @('1.4.0-dev.1')          -ChangeType 'Patch' -Mode 'release'    -Suffix ''         -ExpectedVersion '0.0.1'            -ExpectedLatestTag ''

    if ($failures -gt 0) {
        throw "$failures test case(s) failed."
    }

    Write-Host "All compute-next-version test cases passed."
} finally {
    Remove-Item -Path $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
