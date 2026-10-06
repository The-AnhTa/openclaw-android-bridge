[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    . (Join-Path $PSScriptRoot 'lib\Common.ps1')

    $allChecksPassed = Test-WindowsHostPrerequisites

    $androidEnvironment = Initialize-AndroidEnvironment
    if (-not $androidEnvironment.IsValid) {
        $allChecksPassed = $false
    }

    if ($androidEnvironment.AdbPath) {
        if (-not (Test-ConnectedAndroidDevice -AdbPath $androidEnvironment.AdbPath)) {
            $allChecksPassed = $false
        }
    }

    if ($allChecksPassed) {
        Write-Pass 'All Milestone 1 prerequisite checks passed.'
        exit 0
    }

    Write-Fail 'One or more Milestone 1 prerequisite checks failed.'
    exit 1
}
catch {
    Write-Host "[FAIL] Validation could not complete: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
