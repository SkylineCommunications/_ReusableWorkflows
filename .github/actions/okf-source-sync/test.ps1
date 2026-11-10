$ErrorActionPreference = 'Stop'

$root = Join-Path ([IO.Path]::GetTempPath()) "okf-source-sync-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $root | Out-Null

try {
    & git -C $root init --quiet
    & git -C $root config user.email test@example.invalid
    & git -C $root config user.name 'OKF source sync test'
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'OKF') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'docs') | Out-Null
    Set-Content -LiteralPath (Join-Path $root 'source.md') -Value 'initial source' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $root 'second-source.md') -Value 'initial second source' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $root 'docs\[ab].md') -Value 'unchanged bracket source' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $root 'docs\a.md') -Value 'changed matching source' -Encoding utf8
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
    @"
---
type: Guidance
title: Flow source concept
sources: [{resource: https://github.com/example/example/blob/$baseline/source.md}]
---

Flow source.
"@ | Set-Content -LiteralPath (Join-Path $root 'OKF\flow-source.md') -Encoding utf8
    @"
---
type: Guidance
title: Literal path concept
sources:
  - resource: https://github.com/example/example/blob/$baseline/docs/%5Bab%5D.md
---

Literal path.
"@ | Set-Content -LiteralPath (Join-Path $root 'OKF\literal-path.md') -Encoding utf8
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

    if (@($report.affected_concepts | Where-Object { $_.concept -eq 'concept.md' }).Count -ne 2) {
        throw 'Expected two changed source entries for one affected concept.'
    }

    if ($output -notmatch 'affected-concepts=2') {
        throw "Expected two distinct affected concepts. Actual output: $output"
    }

    if (-not ($report.diagnostics | Where-Object {
            $_.code -eq 'reviewed-commit-required' -and
            $_.concept -eq 'moving-reference.md'
        })) {
        throw 'Expected a reviewed-commit-required diagnostic.'
    }

    if (@($report.affected_concepts | Where-Object { $_.concept -eq 'flow-source.md' }).Count -ne 1) {
        throw 'Expected the flow-style source declaration to be detected.'
    }

    if (@($report.affected_concepts | Where-Object { $_.concept -eq 'literal-path.md' }).Count -ne 0) {
        throw 'Expected the unchanged literal bracket path to remain unaffected.'
    }

    Set-Content -LiteralPath (Join-Path $root 'docs\[ab].md') -Value 'changed bracket source' -Encoding utf8
    & git -C $root add .
    & git -C $root commit --quiet -m 'change literal path'
    $env:GITHUB_WORKSPACE = $root
    $env:SOURCE_REPOSITORY = 'example/example'
    $env:GITHUB_OUTPUT = $outputPath
    $env:REPORT_PATH = $reportPath
    $env:OKF_ROOT = 'OKF'
    $env:DRY_RUN = 'true'
    Remove-Item -LiteralPath $outputPath -Force
    & pwsh -NoLogo -NoProfile -File $scriptPath
    $literalReport = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    if (@($literalReport.affected_concepts | Where-Object { $_.concept -eq 'literal-path.md' }).Count -ne 1) {
        throw 'Expected the changed literal bracket path to be detected.'
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

    $missingCommit = '0000000000000000000000000000000000000000'
    @"
---
type: Guidance
title: Missing baseline concept
sources:
  - resource: https://github.com/example/example/blob/$missingCommit/source.md
---

Missing baseline.
"@ | Set-Content -LiteralPath (Join-Path $root 'OKF\missing-baseline.md') -Encoding utf8

    Remove-Item -LiteralPath $outputPath -Force
    & pwsh -NoLogo -NoProfile -File $scriptPath
    if ($LASTEXITCODE -ne 0) {
        throw "Expected handled baseline diagnostics to exit successfully. Exit code: $LASTEXITCODE"
    }
    $missingReport = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    if ($missingReport.status -ne 'blocked' -or
        -not ($missingReport.diagnostics | Where-Object {
            $_.code -eq 'baseline-unavailable' -and
            $_.concept -eq 'missing-baseline.md'
        })) {
        throw 'Expected a baseline-unavailable diagnostic without a script failure.'
    }

    $blob = (& git -C $root hash-object (Join-Path $root 'source.md')).Trim()
    @"
---
type: Guidance
title: Non-commit baseline concept
sources:
  - resource: https://github.com/example/example/blob/$blob/source.md
---

Non-commit baseline.
"@ | Set-Content -LiteralPath (Join-Path $root 'OKF\non-commit-baseline.md') -Encoding utf8

    Remove-Item -LiteralPath $outputPath -Force
    & pwsh -NoLogo -NoProfile -File $scriptPath
    $nonCommitReport = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    if ($nonCommitReport.status -ne 'blocked' -or
        -not ($nonCommitReport.diagnostics | Where-Object {
            $_.code -eq 'reviewed-commit-required' -and
            $_.concept -eq 'non-commit-baseline.md' -and
            $_.message -match 'blob object'
        })) {
        throw 'Expected a reviewed-commit-required diagnostic for a blob object.'
    }

    @"
---
type: Guidance
title: Partial source concept
sources:
  - resource: https://github.com/example/example/blob/$baseline/source.md
  - invalid
---

Partial source.
"@ | Set-Content -LiteralPath (Join-Path $root 'OKF\partial-source.md') -Encoding utf8
    @"
---
type: Guidance
title: Duplicate key concept
sources:
  - resource: https://github.com/example/example/blob/$baseline/source.md
sources: []
---

Duplicate key.
"@ | Set-Content -LiteralPath (Join-Path $root 'OKF\duplicate-key.md') -Encoding utf8

    Remove-Item -LiteralPath $outputPath -Force
    & pwsh -NoLogo -NoProfile -File $scriptPath
    $parserReport = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    if ($parserReport.status -ne 'blocked') {
        throw 'Expected blocked status for unsupported and duplicate source declarations.'
    }

    if (-not ($parserReport.diagnostics | Where-Object {
            $_.code -eq 'unsupported-source-declaration' -and
            $_.concept -eq 'partial-source.md'
        })) {
        throw 'Expected an unsupported-source-declaration diagnostic.'
    }

    if (-not ($parserReport.diagnostics | Where-Object {
            $_.code -eq 'invalid-frontmatter' -and
            $_.concept -eq 'duplicate-key.md'
        })) {
        throw 'Expected an invalid-frontmatter diagnostic for duplicate keys.'
    }

    if (-not ($parserReport.affected_concepts | Where-Object { $_.concept -eq 'partial-source.md' })) {
        throw 'Expected valid partial source results to be retained.'
    }

    $unborn = Join-Path $root 'unborn'
    New-Item -ItemType Directory -Force -Path (Join-Path $unborn 'OKF') | Out-Null
    & git -C $unborn init --quiet
    @"
---
type: Guidance
title: Unborn repository concept
sources: []
---

Unborn repository.
"@ | Set-Content -LiteralPath (Join-Path $unborn 'OKF\concept.md') -Encoding utf8
    $env:GITHUB_WORKSPACE = $unborn
    $env:SOURCE_REPOSITORY = 'example/example'
    $env:GITHUB_OUTPUT = Join-Path $unborn 'outputs.txt'
    $env:REPORT_PATH = Join-Path $unborn 'report.json'
    $env:OKF_ROOT = 'OKF'
    $env:DRY_RUN = 'true'
    & pwsh -NoLogo -NoProfile -File $scriptPath
    if ($LASTEXITCODE -eq 0) {
        throw 'Expected an invalid candidate HEAD to fail explicitly.'
    }

    Write-Output 'okf-source-sync test passed.'
} finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
