$ErrorActionPreference = 'Stop'
$global:received = @()
$env:GITHUB_STEP_SUMMARY = [IO.Path]::GetTempFileName()
$env:DATAMINER_DEPENDABOT_CATALOG_WEBHOOK_SECRET = 'local-test-secret'
$env:CATALOG_IDS = "7d3e9f10-1111-4aaa-8bbb-000000000001`n7d3e9f10-2222-4aaa-8bbb-000000000002`n7d3e9f10-1111-4aaa-8bbb-000000000001"
$env:VERSION = '1.0.0'
$env:SOURCE_REPOSITORY = 'SkylineCommunications/Test'
$env:WORKFLOW_RUN_ID = '12345'
$env:WORKFLOW_RUN_ATTEMPT = '2'
$env:DEPENDABOT_WEBHOOK_URL = 'https://example.test/api/webhooks/catalog-notification'

function Invoke-RestMethod {
    param($Method, $Uri, $ContentType, $Headers, [byte[]]$Body, $TimeoutSec)
    $payload = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
    $hmac = [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($env:DATAMINER_DEPENDABOT_CATALOG_WEBHOOK_SECRET))
    try {
        $signature = 'sha256=' + [Convert]::ToHexString($hmac.ComputeHash($Body)).ToLowerInvariant()
    } finally {
        $hmac.Dispose()
    }
    if ($Method -ne 'Post' -or $ContentType -ne 'application/json' -or
        $Headers['X-DataMiner-Signature-256'] -ne $signature -or
        $payload.eventId -ne "pub-12345-$($payload.catalogId)" -or
        $payload.workflowRunAttempt -ne 2 -or $payload.version -ne '1.0.0') {
        throw 'Incorrect signed publication notification.'
    }
    $global:received += $payload.catalogId
    return [pscustomobject]@{ Status = 'Enqueued' }
}

try {
    & (Join-Path $PSScriptRoot 'notify-dataminer-dependabot.ps1')
    if ($global:received.Count -ne 2 -or @($global:received | Select-Object -Unique).Count -ne 2) {
        throw 'Expected exactly one signed request for each distinct published ID.'
    }

    Remove-Item Function:Invoke-RestMethod
    function Invoke-RestMethod { throw 'Simulated delivery failure.' }
    $env:CATALOG_IDS = '7d3e9f10-1111-4aaa-8bbb-000000000001'
    & (Join-Path $PSScriptRoot 'notify-dataminer-dependabot.ps1')
    if (-not ((Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw) -match 'Delivery failed')) {
        throw 'Delivery failure was not reported in the workflow summary.'
    }
} finally {
    Remove-Item -LiteralPath $env:GITHUB_STEP_SUMMARY -Force
}