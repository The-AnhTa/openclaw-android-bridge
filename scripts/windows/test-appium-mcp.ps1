[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    . (Join-Path $PSScriptRoot 'lib\Common.ps1')
    . (Join-Path $PSScriptRoot 'lib\AppiumMcp.ps1')

    $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    if (-not (Test-WindowsHostPrerequisites)) {
        Write-Fail 'Milestone 1 host prerequisites are not satisfied.'
        exit 1
    }

    $androidEnvironment = Initialize-AndroidEnvironment
    if (-not $androidEnvironment.IsValid -or -not $androidEnvironment.AdbPath) {
        Write-Fail 'Milestone 1 Android prerequisites are not satisfied.'
        exit 1
    }

    $device = Get-AuthorizedAndroidDevice -AdbPath $androidEnvironment.AdbPath
    if (-not $device) {
        exit 1
    }
    Write-Pass 'Milestone 1 prerequisites'
    Write-Pass 'Authorized Android device detected'

    $installation = Get-LocalAppiumMcpInstallation -RepositoryRoot $repositoryRoot
    if (-not $installation) {
        exit 1
    }
    Write-Pass "appium-mcp $($installation.Version) available"

    Set-AppiumMcpProcessEnvironment
    $nodePath = Resolve-ExternalCommand -Names @('node.exe', 'node')
    $clientPath = Join-Path $repositoryRoot 'scripts\mcp\appium-smoke-client.mjs'
    if (-not $nodePath -or -not (Test-Path -LiteralPath $clientPath -PathType Leaf)) {
        Write-Fail 'The local Node.js MCP smoke-test client is unavailable.'
        exit 1
    }

    $previousUdid = $env:OPENCLAW_ANDROID_UDID
    try {
        $env:OPENCLAW_ANDROID_UDID = $device.Serial
        & $nodePath $clientPath
        $clientExitCode = $LASTEXITCODE
    }
    finally {
        $env:OPENCLAW_ANDROID_UDID = $previousUdid
    }

    if ($clientExitCode -ne 0) {
        Write-Fail "Milestone 2 smoke-test client exited with code $clientExitCode."
        exit 1
    }

    exit 0
}
catch {
    Write-Host "[FAIL] Milestone 2 validation could not complete: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
