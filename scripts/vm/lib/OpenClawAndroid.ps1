Set-StrictMode -Version Latest

$script:AndroidMcpServerName = 'android'
$script:AndroidMcpUrl = 'http://127.0.0.1:8765/sse'
$script:AndroidMcpTransport = 'streamable-http'
$script:AndroidMcpConnectionTimeoutSeconds = 10
$script:AndroidMcpRequestTimeoutSeconds = 240
$script:AndroidMcpTools = @(
    'select_device',
    'appium_session_management',
    'appium_app_lifecycle',
    'appium_get_page_source'
)

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
. (Join-Path $repositoryRoot 'scripts\windows\lib\Common.ps1')
. (Join-Path $repositoryRoot 'scripts\windows\lib\McpListener.ps1')

function Get-SafeDiagnosticText {
    param(
        [AllowNull()]
        [string]$Text,
        [ValidateRange(100, 10000)]
        [int]$MaximumLength = 2000
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $safe = $Text -replace '(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+', 'Bearer <redacted>'
    $safe = $safe -replace '(?i)(authorization|api[-_ ]?key|access[-_ ]?key|token|password|secret|credential)(\s*[:=]\s*)[^\s,;]+', '$1$2<redacted>'
    $safe = $safe -replace '(?i)(https?://)[^/@\s]+@', '$1<redacted>@'
    $safe = ($safe -replace '\s+', ' ').Trim()
    if ($safe.Length -gt $MaximumLength) {
        return $safe.Substring(0, $MaximumLength) + '...'
    }
    return $safe
}

function Resolve-OpenClawCommand {
    $path = Resolve-ExternalCommand -Names @('openclaw.exe', 'openclaw.cmd', 'openclaw.ps1', 'openclaw')
    if (-not $path) {
        throw 'The openclaw executable is unavailable on PATH. Run this script on the configured OpenClaw VM.'
    }
    return $path
}

function Invoke-OpenClawCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenClawPath,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $stderrPath = [System.IO.Path]::GetTempFileName()
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $stdoutLines = @(& $OpenClawPath @Arguments 2> $stderrPath)
        $exitCode = $LASTEXITCODE
        $stderrLines = if (Test-Path -LiteralPath $stderrPath) {
            @(Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue)
        }
        else {
            @()
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if (Test-Path -LiteralPath $stderrPath) {
            [System.IO.File]::Delete($stderrPath)
        }
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        StdOut   = (@($stdoutLines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
        StdErr   = (@($stderrLines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
        Arguments = $Arguments
    }
}

function Assert-OpenClawCommandSucceeded {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    if ($Result.ExitCode -eq 0) {
        return
    }

    $detail = Get-SafeDiagnosticText -Text (($Result.StdErr, $Result.StdOut | Where-Object { $_ }) -join ' ')
    if (-not $detail) {
        $detail = 'no diagnostic output'
    }
    throw "$Operation failed with exit code $($Result.ExitCode): $detail"
}

function ConvertFrom-OpenClawJson {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    Assert-OpenClawCommandSucceeded -Result $Result -Operation $Operation
    if ([string]::IsNullOrWhiteSpace($Result.StdOut)) {
        throw "$Operation returned no JSON output."
    }

    try {
        return $Result.StdOut | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "$Operation returned invalid JSON: $(Get-SafeDiagnosticText -Text $_.Exception.Message)"
    }
}

function Get-JsonPropertyValues {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$PropertyName
    )

    $results = New-Object System.Collections.ArrayList

    function Visit-JsonValue {
        param([AllowNull()]$Value)

        if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) {
            return
        }

        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($key in $Value.Keys) {
                $item = $Value[$key]
                if ([string]$key -ieq $PropertyName) {
                    [void]$results.Add($item)
                }
                Visit-JsonValue -Value $item
            }
            return
        }

        if ($Value -is [System.Collections.IEnumerable]) {
            foreach ($item in $Value) {
                Visit-JsonValue -Value $item
            }
            return
        }

        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -ieq $PropertyName) {
                [void]$results.Add($property.Value)
            }
            Visit-JsonValue -Value $property.Value
        }
    }

    Visit-JsonValue -Value $InputObject
    return @($results.ToArray())
}

function Get-FirstScalarJsonValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$PropertyNames
    )

    foreach ($propertyName in $PropertyNames) {
        foreach ($value in @(Get-JsonPropertyValues -InputObject $InputObject -PropertyName $propertyName)) {
            if ($null -ne $value -and ($value -is [string] -or $value -is [ValueType])) {
                return $value
            }
        }
    }
    return $null
}

