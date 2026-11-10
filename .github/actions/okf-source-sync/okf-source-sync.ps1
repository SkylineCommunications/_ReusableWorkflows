$ErrorActionPreference = 'Stop'

function Write-OutputValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
        return
    }

    "$Name=$Value" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

function Get-Python {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        throw 'Python 3.8 or later is required to parse OKF front matter.'
    }

    return $python.Source
}

function Ensure-PyYaml {
    param([Parameter(Mandatory = $true)][string]$Python)

    $dependencyRoot = Join-Path ([IO.Path]::GetTempPath()) 'okf-source-sync-pyyaml-6.0.3'
    $yamlModule = Join-Path $dependencyRoot 'yaml'
    if (-not (Test-Path -LiteralPath $yamlModule -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $dependencyRoot | Out-Null
        $requirements = Join-Path $PSScriptRoot 'requirements.txt'
        & $Python -m pip install --disable-pip-version-check --no-warn-script-location --target $dependencyRoot -r $requirements | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to install the pinned PyYAML dependency into '$dependencyRoot'."
        }
    }

    return $dependencyRoot
}

function Get-SourceMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Python,
        [Parameter(Mandatory = $true)][string]$DependencyRoot
    )

    $oldPythonPath = $env:PYTHONPATH
    try {
        $env:PYTHONPATH = if ([string]::IsNullOrWhiteSpace($oldPythonPath)) {
            $DependencyRoot
        } else {
            "$DependencyRoot$([IO.Path]::PathSeparator)$oldPythonPath"
        }
        $json = & $Python (Join-Path $PSScriptRoot 'parse-frontmatter.py') $Path
    } finally {
        $env:PYTHONPATH = $oldPythonPath
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to parse OKF front matter in '$Path'."
    }

    try {
        return ($json -join "`n") | ConvertFrom-Json
    } catch {
        throw "The OKF front matter parser returned invalid JSON for '$Path'."
    }
}

