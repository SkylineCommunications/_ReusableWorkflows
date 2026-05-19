# Detects the test runner configured in global.json.
$ErrorActionPreference = 'Stop'

$globalJsonPath = Join-Path $env:GITHUB_WORKSPACE 'global.json'

if (Test-Path $globalJsonPath) {
    $jsonContent = Get-Content $globalJsonPath -Raw | ConvertFrom-Json
    $runner = $jsonContent.test.runner

    if ($runner -eq 'Microsoft.Testing.Platform') {
        Write-Host 'Detected Microsoft.Testing.Platform (MTP) test runner in global.json'
        "test-runner-mode=mtp" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
        return
    }
}

Write-Host 'Using default VSTest test runner'
"test-runner-mode=vstest" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
