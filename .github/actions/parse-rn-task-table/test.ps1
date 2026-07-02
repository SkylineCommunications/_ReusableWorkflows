$ErrorActionPreference = 'Stop'

$actionDirectory = Split-Path -Parent $PSCommandPath
$temporaryDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "parse-rn-task-table-$([System.Guid]::NewGuid())"
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
        [Parameter(Mandatory)][string]$ExpectedPairCount,
        [Parameter(Mandatory)][string]$ExpectedRnsJson,
        [Parameter(Mandatory)][string]$ExpectedPairsJson
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
    $env:COMMENT_HEADER = 'skyline-rn-task'
    $env:GITHUB_OUTPUT = $outputFile
    $env:GITHUB_STEP_SUMMARY = $summaryFile
    $env:GITHUB_WORKSPACE = $workspaceDirectory

    & (Join-Path -Path $actionDirectory -ChildPath 'parse-rn-task-table.ps1')

    $status = Get-OutputValue -Name 'status' -Path $outputFile
    $changeType = Get-OutputValue -Name 'change-type' -Path $outputFile
    $rns = Get-OutputValue -Name 'rns' -Path $outputFile
    $pairs = Get-OutputValue -Name 'pairs' -Path $outputFile
    $commentFile = Get-OutputValue -Name 'comment-file' -Path $outputFile

    Assert-Equal -Actual $status -Expected $ExpectedStatus -Label "${Name} status"

    if ($ExpectedChangeType -ne '-') {
        Assert-Equal -Actual $changeType -Expected $ExpectedChangeType -Label "${Name} change-type"
    }

    if ($ExpectedPairCount -ne '-') {
        $pairCount = @((ConvertFrom-Json -InputObject $pairs -NoEnumerate)).Count
        Assert-Equal -Actual $pairCount -Expected ([int]$ExpectedPairCount) -Label "${Name} pair count"
    }

    if ($ExpectedRnsJson -ne '-') {
        Assert-JsonEqual -Actual $rns -Expected $ExpectedRnsJson -Label "${Name} rns"
    }

    if ($ExpectedPairsJson -ne '-') {
        Assert-JsonEqual -Actual $pairs -Expected $ExpectedPairsJson -Label "${Name} pairs"
    }

    if (-not (Test-Path -Path $commentFile -PathType Leaf)) {
        throw "${Name}: expected comment file '${commentFile}' to exist."
    }
}