function Try-ParseGitHubSource {
    param(
        [Parameter(Mandatory = $true)][string]$Resource,
        [Parameter(Mandatory = $true)][string]$ExpectedRepository,
        [Parameter(Mandatory = $true)][string]$ConceptPath
    )

    $uri = $null
    if (-not [Uri]::TryCreate($Resource, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Host -ne 'github.com') {
        return [pscustomobject]@{
            Kind = 'unsupported'
            Resource = $Resource
            ConceptPath = $ConceptPath
            Message = 'Only absolute GitHub blob URLs are supported in this detection increment.'
        }
    }

    $segments = @($uri.AbsolutePath.Trim('/').Split('/'))
    if ($segments.Count -lt 5 -or $segments[2] -ne 'blob') {
        return [pscustomobject]@{
            Kind = 'unsupported'
            Resource = $Resource
            ConceptPath = $ConceptPath
            Message = 'GitHub source URL must use the /owner/repository/blob/commit/path shape.'
        }
    }

    $repository = "$($segments[0])/$($segments[1])"
    if ($repository -ne $ExpectedRepository) {
        return [pscustomobject]@{
            Kind = 'external'
            Resource = $Resource
            ConceptPath = $ConceptPath
            Message = "Source belongs to $repository, not $ExpectedRepository."
        }
    }

    $sourcePath = [Uri]::UnescapeDataString(($segments[4..($segments.Count - 1)] -join '/'))
    if ([string]::IsNullOrWhiteSpace($sourcePath) -or
        $sourcePath.StartsWith('/') -or
        $sourcePath.Split('/') -contains '..') {
        return [pscustomobject]@{
            Kind = 'unsupported'
            Resource = $Resource
            ConceptPath = $ConceptPath
            Message = 'Source path must be a non-empty repository-relative path.'
        }
    }

    return [pscustomobject]@{
        Kind = 'supported'
        Resource = $Resource
        ConceptPath = $ConceptPath
        Repository = $repository
        Commit = $segments[3]
        Path = $sourcePath
    }
}

if ([string]::IsNullOrWhiteSpace($env:GITHUB_WORKSPACE)) {
    throw 'GITHUB_WORKSPACE must be set.'
}

$workspace = (Resolve-Path -LiteralPath $env:GITHUB_WORKSPACE).Path
$python = Get-Python
$dependencyRoot = Ensure-PyYaml -Python $python
$okfRoot = if ([string]::IsNullOrWhiteSpace($env:OKF_ROOT)) { 'OKF' } else { $env:OKF_ROOT }
$sourceRepository = if ([string]::IsNullOrWhiteSpace($env:SOURCE_REPOSITORY)) {
    $env:GITHUB_REPOSITORY
} else {
    $env:SOURCE_REPOSITORY
}
$reportPath = if ([string]::IsNullOrWhiteSpace($env:REPORT_PATH)) {
    'okf-source-sync-report.json'
} elseif ([IO.Path]::IsPathRooted($env:REPORT_PATH)) {
    $env:REPORT_PATH
} else {
    Join-Path $workspace $env:REPORT_PATH
}

$okfPath = [IO.Path]::GetFullPath((Join-Path $workspace $okfRoot))
if (-not (Test-Path -LiteralPath $okfPath -PathType Container)) {
    throw "OKF root '$okfRoot' was not found."
}

$headOutput = & git -C $workspace rev-parse HEAD
$headExitCode = $LASTEXITCODE
if ($headExitCode -ne 0 -or [string]::IsNullOrWhiteSpace(($headOutput -join "`n"))) {
    throw 'Unable to resolve the candidate commit at HEAD.'
}
$head = ($headOutput -join "`n").Trim()
$concepts = [System.Collections.Generic.List[object]]::new()
$diagnostics = [System.Collections.Generic.List[object]]::new()
$affected = [System.Collections.Generic.List[object]]::new()

$files = Get-ChildItem -LiteralPath $okfPath -Filter '*.md' -File -Recurse |
    Where-Object { $_.Name -notin @('index.md', 'log.md') } |
    Sort-Object FullName

foreach ($file in $files) {
    $conceptPath = $file.FullName.Substring($okfPath.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Replace('\', '/')
    $metadata = Get-SourceMetadata -Path $file.FullName -Python $python -DependencyRoot $dependencyRoot
    foreach ($parserDiagnostic in @($metadata.diagnostics)) {
        $diagnostics.Add([pscustomobject]@{
            code = [string]$parserDiagnostic.code
            concept = $conceptPath
            resource = $null
            message = [string]$parserDiagnostic.message
        })
    }

    foreach ($resource in @($metadata.resources)) {
        $source = Try-ParseGitHubSource -Resource $resource -ExpectedRepository $sourceRepository -ConceptPath $conceptPath
        $concepts.Add([pscustomobject]@{
            concept = $conceptPath
            resource = $resource
            kind = $source.Kind
        })

        if ($source.Kind -ne 'supported') {
            $diagnostics.Add([pscustomobject]@{
                code = if ($source.Kind -eq 'external') { 'external-source-unchecked' } else { 'unsupported-source' }
                concept = $conceptPath
                resource = $resource
                message = $source.Message
            })
            continue
        }

        if ($source.Commit -notmatch '^[0-9a-fA-F]{40}$') {
            $diagnostics.Add([pscustomobject]@{
                code = 'reviewed-commit-required'
                concept = $conceptPath
                resource = $resource
                message = "Source reference must use a full 40-character reviewed commit SHA; '$($source.Commit)' is not valid."
            })
            continue
        }

        $commitTypeOutput = & git -C $workspace cat-file -t $source.Commit 2>$null
        $commitTypeExitCode = $LASTEXITCODE
        $commitType = if ($null -eq $commitTypeOutput) {
            ''
        } else {
            ($commitTypeOutput -join "`n").Trim()
        }

        if ($commitTypeExitCode -ne 0) {
            $diagnostics.Add([pscustomobject]@{
                code = 'baseline-unavailable'
                concept = $conceptPath
                resource = $resource
                message = "Reviewed source commit $($source.Commit) is not available in the checkout."
            })
            continue
        }

        if ($commitType -ne 'commit') {
            $diagnostics.Add([pscustomobject]@{
                code = 'reviewed-commit-required'
                concept = $conceptPath
                resource = $resource
                message = "Source reference must identify a commit object; '$($source.Commit)' identifies a $commitType object."
            })
            continue
        }

        $changedPaths = @(& git -C $workspace --literal-pathspecs diff --name-only $source.Commit $head -- $source.Path)
        if ($LASTEXITCODE -ne 0) {
            $diagnostics.Add([pscustomobject]@{
                code = 'comparison-failed'
                concept = $conceptPath
                resource = $resource
                message = "Unable to compare $($source.Path) between $($source.Commit) and $head."
            })
            continue
        }

        if ($changedPaths.Count -gt 0) {
            $affected.Add([pscustomobject]@{
                concept = $conceptPath
                resource = $resource
                reviewed_commit = $source.Commit
                candidate_commit = $head
                source_path = $source.Path
            })
        }
    }
}

$status = if ($diagnostics.Count -gt 0) {
    'blocked'
} elseif ($affected.Count -gt 0) {
    'changes-detected'
} else {
    'no-change'
}

$affectedConceptCount = @($affected | Select-Object -ExpandProperty concept -Unique).Count

$report = [ordered]@{
    schema = 'skyline.okf-source-sync/0.1'
    status = $status
    dry_run = ($env:DRY_RUN -ne 'false')
    repository = $sourceRepository
    okf_root = $okfRoot
    candidate_commit = $head
    concepts_scanned = $files.Count
    declared_sources = $concepts
    affected_concepts = $affected
    diagnostics = $diagnostics
    limitations = @(
        'This increment detects same-repository immutable GitHub blob references only.',
        'It does not generate content, create concepts, modify files, or open pull requests.',
        'Moving branch references and external source providers require an explicit reviewed baseline.'
    )
}

$reportDirectory = Split-Path -Parent $reportPath
if (-not [string]::IsNullOrWhiteSpace($reportDirectory)) {
    New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null
}
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reportPath -Encoding utf8

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    @(
        '### OKF source sync detection',
        "- Status: **$status**",
        "- Candidate commit: $head",
        "- Concepts scanned: $($files.Count)",
        "- Affected concepts: $affectedConceptCount",
        "- Diagnostics: $($diagnostics.Count)",
        '',
        'This action is detection-only. It does not generate or publish knowledge changes.'
    ) | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

Write-OutputValue -Name 'status' -Value $status
Write-OutputValue -Name 'affected-concepts' -Value ([string]$affectedConceptCount)
Write-OutputValue -Name 'report-path' -Value ((Resolve-Path -LiteralPath $reportPath).Path)
exit 0
