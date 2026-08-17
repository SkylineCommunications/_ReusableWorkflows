$ErrorActionPreference = 'Stop'

# Offline test corpus for sign-assemblies.ps1.
#
# The Sign CLI is replaced by a stub on PATH so the deduplication and the
# copy-back behaviour can be verified without Azure Key Vault. The stub marks
# every file it is handed, which lets the assertions prove that *all* paths that
# held a given content before deduplication hold signed content afterwards.

$scriptPath = Join-Path $PSScriptRoot 'sign-assemblies.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Could not find '$scriptPath'."
}

$failures = @()

function Assert-Equal {
    param($Expected, $Actual, [string]$Because)

    if ("$Expected" -ne "$Actual") {
        $script:failures += "$Because : expected '$Expected' but got '$Actual'."
        Write-Host "  [FAIL] $Because (expected '$Expected', got '$Actual')"
        return
    }

    Write-Host "  [ OK ] $Because"
}

function New-TestTree {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sign-assemblies-" + [System.Guid]::NewGuid().ToString('N'))

    # Shared.dll has identical content in three project bin folders, Other.dll is
    # unique, Ignored.dll sits outside a bin folder, and Notes.txt has a
    # non-matching extension.
    $files = @{
        'ProjectA/bin/Release/Shared.dll'  = 'shared-content'
        'ProjectB/bin/Release/Shared.dll'  = 'shared-content'
        'ProjectC/bin/Debug/Shared.dll'    = 'shared-content'
        'ProjectA/bin/Release/Other.dll'   = 'other-content'
        'ProjectA/obj/Release/Ignored.dll' = 'ignored-content'
        'ProjectA/bin/Release/Notes.txt'   = 'not-an-assembly'
    }

    foreach ($file in $files.GetEnumerator()) {
        $path = Join-Path $root ($file.Key -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        New-Item -Path (Split-Path $path -Parent) -ItemType Directory -Force | Out-Null
        Set-Content -Path $path -Value $file.Value -NoNewline
    }

    return $root
}

function New-SignStub {
    param([Parameter(Mandatory)][string]$Directory)

    New-Item -Path $Directory -ItemType Directory -Force | Out-Null

    # PowerShell resolves .ps1 files found on PATH as commands, so this shadows
    # the real `sign` tool for the duration of the test.
    $stub = @'
$ErrorActionPreference = 'Stop'

$files = @()
$baseDirectory = (Get-Location).Path

for ($i = 0; $i -lt $args.Count; $i++) {
    $argument = [string]$args[$i]

    if ($argument -eq '--base-directory') {
        $baseDirectory = [string]$args[$i + 1]
        $i++
        continue
    }

    if ($argument.StartsWith('--')) {
        $i++
        continue
    }

    if ($argument -in 'code', 'azure-key-vault') {
        continue
    }

    $files += $argument
}

foreach ($file in $files) {
    $path = if ([System.IO.Path]::IsPathFullyQualified($file)) { $file } else { Join-Path $baseDirectory $file }
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Error "Stub received a path that does not exist: $path"
        exit 1
    }

    Add-Content -LiteralPath $path -Value '::SIGNED::' -NoNewline
}

Set-Content -LiteralPath (Join-Path $env:SIGN_STUB_DIR 'invocations.txt') -Value $files -Encoding utf8 -Force
exit 0
'@

    Set-Content -Path (Join-Path $Directory 'sign.ps1') -Value $stub
}

function Invoke-SignAssemblies {
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$DryRun,
        [string]$StubDirectory
    )

    $outputFile = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('N') + '.txt')
    Set-Content -Path $outputFile -Value '' -NoNewline

    $originalPath = $env:PATH
    try {
        if ($StubDirectory) {
            $env:PATH = "$StubDirectory$([System.IO.Path]::PathSeparator)$originalPath"
            $env:SIGN_STUB_DIR = $StubDirectory
        }

        $env:SIGN_ROOT = $Root
        $env:SIGN_DRY_RUN = if ($DryRun) { 'true' } else { 'false' }
        $env:SIGN_EXTENSIONS = 'dll,exe'
        $env:SIGN_PATH_SEGMENT = 'bin'
        $env:SIGNING_KEY_VAULT_URL = 'https://example.vault.azure.net/'
        $env:SIGNING_KEY_VAULT_CERTIFICATE = 'test-certificate'
        $env:GITHUB_OUTPUT = $outputFile

        & $scriptPath | Out-Null
    } finally {
        $env:PATH = $originalPath
        Remove-Item Env:\SIGN_STUB_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:\GITHUB_OUTPUT -ErrorAction SilentlyContinue
    }

    $outputs = @{}
    foreach ($line in (Get-Content -LiteralPath $outputFile -ErrorAction SilentlyContinue)) {
        if ($line -match '^([^=]+)=(.*)$') {
            $outputs[$Matches[1]] = $Matches[2]
        }
    }

    Remove-Item -LiteralPath $outputFile -Force -ErrorAction SilentlyContinue
    return $outputs
}

