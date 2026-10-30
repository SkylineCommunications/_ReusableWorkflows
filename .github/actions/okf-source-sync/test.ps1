$ErrorActionPreference = 'Stop'

$root = Join-Path ([IO.Path]::GetTempPath()) "okf-source-sync-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $root | Out-Null

try {
    & git -C $root init --quiet
    & git -C $root config user.email test@example.invalid
    & git -C $root config user.name 'OKF source sync test'
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'OKF') | Out-Null
    Set-Content -LiteralPath (Join-Path $root 'source.md') -Value 'initial source' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $root 'second-source.md') -Value 'initial second source' -Encoding utf8
    & git -C $root add .
    & git -C $root commit --quiet -m initial
    $baseline = (& git -C $root rev-parse HEAD).Trim()

    @"
---
type: Guidance
title: Example concept
sources:
  - resource: https://github.com/example/example/blob/$baseline/source.md
  - resource: https://github.com/example/example/blob/$baseline/second-source.md
---

Initial projection.
"@ | Set-Content -LiteralPath (Join-Path $root 'OKF\concept.md') -Encoding utf8
@"
---
type: Guidance
title: Moving reference concept
sources:
  - resource: https://github.com/example/example/blob/main/source.md
---

Initial projection.
"@ | Set-Content -LiteralPath (Join-Path $root 'OKF\moving-reference.md') -Encoding utf8
    & git -C $root add .
    & git -C $root commit --quiet -m concept

    Set-Content -LiteralPath (Join-Path $root 'source.md') -Value 'changed source' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $root 'second-source.md') -Value 'changed second source' -Encoding utf8
    & git -C $root add .
    & git -C $root commit --quiet -m change

    $outputPath = Join-Path $root 'outputs.txt'
    $reportPath = Join-Path $root 'report.json'
    $scriptPath = Join-Path $PSScriptRoot 'okf-source-sync.ps1'
    $oldWorkspace = $env:GITHUB_WORKSPACE
    $oldRepository = $env:SOURCE_REPOSITORY
    $oldOutput = $env:GITHUB_OUTPUT
    $oldReport = $env:REPORT_PATH
    $oldSummary = $env:GITHUB_STEP_SUMMARY
    try {
        $env:GITHUB_WORKSPACE = $root
        $env:SOURCE_REPOSITORY = 'example/example'
        $env:GITHUB_OUTPUT = $outputPath
        $env:REPORT_PATH = $reportPath
        $env:GITHUB_STEP_SUMMARY = Join-Path $root 'summary.md'
        $env:OKF_ROOT = 'OKF'
        $env:DRY_RUN = 'true'
        & pwsh -NoLogo -NoProfile -File $scriptPath
    } finally {
        $env:GITHUB_WORKSPACE = $oldWorkspace
        $env:SOURCE_REPOSITORY = $oldRepository
        $env:GITHUB_OUTPUT = $oldOutput
        $env:REPORT_PATH = $oldReport
        $env:GITHUB_STEP_SUMMARY = $oldSummary
    }

    $output = Get-Content -LiteralPath $outputPath -Raw
    if ($output -notmatch 'status=blocked') {
        throw "Expected blocked output for the moving reference. Actual output: $output"
    }

    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    if ($report.status -ne 'blocked') {
        throw "Expected blocked status for moving source references. Actual status: $($report.status)"
    }

    if ($report.affected_concepts.Count -ne 2 -or
        @($report.affected_concepts | Where-Object { $_.concept -eq 'concept.md' }).Count -ne 2) {
        throw 'Expected two changed source entries for one affected concept.'
    }

    if ($output -notmatch 'affected-concepts=1') {
        throw "Expected one distinct affected concept. Actual output: $output"
    }

    if (-not ($report.diagnostics | Where-Object {
            $_.code -eq 'reviewed-commit-required' -and
            $_.concept -eq 'moving-reference.md'
        })) {
        throw 'Expected a reviewed-commit-required diagnostic.'
    }

    @"
---
type: Guidance
title: External concept
sources:
  - resource: https://github.com/other/example/blob/$baseline/source.md
---

External source.
"@ | Set-Content -LiteralPath (Join-Path $root 'OKF\external.md') -Encoding utf8

$env:GITHUB_WORKSPACE = $root
$env:SOURCE_REPOSITORY = 'example/example'
$env:GITHUB_OUTPUT = $outputPath
$env:REPORT_PATH = $reportPath
$env:OKF_ROOT = 'OKF'
$env:DRY_RUN = 'false'
    Remove-Item -LiteralPath $outputPath -Force
    & pwsh -NoLogo -NoProfile -File $scriptPath
    $falseReport = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    if ($falseReport.status -ne 'blocked' -or $falseReport.dry_run) {
        throw 'Expected dry-run false to remain detection-only while reporting false.'
    }

    if (-not ($falseReport.diagnostics | Where-Object {
            $_.code -eq 'external-source-unchecked' -and
            $_.concept -eq 'external.md'
        })) {
        throw 'Expected an external-source-unchecked diagnostic.'
    }

    Write-Output 'okf-source-sync test passed.'
} finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
