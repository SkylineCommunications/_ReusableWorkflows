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
$commentHeader = if ($null -ne $env:COMMENT_HEADER) { $env:COMMENT_HEADER } else { 'skyline-rn-task' }

$errors = [System.Collections.Generic.List[string]]::new()
$allRns = [System.Collections.Generic.List[string]]::new()
$seenRns = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$pairs = [System.Collections.Generic.List[object]]::new()
$changeType = 'Patch'
$tableFound = $false
$dataRowCount = 0

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

function Get-MarkdownCells {
    param([Parameter(Mandatory)][string]$Row)

    $trimmedRow = ConvertTo-TrimmedValue -Value $Row
    if ($trimmedRow.StartsWith('|', [System.StringComparison]::Ordinal)) {
        $trimmedRow = $trimmedRow.Substring(1)
    }

    if ($trimmedRow.EndsWith('|', [System.StringComparison]::Ordinal)) {
        $trimmedRow = $trimmedRow.Substring(0, $trimmedRow.Length - 1)
    }

    $cells = [System.Text.RegularExpressions.Regex]::Split($trimmedRow, '\|')
    return @($cells | ForEach-Object { ConvertTo-TrimmedValue -Value $_ })
}

function Get-NormalizedHeader {
    param([AllowNull()][string]$Value)

    $trimmedValue = ConvertTo-TrimmedValue -Value $Value
    return ([System.Text.RegularExpressions.Regex]::Replace($trimmedValue, '\s+', '')).ToLowerInvariant()
}

function Test-SeparatorCell {
    param([AllowNull()][string]$Value)

    $trimmedValue = ConvertTo-TrimmedValue -Value $Value
    $normalizedValue = [System.Text.RegularExpressions.Regex]::Replace($trimmedValue.Replace(':', ''), '\s+', '')
    return $normalizedValue -match '^-+$'
}

function ConvertTo-JsonArray {
    param([AllowNull()][object[]]$Value)

    $array = if ($null -eq $Value) { @() } else { @($Value) }
    return ConvertTo-Json -InputObject ([object[]]$array) -Compress -Depth 10
}

function Get-ParsedIdCell {
    param(
        [AllowNull()][string]$RawCell,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][int]$RowNumber,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Expected
    )

    $parsedIds = [System.Collections.Generic.List[string]]::new()
    $trimmedCell = ConvertTo-TrimmedValue -Value $RawCell
    if ([string]::IsNullOrWhiteSpace($trimmedCell)) {
        return @()
    }

    $tokens = [System.Text.RegularExpressions.Regex]::Split($trimmedCell, ',')
    foreach ($rawToken in $tokens) {
        $token = ConvertTo-TrimmedValue -Value $rawToken
        if ([string]::IsNullOrWhiteSpace($token)) {
            Add-ValidationError -Message "Row ${RowNumber}: empty ${Kind} id in '${trimmedCell}'."
        } elseif ($token -match $Pattern) {
            $parsedIds.Add($token.ToUpperInvariant())
        } else {
            Add-ValidationError -Message "Row ${RowNumber}: malformed ${Kind} id '${token}' (expected ${Expected})."
        }
    }

    return @($parsedIds.ToArray())
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

function Add-Pair {
    param(
        [Parameter(Mandatory)][string[]]$Rns,
        [AllowEmptyCollection()][string[]]$Tasks
    )

    $taskArray = @($Tasks)
    $script:pairs.Add([PSCustomObject]@{
        rns = [string[]]@($Rns)
        tasks = [string[]]$taskArray
    })
}

function Add-Rn {
    param([Parameter(Mandatory)][string[]]$Rns)

    foreach ($rn in $Rns) {
        if ($script:seenRns.Add($rn)) {
            $script:allRns.Add($rn)
        }
    }
}

