$ErrorActionPreference = 'Stop'

$actionDirectory = Split-Path -Parent $PSCommandPath
$scriptPath = Join-Path -Path $actionDirectory -ChildPath 'determine-version.ps1'
$temporaryDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "determine-version-$([System.Guid]::NewGuid())"
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
        [Parameter(Mandatory)][string]$RefType,
        [AllowEmptyString()][string]$RefName,
        [Parameter(Mandatory)][string]$RunNumber,
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [Parameter(Mandatory)][string]$ExpectedNumericVersion,
        [Parameter(Mandatory)][string]$ExpectedProductVersion,
        [AllowEmptyString()][string]$ExpectedInformationalVersion = '',
        [AllowEmptyString()][string]$ExpectedPackageVersion = '',
        [bool]$ExpectedProductVersionValid = $true
    )

    $outputFile = Join-Path -Path $script:temporaryDirectory -ChildPath "$([System.Guid]::NewGuid()).txt"
    New-Item -Path $outputFile -ItemType File | Out-Null

    $env:GITHUB_OUTPUT = $outputFile
    $env:REF_TYPE = $RefType
    $env:REF_NAME = $RefName
    $env:RUN_NUMBER = $RunNumber

    try {
        & $script:scriptPath | Out-Null

        $version = Get-OutputValue -Name 'version' -Path $outputFile
        $informationalVersion = Get-OutputValue -Name 'informational-version' -Path $outputFile
        $packageVersion = Get-OutputValue -Name 'package-version' -Path $outputFile
        $numericVersion = Get-OutputValue -Name 'numeric-version' -Path $outputFile
        $productVersion = Get-OutputValue -Name 'product-version' -Path $outputFile
        $productVersionValid = Get-OutputValue -Name 'product-version-valid' -Path $outputFile

        Assert-Equal -Actual $version -Expected $ExpectedVersion -Label "${Name} (version)"
        $expectedInformational = if ([string]::IsNullOrEmpty($ExpectedInformationalVersion)) { $ExpectedVersion } else { $ExpectedInformationalVersion }
        Assert-Equal -Actual $informationalVersion -Expected $expectedInformational -Label "${Name} (informational-version)"
        if (-not [string]::IsNullOrEmpty($ExpectedPackageVersion)) {
            Assert-Equal -Actual $packageVersion -Expected $ExpectedPackageVersion -Label "${Name} (package-version)"
        }
        Assert-Equal -Actual $numericVersion -Expected $ExpectedNumericVersion -Label "${Name} (numeric-version)"
        Assert-Equal -Actual $productVersion -Expected $ExpectedProductVersion -Label "${Name} (product-version)"
        Assert-Equal -Actual $productVersionValid -Expected $ExpectedProductVersionValid.ToString().ToLowerInvariant() -Label "${Name} (product-version-valid)"

        Write-Host "PASS: ${Name}"
    } catch {
        $script:failures++
        Write-Host "FAIL: ${Name} -> $($_.Exception.Message)"
    } finally {
        Remove-Item Env:\REF_TYPE -ErrorAction SilentlyContinue
        Remove-Item Env:\REF_NAME -ErrorAction SilentlyContinue
        Remove-Item Env:\RUN_NUMBER -ErrorAction SilentlyContinue
    }
}

function Invoke-FailureCase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RefType,
        [AllowEmptyString()][string]$RefName,
        [Parameter(Mandatory)][string]$RunNumber
    )

    $outputFile = Join-Path -Path $script:temporaryDirectory -ChildPath "$([System.Guid]::NewGuid()).txt"
    New-Item -Path $outputFile -ItemType File | Out-Null

    $env:GITHUB_OUTPUT = $outputFile
    $env:REF_TYPE = $RefType
    $env:REF_NAME = $RefName
    $env:RUN_NUMBER = $RunNumber

    try {
        & $script:scriptPath | Out-Null
        $script:failures++
        Write-Host "FAIL: ${Name} -> expected the script to throw, but it succeeded."
    } catch {
        Write-Host "PASS: ${Name} (threw: $($_.Exception.Message))"
    } finally {
        Remove-Item Env:\REF_TYPE -ErrorAction SilentlyContinue
        Remove-Item Env:\REF_NAME -ErrorAction SilentlyContinue
        Remove-Item Env:\RUN_NUMBER -ErrorAction SilentlyContinue
    }
}

