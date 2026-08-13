$ErrorActionPreference = 'Stop'

$actionDirectory = Split-Path -Parent $PSCommandPath
$scriptPath = Join-Path -Path $actionDirectory -ChildPath 'partition-solution-projects.ps1'
$temporaryDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "partition-solution-projects-$([System.Guid]::NewGuid())"
New-Item -Path $temporaryDirectory -ItemType Directory | Out-Null

function Invoke-DotNet {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [switch]$AllowFailure
    )

    $commandOutput = @(& dotnet @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure.IsPresent) {
        throw "dotnet $($Arguments -join ' ') failed: $($commandOutput -join [Environment]::NewLine)"
    }

    return [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output   = $commandOutput
    }
}

function Assert-Equal {
    param(
        [AllowNull()]
        [object]$Actual,

        [AllowNull()]
        [object]$Expected,

        [Parameter(Mandatory)]
        [string]$Label
    )

    if ($Actual -ne $Expected) {
        throw "${Label}: expected '${Expected}', got '${Actual}'."
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,

        [Parameter(Mandatory)]
        [string]$Label
    )

    if (-not $Condition) {
        throw "${Label}: expected true."
    }
}

function Get-OutputValue {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $prefix = "${Name}="
    $line = Get-Content -LiteralPath $Path | Where-Object { $_.StartsWith($prefix, [System.StringComparison]::Ordinal) } | Select-Object -Last 1
    if ($null -eq $line) {
        throw "Output '$Name' was not written."
    }

    return $line.Substring($prefix.Length)
}

function Set-ProjectFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content
    )

    $projectDirectory = Split-Path -Parent $Path
    New-Item -Path $projectDirectory -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath $Path -Value $Content -Encoding utf8
}

function New-TestSolution {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('sln', 'slnx', 'slnf')]
        [string]$Format
    )

    $solutionDirectory = Join-Path -Path $script:temporaryDirectory -ChildPath "$Name-$Format"
    New-Item -Path $solutionDirectory -ItemType Directory | Out-Null
    $solutionFormat = if ($Format -eq 'slnf') { 'sln' } else { $Format }
    $creationResult = Invoke-DotNet -Arguments @('new', 'sln', '--name', $Name, '--output', $solutionDirectory, '--format', $solutionFormat) -AllowFailure
    if ($creationResult.ExitCode -ne 0) {
        Remove-Item -LiteralPath $solutionDirectory -Recurse -Force
        return $null
    }

    if ($Format -eq 'slnf') {
        $solutionPath = Join-Path -Path $solutionDirectory -ChildPath "$Name.slnf"
        $filter = [ordered]@{
            solution = [ordered]@{
                path     = "$Name.sln"
                projects = @()
            }
        }
        $filter | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $solutionPath -Encoding utf8
    } else {
        $solutionPath = Join-Path -Path $solutionDirectory -ChildPath "$Name.$Format"
    }

    if (-not (Test-Path -LiteralPath $solutionPath -PathType Leaf)) {
        throw "dotnet created no .$Format solution at '$solutionPath'."
    }

    return $solutionPath
}

