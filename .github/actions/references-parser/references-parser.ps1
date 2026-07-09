$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    throw 'GITHUB_OUTPUT must be set.'
}

if ([string]::IsNullOrWhiteSpace($env:GITHUB_WORKSPACE)) {
    throw 'GITHUB_WORKSPACE must be set.'
}

$prBody = if ($null -ne $env:PR_BODY) { $env:PR_BODY } else { '' }
$actor = if ($null -ne $env:ACTOR) { $env:ACTOR } else { '' }
$labelsJson = if ($null -ne $env:LABELS_JSON) { $env:LABELS_JSON } else { '[]' }
$commentHeader = if ($null -ne $env:COMMENT_HEADER) { $env:COMMENT_HEADER } else { 'skyline-references' }

$errors = [System.Collections.Generic.List[string]]::new()
$allRns = [System.Collections.Generic.List[string]]::new()
$seenRns = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$allTasks = [System.Collections.Generic.List[string]]::new()
$seenTasks = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$changeType = 'Patch'
$referencesFound = $false

function Add-ValidationError {
    param([Parameter(Mandatory)][string]$Message)

    $script:errors.Add($Message)
}

function ConvertTo-TrimmedValue {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return $Value.Replace("`r", '').Trim()
}

function ConvertTo-JsonArray {
    param([AllowNull()][object[]]$Value)

    $array = if ($null -eq $Value) { @() } else { @($Value) }
    if ($array.Count -eq 0) {
        return '[]'
    }

    return ConvertTo-Json -InputObject ([object[]]$array) -Compress -Depth 10
}

function Resolve-ChangeType {
    $labels = @()
    try {
        $parsedLabels = ConvertFrom-Json -InputObject $script:labelsJson -NoEnumerate -ErrorAction Stop
        if ($null -eq $parsedLabels) {
            $labels = @()
        } elseif ($parsedLabels -is [System.Array]) {
            $labels = @($parsedLabels)
        } else {
            Add-ValidationError -Message 'labels-json must be a JSON array of label names.'
            return
        }
    } catch {
        Add-ValidationError -Message 'labels-json must be a JSON array of label names.'
        return
    }

    $changeLabels = @($labels | Where-Object { $_ -is [string] -and $_ -match '^Change-Type:' })
    if ($changeLabels.Count -gt 1) {
        Add-ValidationError -Message "At most one Change-Type:* label is allowed; found $($changeLabels.Count)."
        return
    }

    if ($changeLabels.Count -eq 0) {
        $script:changeType = 'Patch'
        return
    }

    $suffix = ($changeLabels[0] -split ':', 2)[1]
    switch -Regex ($suffix) {
        '^(?i)patch$' { $script:changeType = 'Patch'; break }
        '^(?i)minor$' { $script:changeType = 'Minor'; break }
        '^(?i)major$' { $script:changeType = 'Major'; break }
        default { Add-ValidationError -Message "Unsupported Change-Type label '$($changeLabels[0])' (expected Change-Type:Patch, Change-Type:Minor, or Change-Type:Major)." }
    }
}

function Add-ReferenceId {
    param([AllowEmptyString()][string]$RawToken)

    $token = ConvertTo-TrimmedValue -Value $RawToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        Add-ValidationError -Message 'Empty reference id found (expected [RN<number>] or [DCP<number>]).'
        return
    }

    if ($token -match '^RN\d+$') {
        $normalized = $token.ToUpperInvariant()
        if ($script:seenRns.Add($normalized)) {
            $script:allRns.Add($normalized)
        }
    } elseif ($token -match '^DCP\d+$') {
        $normalized = $token.ToUpperInvariant()
        if ($script:seenTasks.Add($normalized)) {
            $script:allTasks.Add($normalized)
        }
    } else {
        Add-ValidationError -Message "Malformed reference id '${token}' (expected [RN<number>] or [DCP<number>])."
    }
}

