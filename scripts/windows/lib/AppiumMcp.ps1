Set-StrictMode -Version Latest

$script:RequiredAppiumMcpVersion = '1.95.0'

function Set-AppiumMcpProcessEnvironment {
    $env:ALLOW_REMOTE_APP_URLS = 'false'
    $env:AI_VISION_ENABLED = 'false'
    $env:APPIUM_MCP_DOCS_ENABLED = 'false'
    $env:APPIUM_MCP_OTEL_ENABLED = 'false'
    $env:APPIUM_MCP_APPS_ENABLED = 'false'
    $env:NO_UI = 'true'
}

function Get-LocalAppiumMcpInstallation {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $rootManifestPath = Join-Path $RepositoryRoot 'package.json'
    $installedManifestPath = Join-Path $RepositoryRoot 'node_modules\appium-mcp\package.json'
    $entryPoint = Join-Path $RepositoryRoot 'node_modules\appium-mcp\dist\index.js'
    $launcher = Join-Path $RepositoryRoot 'node_modules\.bin\appium-mcp.cmd'

    if (-not (Test-Path -LiteralPath $rootManifestPath -PathType Leaf)) {
        Write-Fail "package.json was not found at '$rootManifestPath'."
        return $null
    }

    try {
        $rootManifest = Get-Content -LiteralPath $rootManifestPath -Raw | ConvertFrom-Json
        $declaredVersion = $rootManifest.dependencies.'appium-mcp'
    }
    catch {
        Write-Fail "Could not read the repository package.json: $($_.Exception.Message)"
        return $null
    }

    if ($declaredVersion -ne $script:RequiredAppiumMcpVersion) {
        Write-Fail "package.json must pin appium-mcp exactly to $script:RequiredAppiumMcpVersion; found '$declaredVersion'."
        return $null
    }

    if (-not (Test-Path -LiteralPath $installedManifestPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $entryPoint -PathType Leaf) -or
        -not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        Write-Fail "Local appium-mcp is unavailable. Run 'npm ci' in '$RepositoryRoot', then try again."
        return $null
    }

    try {
        $installedManifest = Get-Content -LiteralPath $installedManifestPath -Raw | ConvertFrom-Json
        $installedVersion = [string]$installedManifest.version
    }
    catch {
        Write-Fail "Could not read the installed appium-mcp manifest: $($_.Exception.Message)"
        return $null
    }

    if ($installedVersion -ne $script:RequiredAppiumMcpVersion) {
        Write-Fail "Installed appium-mcp is $installedVersion, but $script:RequiredAppiumMcpVersion is required. Run 'npm ci'."
        return $null
    }

    return [PSCustomObject]@{
        Version    = $installedVersion
        EntryPoint = $entryPoint
        Launcher   = $launcher
    }
}
