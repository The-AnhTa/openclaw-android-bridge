[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    . (Join-Path $PSScriptRoot 'lib\Common.ps1')

    $androidEnvironment = Initialize-AndroidEnvironment
    if (-not $androidEnvironment.IsValid -or -not $androidEnvironment.AdbPath) {
        Write-Fail 'Android device validation could not start because required Android tools are unavailable.'
        exit 1
    }

    if (-not (Test-ConnectedAndroidDevice -AdbPath $androidEnvironment.AdbPath)) {
        exit 1
    }

    Write-Pass 'Android device validation passed.'
    exit 0
}
catch {
    Write-Host "[FAIL] Android device validation could not complete: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
