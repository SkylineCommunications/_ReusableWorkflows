$ErrorActionPreference = 'Stop'

$actionDirectory = Split-Path -Parent $PSCommandPath
$scriptPath = Join-Path -Path $actionDirectory -ChildPath 'remove-wix-projects.sh'
$temporaryDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "remove-wix-projects-$([System.Guid]::NewGuid())"
New-Item -Path $temporaryDirectory -ItemType Directory | Out-Null

# Resolve bash: on Linux/macOS runners it is on PATH; on Windows fall back to Git for Windows.
$bash = (Get-Command bash -ErrorAction SilentlyContinue).Source
if ([string]::IsNullOrWhiteSpace($bash)) {
    $bash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
}
if (-not (Test-Path $bash)) {
    throw 'bash was not found (required to run remove-wix-projects.sh).'
}

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

try {
    # --- Scaffold a solution with 4 projects: 1 plain lib, 1 test-ish lib, 1 wixproj, 1 Dtf custom-action csproj.
    Push-Location $temporaryDirectory
    try {
        dotnet new sln --name Demo | Out-Null
        $solutionPath = Get-ChildItem -Path $temporaryDirectory -File | Where-Object { $_.Extension -in '.sln', '.slnx' } | Select-Object -First 1 -ExpandProperty FullName
        if ([string]::IsNullOrWhiteSpace($solutionPath)) { throw 'Solution file was not created.' }

        dotnet new classlib -n PlainLib -o PlainLib | Out-Null
        dotnet new classlib -n OtherLib -o OtherLib | Out-Null
        dotnet sln $solutionPath add PlainLib/PlainLib.csproj OtherLib/OtherLib.csproj | Out-Null

        New-Item -ItemType Directory -Path Installer | Out-Null
        Set-Content -Path Installer/Installer.wixproj -Value '<Project Sdk="WixToolset.Sdk/6.0.0"></Project>'
        dotnet sln $solutionPath add Installer/Installer.wixproj | Out-Null

        New-Item -ItemType Directory -Path CustomActions | Out-Null
        Set-Content -Path CustomActions/CustomActions.csproj -Value @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net48</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="WixToolset.Dtf.CustomAction" Version="6.0.0" />
  </ItemGroup>
</Project>
'@
        dotnet sln $solutionPath add CustomActions/CustomActions.csproj | Out-Null
    } finally {
        Pop-Location
    }

    # --- Run the script.
    $outputFile = Join-Path -Path $temporaryDirectory -ChildPath 'github-output.txt'
    New-Item -Path $outputFile -ItemType File | Out-Null
    $env:GITHUB_OUTPUT = $outputFile
    $env:SOLUTION_PATH = $solutionPath

    try {
        & $bash $scriptPath
        if ($LASTEXITCODE -ne 0) { throw "remove-wix-projects.sh exited with $LASTEXITCODE." }
    } finally {
        Remove-Item Env:\SOLUTION_PATH -ErrorAction SilentlyContinue
    }

    # --- Assert: wixproj + Dtf csproj removed, plain libs kept, count = 2.
    $remaining = @(dotnet sln $solutionPath list | Select-Object -Skip 2 | Where-Object { $_ -ne '' } | ForEach-Object { $_ -replace '\\', '/' })

    Assert-Equal -Actual (Get-OutputValue -Name 'removed-count' -Path $outputFile) -Expected '2' -Label 'removed-count'
    Assert-Equal -Actual ($remaining -contains 'Installer/Installer.wixproj') -Expected $false -Label 'wixproj removed'
    Assert-Equal -Actual ($remaining -contains 'CustomActions/CustomActions.csproj') -Expected $false -Label 'Dtf csproj removed'
    Assert-Equal -Actual ($remaining -contains 'PlainLib/PlainLib.csproj') -Expected $true -Label 'plain lib kept'
    Assert-Equal -Actual ($remaining -contains 'OtherLib/OtherLib.csproj') -Expected $true -Label 'other lib kept'

    # --- Idempotency: running again removes nothing and succeeds.
    $outputFile2 = Join-Path -Path $temporaryDirectory -ChildPath 'github-output-2.txt'
    New-Item -Path $outputFile2 -ItemType File | Out-Null
    $env:GITHUB_OUTPUT = $outputFile2
    $env:SOLUTION_PATH = $solutionPath

    try {
        & $bash $scriptPath
        if ($LASTEXITCODE -ne 0) { throw "remove-wix-projects.sh (2nd run) exited with $LASTEXITCODE." }
    } finally {
        Remove-Item Env:\SOLUTION_PATH -ErrorAction SilentlyContinue
    }

    Assert-Equal -Actual (Get-OutputValue -Name 'removed-count' -Path $outputFile2) -Expected '0' -Label 'removed-count (idempotent re-run)'

    Write-Host 'All remove-wix-projects test cases passed.'
} finally {
    Remove-Item -Path $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