try {
    Invoke-ParserCase -Name '01 happy path' -Body "| RN | Task |`n| --- | --- |`n| RN12 | DCP35 |" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'passed' -ExpectedChangeType 'Patch' -ExpectedPairCount '1' -ExpectedRnsJson '["RN12"]' -ExpectedPairsJson '[{"rns":["RN12"],"tasks":["DCP35"]}]'
    Invoke-ParserCase -Name '02 grouped ids in one row' -Body "| RN | Task |`n| --- | --- |`n| RN12, RN13 | DCP35, DCP66 |" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'passed' -ExpectedChangeType 'Patch' -ExpectedPairCount '1' -ExpectedRnsJson '["RN12","RN13"]' -ExpectedPairsJson '[{"rns":["RN12","RN13"],"tasks":["DCP35","DCP66"]}]'
    Invoke-ParserCase -Name '03 multiple rows' -Body "| RN | Task |`n| --- | --- |`n| RN12 | DCP35 |`n| RN13 | DCP66 |" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'passed' -ExpectedChangeType 'Patch' -ExpectedPairCount '2' -ExpectedRnsJson '["RN12","RN13"]' -ExpectedPairsJson '[{"rns":["RN12"],"tasks":["DCP35"]},{"rns":["RN13"],"tasks":["DCP66"]}]'
    Invoke-ParserCase -Name '04 missing task regular' -Body "| RN | Task |`n| --- | --- |`n| RN12 | |" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'failed' -ExpectedChangeType '-' -ExpectedPairCount '-' -ExpectedRnsJson '-' -ExpectedPairsJson '-'
    Invoke-ParserCase -Name '05 task without rn' -Body "| RN | Task |`n| --- | --- |`n| | DCP35 |" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'failed' -ExpectedChangeType '-' -ExpectedPairCount '-' -ExpectedRnsJson '-' -ExpectedPairsJson '-'
    Invoke-ParserCase -Name '06 no table at all' -Body 'This pull request has no release note administration.' -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'failed' -ExpectedChangeType '-' -ExpectedPairCount '-' -ExpectedRnsJson '-' -ExpectedPairsJson '-'
    Invoke-ParserCase -Name '07 header separator only' -Body "| RN | Task |`n| --- | --- |" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'failed' -ExpectedChangeType '-' -ExpectedPairCount '-' -ExpectedRnsJson '-' -ExpectedPairsJson '-'
    Invoke-ParserCase -Name '08 malformed rn' -Body "| RN | Task |`n| --- | --- |`n| R12 | DCP35 |" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'failed' -ExpectedChangeType '-' -ExpectedPairCount '-' -ExpectedRnsJson '-' -ExpectedPairsJson '-'
    Invoke-ParserCase -Name '09 malformed task' -Body "| RN | Task |`n| --- | --- |`n| RN12 | DCP-35 |" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'failed' -ExpectedChangeType '-' -ExpectedPairCount '-' -ExpectedRnsJson '-' -ExpectedPairsJson '-'
    Invoke-ParserCase -Name '10 dependabot rn only' -Body "| RN | Task |`n| --- | --- |`n| RN12 | |" -Actor 'dependabot[bot]' -LabelsJson '[]' -ExpectedStatus 'passed' -ExpectedChangeType 'Patch' -ExpectedPairCount '1' -ExpectedRnsJson '["RN12"]' -ExpectedPairsJson '[{"rns":["RN12"],"tasks":[]}]'
    Invoke-ParserCase -Name '11 dependabot branch human actor' -Body "| RN | Task |`n| --- | --- |`n| RN12 | |" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'failed' -ExpectedChangeType '-' -ExpectedPairCount '-' -ExpectedRnsJson '-' -ExpectedPairsJson '-'
    Invoke-ParserCase -Name '12 one change type label' -Body "| RN | Task |`n| --- | --- |`n| RN12 | DCP35 |" -Actor 'human' -LabelsJson '["Change-Type:Minor"]' -ExpectedStatus 'passed' -ExpectedChangeType 'Minor' -ExpectedPairCount '1' -ExpectedRnsJson '["RN12"]' -ExpectedPairsJson '-'
    Invoke-ParserCase -Name '13 two change type labels' -Body "| RN | Task |`n| --- | --- |`n| RN12 | DCP35 |" -Actor 'human' -LabelsJson '["Change-Type:Minor","Change-Type:Major"]' -ExpectedStatus 'failed' -ExpectedChangeType '-' -ExpectedPairCount '-' -ExpectedRnsJson '-' -ExpectedPairsJson '-'
    Invoke-ParserCase -Name '14 no change type label' -Body "| RN | Task |`n| --- | --- |`n| RN12 | DCP35 |" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'passed' -ExpectedChangeType 'Patch' -ExpectedPairCount '1' -ExpectedRnsJson '["RN12"]' -ExpectedPairsJson '-'
    Invoke-ParserCase -Name '15 case insensitive' -Body "| rn | task |`n| --- | --- |`n| rn12 | dcp35 |" -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'passed' -ExpectedChangeType 'Patch' -ExpectedPairCount '1' -ExpectedRnsJson '["RN12"]' -ExpectedPairsJson '[{"rns":["RN12"],"tasks":["DCP35"]}]'
    Invoke-ParserCase -Name '16 surrounding prose other tables' -Body "Intro text.`n`n| Name | Value |`n| --- | --- |`n| Noise | Table |`n`n| RN | Task |`n| --- | --- |`n| RN12 | DCP35 |`n`nFooter text." -Actor 'human' -LabelsJson '[]' -ExpectedStatus 'passed' -ExpectedChangeType 'Patch' -ExpectedPairCount '1' -ExpectedRnsJson '["RN12"]' -ExpectedPairsJson '[{"rns":["RN12"],"tasks":["DCP35"]}]'

    Write-Output 'All parse-rn-task-table cases passed.'
} finally {
    Remove-Item -Path $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}