function Parse-References {
    $lines = [System.Text.RegularExpressions.Regex]::Split($script:prBody, "`r?`n")
    $referencesContent = $null

    foreach ($line in $lines) {
        $match = [System.Text.RegularExpressions.Regex]::Match($line, '^\s*References:\s*(.*)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            $script:referencesFound = $true
            $referencesContent = $match.Groups[1].Value
        }
    }

    if (-not $script:referencesFound) {
        Add-ValidationError -Message 'Could not find a "References:" line in the PR description (expected e.g. "References: [RN12] [DCP35]").'
        return
    }

    $tokenMatches = [System.Text.RegularExpressions.Regex]::Matches($referencesContent, '\[([^\]]*)\]')
    if ($tokenMatches.Count -eq 0) {
        Add-ValidationError -Message 'The "References:" line contains no [RN<number>]/[DCP<number>] ids.'
        return
    }

    foreach ($tokenMatch in $tokenMatches) {
        Add-ReferenceId -RawToken $tokenMatch.Groups[1].Value
    }
}

function Write-ValidationComment {
    param(
        [Parameter(Mandatory)][string]$Status,
        [AllowEmptyCollection()][string[]]$Rns,
        [AllowEmptyCollection()][string[]]$Tasks
    )

    $commentFile = Join-Path -Path $env:GITHUB_WORKSPACE -ChildPath 'references-validation-comment.md'
    $isDependabot = $script:actor -eq 'dependabot[bot]'
    if ($Status -eq 'failed') {
        $statusIcon = '❌'
        $headingText = '**Failed**'
    } else {
        $statusIcon = '✅'
        $headingText = '**Passed**'
    }

    $content = [System.Collections.Generic.List[string]]::new()

    $content.Add("<!-- ${script:commentHeader} -->")
    $content.Add("## PR References Validation: ${statusIcon} ${headingText}")
    $content.Add('')
    $content.Add('| Item | Value |')
    $content.Add('| --- | :---: |')
    $content.Add("| Status | ${statusIcon} |")
    $content.Add("| Change-Type | ${script:changeType} |")
    if ($isDependabot) {
        $content.Add('| Dependabot RN-only mode | Yes |')
    }
    $content.Add('')

    if ($script:errors.Count -gt 0) {
        $content.Add('Validation errors:')
        foreach ($validationError in $script:errors) {
            $content.Add("- ${validationError}")
        }
        $content.Add('')
    }

    if ($Rns.Count -gt 0) {
        $content.Add('**Release Notes**')
        $content.Add('')
        foreach ($rn in $Rns) {
            $number = $rn -replace '\D', ''
            $content.Add("- [${rn}](https://collaboration.dataminer.services/releasenotes/${number})")
        }
        $content.Add('')
    }

    if ($tasks.Count -gt 0) {
        $content.Add('**Tasks**')
        $content.Add('')
        foreach ($task in $tasks) {
            $number = $task -replace '\D', ''
            $content.Add("- [${task}](https://collaboration.dataminer.services/task/${number})")
        }
        $content.Add('')
    }

    Set-Content -Path $commentFile -Value $content -Encoding utf8
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $content -Encoding utf8
    }

    return $commentFile
}

Resolve-ChangeType
Parse-References

$rns = [string[]]@($allRns.ToArray())
$tasks = [string[]]@($allTasks.ToArray())
$rnsJson = ConvertTo-JsonArray -Value $rns
$tasksJson = ConvertTo-JsonArray -Value $tasks

if ($referencesFound) {
    if ($rns.Count -eq 0) {
        Add-ValidationError -Message 'At least one RN id is required.'
    }

    if ($actor -ne 'dependabot[bot]' -and $tasks.Count -eq 0) {
        Add-ValidationError -Message 'At least one task id is required for non-Dependabot PRs.'
    }
}

$status = if ($errors.Count -gt 0) { 'failed' } else { 'passed' }
$commentFile = Write-ValidationComment -Status $status -Rns $rns -Tasks $tasks

@(
    "status=${status}"
    "rns=${rnsJson}"
    "tasks=${tasksJson}"
    "change-type=${changeType}"
    "comment-file=${commentFile}"
) | Add-Content -Path $env:GITHUB_OUTPUT -Encoding utf8