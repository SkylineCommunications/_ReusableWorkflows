$ErrorActionPreference = 'Stop'

# Offline test corpus for sign-assemblies.ps1.
#
# The verifier is mocked in the invocation helper and the Sign CLI is replaced
# by a stub on PATH. Synthetic signature metadata and marked file contents keep
# the corpus offline: no Azure calls, real signing, or certificate-store changes.
# Windows trust integration is covered separately by the composite smoke job.

$scriptPath = Join-Path $PSScriptRoot 'sign-assemblies.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Could not find '$scriptPath'."
}

$failures = @()
$assertionCount = 0
$testCaseCount = 0

function Start-TestCase {
    param([string]$Name)

    $script:testCaseCount++
    Write-Host "Test: $Name"
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Because)

    $script:assertionCount++
    if ("$Expected" -ne "$Actual") {
        $script:failures += "$Because : expected '$Expected' but got '$Actual'."
        Write-Host "  [FAIL] $Because (expected '$Expected', got '$Actual')"
        return
    }

    Write-Host "  [ OK ] $Because"
}

function Assert-RunCount {
    param(
        [Parameter(Mandatory)]$Result,
        [int]$Total,
        [int]$Signed,
        [int]$Copied,
        [int]$Skipped,
        [int]$Batches
    )

    Assert-Equal -Expected '' -Actual $Result.Error -Because 'the action succeeds'
    Assert-Equal -Expected $Total -Actual $Result.Outputs['files-total'] -Because 'files-total counts every matching path'
    Assert-Equal -Expected $Signed -Actual $Result.Outputs['files-signed'] -Because 'files-signed counts remaining representatives'
    Assert-Equal -Expected $Copied -Actual $Result.Outputs['files-copied'] -Because 'files-copied counts remaining duplicates'
    Assert-Equal -Expected $Skipped -Actual $Result.Outputs['files-skipped'] -Because 'files-skipped counts every preserved path'
    Assert-Equal -Expected $Batches -Actual $Result.Outputs['batches'] -Because 'batches counts remaining signing batches'
    Assert-Equal -Expected $Total -Actual (
        [int]$Result.Outputs['files-signed'] +
        [int]$Result.Outputs['files-copied'] +
        [int]$Result.Outputs['files-skipped']
    ) -Because 'signed plus copied plus skipped accounts for every matching path'
}

function New-TestSignature {
    param(
        [string]$Status = 'NotSigned',
        [string]$SignatureType = 'None',
        [switch]$WithSigner
    )

    return [PSCustomObject]@{
        Status            = $Status
        StatusMessage     = 'Synthetic verification result.'
        SignatureType     = $SignatureType
        SignerCertificate = if ($WithSigner.IsPresent) {
            [PSCustomObject]@{ Subject = 'CN=Example Publisher' }
        } else {
            $null
        }
    }
}

