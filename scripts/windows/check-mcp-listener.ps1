[CmdletBinding()]
param(
    [ValidateRange(1, 65535)][int]$Port = 8765,
    [ValidateRange(0, [int]::MaxValue)][int]$OwningProcessId = 0
)

$ErrorActionPreference = 'Stop'

try {
    . (Join-Path $PSScriptRoot 'lib\Common.ps1')
    . (Join-Path $PSScriptRoot 'lib\McpListener.ps1')

    $assessment = Get-McpListenerAssessment -Port $Port -OwningProcessId $OwningProcessId
    if (-not $assessment.Exists) {
        Write-Fail "No TCP listener was found on port $Port$(if ($OwningProcessId) { " for process $OwningProcessId" })."
        exit 1
    }

    foreach ($listener in $assessment.Listeners) {
        Write-Pass "Listener $($listener.LocalAddress):$($listener.LocalPort) belongs to process $($listener.OwningProcess)."
    }

    if (-not $assessment.IsLoopbackOnly) {
        Write-Fail "Port $Port is exposed on a non-loopback address: $($assessment.UnsafeAddresses -join ', ')."
        exit 1
    }

    Write-Pass "Port $Port is loopback-only."
    exit 0
}
catch {
    Write-Host "[FAIL] MCP listener validation could not complete: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
