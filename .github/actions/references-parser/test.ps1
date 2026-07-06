$ErrorActionPreference = 'Stop'

$actionDirectory = Split-Path -Parent $PSCommandPath
$temporaryDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "references-parser-$([System.Guid]::NewGuid())"
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

function Assert-JsonEqual {
    param(
        [Parameter(Mandatory)][string]$Actual,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string]$Label
    )

    $actualCanonical = ConvertTo-Json -InputObject (ConvertFrom-Json -InputObject $Actual -NoEnumerate) -Compress -Depth 10
    $expectedCanonical = ConvertTo-Json -InputObject (ConvertFrom-Json -InputObject $Expected -NoEnumerate) -Compress -Depth 10
    if ($actualCanonical -ne $expectedCanonical) {
        throw "${Label}: expected ${expectedCanonical}, got ${actualCanonical}."
    }
}

function Invoke-ParserCase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$Actor,
        [Parameter(Mandatory)][string]$LabelsJson,
        [Parameter(Mandatory)][string]$ExpectedStatus,
        [Parameter(Mandatory)][string]$ExpectedChangeType,
        [Parameter(Mandatory)][string]$ExpectedRnsJson,
        [Parameter(Mandatory)][string]$ExpectedTasksJson,
        [string[]]$ExpectedCommentContains = @(),
        [string[]]$ExpectedCommentMissing = @()
    )

    $caseDirectoryName = $Name -replace '[^A-Za-z0-9]', '_'
    $caseDirectory = Join-Path -Path $temporaryDirectory -ChildPath $caseDirectoryName
    $workspaceDirectory = Join-Path -Path $caseDirectory -ChildPath 'workspace'
    New-Item -Path $workspaceDirectory -ItemType Directory -Force | Out-Null
    $outputFile = Join-Path -Path $caseDirectory -ChildPath 'outputs.txt'
    $summaryFile = Join-Path -Path $caseDirectory -ChildPath 'summary.md'

    $env:PR_BODY = $Body
    $env:ACTOR = $Actor
    $env:LABELS_JSON = $LabelsJson
    $env:COMMENT_HEADER = 'skyline-references'
    $env:GITHUB_OUTPUT = $outputFile
    $env:GITHUB_STEP_SUMMARY = $summaryFile
    $env:GITHUB_WORKSPACE = $workspaceDirectory

    & (Join-Path -Path $actionDirectory -ChildPath 'references-parser.ps1')

    $status = Get-OutputValue -Name 'status' -Path $outputFile
    $changeType = Get-OutputValue -Name 'change-type' -Path $outputFile
    $rns = Get-OutputValue -Name 'rns' -Path $outputFile
    $tasks = Get-OutputValue -Name 'tasks' -Path $outputFile
    $commentFile = Get-OutputValue -Name 'comment-file' -Path $outputFile

    Assert-Equal -Actual $status -Expected $ExpectedStatus -Label "${Name} status"

    if ($ExpectedChangeType -ne '-') {
        Assert-Equal -Actual $changeType -Expected $ExpectedChangeType -Label "${Name} change-type"
    }

    if ($ExpectedRnsJson -ne '-') {
        Assert-JsonEqual -Actual $rns -Expected $ExpectedRnsJson -Label "${Name} rns"
    }

    if ($ExpectedTasksJson -ne '-') {
        Assert-JsonEqual -Actual $tasks -Expected $ExpectedTasksJson -Label "${Name} tasks"
    }

    if (-not (Test-Path -Path $commentFile -PathType Leaf)) {
        throw "${Name}: expected comment file '${commentFile}' to exist."
    }

    if ($ExpectedCommentContains.Count -gt 0 -or $ExpectedCommentMissing.Count -gt 0) {
        $commentText = Get-Content -Path $commentFile -Raw
        foreach ($expected in $ExpectedCommentContains) {
            if (-not $commentText.Contains($expected)) {
                throw "${Name}: expected comment to contain '${expected}'."
            }
        }
        foreach ($forbidden in $ExpectedCommentMissing) {
            if ($commentText.Contains($forbidden)) {
                throw "${Name}: expected comment to NOT contain '${forbidden}'."
            }
        }
    }
}

