$ErrorActionPreference = 'Stop'

$actionDirectory = Split-Path -Parent $PSCommandPath
$scriptPath = Join-Path -Path $actionDirectory -ChildPath 'set-repo-type.ps1'

# Dot-source the action script. `InvocationName` becomes '.', so Invoke-Main is NOT run — only the
# pure helper functions are defined, which is exactly what we unit-test here (no API calls).
. $scriptPath

$script:failures = 0

function Assert-Equal {
    param(
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected,
        [Parameter(Mandatory)][string]$Label
    )

    if ($Actual -ne $Expected) {
        Write-Host "FAIL  ${Label}: expected '${Expected}', got '${Actual}'."
        $script:failures++
        return
    }
    Write-Host "PASS  $Label"
}

function Assert-True {
    param(
        [bool]$Condition,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not $Condition) {
        Write-Host "FAIL  ${Label}: expected condition to be true."
        $script:failures++
        return
    }
    Write-Host "PASS  $Label"
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Label
    )

    try {
        & $Action | Out-Null
        Write-Host "FAIL  ${Label}: expected an exception, none thrown."
        $script:failures++
    }
    catch {
        Write-Host "PASS  $Label"
    }
}

# ---- ConvertTo-RepoTypeSet ------------------------------------------------------------------------

Assert-Equal -Label 'empty string -> empty set' `
    -Actual ((ConvertTo-RepoTypeSet -Raw '') -join ',') -Expected ''

Assert-Equal -Label 'whitespace -> empty set' `
    -Actual ((ConvertTo-RepoTypeSet -Raw '   ') -join ',') -Expected ''

Assert-Equal -Label 'single comma value' `
    -Actual ((ConvertTo-RepoTypeSet -Raw 'Connector') -join ',') -Expected 'Connector'

Assert-Equal -Label 'comma list, canonical order' `
    -Actual ((ConvertTo-RepoTypeSet -Raw 'NuGet,DxM') -join ',') -Expected 'DxM,NuGet'

Assert-Equal -Label 'comma list with spaces' `
    -Actual ((ConvertTo-RepoTypeSet -Raw ' DxM , AppPackage ') -join ',') -Expected 'DxM,AppPackage'

Assert-Equal -Label 'JSON array' `
    -Actual ((ConvertTo-RepoTypeSet -Raw '["DxM","NuGet"]') -join ',') -Expected 'DxM,NuGet'

Assert-Equal -Label 'case-insensitive -> canonical casing' `
    -Actual ((ConvertTo-RepoTypeSet -Raw 'dxm,NUGET,apppackage') -join ',') -Expected 'DxM,NuGet,AppPackage'

Assert-Equal -Label 'duplicates removed' `
    -Actual ((ConvertTo-RepoTypeSet -Raw 'DxM,DxM,dxm') -join ',') -Expected 'DxM'

Assert-Equal -Label 'empty tokens ignored' `
    -Actual ((ConvertTo-RepoTypeSet -Raw 'DxM,,NuGet,') -join ',') -Expected 'DxM,NuGet'

Assert-Equal -Label 'all four, stable canonical order' `
    -Actual ((ConvertTo-RepoTypeSet -Raw 'AppPackage,Connector,NuGet,DxM') -join ',') -Expected 'DxM,NuGet,Connector,AppPackage'

Assert-Throws -Label 'invalid value throws' -Action { ConvertTo-RepoTypeSet -Raw 'DxM,Bogus' }

# ---- Test-RepoTypeSetEqual ------------------------------------------------------------------------

Assert-True -Label 'equal sets (same order)' `
    -Condition (Test-RepoTypeSetEqual -First @('DxM', 'NuGet') -Second @('DxM', 'NuGet'))

Assert-True -Label 'equal sets (different order)' `
    -Condition (Test-RepoTypeSetEqual -First @('NuGet', 'DxM') -Second @('DxM', 'NuGet'))

Assert-True -Label 'both empty are equal' `
    -Condition (Test-RepoTypeSetEqual -First @() -Second @())

Assert-True -Label 'different length not equal' `
    -Condition (-not (Test-RepoTypeSetEqual -First @('DxM') -Second @('DxM', 'NuGet')))

Assert-True -Label 'different content not equal' `
    -Condition (-not (Test-RepoTypeSetEqual -First @('DxM') -Second @('NuGet')))

# ---- ConvertTo-PropertyPatchBody ------------------------------------------------------------------

$singleBody = ConvertTo-PropertyPatchBody -PropertyName 'Workflow-Repo-Type' -Value @('Connector')
$singleParsed = $singleBody | ConvertFrom-Json
Assert-Equal -Label 'body property_name' `
    -Actual $singleParsed.properties[0].property_name -Expected 'Workflow-Repo-Type'
Assert-True -Label 'single value serialises as JSON array' `
    -Condition ($singleParsed.properties[0].value -is [array])
Assert-Equal -Label 'single value content' `
    -Actual ($singleParsed.properties[0].value -join ',') -Expected 'Connector'

$multiBody = ConvertTo-PropertyPatchBody -PropertyName 'Workflow-Repo-Type' -Value @('DxM', 'NuGet')
$multiParsed = $multiBody | ConvertFrom-Json
Assert-Equal -Label 'multi value content' `
    -Actual ($multiParsed.properties[0].value -join ',') -Expected 'DxM,NuGet'

# ---- ConvertTo-OrgPropertyPatchBody ---------------------------------------------------------------

$orgBody = ConvertTo-OrgPropertyPatchBody -PropertyName 'Workflow-Repo-Type' -Value @('Connector') -RepositoryName 'MyRepo'
$orgParsed = $orgBody | ConvertFrom-Json
Assert-True -Label 'org body repository_names is an array' `
    -Condition ($orgParsed.repository_names -is [array])
Assert-Equal -Label 'org body repository_names content' `
    -Actual ($orgParsed.repository_names -join ',') -Expected 'MyRepo'
Assert-Equal -Label 'org body property_name' `
    -Actual $orgParsed.properties[0].property_name -Expected 'Workflow-Repo-Type'
Assert-True -Label 'org body single value serialises as JSON array' `
    -Condition ($orgParsed.properties[0].value -is [array])
Assert-Equal -Label 'org body value content' `
    -Actual ($orgParsed.properties[0].value -join ',') -Expected 'Connector'

# ---- Result ---------------------------------------------------------------------------------------

if ($script:failures -gt 0) {
    throw "$script:failures test case(s) failed."
}

Write-Host 'All set-repo-type test cases passed.'
