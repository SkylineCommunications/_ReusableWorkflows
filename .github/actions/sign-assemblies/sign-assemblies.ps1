$ErrorActionPreference = 'Stop'

function Get-EnvironmentValue {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [string]$Default = ''
    )

    $value = [System.Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }

    return $value.Trim()
}

function Write-StepOutput {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Values
    )

    foreach ($key in $Values.Keys) {
        Write-Host "$key=$($Values[$key])"
    }

    if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
        return
    }

    $writer = [System.IO.StreamWriter]::new($env:GITHUB_OUTPUT, $true, [System.Text.UTF8Encoding]::new($false))
    try {
        foreach ($key in $Values.Keys) {
            $writer.WriteLine("$key=$($Values[$key])")
        }
    } finally {
        $writer.Dispose()
    }
}

# The Sign CLI signs one file at a time, so two byte-identical files cost two
# Azure Key Vault signing requests for an identical result. Solutions copy the
# same third-party assemblies into every project's bin folder, which multiplies
# the request count by the number of projects and trips the per-vault rate limit
# (HTTP 429 VaultRequestTypeLimitReached). Grouping by content hash lets us sign
# each distinct file once; every path that held that content still ends up with
# the signed bytes because the signed representative is copied back over them.
function Get-SignGroup {
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string[]]$Extension,

        [Parameter(Mandatory)]
        [string]$PathSegment
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $segmentMarker = "$separator$PathSegment$separator"

    $candidates = Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $Extension -contains $_.Extension.TrimStart('.').ToLowerInvariant() } |
        Where-Object { $_.FullName.Replace('/', $separator).Replace('\', $separator).Contains($segmentMarker) }

    $groups = @()
    foreach ($group in ($candidates | Group-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })) {
        # Sort so the representative is stable between runs, which keeps re-runs
        # signing the same path and makes the logs comparable.
        $paths = @($group.Group | ForEach-Object { $_.FullName } | Sort-Object)
        $groups += [PSCustomObject]@{
            Representative = $paths[0]
            Duplicates     = @($paths | Select-Object -Skip 1)
        }
    }

    return $groups
}

# Windows caps a command line at ~32k characters and a large solution can have
# thousands of distinct assemblies, so representatives are signed in chunks.
function Get-SignBatch {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$RelativePath,

        [int]$MaxCommandLength = 24000
    )

    $batches = @()
    $current = @()
    $currentLength = 0

    foreach ($path in $RelativePath) {
        $cost = $path.Length + 3
        if ($current.Count -gt 0 -and ($currentLength + $cost) -gt $MaxCommandLength) {
            $batches += , $current
            $current = @()
            $currentLength = 0
        }

        $current += $path
        $currentLength += $cost
    }

    if ($current.Count -gt 0) {
        $batches += , $current
    }

    return $batches
}

function Copy-SignedFile {
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    # Build servers (VBCSCompiler, MSBuild node reuse) can still hold a handle on
    # a freshly produced assembly, so a copy can hit a sharing violation.
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force
            return
        } catch {
            if ($attempt -eq 5) {
                throw "Could not copy signed file '$Source' to '$Destination': $($_.Exception.Message)"
            }

            Start-Sleep -Seconds 2
        }
    }
}

$root = Get-EnvironmentValue -Name 'SIGN_ROOT' -Default '.'
$rootFullPath = [System.IO.Path]::GetFullPath($root)
if (-not (Test-Path -LiteralPath $rootFullPath -PathType Container)) {
    throw "Root directory '$rootFullPath' does not exist."
}

$extensions = @(
    (Get-EnvironmentValue -Name 'SIGN_EXTENSIONS' -Default 'dll,exe') -split ',' |
        ForEach-Object { $_.Trim().TrimStart('.').ToLowerInvariant() } |
        Where-Object { $_ }
)
if ($extensions.Count -eq 0) {
    throw 'SIGN_EXTENSIONS must contain at least one extension.'
}

