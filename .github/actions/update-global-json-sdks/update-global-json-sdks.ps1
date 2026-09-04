# Central source of truth for all managed SDK versions.
$DATAMINER_SDK_VERSION = '2.5.8'

$dataMinerSdkPatterns = @(
    '^Skyline\.DataMiner\..*'
)

$otherManagedSdks = @{
    # 'Skyline.DataMiner.Sdk.WindowsInstaller' = '1.0.0'
    # 'Company.Other.Sdk'                      = '1.0.0'
}

$globalJsonPaths = @(
    Get-ChildItem -Path $env:GITHUB_WORKSPACE -Filter 'global.json' -File -Recurse -Depth 3 -Force
)

if ($globalJsonPaths.Count -eq 0) {
    Write-Host 'No global.json files found through subdirectory depth 3. Skipping update.'
    return
}

foreach ($globalJsonPath in $globalJsonPaths) {
    $relativePath = [System.IO.Path]::GetRelativePath($env:GITHUB_WORKSPACE, $globalJsonPath.FullName)
    $jsonContent = Get-Content $globalJsonPath.FullName -Raw | ConvertFrom-Json

    if (-not $jsonContent.'msbuild-sdks') {
        Write-Host "$relativePath has no 'msbuild-sdks' section. Skipping update."
        continue
    }

    $sdks = $jsonContent.'msbuild-sdks'
    $changes = @()

    foreach ($property in @($sdks.PSObject.Properties)) {
        $name = $property.Name
        $oldValue = $property.Value
        $newValue = $null

        if ($otherManagedSdks.ContainsKey($name)) {
            $newValue = $otherManagedSdks[$name]
        }

        if (-not $newValue) {
            foreach ($pattern in $dataMinerSdkPatterns) {
                if ($name -match $pattern) {
                    $newValue = $DATAMINER_SDK_VERSION
                    break
                }
            }
        }

        if ($null -ne $newValue -and $oldValue -ne $newValue) {
            $sdks.$name = $newValue
            $changes += "  ${name}: $oldValue -> $newValue"
        }
    }

    if ($changes.Count -eq 0) {
        Write-Host "No msbuild-sdks entries needed updating in $relativePath."
        continue
    }

    $updatedJson = $jsonContent | ConvertTo-Json -Depth 10
    $updatedJson | Set-Content $globalJsonPath.FullName -Encoding UTF8

    Write-Host "Updated msbuild-sdks in ${relativePath}:"
    $changes | ForEach-Object { Write-Host $_ }
    Write-Host ''
    Write-Host "New ${relativePath}:"
    Write-Host $updatedJson
}