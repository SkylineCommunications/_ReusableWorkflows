$ErrorActionPreference = 'Stop'

$actionDirectory = Split-Path -Parent $PSCommandPath
$temporaryDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "exempt-change-detector-$([System.Guid]::NewGuid())"
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

# Default patterns mirror the action.yml default so tests exercise the real configuration.
$defaultPatterns = @(
    '.github/**'
    '**/*Tests/**'
    '**/*.Tests/**'
) -join "`n"

function Invoke-DetectorCase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ChangedFiles,
        [Parameter(Mandatory)][string]$ExpectedExempt,
        [string]$Patterns = $defaultPatterns
    )

    $caseDirectoryName = $Name -replace '[^A-Za-z0-9]', '_'
    $caseDirectory = Join-Path -Path $temporaryDirectory -ChildPath $caseDirectoryName
    New-Item -Path $caseDirectory -ItemType Directory -Force | Out-Null
    $outputFile = Join-Path -Path $caseDirectory -ChildPath 'outputs.txt'

    $env:CHANGED_FILES = $ChangedFiles
    $env:PATTERNS = $Patterns
    $env:GITHUB_OUTPUT = $outputFile

    & (Join-Path -Path $actionDirectory -ChildPath 'exempt-change-detector.ps1') | Out-Null

    $exempt = Get-OutputValue -Name 'exempt' -Path $outputFile
    Assert-Equal -Actual $exempt -Expected $ExpectedExempt -Label "${Name} exempt"
}

try {
    Invoke-DetectorCase -Name '01 workflow only' -ChangedFiles ".github/workflows/ci.yml" -ExpectedExempt 'true'
    Invoke-DetectorCase -Name '02 github config file' -ChangedFiles ".github/dependabot.yml" -ExpectedExempt 'true'
    Invoke-DetectorCase -Name '03 github nested action' -ChangedFiles ".github/actions/foo/action.yml" -ExpectedExempt 'true'
    Invoke-DetectorCase -Name '04 unit test project folder' -ChangedFiles "src/MyProject.Tests/FooTests.cs" -ExpectedExempt 'true'
    Invoke-DetectorCase -Name '05 unit test project suffix' -ChangedFiles "src/MyProjectTests/FooTests.cs" -ExpectedExempt 'true'
    Invoke-DetectorCase -Name '06 all exempt mixed' -ChangedFiles ".github/workflows/ci.yml`nsrc/MyProject.Tests/FooTests.cs" -ExpectedExempt 'true'
    Invoke-DetectorCase -Name '07 source code not exempt' -ChangedFiles "src/MyProject/Foo.cs" -ExpectedExempt 'false'
    Invoke-DetectorCase -Name '08 mixed source and exempt' -ChangedFiles ".github/workflows/ci.yml`nsrc/MyProject/Foo.cs" -ExpectedExempt 'false'
    Invoke-DetectorCase -Name '09 empty change set' -ChangedFiles "" -ExpectedExempt 'false'
    Invoke-DetectorCase -Name '10 blank lines only' -ChangedFiles "`n  `n" -ExpectedExempt 'false'
    Invoke-DetectorCase -Name '11 case insensitive tests' -ChangedFiles "src/MyProject.tests/footests.cs" -ExpectedExempt 'true'
    Invoke-DetectorCase -Name '12 test file at repo root not matched by folder pattern' -ChangedFiles "FooTests.cs" -ExpectedExempt 'false'
    Invoke-DetectorCase -Name '13 non-test cs under tests-like name' -ChangedFiles "src/Testing/Foo.cs" -ExpectedExempt 'false'
    Invoke-DetectorCase -Name '14 docs not exempt by default' -ChangedFiles "README.md" -ExpectedExempt 'false'

    Write-Output 'All exempt-change-detector cases passed.'
} finally {
    Remove-Item -Path $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