function Get-OpenClawAgentId {
    param(
        [Parameter(Mandatory = $true)][string]$OpenClawPath,
        [string]$RequestedAgentId
    )

    $result = Invoke-OpenClawCommand -OpenClawPath $OpenClawPath -Arguments @('agents', 'list', '--json')
    $json = ConvertFrom-OpenClawJson -Result $result -Operation 'OpenClaw agent discovery'
    $agents = @()

    if ($json -is [System.Array]) {
        $agents = @($json)
    }
    else {
        $collections = @(Get-JsonPropertyValues -InputObject $json -PropertyName 'agents')
        if ($collections.Count -gt 0) {
            $agents = @($collections[0])
        }
    }

    if ($agents.Count -eq 0) {
        throw 'OpenClaw reported no configured agents.'
    }

    $normalized = @($agents | ForEach-Object {
        $id = Get-FirstScalarJsonValue -InputObject $_ -PropertyNames @('id', 'agentId', 'name')
        $isDefault = Get-FirstScalarJsonValue -InputObject $_ -PropertyNames @('isDefault', 'default')
        if ($id) {
            [PSCustomObject]@{ Id = [string]$id; IsDefault = ($isDefault -eq $true) }
        }
    })

    if ($RequestedAgentId) {
        $match = @($normalized | Where-Object { $_.Id -ceq $RequestedAgentId })
        if ($match.Count -ne 1) {
            throw "Requested OpenClaw agent '$RequestedAgentId' was not found. Available agents: $($normalized.Id -join ', ')."
        }
        return $match[0].Id
    }

    $defaults = @($normalized | Where-Object { $_.IsDefault })
    if ($defaults.Count -eq 1) {
        return $defaults[0].Id
    }
    if ($normalized.Count -eq 1) {
        return $normalized[0].Id
    }

    throw "Multiple OpenClaw agents exist and no unique default was reported. Pass -AgentId with one of: $($normalized.Id -join ', ')."
}

function Get-OpenClawAgentResponseText {
    param([AllowNull()]$AgentResult)

    $final = Get-FirstScalarJsonValue -InputObject $AgentResult -PropertyNames @('final')
    if ($final) {
        return [string]$final
    }

    $payloadCollections = @(Get-JsonPropertyValues -InputObject $AgentResult -PropertyName 'payloads')
    if ($payloadCollections.Count -gt 0) {
        $texts = @($payloadCollections[0] | ForEach-Object {
            Get-FirstScalarJsonValue -InputObject $_ -PropertyNames @('text')
        } | Where-Object { $_ })
        if ($texts.Count -gt 0) {
            return ($texts -join [Environment]::NewLine).Trim()
        }
    }

    return ''
}

function Get-NormalizedMcpToolName {
    param([Parameter(Mandatory = $true)][string]$ToolName)

    if ($ToolName -match '^[^_]+__(.+)$') {
        return $Matches[1]
    }
    return $ToolName
}

function Test-ExactToolSet {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][string[]]$ActualTools,
        [Parameter(Mandatory = $true)][string[]]$ExpectedTools
    )

    $actual = @($ActualTools | ForEach-Object { Get-NormalizedMcpToolName -ToolName $_ } | Sort-Object -Unique)
    $expected = @($ExpectedTools | Sort-Object -Unique)
    return (($actual -join ',') -ceq ($expected -join ','))
}

