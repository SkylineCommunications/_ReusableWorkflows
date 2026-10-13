$ErrorActionPreference = 'Stop'

function Write-NotificationWarning([string]$message) {
    Write-Output "::warning title=DataMiner Dependabot notification::$message"
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value "- DataMiner Dependabot: $message"
}

if ([string]::IsNullOrWhiteSpace($env:DATAMINER_DEPENDABOT_CATALOG_WEBHOOK_SECRET)) {
    Write-NotificationWarning 'Catalog webhook signing secret could not be loaded; notifications were skipped.'
    return
}

$catalogIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($value in ($env:CATALOG_IDS -split '\r?\n')) {
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    $catalogGuid = [guid]::Empty
    if (-not [guid]::TryParseExact($value.Trim(), 'D', [ref]$catalogGuid)) {
        Write-NotificationWarning 'Invalid Catalog ID found in published artifacts; notification skipped.'
        continue
    }
    $null = $catalogIds.Add($catalogGuid.ToString('D'))
}

if ($catalogIds.Count -eq 0) {
    Write-NotificationWarning 'No published Catalog IDs were found; no notifications were sent.'
    return
}

foreach ($catalogId in $catalogIds) {
    $eventId = "pub-$env:WORKFLOW_RUN_ID-$catalogId"
    $payload = @{
        eventId = $eventId
        catalogId = $catalogId
        version = $env:VERSION
        sourceRepository = $env:SOURCE_REPOSITORY
        workflowRunId = $env:WORKFLOW_RUN_ID
        workflowRunAttempt = [int]$env:WORKFLOW_RUN_ATTEMPT
    } | ConvertTo-Json -Compress
    $body = [Text.Encoding]::UTF8.GetBytes($payload)
    $hmac = [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($env:DATAMINER_DEPENDABOT_CATALOG_WEBHOOK_SECRET))
    try {
        $signature = [Convert]::ToHexString($hmac.ComputeHash($body)).ToLowerInvariant()
    } finally {
        $hmac.Dispose()
    }

    try {
        $response = Invoke-RestMethod -Method Post -Uri $env:DEPENDABOT_WEBHOOK_URL `
            -ContentType 'application/json' -Headers @{ 'X-DataMiner-Signature-256' = "sha256=$signature" } `
            -Body $body -TimeoutSec 30
        if ($response.Status -notin @('Enqueued', 'Deduplicated')) { throw 'Unexpected notification response.' }
        Write-Output "DataMiner Dependabot notification for ${catalogId}: $($response.Status)"
    } catch {
        Write-NotificationWarning "Delivery failed for $catalogId ($($_.Exception.GetType().Name)); retry with event ID $eventId."
    }
}