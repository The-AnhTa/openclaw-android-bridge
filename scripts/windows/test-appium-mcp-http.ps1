[CmdletBinding()]
param(
    [string]$McpUrl = 'http://127.0.0.1:8765/sse'
)

$ErrorActionPreference = 'Stop'

try {
    . (Join-Path $PSScriptRoot 'lib\Common.ps1')
    . (Join-Path $PSScriptRoot 'lib\McpListener.ps1')

    $uri = [Uri]$McpUrl
    if ($uri.Scheme -ne 'http' -or -not [System.Net.IPAddress]::IsLoopback([System.Net.IPAddress]::Parse($uri.DnsSafeHost))) {
        Write-Fail 'The local MCP test URL must use HTTP and a literal loopback address.'
        exit 1
    }

    $assessment = Get-McpListenerAssessment -Port $uri.Port
    if (-not $assessment.IsLoopbackOnly) {
        Write-Fail "Port $($uri.Port) is not proven to be loopback-only."
        exit 1
    }

    $nodePath = Resolve-ExternalCommand -Names @('node.exe', 'node')
    $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $clientPath = Join-Path $repositoryRoot 'tools\remote-mcp-client\appium-http-smoke-client.mjs'
    if (-not $nodePath -or -not (Test-Path -LiteralPath $clientPath -PathType Leaf)) {
        Write-Fail 'The Node.js HTTP smoke client is unavailable.'
        exit 1
    }

    & $nodePath $clientPath --url $McpUrl --list-tools-only
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Local HTTP MCP smoke client exited with code $LASTEXITCODE."
        exit 1
    }

    Write-Pass 'Local Streamable HTTP MCP transport test passed.'
    exit 0
}
catch {
    Write-Host "[FAIL] Local HTTP MCP validation could not complete: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