function Get-NormalizedMcpToolFilter {
    param(
        [AllowNull()]$Definition
    )

    $includeCollections = @(Get-JsonPropertyValues -InputObject $Definition -PropertyName 'include')
    $includes = @()
    if ($includeCollections.Count -gt 0) {
        $includes = @($includeCollections[0] | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    }

    $excludeCollections = @(Get-JsonPropertyValues -InputObject $Definition -PropertyName 'exclude')
    $excludes = @()
    if ($excludeCollections.Count -gt 0) {
        $excludes = @($excludeCollections[0] | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    }

    return [PSCustomObject]@{
        Include = [string[]]@($includes)
        Exclude = [string[]]@($excludes)
    }
}

function Get-AndroidMcpDefinitionAssessment {
    param(
        [Parameter(Mandatory = $true)]$Definition
    )

    $url = [string](Get-FirstScalarJsonValue -InputObject $Definition -PropertyNames @('url'))
    $transport = [string](Get-FirstScalarJsonValue -InputObject $Definition -PropertyNames @('transport'))
    $connectionTimeout = Get-FirstScalarJsonValue -InputObject $Definition -PropertyNames @('connectionTimeoutMs')
    $requestTimeout = Get-FirstScalarJsonValue -InputObject $Definition -PropertyNames @('requestTimeoutMs')
    $filter = Get-NormalizedMcpToolFilter -Definition $Definition
    $includes = @($filter.Include)
    $excludes = @($filter.Exclude)

    $endpointMatches = $url -ceq $script:AndroidMcpUrl -and $transport -ceq $script:AndroidMcpTransport
    $timeoutsMatch = (
        $null -ne $connectionTimeout -and
        $null -ne $requestTimeout -and
        [int64]$connectionTimeout -eq ($script:AndroidMcpConnectionTimeoutSeconds * 1000) -and
        [int64]$requestTimeout -eq ($script:AndroidMcpRequestTimeoutSeconds * 1000)
    )
    $toolFilterMatches = (
        (Test-ExactToolSet -ActualTools $includes -ExpectedTools $script:AndroidMcpTools) -and
        @($excludes).Count -eq 0
    )

    return [PSCustomObject]@{
        Url = $url
        Transport = $transport
        ConnectionTimeoutMs = $connectionTimeout
        RequestTimeoutMs = $requestTimeout
        Includes = [string[]]@($includes)
        Excludes = [string[]]@($excludes)
        EndpointMatches = $endpointMatches
        TimeoutsMatch = $timeoutsMatch
        ToolFilterMatches = $toolFilterMatches
        IsExact = $endpointMatches -and $timeoutsMatch -and $toolFilterMatches
    }
}

function Get-OpenClawModelSummary {
    param(
        [Parameter(Mandatory = $true)][string]$OpenClawPath,
        [Parameter(Mandatory = $true)][string]$AgentId
    )

    $result = Invoke-OpenClawCommand -OpenClawPath $OpenClawPath -Arguments @('models', 'status', '--agent', $AgentId, '--json')
    $json = ConvertFrom-OpenClawJson -Result $result -Operation "OpenClaw model status for agent '$AgentId'"
    $model = Get-FirstScalarJsonValue -InputObject $json -PropertyNames @('resolvedDefault', 'defaultModel', 'primary', 'model')
    $provider = Get-FirstScalarJsonValue -InputObject $json -PropertyNames @('provider', 'providerId')

    return [PSCustomObject]@{
        Json = $json
        Model = if ($model) { [string]$model } else { '<reported by OpenClaw JSON; field shape not recognized>' }
        Provider = if ($provider) { [string]$provider } else { '<reported by OpenClaw JSON; field shape not recognized>' }
    }
}

function Test-OpenClawInference {
    param(
        [Parameter(Mandatory = $true)][string]$OpenClawPath,
        [Parameter(Mandatory = $true)][string]$AgentId,
        [ValidateRange(30, 600)][int]$TimeoutSeconds = 120
    )

    $sessionKey = 'm4-inference-' + [Guid]::NewGuid().ToString('N')
    $arguments = @(
        'agent', '--agent', $AgentId,
        '--session-key', $sessionKey,
        '--message', 'Reply with exactly: openclaw-model-ok. Do not use tools.',
        '--timeout', [string]$TimeoutSeconds,
        '--json'
    )
    $result = Invoke-OpenClawCommand -OpenClawPath $OpenClawPath -Arguments $arguments
    $json = ConvertFrom-OpenClawJson -Result $result -Operation 'OpenClaw independent inference smoke test'
    $text = (Get-OpenClawAgentResponseText -AgentResult $json).Trim()
    if ($text -cne 'openclaw-model-ok') {
        throw "OpenClaw inference returned an unexpected response: $(Get-SafeDiagnosticText -Text $text -MaximumLength 300)"
    }

    $toolSummaries = @(Get-JsonPropertyValues -InputObject $json -PropertyName 'toolSummary')
    if ($toolSummaries.Count -gt 0) {
        $toolCallCount = Get-FirstScalarJsonValue -InputObject $toolSummaries[0] -PropertyNames @('calls')
        if ($null -ne $toolCallCount -and [int64]$toolCallCount -ne 0) {
            throw "The independent inference smoke test unexpectedly invoked $toolCallCount tool call(s)."
        }
    }

    return $json
}

function Test-OpenClawAndroidPrerequisites {
    param(
        [string]$AgentId,
        [ValidateRange(1, 65535)][int]$McpPort = 8765,
        [ValidateRange(30, 600)][int]$InferenceTimeoutSeconds = 120
    )

    $openClawPath = Resolve-OpenClawCommand
    $versionResult = Invoke-OpenClawCommand -OpenClawPath $openClawPath -Arguments @('--version')
    Assert-OpenClawCommandSucceeded -Result $versionResult -Operation 'openclaw --version'
    $openClawVersion = ($versionResult.StdOut, $versionResult.StdErr | Where-Object { $_ } | Select-Object -First 1).Trim()
    Write-Pass "OpenClaw available: $openClawVersion"

    $nodePath = Resolve-ExternalCommand -Names @('node.exe', 'node')
    if (-not $nodePath) {
        throw 'Node.js is unavailable on PATH; the existing OpenClaw installation requires Node.js 22 or newer.'
    }
    $nodeResult = Invoke-NativeCommand -FilePath $nodePath -Arguments @('--version')
    if ($nodeResult.ExitCode -ne 0) {
        throw 'Node.js was found but did not run successfully.'
    }
    $nodeText = Get-FirstOutputLine -Result $nodeResult
    if ($nodeText -notmatch '^v?(\d+)\.') {
        throw "Could not parse Node.js version '$nodeText'."
    }
    if ([int]$Matches[1] -lt 22) {
        throw "Node.js 22 or newer is required; found $nodeText."
    }
    Write-Pass "Node.js available: $nodeText"

    $configResult = Invoke-OpenClawCommand -OpenClawPath $openClawPath -Arguments @('config', 'validate', '--json')
    $configJson = ConvertFrom-OpenClawJson -Result $configResult -Operation 'OpenClaw configuration validation'
    $validValues = @(Get-JsonPropertyValues -InputObject $configJson -PropertyName 'valid')
    if ($validValues -contains $false) {
        throw 'OpenClaw configuration validation reported valid=false.'
    }
    Write-Pass 'OpenClaw configuration is valid.'

    $gatewayResult = Invoke-OpenClawCommand -OpenClawPath $openClawPath -Arguments @('gateway', 'status', '--require-rpc', '--json')
    [void](ConvertFrom-OpenClawJson -Result $gatewayResult -Operation 'OpenClaw Gateway status')
    Write-Pass 'OpenClaw Gateway status and read-scope RPC are healthy.'

    $listener = Get-McpListenerAssessment -Port $McpPort
    if (-not $listener.Exists) {
        throw "No VM listener exists on 127.0.0.1:$McpPort. Start the existing SSH reverse tunnel from the laptop."
    }
    if (-not $listener.IsLoopbackOnly) {
        throw "Port $McpPort is exposed on a non-loopback address: $($listener.UnsafeAddresses -join ', '). Stop it and restore the loopback-only SSH reverse forward."
    }
    Write-Pass "VM MCP listener is loopback-only on $($listener.Addresses -join ', '):$McpPort."

    $selectedAgentId = Get-OpenClawAgentId -OpenClawPath $openClawPath -RequestedAgentId $AgentId
    Write-Pass "Selected OpenClaw agent: $selectedAgentId"

    $model = Get-OpenClawModelSummary -OpenClawPath $openClawPath -AgentId $selectedAgentId
    Write-Pass 'Existing model/provider configuration was inspected.'

    $inferenceJson = Test-OpenClawInference -OpenClawPath $openClawPath -AgentId $selectedAgentId -TimeoutSeconds $InferenceTimeoutSeconds
    $inferenceModel = Get-FirstScalarJsonValue -InputObject $inferenceJson -PropertyNames @('model')
    $inferenceProvider = Get-FirstScalarJsonValue -InputObject $inferenceJson -PropertyNames @('provider')
    if ($inferenceModel) {
        $model.Model = [string]$inferenceModel
    }
    if ($inferenceProvider) {
        $model.Provider = [string]$inferenceProvider
    }
    Write-Pass 'Independent OpenClaw inference smoke test returned openclaw-model-ok.'
    Write-Pass "Existing inference provider/model: $($model.Provider) / $($model.Model)"
    Write-Pass 'Existing model/provider configuration was not modified.'

    return [PSCustomObject]@{
        OpenClawPath = $openClawPath
        OpenClawVersion = $openClawVersion
        NodeVersion = $nodeText
        AgentId = $selectedAgentId
        Model = $model.Model
        Provider = $model.Provider
        ListenerAddresses = $listener.Addresses
        InferencePassed = $true
    }
}

function Assert-OpenClawMcpCliCapabilities {
    param([Parameter(Mandatory = $true)][string]$OpenClawPath)

    $checks = @(
        @{ Arguments = @('mcp', 'add', '--help'); Tokens = @('--url', '--transport', '--timeout', '--connect-timeout', '--include') },
        @{ Arguments = @('mcp', 'configure', '--help'); Tokens = @('--timeout', '--connect-timeout', '--include') },
        @{ Arguments = @('mcp', 'tools', '--help'); Tokens = @('--include', '--exclude', '--clear') },
        @{ Arguments = @('mcp', 'probe', '--help'); Tokens = @('--json') },
        @{ Arguments = @('agent', '--help'); Tokens = @('--message-file', '--agent', '--json', '--timeout') }
    )

    foreach ($check in $checks) {
        $result = Invoke-OpenClawCommand -OpenClawPath $OpenClawPath -Arguments $check.Arguments
        Assert-OpenClawCommandSucceeded -Result $result -Operation "OpenClaw CLI capability check: $($check.Arguments -join ' ')"
        $help = $result.StdOut + [Environment]::NewLine + $result.StdErr
        foreach ($token in $check.Tokens) {
            if ($help -notmatch [regex]::Escape($token)) {
                throw "The installed OpenClaw CLI does not advertise required option '$token' for '$($check.Arguments -join ' ')'."
            }
        }
    }
    Write-Pass 'Installed OpenClaw CLI advertises the required MCP and agent options.'
}

function Assert-OpenClawTrajectoryCliCapabilities {
    param([Parameter(Mandatory = $true)][string]$OpenClawPath)

    $result = Invoke-OpenClawCommand -OpenClawPath $OpenClawPath -Arguments @('sessions', 'export-trajectory', '--help')
    Assert-OpenClawCommandSucceeded -Result $result -Operation 'OpenClaw trajectory-export capability check'
    $help = $result.StdOut + [Environment]::NewLine + $result.StdErr
    foreach ($token in @('--session-key', '--workspace', '--output', '--agent', '--json')) {
        if ($help -notmatch [regex]::Escape($token)) {
            throw "The installed OpenClaw CLI does not advertise required trajectory option '$token'."
        }
    }
    Write-Pass 'Installed OpenClaw CLI advertises redacted trajectory export for tool-call evidence.'
}

function Invoke-OpenClawMcpValidation {
    param([Parameter(Mandatory = $true)][string]$OpenClawPath)

    $status = Invoke-OpenClawCommand -OpenClawPath $OpenClawPath -Arguments @('mcp', 'status', '--verbose')
    Assert-OpenClawCommandSucceeded -Result $status -Operation 'openclaw mcp status --verbose'
    Write-Host $status.StdOut
    Write-Pass 'openclaw mcp status --verbose passed.'

    $doctor = Invoke-OpenClawCommand -OpenClawPath $OpenClawPath -Arguments @('mcp', 'doctor', $script:AndroidMcpServerName)
    Assert-OpenClawCommandSucceeded -Result $doctor -Operation 'openclaw mcp doctor android'
    Write-Host $doctor.StdOut
    Write-Pass 'openclaw mcp doctor android passed.'

    $doctorProbe = Invoke-OpenClawCommand -OpenClawPath $OpenClawPath -Arguments @('mcp', 'doctor', $script:AndroidMcpServerName, '--probe')
    Assert-OpenClawCommandSucceeded -Result $doctorProbe -Operation 'openclaw mcp doctor android --probe'
    Write-Host $doctorProbe.StdOut
    Write-Pass 'openclaw mcp doctor android --probe passed.'

    $probeResult = Invoke-OpenClawCommand -OpenClawPath $OpenClawPath -Arguments @('mcp', 'probe', $script:AndroidMcpServerName, '--json')
    $probeJson = ConvertFrom-OpenClawJson -Result $probeResult -Operation 'openclaw mcp probe android --json'
    $toolCollections = @(Get-JsonPropertyValues -InputObject $probeJson -PropertyName 'tools')
    $probeCollection = $null
    foreach ($candidate in $toolCollections) {
        if ($candidate -is [System.Collections.IEnumerable] -and $candidate -isnot [string]) {
            $probeCollection = $candidate
            break
        }
    }
    $probeTools = @()
    foreach ($tool in @($probeCollection)) {
        $probeTools += [string]$tool
    }
    if (-not (Test-ExactToolSet -ActualTools $probeTools -ExpectedTools $script:AndroidMcpTools)) {
        throw "The live MCP probe did not expose exactly the required tool allowlist. Discovered: $($probeTools -join ', ')."
    }
    Write-Pass "Live MCP probe discovered only the required tools: $($probeTools -join ', ')."

    return [PSCustomObject]@{
        StatusOutput = $status.StdOut
        DoctorOutput = $doctor.StdOut
        DoctorProbeOutput = $doctorProbe.StdOut
        ProbeJson = $probeJson
        Tools = $probeTools
    }
}