try {
    # Branch builds keep the legacy 0.0.<run-number> in all modes.
    Invoke-Case -Name 'Branch build'                       -RefType 'branch' -RefName 'dev/my-feature'            -RunNumber '42'    -ExpectedVersion '0.0.42'                 -ExpectedNumericVersion '0.0.42.42'     -ExpectedProductVersion '0.0.42.42'
    Invoke-Case -Name 'Branch build, large run number'     -RefType 'branch' -RefName 'main'                      -RunNumber '70000' -ExpectedVersion '0.0.70000'              -ExpectedNumericVersion '0.0.4465.4465' -ExpectedProductVersion '0.0.4465.4465'

    # Tag builds use the tag name for Version and InformationalVersion; numeric-version strips the suffix + appends the run number.
    Invoke-Case -Name 'Final release tag'                  -RefType 'tag'    -RefName '1.2.3'                     -RunNumber '7'     -ExpectedVersion '1.2.3'                  -ExpectedNumericVersion '1.2.3.7'      -ExpectedProductVersion '1.2.3'
    Invoke-Case -Name 'Manual pre-release tag'             -RefType 'tag'    -RefName '1.4.0-userSuffix'          -RunNumber '98'    -ExpectedVersion '1.4.0-userSuffix'       -ExpectedNumericVersion '1.4.0.98'     -ExpectedProductVersion '1.4.0.98'
    Invoke-Case -Name 'Pre-release tag'                    -RefType 'tag'    -RefName '1.4.0-123.42.a1b2c3d4'     -RunNumber '99'    -ExpectedVersion '1.4.0-123.42.a1b2c3d4'  -ExpectedNumericVersion '1.4.0.99'      -ExpectedProductVersion '1.4.0.99'
    Invoke-Case -Name 'Package-compatible prerelease'      -RefType 'tag'    -RefName '1.4.0-123.42.a1b2c3d4'     -RunNumber '99'    -ExpectedVersion '1.4.0-123.42.a1b2c3d4'  -ExpectedNumericVersion '1.4.0.99'      -ExpectedProductVersion '1.4.0.99' -ExpectedPackageVersion '1.4.0-12342a1b2c3d4'
    Invoke-Case -Name 'Package version drops metadata'     -RefType 'tag'    -RefName '2.3.1+build.5'             -RunNumber '3'     -ExpectedVersion '2.3.1+build.5'          -ExpectedNumericVersion '2.3.1.3'       -ExpectedProductVersion '2.3.1'    -ExpectedPackageVersion '2.3.1'
    Invoke-Case -Name 'Package version prerelease+meta'    -RefType 'tag'    -RefName '1.2.3-rc.1+meta'           -RunNumber '8'     -ExpectedVersion '1.2.3-rc.1+meta'        -ExpectedNumericVersion '1.2.3.8'       -ExpectedProductVersion '1.2.3.8'  -ExpectedPackageVersion '1.2.3-rc1'
    Invoke-Case -Name 'Package version keeps stable tag'   -RefType 'tag'    -RefName '1.2.3'                     -RunNumber '7'     -ExpectedVersion '1.2.3'                  -ExpectedNumericVersion '1.2.3.7'       -ExpectedProductVersion '1.2.3'    -ExpectedPackageVersion '1.2.3'
    Invoke-Case -Name 'Package version branch build'       -RefType 'branch' -RefName 'dev/my-feature'            -RunNumber '42'    -ExpectedVersion '0.0.42'                 -ExpectedNumericVersion '0.0.42.42'     -ExpectedProductVersion '0.0.42.42' -ExpectedPackageVersion '0.0.42'
    Invoke-Case -Name 'Build-metadata tag'                 -RefType 'tag'    -RefName '2.3.1+build.5'             -RunNumber '3'     -ExpectedVersion '2.3.1+build.5'          -ExpectedNumericVersion '2.3.1.3'      -ExpectedProductVersion '2.3.1'
    Invoke-Case -Name 'Pre-release + metadata tag'         -RefType 'tag'    -RefName '1.2.3-rc.1+meta'           -RunNumber '8'     -ExpectedVersion '1.2.3-rc.1+meta'        -ExpectedNumericVersion '1.2.3.8'       -ExpectedProductVersion '1.2.3.8'
    Invoke-Case -Name 'Leading v prefix tolerated'         -RefType 'tag'    -RefName 'v1.2.3'                    -RunNumber '5'     -ExpectedVersion 'v1.2.3'                 -ExpectedNumericVersion '1.2.3.5'      -ExpectedProductVersion '1.2.3'

    # 4-part cores (e.g. date-based tags) keep their own 4th field — the run number is not appended.
    Invoke-Case -Name 'Four-part date tag'                 -RefType 'tag'    -RefName '2026.07.08.230'            -RunNumber '44'    -ExpectedVersion '2026.07.08.230'         -ExpectedNumericVersion '2026.7.8.230'  -ExpectedProductVersion '2026.7.8.230' -ExpectedProductVersionValid $false
    Invoke-Case -Name 'Four-part tag keeps 4th field'      -RefType 'tag'    -RefName '1.2.3.4'                   -RunNumber '99'    -ExpectedVersion '1.2.3.4'                -ExpectedNumericVersion '1.2.3.4'       -ExpectedProductVersion '1.2.3.4'
    Invoke-Case -Name 'Four-part prerelease package'       -RefType 'tag'    -RefName '1.2.3.4-rc.1'              -RunNumber '99'    -ExpectedVersion '1.2.3.4-rc.1'           -ExpectedNumericVersion '1.2.3.4'       -ExpectedProductVersion '1.2.3.4' -ExpectedPackageVersion '1.2.3-4rc1'
    Invoke-Case -Name 'Four-part tag wraps 4th field'      -RefType 'tag'    -RefName '1.2.3.70000'               -RunNumber '7'     -ExpectedVersion '1.2.3.70000'            -ExpectedNumericVersion '1.2.3.4465'    -ExpectedProductVersion '1.2.3.4465'

    # Fields must be < 65535 (assembly-metadata max 65534): wrap-around % 65535, never a clamp.
    Invoke-Case -Name 'Run number 65534 fits'              -RefType 'tag'    -RefName '1.0.0'                     -RunNumber '65534' -ExpectedVersion '1.0.0'                  -ExpectedNumericVersion '1.0.0.65534'  -ExpectedProductVersion '1.0.0'
    Invoke-Case -Name 'Run number wraps at 65535'          -RefType 'tag'    -RefName '1.0.0'                     -RunNumber '65535' -ExpectedVersion '1.0.0'                  -ExpectedNumericVersion '1.0.0.0'      -ExpectedProductVersion '1.0.0'
    Invoke-Case -Name 'Run number 65536 wraps to 1'        -RefType 'tag'    -RefName '1.0.0'                     -RunNumber '65536' -ExpectedVersion '1.0.0'                  -ExpectedNumericVersion '1.0.0.1'      -ExpectedProductVersion '1.0.0'
    Invoke-Case -Name 'Run number above 65536'             -RefType 'tag'    -RefName '1.0.0'                     -RunNumber '70000' -ExpectedVersion '1.0.0'                  -ExpectedNumericVersion '1.0.0.4465'   -ExpectedProductVersion '1.0.0'

    # Windows Installer ProductVersion bounds: major/minor <= 255; build <= 65535.
    Invoke-Case -Name 'ProductVersion maximum fields'      -RefType 'tag'    -RefName '255.255.65535'             -RunNumber '1'     -ExpectedVersion '255.255.65535'          -ExpectedNumericVersion '255.255.0.1'   -ExpectedProductVersion '255.255.65535'
    Invoke-Case -Name 'Prerelease ProductVersion maximum' -RefType 'tag'    -RefName '255.255.65535-rc.1'        -RunNumber '2'     -ExpectedVersion '255.255.65535-rc.1'     -ExpectedNumericVersion '255.255.0.2'   -ExpectedProductVersion '255.255.65535.2'
    Invoke-Case -Name 'ProductVersion major out of range'  -RefType 'tag'    -RefName '256.1.1'                   -RunNumber '1'     -ExpectedVersion '256.1.1'                -ExpectedNumericVersion '256.1.1.1'     -ExpectedProductVersion '256.1.1'       -ExpectedProductVersionValid $false
    Invoke-Case -Name 'ProductVersion minor out of range'  -RefType 'tag'    -RefName '1.256.1'                   -RunNumber '1'     -ExpectedVersion '1.256.1'                -ExpectedNumericVersion '1.256.1.1'     -ExpectedProductVersion '1.256.1'       -ExpectedProductVersionValid $false
    Invoke-Case -Name 'ProductVersion build out of range'  -RefType 'tag'    -RefName '1.1.65536'                 -RunNumber '1'     -ExpectedVersion '1.1.65536'              -ExpectedNumericVersion '1.1.1.1'       -ExpectedProductVersion '1.1.65536'     -ExpectedProductVersionValid $false

    # Failure cases: tags that have no major.minor.patch[.build] core cannot yield a numeric-version.
    Invoke-FailureCase -Name 'Non-SemVer tag rejected'     -RefType 'tag'    -RefName 'release-1'                 -RunNumber '1'
    Invoke-FailureCase -Name 'Two-part tag rejected'       -RefType 'tag'    -RefName '1.2'                       -RunNumber '1'
    Invoke-FailureCase -Name 'Five-part tag rejected'      -RefType 'tag'    -RefName '1.2.3.4.5'                 -RunNumber '1'
    Invoke-FailureCase -Name 'Empty tag name rejected'     -RefType 'tag'    -RefName ''                          -RunNumber '1'

    if ($failures -gt 0) {
        throw "$failures test case(s) failed."
    }

    Write-Host "All determine-version test cases passed."
} finally {
    Remove-Item -Path $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
