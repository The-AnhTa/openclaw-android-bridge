[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:DiagnosticsToStandardError = $true

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

    $installation = Get-LocalAppiumMcpInstallation -RepositoryRoot $repositoryRoot
    if (-not $installation) {
        exit 1
    }
    Write-Pass "appium-mcp $($installation.Version) available"

    $nodePath = Resolve-ExternalCommand -Names @('node.exe', 'node')
    if (-not $nodePath) {
        Write-Fail 'Node.js is unavailable after prerequisite validation.'
        exit 1
    }

    Set-AppiumMcpProcessEnvironment
    Write-Pass 'Starting appium-mcp over stdio; no TCP listener will be created.'
    & $nodePath $installation.EntryPoint
    exit $LASTEXITCODE
}
catch {
    [Console]::Error.WriteLine("[FAIL] appium-mcp could not start: $($_.Exception.Message)")
    exit 1
}
