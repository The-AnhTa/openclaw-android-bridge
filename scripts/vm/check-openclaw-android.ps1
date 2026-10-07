[CmdletBinding()]
param(
    [string]$AgentId,
    [ValidateRange(1, 65535)][int]$McpPort = 8765,
    [ValidateRange(30, 600)][int]$InferenceTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'

try {
    . (Join-Path $PSScriptRoot 'lib\OpenClawAndroid.ps1')
    [void](Test-OpenClawAndroidPrerequisites `
        -AgentId $AgentId `
        -McpPort $McpPort `
        -InferenceTimeoutSeconds $InferenceTimeoutSeconds)
    Write-Pass 'Milestone 4 OpenClaw/VM preflight passed.'
    exit 0
}
catch {
    Write-Host "[FAIL] Milestone 4 OpenClaw/VM preflight failed: $(Get-SafeDiagnosticText -Text $_.Exception.Message)" -ForegroundColor Red
    exit 1
}