$pathSegment = Get-EnvironmentValue -Name 'SIGN_PATH_SEGMENT' -Default 'bin'
$dryRun = (Get-EnvironmentValue -Name 'SIGN_DRY_RUN' -Default 'false').Equals('true', [System.StringComparison]::OrdinalIgnoreCase)

$groups = @(Get-SignGroup -Root $rootFullPath -Extension $extensions -PathSegment $pathSegment)
$duplicateCount = @($groups | ForEach-Object { $_.Duplicates }).Count
$totalFiles = $groups.Count + $duplicateCount

Write-Host "Found $totalFiles build output file(s) under '$rootFullPath' matching: $($extensions -join ', ')."
Write-Host "$($groups.Count) unique file content(s) to sign, $duplicateCount duplicate(s) to copy afterwards."

if ($groups.Count -eq 0) {
    Write-StepOutput -Values @{
        'files-total'  = 0
        'files-signed' = 0
        'files-copied' = 0
        'batches'      = 0
    }
    return
}

$relativePaths = @($groups | ForEach-Object { [System.IO.Path]::GetRelativePath($rootFullPath, $_.Representative) })
$batches = @(Get-SignBatch -RelativePath $relativePaths)

if ($dryRun) {
    Write-Host 'Dry run: not invoking the Sign CLI and not copying representatives.'
    Write-StepOutput -Values @{
        'files-total'  = $totalFiles
        'files-signed' = $groups.Count
        'files-copied' = $duplicateCount
        'batches'      = $batches.Count
    }
    return
}

if ($null -eq (Get-Command sign -ErrorAction SilentlyContinue)) {
    throw "The 'sign' tool must be installed and available on PATH."
}

$keyVaultUrl = Get-EnvironmentValue -Name 'SIGNING_KEY_VAULT_URL'
$keyVaultCertificate = Get-EnvironmentValue -Name 'SIGNING_KEY_VAULT_CERTIFICATE'
if ([string]::IsNullOrWhiteSpace($keyVaultUrl) -or [string]::IsNullOrWhiteSpace($keyVaultCertificate)) {
    throw 'SIGNING_KEY_VAULT_URL and SIGNING_KEY_VAULT_CERTIFICATE must be set.'
}

$commonArguments = @(
    '--base-directory', $rootFullPath
    '--publisher-name', (Get-EnvironmentValue -Name 'SIGN_PUBLISHER_NAME' -Default 'Skyline Communications')
    '--description', (Get-EnvironmentValue -Name 'SIGN_DESCRIPTION' -Default 'Skyline Signing')
    '--description-url', (Get-EnvironmentValue -Name 'SIGN_DESCRIPTION_URL' -Default 'https://www.skyline.be/')
    '--azure-key-vault-certificate', $keyVaultCertificate
    '--azure-key-vault-url', $keyVaultUrl
)

for ($batchIndex = 0; $batchIndex -lt $batches.Count; $batchIndex++) {
    $batch = @($batches[$batchIndex])
    Write-Host "Signing batch $($batchIndex + 1) of $($batches.Count) ($($batch.Count) file(s))."

    & sign code azure-key-vault @batch @commonArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Signing failed with exit code $LASTEXITCODE."
    }
}

# Every path that held this content before deduplication must hold the signed
# bytes afterwards, otherwise packaging would pick up unsigned assemblies.
foreach ($group in $groups) {
    foreach ($duplicate in $group.Duplicates) {
        Copy-SignedFile -Source $group.Representative -Destination $duplicate
    }
}

Write-Host "Signed $($groups.Count) unique file(s) and copied the signed result over $duplicateCount duplicate(s)."

Write-StepOutput -Values @{
    'files-total'  = $totalFiles
    'files-signed' = $groups.Count
    'files-copied' = $duplicateCount
    'batches'      = $batches.Count
}
