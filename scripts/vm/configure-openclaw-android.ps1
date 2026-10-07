[CmdletBinding()]
param(
    [string]$AgentId,
    [ValidateRange(1, 65535)][int]$McpPort = 8765,
    [switch]$Replace
)

$ErrorActionPreference = 'Stop'

try {
    . (Join-Path $PSScriptRoot 'lib\OpenClawAndroid.ps1')

    $preflight = Test-OpenClawAndroidPrerequisites -AgentId $AgentId -McpPort $McpPort
    $openClawPath = $preflight.OpenClawPath
    Assert-OpenClawMcpCliCapabilities -OpenClawPath $openClawPath

    $showResult = Invoke-OpenClawCommand -OpenClawPath $openClawPath -Arguments @('mcp', 'show', $script:AndroidMcpServerName, '--json')
    $existing = $null
    if ($showResult.ExitCode -eq 0) {
        $existing = ConvertFrom-OpenClawJson -Result $showResult -Operation 'Inspect existing android MCP server'
    }
    else {
        $listResult = Invoke-OpenClawCommand -OpenClawPath $openClawPath -Arguments @('mcp', 'list', '--json')
        $listJson = ConvertFrom-OpenClawJson -Result $listResult -Operation 'List OpenClaw MCP servers'
        $serverNames = @(Get-JsonPropertyValues -InputObject $listJson -PropertyName 'name' | ForEach-Object { [string]$_ })
        $serverCollections = @(Get-JsonPropertyValues -InputObject $listJson -PropertyName 'servers')
        foreach ($serverCollection in $serverCollections) {
            if ($serverCollection -is [System.Collections.IDictionary]) {
                $serverNames += @($serverCollection.Keys | ForEach-Object { [string]$_ })
            }
            elseif ($serverCollection -is [System.Collections.IEnumerable] -and $serverCollection -isnot [string]) {
                foreach ($server in $serverCollection) {
                    if ($server -is [string]) {
                        $serverNames += [string]$server
                    }
                    elseif ($server -and $server.PSObject.Properties['name']) {
                        $serverNames += [string]$server.name
                    }
                }
            }
            elseif ($serverCollection -and $serverCollection.PSObject) {
                $serverNames += @($serverCollection.PSObject.Properties.Name | ForEach-Object { [string]$_ })
            }
        }
        $serverNames = @($serverNames | Sort-Object -Unique)
        if ($serverNames -contains $script:AndroidMcpServerName) {
            throw "The android MCP server exists, but OpenClaw could not inspect it: $(Get-SafeDiagnosticText -Text (($showResult.StdErr, $showResult.StdOut) -join ' '))"
        }
    }

    $toolCsv = $script:AndroidMcpTools -join ','
    $needsConfigure = $false
    $needsToolConfigure = $false

    if ($existing) {
        $existingAssessment = Get-AndroidMcpDefinitionAssessment -Definition $existing
        $existingUrl = $existingAssessment.Url
        $existingTransport = $existingAssessment.Transport

        if (-not $existingAssessment.EndpointMatches) {
            if (-not $Replace) {
                throw "OpenClaw MCP server 'android' already exists with a different endpoint or transport. Found URL '$existingUrl' and transport '$existingTransport'. Rerun with -Replace only after confirming this definition may be replaced."
            }

            $replacement = [ordered]@{
                url = $script:AndroidMcpUrl
                transport = $script:AndroidMcpTransport
                connectionTimeoutMs = $script:AndroidMcpConnectionTimeoutSeconds * 1000
                requestTimeoutMs = $script:AndroidMcpRequestTimeoutSeconds * 1000
                toolFilter = [ordered]@{
                    include = $script:AndroidMcpTools
                    exclude = @()
                }
            }
            $replacementJson = $replacement | ConvertTo-Json -Depth 6 -Compress
            $setResult = Invoke-OpenClawCommand -OpenClawPath $openClawPath -Arguments @('mcp', 'set', $script:AndroidMcpServerName, $replacementJson)
            Assert-OpenClawCommandSucceeded -Result $setResult -Operation 'Replace the android MCP server definition'
            Write-Pass "Replaced the explicitly approved conflicting 'android' MCP definition."
        }
        else {
            Write-Pass "Existing 'android' MCP endpoint and transport already match."
            if (-not $existingAssessment.TimeoutsMatch) {
                $needsConfigure = $true
            }
            if (-not $existingAssessment.ToolFilterMatches) {
                $needsToolConfigure = $true
            }
            if ($existingAssessment.IsExact) {
                Write-Pass "Existing 'android' MCP server is already configured exactly; no registry mutation is required."
            }
        }
    }
    else {
        $addArguments = @(
            'mcp', 'add', $script:AndroidMcpServerName,
            '--url', $script:AndroidMcpUrl,
            '--transport', $script:AndroidMcpTransport,
            '--connect-timeout', [string]$script:AndroidMcpConnectionTimeoutSeconds,
            '--timeout', [string]$script:AndroidMcpRequestTimeoutSeconds,
            '--include', $toolCsv
        )
        $addResult = Invoke-OpenClawCommand -OpenClawPath $openClawPath -Arguments $addArguments
        Assert-OpenClawCommandSucceeded -Result $addResult -Operation 'Add the android MCP server'
        Write-Pass "Added OpenClaw MCP server 'android'."
    }

    if ($needsConfigure) {
        $configureArguments = @(
            'mcp', 'configure', $script:AndroidMcpServerName,
            '--connect-timeout', [string]$script:AndroidMcpConnectionTimeoutSeconds,
            '--timeout', [string]$script:AndroidMcpRequestTimeoutSeconds
        )
        $configureResult = Invoke-OpenClawCommand -OpenClawPath $openClawPath -Arguments $configureArguments
        Assert-OpenClawCommandSucceeded -Result $configureResult -Operation 'Configure android MCP timeouts and tool filter'
        Write-Pass 'Updated only the android MCP timeouts.'
    }

    if ($needsToolConfigure) {
        $clearToolsResult = Invoke-OpenClawCommand -OpenClawPath $openClawPath -Arguments @('mcp', 'tools', $script:AndroidMcpServerName, '--clear')
        Assert-OpenClawCommandSucceeded -Result $clearToolsResult -Operation 'Clear the conflicting android MCP tool filter'
        $setToolsResult = Invoke-OpenClawCommand -OpenClawPath $openClawPath -Arguments @('mcp', 'tools', $script:AndroidMcpServerName, '--include', $toolCsv)
        Assert-OpenClawCommandSucceeded -Result $setToolsResult -Operation 'Set the android MCP tool allowlist'
        Write-Pass 'Replaced only the android MCP tool filter with the required allowlist.'
    }

    $configResult = Invoke-OpenClawCommand -OpenClawPath $openClawPath -Arguments @('config', 'validate', '--json')
    [void](ConvertFrom-OpenClawJson -Result $configResult -Operation 'Validate OpenClaw configuration after MCP update')
    Write-Pass 'OpenClaw configuration remains valid.'

    $reloadResult = Invoke-OpenClawCommand -OpenClawPath $openClawPath -Arguments @('mcp', 'reload')
    Assert-OpenClawCommandSucceeded -Result $reloadResult -Operation 'Reload OpenClaw MCP runtime state'
    Write-Pass 'Requested OpenClaw MCP runtime reload.'

    $finalShowResult = Invoke-OpenClawCommand -OpenClawPath $openClawPath -Arguments @('mcp', 'show', $script:AndroidMcpServerName, '--json')
    $finalDefinition = ConvertFrom-OpenClawJson -Result $finalShowResult -Operation 'Inspect final android MCP server definition'
    $finalAssessment = Get-AndroidMcpDefinitionAssessment -Definition $finalDefinition
    if (-not $finalAssessment.EndpointMatches) {
        throw "Saved android MCP definition is not canonical: URL '$($finalAssessment.Url)', transport '$($finalAssessment.Transport)'."
    }
    if (-not $finalAssessment.TimeoutsMatch -or -not $finalAssessment.ToolFilterMatches) {
        throw 'Saved android MCP timeouts or tool filter do not match the required narrow definition.'
    }

    [void](Invoke-OpenClawMcpValidation -OpenClawPath $openClawPath)

    Write-Pass "OpenClaw MCP server: $($script:AndroidMcpServerName)"
    Write-Pass "Configured URL: $($script:AndroidMcpUrl)"
    Write-Pass "Configured transport: $($script:AndroidMcpTransport)"
    Write-Pass "Connection/request timeouts: $($script:AndroidMcpConnectionTimeoutSeconds)s / $($script:AndroidMcpRequestTimeoutSeconds)s"
    Write-Pass "Tool allowlist: $toolCsv"
    Write-Pass 'Milestone 4 OpenClaw MCP configuration and live probe passed.'
    exit 0
}
catch {
    Write-Host "[FAIL] OpenClaw Android MCP configuration failed: $(Get-SafeDiagnosticText -Text $_.Exception.Message)" -ForegroundColor Red
    exit 1
}