function New-TestTree {
    param([hashtable]$File)

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("sign-assemblies-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -Path $root -ItemType Directory -Force | Out-Null

    # Shared.dll has identical content in three project bin folders, Other.dll is
    # unique, Ignored.dll sits outside a bin folder, and Notes.txt has a
    # non-matching extension.
    if ($null -eq $File) {
        $File = @{
            'ProjectA/bin/Release/Shared.dll'  = 'shared-content'
            'ProjectB/bin/Release/Shared.dll'  = 'shared-content'
            'ProjectC/bin/Debug/Shared.dll'    = 'shared-content'
            'ProjectA/bin/Release/Other.dll'   = 'other-content'
            'ProjectA/obj/Release/Ignored.dll' = 'ignored-content'
            'ProjectA/bin/Release/Notes.txt'   = 'not-an-assembly'
        }
    }

    foreach ($entry in $File.GetEnumerator()) {
        $path = Join-Path $root ($entry.Key -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        New-Item -Path (Split-Path $path -Parent) -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath $path -Value $entry.Value -NoNewline
    }

    return $root
}

function Get-TestSnapshot {
    param([Parameter(Mandatory)][string]$Root)

    $snapshot = @{}
    foreach ($file in (Get-ChildItem -LiteralPath $Root -Recurse -File)) {
        $snapshot[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }

    return $snapshot
}

function Assert-TestSnapshot {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][hashtable]$Before
    )

    $after = Get-TestSnapshot -Root $Root
    Assert-Equal -Expected $Before.Count -Actual $after.Count -Because 'the file set is unchanged'
    foreach ($path in ($Before.Keys | Sort-Object)) {
        $relative = [System.IO.Path]::GetRelativePath($Root, $path)
        Assert-Equal -Expected $Before[$path] -Actual $after[$path] -Because "$relative keeps its original bytes"
    }
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

Add-Content -LiteralPath (Join-Path $env:SIGN_STUB_DIR 'invocations.txt') -Value $files -Encoding utf8
exit 0
'@

    Set-Content -Path (Join-Path $Directory 'sign.ps1') -Value $stub
}

function Invoke-SignAssemblies {
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$DryRun,
        [string]$StubDirectory,
        [hashtable]$SignatureByContent = @{},
        [switch]$WithoutSigningSettings,
        [switch]$WithoutVerifier
    )

    $outputFile = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('N') + '.txt')
    $verifiedPaths = [System.Collections.Generic.List[string]]::new()
    $verifiedContents = [System.Collections.Generic.List[string]]::new()
    $commandQueries = [System.Collections.Generic.List[string]]::new()
    $messages = [System.Collections.Generic.List[string]]::new()
    $outputs = @{}
    $signedInputs = @()
    $runError = ''

    # These functions exist only in this helper's scope. Production code has no
    # test hook or trust override, and subsequent invocations get fresh mocks.
    function Get-AuthenticodeSignature {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory, Position = 0)]
            [Alias('FilePath')]
            [string]$LiteralPath
        )

        if ($WithoutVerifier.IsPresent) {
            throw [System.Management.Automation.CommandNotFoundException]::new(
                'Get-AuthenticodeSignature is unavailable in this offline fixture.'
            )
        }

        $verifiedPaths.Add($LiteralPath)
        $content = [System.IO.File]::ReadAllText($LiteralPath)
        $verifiedContents.Add($content)
        if ($SignatureByContent.ContainsKey($content)) {
            $fixture = $SignatureByContent[$content]
            if ($fixture -is [scriptblock]) {
                & $fixture
                return
            }

            return $fixture
        }

        # A stub-signed representative and its copied duplicates become trusted
        # inputs on the next run. The two other values are synthetic third-party
        # fixtures, not a publisher allowlist in the production action.
        if ($content -in @('trusted-content', 'other-trusted-content') -or $content.EndsWith('::SIGNED::')) {
            return New-TestSignature -Status 'Valid' -SignatureType 'Authenticode' -WithSigner
        }

        return New-TestSignature
    }

    function Get-Command {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory, Position = 0)]
            [string[]]$Name,
            [System.Management.Automation.CommandTypes]$CommandType = 'All'
        )

        foreach ($commandName in $Name) {
            $commandQueries.Add($commandName)
        }

        if (($WithoutVerifier.IsPresent -and $Name -contains 'Get-AuthenticodeSignature') -or
            (-not $StubDirectory -and $Name -contains 'sign')) {
            return
        }

        Microsoft.PowerShell.Core\Get-Command @PSBoundParameters
    }

    if (-not $StubDirectory) {
        # Even a regression that omits the tool-availability check must never
        # reach a real Sign CLI installed on the developer's machine.
        function sign {
            throw 'The Sign CLI must not be invoked in this offline fixture.'
        }
    }

    $environmentNames = @(
        'PATH', 'SIGN_STUB_DIR', 'SIGN_ROOT', 'SIGN_DRY_RUN',
        'SIGN_EXTENSIONS', 'SIGN_PATH_SEGMENT',
        'SIGNING_KEY_VAULT_URL', 'SIGNING_KEY_VAULT_CERTIFICATE',
        'AZURE_TENANT_ID', 'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET',
        'GITHUB_OUTPUT'
    )
    $originalEnvironment = @{}
    foreach ($name in $environmentNames) {
        $originalEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name)
    }

    try {
        Set-Content -LiteralPath $outputFile -Value '' -NoNewline
        $invocationFile = if ($StubDirectory) { Join-Path $StubDirectory 'invocations.txt' } else { $null }
        $previousInputCount = if ($invocationFile -and (Test-Path -LiteralPath $invocationFile)) {
            @(Get-Content -LiteralPath $invocationFile).Count
        } else {
            0
        }

        $env:SIGN_STUB_DIR = $null
        if ($StubDirectory) {
            $env:PATH = "$StubDirectory$([System.IO.Path]::PathSeparator)$($originalEnvironment['PATH'])"
            $env:SIGN_STUB_DIR = $StubDirectory
        }

        $env:SIGN_ROOT = $Root
        $env:SIGN_DRY_RUN = if ($DryRun) { 'true' } else { 'false' }
        $env:SIGN_EXTENSIONS = 'dll,exe'
        $env:SIGN_PATH_SEGMENT = 'bin'
        $env:SIGNING_KEY_VAULT_URL = if ($WithoutSigningSettings.IsPresent) { $null } else { 'https://example.vault.azure.net/' }
        $env:SIGNING_KEY_VAULT_CERTIFICATE = if ($WithoutSigningSettings.IsPresent) { $null } else { 'test-certificate' }
        if ($WithoutSigningSettings.IsPresent) {
            foreach ($name in @('AZURE_TENANT_ID', 'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET')) {
                [System.Environment]::SetEnvironmentVariable($name, $null)
            }
        }

        $env:GITHUB_OUTPUT = $outputFile

        try {
            & $scriptPath 6>&1 | ForEach-Object { $messages.Add([string]$_) }
        } catch {
            # Preserve the production failure as an assertion result so the red
            # checkpoint reports every focused regression, rather than aborting
            # at the first deliberately invalid signature.
            $runError = $_.Exception.Message
        }

        foreach ($line in (Get-Content -LiteralPath $outputFile)) {
            if ($line -match '^([^=]+)=(.*)$') {
                $outputs[$Matches[1]] = $Matches[2]
            }
        }

        if ($invocationFile -and (Test-Path -LiteralPath $invocationFile)) {
            $signedInputs = @(Get-Content -LiteralPath $invocationFile | Select-Object -Skip $previousInputCount)
        }
    } finally {
        foreach ($name in $environmentNames) {
            [System.Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name])
        }

        Remove-Item -LiteralPath $outputFile -Force -ErrorAction SilentlyContinue
    }

    return [PSCustomObject]@{
        Outputs          = $outputs
        Error            = $runError
        VerifiedPaths    = $verifiedPaths.ToArray()
        VerifiedContents = $verifiedContents.ToArray()
        CommandQueries   = $commandQueries.ToArray()
        SignedInputs     = $signedInputs
        Messages         = $messages.ToArray()
    }
}

