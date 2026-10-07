[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-RegressionCondition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

try {
    . (Join-Path $PSScriptRoot 'lib\OpenClawAndroid.ps1')

    # OpenClaw 2026.9.7 omits toolFilter.exclude when it is empty. The
    # toolFilter itself is a PSCustomObject after ConvertFrom-Json.
    $openClaw2026_9_7 = @'
{
  "url": "http://127.0.0.1:8765/sse",
  "transport": "streamable-http",
  "connectionTimeoutMs": 10000,
  "requestTimeoutMs": 240000,
  "toolFilter": {
    "include": [
      "select_device",
      "appium_session_management",
      "appium_app_lifecycle",
      "appium_get_page_source"
    ]
  }
}
'@ | ConvertFrom-Json -ErrorAction Stop

    $filter = Get-NormalizedMcpToolFilter -Definition $openClaw2026_9_7
    $includes = @($filter.Include)
    $excludes = @($filter.Exclude)

    Assert-RegressionCondition -Condition ($includes.Count -eq 4) -Message 'Expected four normalized include entries.'
    Assert-RegressionCondition -Condition ($excludes.Count -eq 0) -Message 'A missing exclude property must normalize to an empty array.'
    Assert-RegressionCondition `
        -Condition (Test-ExactToolSet -ActualTools $includes -ExpectedTools $script:AndroidMcpTools) `
        -Message 'The OpenClaw 2026.9.7 tool filter must match the exact Android allowlist.'
    $assessment = Get-AndroidMcpDefinitionAssessment -Definition $openClaw2026_9_7
    Assert-RegressionCondition `
        -Condition $assessment.IsExact `
        -Message 'The matching OpenClaw 2026.9.7 definition must be recognized as exactly configured for an idempotent second run.'

    $scalarShape = [PSCustomObject]@{
        toolFilter = [PSCustomObject]@{
            include = 'select_device'
            exclude = $null
        }
    }
    $scalarFilter = Get-NormalizedMcpToolFilter -Definition $scalarShape
    $scalarIncludes = @($scalarFilter.Include)
    $scalarExcludes = @($scalarFilter.Exclude)

    Assert-RegressionCondition -Condition ($scalarIncludes.Count -eq 1) -Message 'A scalar include must normalize to a one-item array.'
    Assert-RegressionCondition -Condition ($scalarExcludes.Count -eq 0) -Message 'A null exclude must normalize to an empty array.'
    Assert-RegressionCondition `
        -Condition (-not (Test-ExactToolSet -ActualTools $scalarIncludes -ExpectedTools $script:AndroidMcpTools)) `
        -Message 'A scalar partial allowlist must not pass exact tool-set validation.'

    $oneElementShape = [PSCustomObject]@{
        toolFilter = [PSCustomObject]@{
            include = [object[]]@('select_device')
            exclude = [object[]]@()
        }
    }
    $oneElementFilter = Get-NormalizedMcpToolFilter -Definition $oneElementShape
    Assert-RegressionCondition `
        -Condition (@($oneElementFilter.Include).Count -eq 1) `
        -Message 'A one-element collection must remain a one-element collection.'

    Write-Pass 'OpenClaw 2026.9.7 missing-exclude JSON regression passed.'
    Write-Pass 'Scalar, null, one-element, and four-element collection regressions passed.'
    exit 0
}
catch {
    Write-Host "[FAIL] OpenClaw JSON-shape regression failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