function Add-Project {
    param(
        [Parameter(Mandatory)]
        [string]$SolutionPath,

        [Parameter(Mandatory)]
        [string]$RelativePath,

        [Parameter(Mandatory)]
        [string]$Content
    )

    $solutionDirectory = Split-Path -Parent $SolutionPath
    $projectPath = Join-Path -Path $solutionDirectory -ChildPath $RelativePath
    Set-ProjectFile -Path $projectPath -Content $Content

    if ([System.IO.Path]::GetExtension($SolutionPath) -eq '.slnf') {
        $filter = Get-Content -LiteralPath $SolutionPath -Raw | ConvertFrom-Json
        $backingSolutionPath = Join-Path -Path $solutionDirectory -ChildPath $filter.solution.path
        Invoke-DotNet -Arguments @('sln', $backingSolutionPath, 'add', $projectPath) | Out-Null
        $filterProjectPath = [System.IO.Path]::GetRelativePath($solutionDirectory, $projectPath).Replace('/', '\')
        $filter.solution.projects = @($filter.solution.projects) + $filterProjectPath
        $filter | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $SolutionPath -Encoding utf8
    } else {
        Invoke-DotNet -Arguments @('sln', $SolutionPath, 'add', $projectPath) | Out-Null
    }

    return $projectPath
}

function Get-SolutionProjectName {
    param(
        [Parameter(Mandatory)]
        [string]$SolutionPath
    )

    $listResult = Invoke-DotNet -Arguments @('sln', $SolutionPath, 'list')
    $lines = @($listResult.Output | ForEach-Object { $_.ToString().Trim() })
    $separatorIndex = -1
    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        if ($lines[$lineIndex] -match '^-{3,}$') {
            $separatorIndex = $lineIndex
            break
        }
    }

    if ($separatorIndex -lt 0) {
        return @()
    }

    return @($lines[($separatorIndex + 1)..($lines.Count - 1)] |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Replace('\', '/') } |
        Sort-Object)
}

function Invoke-Partition {
    param(
        [Parameter(Mandatory)]
        [string]$SolutionPath
    )

    $outputPath = Join-Path -Path $script:temporaryDirectory -ChildPath "$([System.Guid]::NewGuid()).output"
    New-Item -Path $outputPath -ItemType File | Out-Null
    $env:SOLUTION_PATH = $SolutionPath
    $env:GITHUB_OUTPUT = $outputPath
    try {
        & $script:scriptPath | Out-Null
    } finally {
        Remove-Item Env:\SOLUTION_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:\GITHUB_OUTPUT -ErrorAction SilentlyContinue
    }

    return $outputPath
}

function Assert-Partition {
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [ValidateSet('remaining', 'wix', 'dataminer-package')]
        [string]$Partition,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ExpectedProject,

        [Parameter(Mandatory)]
        [int]$ExpectedCount
    )

    $solutionPath = Get-OutputValue -Name "$Partition-solution-path" -Path $OutputPath
    $count = Get-OutputValue -Name "$Partition-count" -Path $OutputPath
    Assert-True -Condition ([System.IO.Path]::IsPathFullyQualified($solutionPath)) -Label "$Partition path is absolute"
    Assert-True -Condition (Test-Path -LiteralPath $solutionPath -PathType Leaf) -Label "$Partition solution exists"
    Assert-Equal -Actual $count -Expected $ExpectedCount.ToString() -Label "$Partition count"

    $actualProjects = @(Get-SolutionProjectName -SolutionPath $solutionPath)
    $expectedProjects = @($ExpectedProject | Sort-Object)
    Assert-Equal -Actual ($actualProjects -join '|') -Expected ($expectedProjects -join '|') -Label "$Partition projects"
}

