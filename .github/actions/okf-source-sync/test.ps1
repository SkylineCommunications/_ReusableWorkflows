$ErrorActionPreference = 'Stop'

$root = Join-Path ([IO.Path]::GetTempPath()) "okf-source-sync-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $root | Out-Null

try {
    & git -C $root init --quiet
    & git -C $root config user.email test@example.invalid
    & git -C $root config user.name 'OKF source sync test'
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'OKF') | Out-Null
    Set-Content -LiteralPath (Join-Path $root 'source.md') -Value 'initial source' -Encoding utf8
    & git -C $root add .
    & git -C $root commit --quiet -m initial
    $baseline = (& git -C $root rev-parse HEAD).Trim()

    @"
---
type: Guidance
title: Example concept
sources:
  - resource: https://github.com/example/example/blob/$baseline/source.md
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
    & git -C $root add .
    & git -C $root commit --quiet -m change

    $outputPath = Join-Path $root 'outputs.txt'
    $reportPath = Join-Path $root 'report.json'
    $scriptPath = Join-Path $PSScriptRoot 'okf-source-sync.ps1'
    $oldWorkspace = $env:GITHUB_WORKSPACE
    $oldRepository = $env:SOURCE_REPOSITORY
    $oldOutput = $env:GITHUB_OUTPUT
    $oldReport = $env:REPORT_PATH
    try {
        $env:GITHUB_WORKSPACE = $root
        $env:SOURCE_REPOSITORY = 'example/example'
        $env:GITHUB_OUTPUT = $outputPath
        $env:REPORT_PATH = $reportPath
        $env:OKF_ROOT = 'OKF'
        $env:DRY_RUN = 'true'
        & pwsh -NoLogo -NoProfile -File $scriptPath
    } finally {
        $env:GITHUB_WORKSPACE = $oldWorkspace
        $env:SOURCE_REPOSITORY = $oldRepository
        $env:GITHUB_OUTPUT = $oldOutput
        $env:REPORT_PATH = $oldReport
    }

    $output = Get-Content -LiteralPath $outputPath -Raw
    if ($output -notmatch 'status=blocked') {
        throw "Expected blocked output for the moving reference. Actual output: $output"
    }

    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    if ($report.status -ne 'blocked') {
        throw "Expected blocked status for moving source references. Actual status: $($report.status)"
    }

    if ($report.affected_concepts.Count -ne 1 -or $report.affected_concepts[0].concept -ne 'concept.md') {
        throw 'Expected exactly one affected concept.'
    }

    if (-not ($report.diagnostics | Where-Object {
            $_.code -eq 'reviewed-commit-required' -and
            $_.concept -eq 'moving-reference.md'
        })) {
        throw 'Expected a reviewed-commit-required diagnostic.'
    }

    Write-Output 'okf-source-sync test passed.'
} finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
