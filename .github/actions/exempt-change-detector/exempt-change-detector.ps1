$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    throw 'GITHUB_OUTPUT must be set.'
}

$changedFilesRaw = if ($null -ne $env:CHANGED_FILES) { $env:CHANGED_FILES } else { '' }
$patternsRaw = if ($null -ne $env:PATTERNS) { $env:PATTERNS } else { '' }

function ConvertTo-Lines {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrEmpty($Value)) {
        return @()
    }

    $lines = [System.Text.RegularExpressions.Regex]::Split($Value, "`r?`n")
    return @($lines | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Convert-GlobToRegex {
    param([Parameter(Mandatory)][string]$Glob)

    $builder = [System.Text.StringBuilder]::new()
    $null = $builder.Append('^')

    $index = 0
    $length = $Glob.Length
    while ($index -lt $length) {
        $character = $Glob[$index]
        switch ($character) {
            '*' {
                $isDoubleStar = ($index + 1 -lt $length) -and ($Glob[$index + 1] -eq '*')
                if ($isDoubleStar) {
                    $followedBySlash = ($index + 2 -lt $length) -and ($Glob[$index + 2] -eq '/')
                    if ($followedBySlash) {
                        # '**/' matches zero or more leading path segments.
                        $null = $builder.Append('(?:.*/)?')
                        $index += 3
                    } else {
                        # '**' matches anything, including path separators.
                        $null = $builder.Append('.*')
                        $index += 2
                    }
                } else {
                    # '*' matches anything except a path separator.
                    $null = $builder.Append('[^/]*')
                    $index += 1
                }
            }
            '?' {
                $null = $builder.Append('[^/]')
                $index += 1
            }
            default {
                $null = $builder.Append([System.Text.RegularExpressions.Regex]::Escape([string]$character))
                $index += 1
            }
        }
    }

    $null = $builder.Append('$')
    return $builder.ToString()
}

$patterns = ConvertTo-Lines -Value $patternsRaw
if ($patterns.Count -eq 0) {
    throw 'At least one exempt pattern must be provided via the patterns input.'
}

$patternRegexes = @($patterns | ForEach-Object { Convert-GlobToRegex -Glob $_ })

$changedFiles = ConvertTo-Lines -Value $changedFilesRaw

# A change is only exempt when at least one file changed and every changed file matches a pattern.
# An empty file list is never exempt, so it can never trigger the auto-RN injection.
$exempt = $changedFiles.Count -gt 0
$nonMatching = [System.Collections.Generic.List[string]]::new()

foreach ($file in $changedFiles) {
    $matched = $false
    foreach ($regex in $patternRegexes) {
        if ([System.Text.RegularExpressions.Regex]::IsMatch($file, $regex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $matched = $true
            break
        }
    }

    if (-not $matched) {
        $exempt = $false
        $nonMatching.Add($file)
    }
}

$exemptValue = if ($exempt) { 'true' } else { 'false' }

@(
    "exempt=${exemptValue}"
) | Add-Content -Path $env:GITHUB_OUTPUT -Encoding utf8

if ($changedFiles.Count -eq 0) {
    Write-Output 'No changed files detected; not exempt.'
} elseif ($exempt) {
    Write-Output "All $($changedFiles.Count) changed file(s) match an exempt pattern; exempt=true."
} else {
    Write-Output "Not exempt; $($nonMatching.Count) changed file(s) outside exempt patterns:"
    foreach ($file in $nonMatching) {
        Write-Output "  - ${file}"
    }
}