function Assert-PartitionFailure {
    param(
        [Parameter(Mandatory)]
        [string]$SolutionPath,

        [Parameter(Mandatory)]
        [string]$ExpectedMessage,

        [Parameter(Mandatory)]
        [string]$Label
    )

    try {
        Invoke-Partition -SolutionPath $SolutionPath | Out-Null
        throw "${Label}: expected the partition script to fail."
    } catch {
        if (-not $_.Exception.Message.Contains($ExpectedMessage, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "${Label}: unexpected error '$($_.Exception.Message)'."
        }
    }
}

$plainProject = '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>'
$wixProject = '<Project Sdk="WixToolset.Sdk/6.0.0"></Project>'
$packageTrueProject = '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><GenerateDataMinerPackage>  TrUe  </GenerateDataMinerPackage></PropertyGroup></Project>'
$packageFalseProject = '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><GenerateDataMinerPackage>false</GenerateDataMinerPackage></PropertyGroup></Project>'
$dataMinerTypeProject = '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><DataMinerType>Automation</DataMinerType></PropertyGroup></Project>'
$expressionProject = '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><GenerateDataMinerPackage>$(PackageEnabled)</GenerateDataMinerPackage></PropertyGroup></Project>'
$customActionProject = '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><PackageReference Include="WixToolset.Dtf.CustomAction" Version="6.0.0" /></ItemGroup></Project>'

try {
    if ($null -eq (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw 'dotnet must be installed and available on PATH.'
    }

    $testedFormats = @()
    foreach ($format in @('sln', 'slnx', 'slnf')) {
        $sourceSolutionPath = New-TestSolution -Name 'PartitionTest' -Format $format
        if ($null -eq $sourceSolutionPath) {
            Write-Host "SKIP: .$format is not supported by the installed dotnet SDK."
            continue
        }

        $testedFormats += $format
        Add-Project -SolutionPath $sourceSolutionPath -RelativePath 'Plain/Plain.csproj' -Content $plainProject | Out-Null
        Add-Project -SolutionPath $sourceSolutionPath -RelativePath 'Installer/Installer.wixproj' -Content $wixProject | Out-Null
        Add-Project -SolutionPath $sourceSolutionPath -RelativePath 'PackageTrue/PackageTrue.csproj' -Content $packageTrueProject | Out-Null
        Add-Project -SolutionPath $sourceSolutionPath -RelativePath 'PackageFalse/PackageFalse.csproj' -Content $packageFalseProject | Out-Null
        Add-Project -SolutionPath $sourceSolutionPath -RelativePath 'DataMinerType/DataMinerType.csproj' -Content $dataMinerTypeProject | Out-Null
        Add-Project -SolutionPath $sourceSolutionPath -RelativePath 'Expression/Expression.csproj' -Content $expressionProject | Out-Null
        Add-Project -SolutionPath $sourceSolutionPath -RelativePath 'CustomAction/CustomAction.csproj' -Content $customActionProject | Out-Null

        $sourceHash = (Get-FileHash -LiteralPath $sourceSolutionPath -Algorithm SHA256).Hash
        $backingSolutionPath = if ($format -eq 'slnf') {
            Join-Path -Path (Split-Path -Parent $sourceSolutionPath) -ChildPath 'PartitionTest.sln'
        } else {
            $null
        }
        $backingSolutionHash = if ($null -ne $backingSolutionPath) {
            (Get-FileHash -LiteralPath $backingSolutionPath -Algorithm SHA256).Hash
        } else {
            $null
        }

        $firstOutput = Invoke-Partition -SolutionPath $sourceSolutionPath
        Assert-Equal -Actual (Get-FileHash -LiteralPath $sourceSolutionPath -Algorithm SHA256).Hash -Expected $sourceHash -Label ".$format source unchanged"
        if ($null -ne $backingSolutionPath) {
            Assert-Equal -Actual (Get-FileHash -LiteralPath $backingSolutionPath -Algorithm SHA256).Hash -Expected $backingSolutionHash -Label ".$format backing solution unchanged"
        }

        Assert-Partition -OutputPath $firstOutput -Partition remaining -ExpectedProject @(
            'CustomAction/CustomAction.csproj',
            'DataMinerType/DataMinerType.csproj',
            'Expression/Expression.csproj',
            'PackageFalse/PackageFalse.csproj',
            'Plain/Plain.csproj'
        ) -ExpectedCount 5
        Assert-Partition -OutputPath $firstOutput -Partition wix -ExpectedProject @('Installer/Installer.wixproj') -ExpectedCount 1
        Assert-Partition -OutputPath $firstOutput -Partition dataminer-package -ExpectedProject @('PackageTrue/PackageTrue.csproj') -ExpectedCount 1

        $secondOutput = Invoke-Partition -SolutionPath $sourceSolutionPath
        foreach ($partition in @('remaining', 'wix', 'dataminer-package')) {
            $firstPath = Get-OutputValue -Name "$partition-solution-path" -Path $firstOutput
            $secondPath = Get-OutputValue -Name "$partition-solution-path" -Path $secondOutput
            Assert-True -Condition ($firstPath -ne $secondPath) -Label ".$format repeated $partition path is unique"
            Assert-True -Condition (Test-Path -LiteralPath $secondPath -PathType Leaf) -Label ".$format repeated $partition solution exists"
        }

        Write-Host "PASS: .$format exact partitions, source preservation, and unique repeat invocation"
    }

    Assert-True -Condition ($testedFormats.Count -gt 0) -Label 'At least one solution format is supported'

    $zeroSolutionPath = New-TestSolution -Name 'ZeroPartitions' -Format $testedFormats[0]
    Add-Project -SolutionPath $zeroSolutionPath -RelativePath 'Plain/Plain.csproj' -Content $plainProject | Out-Null
    $zeroOutput = Invoke-Partition -SolutionPath $zeroSolutionPath
    Assert-Partition -OutputPath $zeroOutput -Partition remaining -ExpectedProject @('Plain/Plain.csproj') -ExpectedCount 1
    Assert-Partition -OutputPath $zeroOutput -Partition wix -ExpectedProject @() -ExpectedCount 0
    Assert-Partition -OutputPath $zeroOutput -Partition dataminer-package -ExpectedProject @() -ExpectedCount 0
    Write-Host 'PASS: zero-count partitions'

    $missingSolutionPath = New-TestSolution -Name 'MissingProject' -Format $testedFormats[0]
    $missingProjectPath = Add-Project -SolutionPath $missingSolutionPath -RelativePath 'Missing/Missing.csproj' -Content $plainProject
    Remove-Item -LiteralPath $missingProjectPath -Force
    Assert-PartitionFailure -SolutionPath $missingSolutionPath -ExpectedMessage 'does not exist' -Label 'Missing project'
    Write-Host 'PASS: missing project fails closed'

    $malformedSolutionPath = New-TestSolution -Name 'MalformedProject' -Format $testedFormats[0]
    $malformedProjectPath = Add-Project -SolutionPath $malformedSolutionPath -RelativePath 'Malformed/Malformed.csproj' -Content $plainProject
    Set-Content -LiteralPath $malformedProjectPath -Value '<Project><PropertyGroup></Project>' -Encoding utf8
    Assert-PartitionFailure -SolutionPath $malformedSolutionPath -ExpectedMessage 'malformed XML' -Label 'Malformed project XML'
    Write-Host 'PASS: malformed project XML fails closed'

    Assert-PartitionFailure -SolutionPath (Join-Path -Path $temporaryDirectory -ChildPath 'missing.sln') -ExpectedMessage 'does not exist' -Label 'Missing solution'
    Write-Host 'PASS: missing solution fails closed'

    Write-Host "All partition-solution-projects tests passed for: $($testedFormats -join ', ')."
} finally {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}