Start-TestCase 'unsigned dry run reports deduplicated counts without touching any files.'
$root = New-TestTree
try {
    $before = Get-TestSnapshot -Root $root
    $result = Invoke-SignAssemblies -Root $root -DryRun -WithoutSigningSettings

    Assert-RunCount -Result $result -Total 4 -Signed 2 -Copied 2 -Skipped 0 -Batches 1
    Assert-Equal -Expected 2 -Actual $result.VerifiedPaths.Count -Because 'dry run really verifies each unique content'
    Assert-Equal -Expected 0 -Actual $result.SignedInputs.Count -Because 'dry run never calls the signer'
    Assert-TestSnapshot -Root $root -Before $before
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Start-TestCase 'every unsigned duplicate location receives the signed bytes.'
$root = New-TestTree
$stubDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("sign-stub-" + [System.Guid]::NewGuid().ToString('N'))
try {
    New-SignStub -Directory $stubDirectory
    $result = Invoke-SignAssemblies -Root $root -StubDirectory $stubDirectory

    Assert-RunCount -Result $result -Total 4 -Signed 2 -Copied 2 -Skipped 0 -Batches 1
    Assert-Equal -Expected 2 -Actual $result.VerifiedPaths.Count -Because 'duplicates do not cause repeated verification'
    Assert-Equal -Expected 2 -Actual @($result.VerifiedContents | Sort-Object -Unique).Count -Because 'both distinct contents are verified'
    Assert-Equal -Expected $true -Actual ($result.Messages -contains '2 unique file content(s) to sign, 2 duplicate(s) to copy afterwards.') -Because 'the downstream-coupled summary keeps its exact shape'

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

    Assert-Equal -Expected 2 -Actual $result.SignedInputs.Count -Because 'the signer was handed exactly the unique files'

    $ignored = Get-Content -LiteralPath (Join-Path $root 'ProjectA/obj/Release/Ignored.dll') -Raw
    Assert-Equal -Expected 'ignored-content' -Actual $ignored -Because 'files outside a bin folder are left alone'

    $notes = Get-Content -LiteralPath (Join-Path $root 'ProjectA/bin/Release/Notes.txt') -Raw
    Assert-Equal -Expected 'not-an-assembly' -Actual $notes -Because 'non-matching extensions are left alone'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stubDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

Start-TestCase 'a re-run preserves trusted outputs instead of submitting them to Sign CLI again.'
$root = New-TestTree
$stubDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("sign-stub-" + [System.Guid]::NewGuid().ToString('N'))
try {
    New-SignStub -Directory $stubDirectory
    $first = Invoke-SignAssemblies -Root $root -StubDirectory $stubDirectory
    Assert-Equal -Expected '' -Actual $first.Error -Because 'the initial unsigned signing pass succeeds'
    Assert-Equal -Expected 2 -Actual $first.SignedInputs.Count -Because 'the initial pass signs only the two representatives'
    $before = Get-TestSnapshot -Root $root
    $result = Invoke-SignAssemblies -Root $root -StubDirectory $stubDirectory

    Assert-RunCount -Result $result -Total 4 -Signed 0 -Copied 0 -Skipped 4 -Batches 0
    Assert-Equal -Expected 2 -Actual $result.VerifiedPaths.Count -Because 'a re-run verifies once per signed content group'
    Assert-Equal -Expected 0 -Actual $result.SignedInputs.Count -Because 'trusted signed outputs are not redundant Sign CLI inputs'
    Assert-Equal -Expected $true -Actual ($result.Messages -contains '0 unique file content(s) to sign, 0 duplicate(s) to copy afterwards.') -Because 'the remaining-work summary is zero on a re-run'
    Assert-TestSnapshot -Root $root -Before $before
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stubDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

foreach ($dryRunCase in @($false, $true)) {
    $mode = if ($dryRunCase) { 'dry run' } else { 'signing pass' }
    Start-TestCase "a mixed $mode preserves third-party trusted groups and retains unsigned deduplication."
    $root = New-TestTree -File @{
        'ProjectA/bin/Release/Shared.dll'  = 'shared-content'
        'ProjectB/bin/Release/Shared.dll'  = 'shared-content'
        'ProjectC/bin/Debug/Shared.dll'    = 'shared-content'
        'ProjectA/bin/Release/Other.dll'   = 'other-content'
        'ProjectA/bin/Release/Trusted.dll' = 'trusted-content'
        'ProjectB/bin/Release/Trusted.dll' = 'trusted-content'
        'ProjectA/obj/Release/Ignored.dll' = 'ignored-content'
        'ProjectA/bin/Release/Notes.txt'   = 'not-an-assembly'
    }
    $stubDirectory = $null
    try {
        if (-not $dryRunCase) {
            $stubDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("sign-stub-" + [System.Guid]::NewGuid().ToString('N'))
            New-SignStub -Directory $stubDirectory
        }

        $before = Get-TestSnapshot -Root $root
        $result = Invoke-SignAssemblies -Root $root -DryRun:$dryRunCase -StubDirectory $stubDirectory -WithoutSigningSettings:$dryRunCase

        Assert-RunCount -Result $result -Total 6 -Signed 2 -Copied 2 -Skipped 2 -Batches 1
        Assert-Equal -Expected 3 -Actual $result.VerifiedPaths.Count -Because 'each of the three SHA256 groups is inspected once'
        Assert-Equal -Expected 3 -Actual @($result.VerifiedContents | Sort-Object -Unique).Count -Because 'verification covers all distinct contents'
        $expectedInputs = if ($dryRunCase) { 0 } else { 2 }
        Assert-Equal -Expected $expectedInputs -Actual $result.SignedInputs.Count -Because 'only remaining unsigned representatives reach Sign CLI'
        Assert-Equal -Expected 0 -Actual @($result.SignedInputs | Where-Object { $_ -match 'Trusted\.dll$' }).Count -Because 'third-party trusted files are never Sign CLI inputs'
        Assert-Equal -Expected $true -Actual ($result.Messages -contains '2 unique file content(s) to sign, 2 duplicate(s) to copy afterwards.') -Because 'the summary describes only remaining work'

        foreach ($path in ($before.Keys | Where-Object { $_ -match 'Trusted\.dll$' } | Sort-Object)) {
            Assert-Equal -Expected $before[$path] -Actual (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -Because 'a trusted path keeps its exact original bytes'
        }

        if ($dryRunCase) {
            Assert-TestSnapshot -Root $root -Before $before
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        if ($stubDirectory) {
            Remove-Item -LiteralPath $stubDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Start-TestCase 'all-trusted normal execution needs neither Sign CLI nor signing settings.'
$root = New-TestTree -File @{
    'ProjectA/bin/Release/Trusted.dll'      = 'trusted-content'
    'ProjectB/bin/Release/Trusted.dll'      = 'trusted-content'
    'ProjectC/bin/Release/OtherTrusted.exe' = 'other-trusted-content'
}
try {
    $before = Get-TestSnapshot -Root $root
    $result = Invoke-SignAssemblies -Root $root -WithoutSigningSettings

    Assert-RunCount -Result $result -Total 3 -Signed 0 -Copied 0 -Skipped 3 -Batches 0
    Assert-Equal -Expected 2 -Actual $result.VerifiedPaths.Count -Because 'all-trusted duplicates are verified only once'
    Assert-Equal -Expected 0 -Actual @($result.CommandQueries | Where-Object { $_ -eq 'sign' }).Count -Because 'an all-skipped scan does not require the sign tool'
    Assert-Equal -Expected 0 -Actual $result.SignedInputs.Count -Because 'all-skipped execution makes no signing calls'
    Assert-TestSnapshot -Root $root -Before $before
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Start-TestCase 'a valid catalog signature is explained and stays on the signing path.'
$root = New-TestTree
$stubDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("sign-stub-" + [System.Guid]::NewGuid().ToString('N'))
try {
    New-SignStub -Directory $stubDirectory
    $result = Invoke-SignAssemblies -Root $root -StubDirectory $stubDirectory -SignatureByContent @{
        'shared-content' = (New-TestSignature -Status 'Valid' -SignatureType 'Catalog' -WithSigner)
    }

    Assert-RunCount -Result $result -Total 4 -Signed 2 -Copied 2 -Skipped 0 -Batches 1
    Assert-Equal -Expected 2 -Actual $result.VerifiedPaths.Count -Because 'catalog and unsigned groups are both inspected'
    Assert-Equal -Expected 2 -Actual $result.SignedInputs.Count -Because 'catalog trust does not remove a signing representative'
    Assert-Equal -Expected 1 -Actual @($result.SignedInputs | Where-Object { $_ -match 'Shared\.dll$' }).Count -Because 'the catalog-signed representative is submitted'
    Assert-Equal -Expected $true -Actual (($result.Messages -join "`n") -match '(?i)catalog.*(embedded|portable|sign)') -Because 'the log explains why catalog trust does not cause a skip'

    foreach ($relative in @('ProjectA/bin/Release/Shared.dll', 'ProjectB/bin/Release/Shared.dll', 'ProjectC/bin/Debug/Shared.dll')) {
        $content = Get-Content -LiteralPath (Join-Path $root $relative) -Raw
        Assert-Equal -Expected 'shared-content::SIGNED::' -Actual $content -Because 'catalog-signed duplicates receive the new embedded-signing result'
    }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stubDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

$failureCases = @()
foreach ($status in @('HashMismatch', 'NotTrusted', 'UnknownError', 'NotSupportedFileFormat', 'Incompatible')) {
    $failureCases += @{
        Name            = "signature status $status"
        Signature       = (New-TestSignature -Status $status)
        ExpectedContext = $status
    }
}
$failureCases += @(
    @{
        Name            = 'Valid Authenticode metadata without a signer certificate'
        Signature       = (New-TestSignature -Status 'Valid' -SignatureType 'Authenticode')
        ExpectedContext = 'Valid'
    },
    @{
        Name            = 'Valid catalog metadata without a signer certificate'
        Signature       = (New-TestSignature -Status 'Valid' -SignatureType 'Catalog')
        ExpectedContext = 'Valid'
    },
    @{
        Name            = 'Valid metadata with an unsupported signature type'
        Signature       = (New-TestSignature -Status 'Valid' -SignatureType 'None' -WithSigner)
        ExpectedContext = 'Valid'
    },
    @{
        Name      = 'Valid metadata with no signature type'
        Signature = [PSCustomObject]@{
            Status            = 'Valid'
            SignerCertificate = [PSCustomObject]@{ Subject = 'CN=Example Publisher' }
        }
        ExpectedContext = 'Valid'
    },
    @{
        Name            = 'a verifier exception'
        Signature       = { throw 'Synthetic verification failure.' }
        ExpectedContext = [regex]::Escape('Synthetic verification failure.')
    },
    @{
        Name            = 'an empty verifier result'
        Signature       = $null
        ExpectedContext = '(?i)(signature|metadata|verification)'
    }
)

foreach ($case in $failureCases) {
    Start-TestCase "$($case.Name) fails closed before any signing or copying."
    $root = New-TestTree
    $stubDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("sign-stub-" + [System.Guid]::NewGuid().ToString('N'))
    try {
        New-SignStub -Directory $stubDirectory
        $before = Get-TestSnapshot -Root $root

        # Reject the last hash group so an unsigned group has already been
        # inspected. Preflight must finish successfully for the whole scan
        # before any pending representative is signed or copied.
        $orderedRepresentatives = @(
            (Join-Path $root 'ProjectA/bin/Release/Shared.dll')
            (Join-Path $root 'ProjectA/bin/Release/Other.dll')
        ) | Sort-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
        $rejectedPath = [System.IO.Path]::GetFullPath($orderedRepresentatives[-1])
        $signatures = @{}
        $signatures[[System.IO.File]::ReadAllText($rejectedPath)] = $case.Signature
        $result = Invoke-SignAssemblies -Root $root -StubDirectory $stubDirectory -SignatureByContent $signatures

        Assert-Equal -Expected $true -Actual (-not [string]::IsNullOrWhiteSpace($result.Error)) -Because 'verification failure is explicit'
        Assert-Equal -Expected $true -Actual $result.Error.Contains($rejectedPath) -Because 'the failure identifies the affected file'
        Assert-Equal -Expected $true -Actual ($result.Error -match $case.ExpectedContext) -Because 'the failure includes status or verification-error context'
        Assert-Equal -Expected 2 -Actual $result.VerifiedPaths.Count -Because 'the pending unsigned group was inspected before the rejected group'
        Assert-Equal -Expected 0 -Actual $result.SignedInputs.Count -Because 'a preflight failure submits no files to Sign CLI'
        Assert-TestSnapshot -Root $root -Before $before
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stubDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Start-TestCase 'dry run still rejects invalid signatures before reporting a signing plan.'
$root = New-TestTree
try {
    $before = Get-TestSnapshot -Root $root
    $result = Invoke-SignAssemblies -Root $root -DryRun -WithoutSigningSettings -SignatureByContent @{
        'shared-content' = (New-TestSignature -Status 'HashMismatch')
    }

    Assert-Equal -Expected $true -Actual ($result.Error -match 'HashMismatch') -Because 'dry run performs real signature-status preflight'
    Assert-Equal -Expected $true -Actual ($result.Error -match 'Shared\.dll') -Because 'dry-run failure includes the rejected file'
    Assert-Equal -Expected 0 -Actual $result.SignedInputs.Count -Because 'invalid dry run never calls the signer'
    Assert-TestSnapshot -Root $root -Before $before
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Start-TestCase 'a missing verifier fails clearly when candidate files need inspection.'
$root = New-TestTree
try {
    $before = Get-TestSnapshot -Root $root
    $result = Invoke-SignAssemblies -Root $root -DryRun -WithoutSigningSettings -WithoutVerifier

    Assert-Equal -Expected $true -Actual (-not [string]::IsNullOrWhiteSpace($result.Error)) -Because 'missing verification cannot silently sign or skip candidates'
    Assert-Equal -Expected $true -Actual ($result.Error -match 'Get-AuthenticodeSignature') -Because 'the failure names the missing verifier'
    Assert-Equal -Expected 0 -Actual $result.SignedInputs.Count -Because 'missing verification never reaches Sign CLI'
    Assert-TestSnapshot -Root $root -Before $before
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Start-TestCase 'an empty scan reports all zeros without verifier, Sign CLI, or signing settings.'
$root = New-TestTree -File @{}
try {
    $result = Invoke-SignAssemblies -Root $root -WithoutSigningSettings -WithoutVerifier

    Assert-RunCount -Result $result -Total 0 -Signed 0 -Copied 0 -Skipped 0 -Batches 0
    Assert-Equal -Expected 0 -Actual $result.VerifiedPaths.Count -Because 'there is nothing to inspect'
    Assert-Equal -Expected 0 -Actual $result.CommandQueries.Count -Because 'an empty scan needs neither verifier nor signer'
    Assert-Equal -Expected 0 -Actual $result.SignedInputs.Count -Because 'an empty scan makes no signing calls'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($failures.Count) of $assertionCount assertion(s) failed across $testCaseCount test case(s):"
    $failures | ForEach-Object { Write-Host "  - $_" }
    exit 1
}

Write-Host ''
Write-Host "All sign-assemblies tests passed ($assertionCount assertion(s), $testCaseCount test case(s))."