Write-Host 'Test: dry run reports deduplicated counts without touching files.'
$root = New-TestTree
try {
    $outputs = Invoke-SignAssemblies -Root $root -DryRun

    Assert-Equal -Expected 4 -Actual $outputs['files-total'] -Because 'files-total counts every matching build output'
    Assert-Equal -Expected 2 -Actual $outputs['files-signed'] -Because 'files-signed counts unique contents only'
    Assert-Equal -Expected 2 -Actual $outputs['files-copied'] -Because 'files-copied counts the duplicates'
    Assert-Equal -Expected 1 -Actual $outputs['batches'] -Because 'a small corpus fits in one batch'

    $sharedContent = Get-Content -LiteralPath (Join-Path $root 'ProjectA/bin/Release/Shared.dll') -Raw
    Assert-Equal -Expected 'shared-content' -Actual $sharedContent -Because 'a dry run does not modify files'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Test: every duplicate location receives the signed bytes.'
$root = New-TestTree
$stubDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("sign-stub-" + [System.Guid]::NewGuid().ToString('N'))
try {
    New-SignStub -Directory $stubDirectory
    $outputs = Invoke-SignAssemblies -Root $root -StubDirectory $stubDirectory

    Assert-Equal -Expected 4 -Actual $outputs['files-total'] -Because 'files-total counts every matching build output'
    Assert-Equal -Expected 2 -Actual $outputs['files-signed'] -Because 'only unique contents are sent to the signer'
    Assert-Equal -Expected 2 -Actual $outputs['files-copied'] -Because 'both duplicates are copied back'

    # The core guarantee: deduplication must not leave any location unsigned.
    $mustBeSigned = @(
        'ProjectA/bin/Release/Shared.dll'
        'ProjectB/bin/Release/Shared.dll'
        'ProjectC/bin/Debug/Shared.dll'
        'ProjectA/bin/Release/Other.dll'
    )

    foreach ($relative in $mustBeSigned) {
        $content = Get-Content -LiteralPath (Join-Path $root $relative) -Raw
        Assert-Equal -Expected $true -Actual $content.EndsWith('::SIGNED::') -Because "$relative holds signed content"
    }

    $signedInvocations = @(Get-Content -LiteralPath (Join-Path $stubDirectory 'invocations.txt'))
    Assert-Equal -Expected 2 -Actual $signedInvocations.Count -Because 'the signer was handed exactly the unique files'

    $ignored = Get-Content -LiteralPath (Join-Path $root 'ProjectA/obj/Release/Ignored.dll') -Raw
    Assert-Equal -Expected 'ignored-content' -Actual $ignored -Because 'files outside a bin folder are left alone'

    $notes = Get-Content -LiteralPath (Join-Path $root 'ProjectA/bin/Release/Notes.txt') -Raw
    Assert-Equal -Expected 'not-an-assembly' -Actual $notes -Because 'non-matching extensions are left alone'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stubDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Test: an already deduplicated tree signs cleanly a second time.'
$root = New-TestTree
$stubDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("sign-stub-" + [System.Guid]::NewGuid().ToString('N'))
try {
    New-SignStub -Directory $stubDirectory
    Invoke-SignAssemblies -Root $root -StubDirectory $stubDirectory | Out-Null
    $outputs = Invoke-SignAssemblies -Root $root -StubDirectory $stubDirectory

    # After the first pass the duplicates are byte-identical to their signed
    # representative, so the grouping must stay stable rather than fan back out.
    Assert-Equal -Expected 4 -Actual $outputs['files-total'] -Because 'the file count is unchanged on a re-run'
    Assert-Equal -Expected 2 -Actual $outputs['files-signed'] -Because 're-running still signs only the unique contents'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stubDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($failures.Count) assertion(s) failed:"
    $failures | ForEach-Object { Write-Host "  - $_" }
    exit 1
}

Write-Host ''
Write-Host 'All sign-assemblies tests passed.'