function Parse-RnTaskTable {
    $lines = [System.Text.RegularExpressions.Regex]::Split($script:prBody, "`r?`n")
    $rnColumn = -1
    $taskColumn = -1
    $dataStart = -1

    for ($index = 0; $index -lt $lines.Count; $index++) {
        if (-not $lines[$index].Contains('|')) {
            continue
        }

        $cells = Get-MarkdownCells -Row $lines[$index]
        $rnColumn = -1
        $taskColumn = -1

        for ($column = 0; $column -lt $cells.Count; $column++) {
            switch (Get-NormalizedHeader -Value $cells[$column]) {
                'rn' { $rnColumn = $column }
                'task' { $taskColumn = $column }
            }
        }

        if ($rnColumn -ge 0 -and $taskColumn -ge 0 -and ($index + 1) -lt $lines.Count) {
            $separatorCells = Get-MarkdownCells -Row $lines[$index + 1]
            if ($separatorCells.Count -gt $rnColumn -and $separatorCells.Count -gt $taskColumn -and
                (Test-SeparatorCell -Value $separatorCells[$rnColumn]) -and
                (Test-SeparatorCell -Value $separatorCells[$taskColumn])) {
                $script:tableFound = $true
                $dataStart = $index + 2
                break
            }
        }
    }

    if (-not $script:tableFound) {
        Add-ValidationError -Message 'Could not find an RN/Task markdown table with header columns RN and Task.'
        return
    }

    for ($index = $dataStart; $index -lt $lines.Count; $index++) {
        if (-not $lines[$index].Contains('|')) {
            break
        }

        $cells = Get-MarkdownCells -Row $lines[$index]
        if ($cells.Count -le $rnColumn -or $cells.Count -le $taskColumn) {
            break
        }

        if ((Test-SeparatorCell -Value $cells[$rnColumn]) -and (Test-SeparatorCell -Value $cells[$taskColumn])) {
            continue
        }

        $script:dataRowCount++
        $rowNumber = $script:dataRowCount
        $rowRns = [string[]]@(Get-ParsedIdCell -RawCell $cells[$rnColumn] -Kind 'RN' -RowNumber $rowNumber -Pattern '^RN\d+$' -Expected 'RN followed by digits' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $rowTasks = [string[]]@(Get-ParsedIdCell -RawCell $cells[$taskColumn] -Kind 'task' -RowNumber $rowNumber -Pattern '^DCP\d+$' -Expected 'DCP followed by digits' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        if ($rowRns.Count -eq 0 -and $rowTasks.Count -eq 0) {
            Add-ValidationError -Message "Row ${rowNumber}: at least one RN id is required."
        }

        if ($rowRns.Count -eq 0 -and $rowTasks.Count -gt 0) {
            Add-ValidationError -Message "Row ${rowNumber}: task ids require at least one linked RN id."
        }

        if ($script:actor -ne 'dependabot[bot]' -and $rowRns.Count -gt 0 -and $rowTasks.Count -eq 0) {
            Add-ValidationError -Message "Row ${rowNumber}: task id is required for non-Dependabot PRs."
        }

        if ($rowRns.Count -gt 0) {
            Add-Rn -Rns $rowRns
            Add-Pair -Rns $rowRns -Tasks $rowTasks
        }
    }

    if ($script:dataRowCount -eq 0) {
        Add-ValidationError -Message 'The RN/Task table has no data rows.'
    }
}

function Write-ValidationComment {
    param(
        [Parameter(Mandatory)][string]$Status,
        [AllowEmptyCollection()][string[]]$Rns
    )

    $commentFile = Join-Path -Path $env:GITHUB_WORKSPACE -ChildPath 'rn-task-validation-comment.md'
    $headingStatus = if ($Status -eq 'failed') { 'Failed' } else { 'Passed' }
    $dependabotMode = if ($script:actor -eq 'dependabot[bot]') { 'yes' } else { 'no' }
    $content = [System.Collections.Generic.List[string]]::new()

    $content.Add("<!-- ${script:commentHeader} -->")
    $content.Add("## PR RN/Task Validation: ${headingStatus}")
    $content.Add('')
    $content.Add('| Item | Value |')
    $content.Add('| --- | --- |')
    $content.Add("| Status | ${Status} |")
    $content.Add("| Change-Type | ${script:changeType} |")
    $content.Add("| Dependabot RN-only mode | ${dependabotMode} |")
    $content.Add('')

    if ($script:pairs.Count -gt 0) {
        $content.Add('| RN(s) | Task(s) |')
        $content.Add('| --- | --- |')
        foreach ($pair in $script:pairs) {
            $rnsValue = [string]::Join(', ', @($pair.rns))
            $tasksValue = if (@($pair.tasks).Count -eq 0) { '-' } else { [string]::Join(', ', @($pair.tasks)) }
            $content.Add("| ${rnsValue} | ${tasksValue} |")
        }
        $content.Add('')
    }

    if ($script:errors.Count -gt 0) {
        $content.Add('Validation errors:')
        foreach ($validationError in $script:errors) {
            $content.Add("- ${validationError}")
        }
        $content.Add('')
    }

    if ($Rns.Count -gt 0) {
        $content.Add("Parsed RN ids: $([string]::Join(', ', $Rns))")
    }

    Set-Content -Path $commentFile -Value $content -Encoding utf8
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $content -Encoding utf8
    }

    return $commentFile
}

Resolve-ChangeType
Parse-RnTaskTable

$rns = [string[]]@($allRns.ToArray())
$rnsJson = ConvertTo-JsonArray -Value $rns
$pairsJson = ConvertTo-Json -InputObject ([object[]]$pairs.ToArray()) -Compress -Depth 10

if ($tableFound) {
    if ($rns.Count -eq 0) {
        Add-ValidationError -Message 'At least one RN id is required.'
    }

    $taskCount = 0
    foreach ($pair in $pairs) {
        $taskCount += @($pair.tasks).Count
    }

    if ($actor -ne 'dependabot[bot]' -and $taskCount -eq 0) {
        Add-ValidationError -Message 'At least one task id is required for non-Dependabot PRs.'
    }
}

$status = if ($errors.Count -gt 0) { 'failed' } else { 'passed' }
$commentFile = Write-ValidationComment -Status $status -Rns $rns

@(
    "status=${status}"
    "rns=${rnsJson}"
    "pairs=${pairsJson}"
    "change-type=${changeType}"
    "comment-file=${commentFile}"
) | Add-Content -Path $env:GITHUB_OUTPUT -Encoding utf8