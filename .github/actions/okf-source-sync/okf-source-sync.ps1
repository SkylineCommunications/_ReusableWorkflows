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

function Unquote {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ''
    }

    $trimmed = $Value.Trim()
    if ($trimmed.Length -ge 2 -and
        (($trimmed.StartsWith("'") -and $trimmed.EndsWith("'")) -or
         ($trimmed.StartsWith('"') -and $trimmed.EndsWith('"')))) {
        return $trimmed.Substring(1, $trimmed.Length - 2)
    }

    return $trimmed
}

function Get-SourceResources {
    param([Parameter(Mandatory = $true)][string]$Path)

    $lines = Get-Content -LiteralPath $Path
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') {
        return @()
    }

    $frontmatter = [System.Collections.Generic.List[string]]::new()
    for ($index = 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index].Trim() -eq '---') {
            break
        }

        $frontmatter.Add($lines[$index])
    }

    $resources = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $frontmatter) {
        if ($line -match '^\s*(?:-\s*)?resource\s*:\s*(?<resource>.+?)\s*$') {
            $resource = Unquote $Matches.resource
            if (-not [string]::IsNullOrWhiteSpace($resource)) {
                $resources.Add($resource)
            }
        }
    }

    return $resources.ToArray()
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

$okfPath = Join-Path $workspace $okfRoot
if (-not (Test-Path -LiteralPath $okfPath -PathType Container)) {
    throw "OKF root '$okfRoot' was not found."
}

$head = (& git -C $workspace rev-parse HEAD).Trim()
$concepts = [System.Collections.Generic.List[object]]::new()
$diagnostics = [System.Collections.Generic.List[object]]::new()
$affected = [System.Collections.Generic.List[object]]::new()

$files = Get-ChildItem -LiteralPath $okfPath -Filter '*.md' -File -Recurse |
    Where-Object { $_.Name -notin @('index.md', 'log.md') } |
    Sort-Object FullName

foreach ($file in $files) {
    $conceptPath = $file.FullName.Substring($okfPath.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Replace('\', '/')
    $resources = @(Get-SourceResources -Path $file.FullName)
    if ($resources.Count -eq 0) {
        continue
    }

    foreach ($resource in $resources) {
        $source = Try-ParseGitHubSource -Resource $resource -ExpectedRepository $sourceRepository -ConceptPath $conceptPath
        $concepts.Add([pscustomobject]@{
            concept = $conceptPath
            resource = $resource
            kind = $source.Kind
        })

        if ($source.Kind -ne 'supported') {
            if ($source.Kind -eq 'unsupported') {
                $diagnostics.Add($source)
            }
            continue
        }

        $commitExists = & git -C $workspace cat-file -e "$($source.Commit)^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) {
            $diagnostics.Add([pscustomobject]@{
                code = 'baseline-unavailable'
                concept = $conceptPath
                resource = $resource
                message = "Reviewed source commit $($source.Commit) is not available in the checkout."
            })
            continue
        }

        $changedPaths = @(& git -C $workspace diff --name-only $source.Commit $head -- $source.Path)
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

$status = if ($diagnostics | Where-Object { $_.code -eq 'baseline-unavailable' -or $_.code -eq 'comparison-failed' }) {
    'blocked'
} elseif ($affected.Count -gt 0) {
    'changes-detected'
} else {
    'no-change'
}

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
        "- Affected concepts: $($affected.Count)",
        "- Diagnostics: $($diagnostics.Count)",
        '',
        'This action is detection-only. It does not generate or publish knowledge changes.'
    ) | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

Write-OutputValue -Name 'status' -Value $status
Write-OutputValue -Name 'affected-concepts' -Value ([string]$affected.Count)
Write-OutputValue -Name 'report-path' -Value ((Resolve-Path -LiteralPath $reportPath).Path)
