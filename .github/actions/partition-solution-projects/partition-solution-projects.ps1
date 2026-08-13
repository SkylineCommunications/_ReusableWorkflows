$ErrorActionPreference = 'Stop'

function Invoke-DotNet {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $commandOutput = @(& dotnet @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $details = ($commandOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "dotnet $($Arguments -join ' ') failed with exit code $LASTEXITCODE.$([Environment]::NewLine)$details"
    }

    return $commandOutput
}

function Get-SolutionProject {
    param(
        [Parameter(Mandatory)]
        [string]$SolutionPath
    )

    $solutionDirectory = Split-Path -Parent $SolutionPath
    $listOutput = @(Invoke-DotNet -Arguments @('sln', $SolutionPath, 'list'))
    $separatorIndex = -1

    for ($lineIndex = 0; $lineIndex -lt $listOutput.Count; $lineIndex++) {
        if ($listOutput[$lineIndex].ToString().Trim() -match '^-{3,}$') {
            $separatorIndex = $lineIndex
            break
        }
    }

    if ($separatorIndex -lt 0) {
        if ($listOutput | Where-Object { $_.ToString() -match '(?i)no projects found' }) {
            return @()
        }

        throw "Could not parse the project list for solution '$SolutionPath'."
    }

    $projects = @()
    foreach ($projectLine in $listOutput[($separatorIndex + 1)..($listOutput.Count - 1)]) {
        $listedPath = $projectLine.ToString().Trim()
        if ([string]::IsNullOrWhiteSpace($listedPath)) {
            continue
        }

        $platformPath = $listedPath.Replace('\', [System.IO.Path]::DirectorySeparatorChar).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $projectPath = if ([System.IO.Path]::IsPathFullyQualified($platformPath)) {
            [System.IO.Path]::GetFullPath($platformPath)
        } else {
            [System.IO.Path]::GetFullPath((Join-Path -Path $solutionDirectory -ChildPath $platformPath))
        }

        if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
            throw "Project '$listedPath' referenced by solution '$SolutionPath' does not exist."
        }

        $projects += [PSCustomObject]@{
            ListedPath = $listedPath
            FullPath   = $projectPath
            Category   = $null
        }
    }

    return $projects
}

function Get-ProjectCategory {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectPath
    )

    if ([System.IO.Path]::GetExtension($ProjectPath).Equals('.wixproj', [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'wix'
    }

    try {
        $xmlDocument = [System.Xml.XmlDocument]::new()
        $xmlDocument.XmlResolver = $null
        $xmlDocument.Load($ProjectPath)
    } catch {
        throw "Project '$ProjectPath' contains malformed XML: $($_.Exception.Message)"
    }

    $packageElements = $xmlDocument.SelectNodes("//*[local-name()='GenerateDataMinerPackage']")
    foreach ($packageElement in $packageElements) {
        if ($packageElement.InnerText.Trim().Equals('true', [System.StringComparison]::OrdinalIgnoreCase)) {
            return 'dataminer-package'
        }
    }

    return 'remaining'
}

function Remove-PartitionProject {
    param(
        [Parameter(Mandatory)]
        [string]$SolutionPath,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ProjectPath
    )

    if ($ProjectPath.Count -eq 0) {
        return
    }

    $arguments = @('sln', $SolutionPath, 'remove') + $ProjectPath
    Invoke-DotNet -Arguments $arguments | Out-Null
}

if ([string]::IsNullOrWhiteSpace($env:SOLUTION_PATH)) {
    throw 'SOLUTION_PATH must be set.'
}

if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    throw 'GITHUB_OUTPUT must be set.'
}

if ($null -eq (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'dotnet must be installed and available on PATH.'
}

$sourceSolutionPath = [System.IO.Path]::GetFullPath($env:SOLUTION_PATH)
if (-not (Test-Path -LiteralPath $sourceSolutionPath -PathType Leaf)) {
    throw "Solution '$sourceSolutionPath' does not exist."
}

$solutionExtension = [System.IO.Path]::GetExtension($sourceSolutionPath)
if ($solutionExtension -notin '.sln', '.slnx', '.slnf') {
    throw "Solution '$sourceSolutionPath' must have a .sln, .slnx, or .slnf extension."
}

$projects = @(Get-SolutionProject -SolutionPath $sourceSolutionPath)
foreach ($project in $projects) {
    $project.Category = Get-ProjectCategory -ProjectPath $project.FullPath
}

$solutionDirectory = Split-Path -Parent $sourceSolutionPath
$solutionName = [System.IO.Path]::GetFileNameWithoutExtension($sourceSolutionPath)
$invocationId = [System.Guid]::NewGuid().ToString('N')
$partitionNames = @('remaining', 'wix', 'dataminer-package')
$partitionPaths = @{}

try {
    foreach ($partitionName in $partitionNames) {
        $partitionFileName = "$solutionName.$partitionName.$invocationId$solutionExtension"
        $partitionPath = Join-Path -Path $solutionDirectory -ChildPath $partitionFileName
        Copy-Item -LiteralPath $sourceSolutionPath -Destination $partitionPath
        $partitionPaths[$partitionName] = $partitionPath

        $projectsToRemove = @($projects | Where-Object { $_.Category -ne $partitionName } | ForEach-Object { $_.FullPath })
        Remove-PartitionProject -SolutionPath $partitionPath -ProjectPath $projectsToRemove
    }

    $outputLines = @(
        "remaining-solution-path=$($partitionPaths['remaining'])"
        "remaining-count=$(@($projects | Where-Object { $_.Category -eq 'remaining' }).Count)"
        "wix-solution-path=$($partitionPaths['wix'])"
        "wix-count=$(@($projects | Where-Object { $_.Category -eq 'wix' }).Count)"
        "dataminer-package-solution-path=$($partitionPaths['dataminer-package'])"
        "dataminer-package-count=$(@($projects | Where-Object { $_.Category -eq 'dataminer-package' }).Count)"
    )
    $outputWriter = [System.IO.StreamWriter]::new($env:GITHUB_OUTPUT, $true, [System.Text.UTF8Encoding]::new($false))
    try {
        foreach ($outputLine in $outputLines) {
            $outputWriter.WriteLine($outputLine)
        }
    } finally {
        $outputWriter.Dispose()
    }
} catch {
    foreach ($partitionPath in $partitionPaths.Values) {
        Remove-Item -LiteralPath $partitionPath -Force -ErrorAction SilentlyContinue
    }

    throw
}