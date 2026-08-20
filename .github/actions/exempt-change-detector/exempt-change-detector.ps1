$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    throw 'GITHUB_OUTPUT must be set.'
}

$changedFilesRaw = if ($null -ne $env:CHANGED_FILES) { $env:CHANGED_FILES } else { '' }
$patternsRaw = if ($null -ne $env:PATTERNS) { $env:PATTERNS } else { '' }
$repositoryPatternsPath = if ([string]::IsNullOrWhiteSpace($env:GITHUB_WORKSPACE)) {
    $null
} else {
    Join-Path -Path $env:GITHUB_WORKSPACE -ChildPath '.github/exempt-change-patterns.txt'
}

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

function Get-RepositoryPatterns {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $item = Get-Item -LiteralPath $Path
    if ($item.PSIsContainer) {
        throw "Repository exempt-pattern configuration must be a file: ${Path}"
    }

    if ($item.Length -gt 64KB) {
        throw "Repository exempt-pattern configuration exceeds 64 KiB: ${Path}"
    }

    $patterns = @(
        Get-Content -LiteralPath $Path |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith('#') }
    )

    if ($patterns.Count -gt 256) {
        throw 'Repository exempt-pattern configuration contains more than 256 patterns.'
    }

    foreach ($pattern in $patterns) {
        if ($pattern.Length -gt 1024) {
            throw 'Repository exempt-pattern configuration contains a pattern longer than 1024 characters.'
        }

        $dotSegments = @($pattern -split '/' | Where-Object { $_ -eq '.' -or $_ -eq '..' })
        if ($pattern -eq '**' -or $pattern.StartsWith('!') -or $pattern.StartsWith('/') -or
            $pattern.Contains('\') -or $pattern -match '^[A-Za-z]:' -or
            $dotSegments.Count -gt 0) {
            throw "Invalid repository exempt pattern '${pattern}'. Patterns must be relative globs and cannot match the entire repository."
        }
    }

    return $patterns
}

$repositoryPatterns = Get-RepositoryPatterns -Path $repositoryPatternsPath
$patterns = @((ConvertTo-Lines -Value $patternsRaw) + $repositoryPatterns)
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