try {
    Invoke-ParserCase -Name '01 happy path' -Body "References: [RN12] [DCP35]" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'passed' -ExpectedChangeType 'Patch' -ExpectedRnsJson '["RN12"]' -ExpectedTasksJson '["DCP35"]'
    Invoke-ParserCase -Name '02 multiple ids' -Body "References: [RN44205] [DCP284603] [RN4345] [DCP28543]" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'passed' -ExpectedChangeType 'Patch' -ExpectedRnsJson '["RN44205","RN4345"]' -ExpectedTasksJson '["DCP284603","DCP28543"]'
    Invoke-ParserCase -Name '03 references after description' -Body "This PR changes some things.`n`nMore context here.`n`nReferences: [RN12] [DCP35]" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'passed' -ExpectedChangeType 'Patch' -ExpectedRnsJson '["RN12"]' -ExpectedTasksJson '["DCP35"]'
    Invoke-ParserCase -Name '04 missing task regular' -Body "References: [RN12]" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'failed' -ExpectedChangeType '-' -ExpectedRnsJson '-' -ExpectedTasksJson '-'
    Invoke-ParserCase -Name '05 task without rn' -Body "References: [DCP35]" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'failed' -ExpectedChangeType '-' -ExpectedRnsJson '-' -ExpectedTasksJson '-'
    Invoke-ParserCase -Name '06 no references line' -Body 'This pull request has no references.' -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'failed' -ExpectedChangeType '-' -ExpectedRnsJson '-' -ExpectedTasksJson '-'
    Invoke-ParserCase -Name '07 references line empty' -Body "References:" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'failed' -ExpectedChangeType '-' -ExpectedRnsJson '-' -ExpectedTasksJson '-'
    Invoke-ParserCase -Name '08 malformed rn' -Body "References: [R12] [DCP35]" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'failed' -ExpectedChangeType '-' -ExpectedRnsJson '-' -ExpectedTasksJson '-'
    Invoke-ParserCase -Name '09 malformed task' -Body "References: [RN12] [DCP-35]" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'failed' -ExpectedChangeType '-' -ExpectedRnsJson '-' -ExpectedTasksJson '-'
    Invoke-ParserCase -Name '10 dependabot rn only' -Body "References: [RN12]" -Actor 'dependabot[bot]' -LabelsJson '[]' -ExpectedStatus 'passed' -ExpectedChangeType 'Patch' -ExpectedRnsJson '["RN12"]' -ExpectedTasksJson '[]'
    Invoke-ParserCase -Name '11 dependabot branch human actor' -Body "References: [RN12]" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'failed' -ExpectedChangeType '-' -ExpectedRnsJson '-' -ExpectedTasksJson '-'
    Invoke-ParserCase -Name '12 one change type label' -Body "References: [RN12] [DCP35]" -Actor 'human' -LabelsJson '["Change-Type:Minor"]' -ExpectedStatus 'passed' -ExpectedChangeType 'Minor' -ExpectedRnsJson '["RN12"]' -ExpectedTasksJson '["DCP35"]'
    Invoke-ParserCase -Name '13 two change type labels' -Body "References: [RN12] [DCP35]" -Actor 'human' -LabelsJson '["Change-Type:Minor","Change-Type:Major"]' -ExpectedStatus 'failed' -ExpectedChangeType '-' -ExpectedRnsJson '-' -ExpectedTasksJson '-'
    Invoke-ParserCase -Name '14 no change type label' -Body "References: [RN12] [DCP35]" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'passed' -ExpectedChangeType 'Patch' -ExpectedRnsJson '["RN12"]' -ExpectedTasksJson '["DCP35"]'
    Invoke-ParserCase -Name '15 case insensitive' -Body "references: [rn12] [dcp35]" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'passed' -ExpectedChangeType 'Patch' -ExpectedRnsJson '["RN12"]' -ExpectedTasksJson '["DCP35"]'
    Invoke-ParserCase -Name '16 duplicate ids deduped' -Body "References: [RN12] [RN12] [DCP35] [DCP35]" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'passed' -ExpectedChangeType 'Patch' -ExpectedRnsJson '["RN12"]' -ExpectedTasksJson '["DCP35"]'

    # Comment-format cases (lock the sticky-comment structure).
    Invoke-ParserCase -Name '17 comment format happy path' -Body "References: [RN12] [RN13] [DCP35]" -Actor 'human' -LabelsJson '["Change-Type:Minor"]' -ExpectedStatus 'passed' -ExpectedChangeType 'Minor' -ExpectedRnsJson '["RN12","RN13"]' -ExpectedTasksJson '["DCP35"]' -ExpectedCommentContains @(
        '## PR References Validation: ✅ **Passed**',
        '| Status | ✅ |',
        '| Change-Type | Minor |',
        '**Release Notes**',
        '- [RN12](https://collaboration.dataminer.services/releasenotes/12)',
        '- [RN13](https://collaboration.dataminer.services/releasenotes/13)',
        '**Tasks**',
        '- [DCP35](https://collaboration.dataminer.services/task/35)'
    ) -ExpectedCommentMissing @('Dependabot RN-only mode', '| RN(s) | Task(s) |', 'Parsed RN ids')
    Invoke-ParserCase -Name '18 comment format failed' -Body "References: [R12] [DCP35]" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'failed' -ExpectedChangeType '-' -ExpectedRnsJson '-' -ExpectedTasksJson '-' -ExpectedCommentContains @(
        '## PR References Validation: ❌ **Failed**',
        '| Status | ❌ |',
        'Validation errors:'
    )
    Invoke-ParserCase -Name '19 comment format dependabot rn only' -Body "References: [RN12]" -Actor 'dependabot[bot]' -LabelsJson '[]' -ExpectedStatus 'passed' -ExpectedChangeType 'Patch' -ExpectedRnsJson '["RN12"]' -ExpectedTasksJson '[]' -ExpectedCommentContains @(
        '| Dependabot RN-only mode | Yes |',
        '**Release Notes**',
        '- [RN12](https://collaboration.dataminer.services/releasenotes/12)'
    ) -ExpectedCommentMissing @('**Tasks**')
    Invoke-ParserCase -Name '20 comment format dependabot with task' -Body "References: [RN12] [DCP35]" -Actor 'dependabot[bot]' -LabelsJson '[]' -ExpectedStatus 'passed' -ExpectedChangeType 'Patch' -ExpectedRnsJson '["RN12"]' -ExpectedTasksJson '["DCP35"]' -ExpectedCommentContains @(
        '| Dependabot RN-only mode | Yes |',
        '**Tasks**',
        '- [DCP35](https://collaboration.dataminer.services/task/35)'
    )

    Write-Output 'All references-parser cases passed.'
} finally {
    Remove-Item -Path $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}