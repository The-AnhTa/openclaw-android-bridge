[CmdletBinding()]
param(
    [string]$AgentId,
    [ValidateRange(1, 65535)][int]$McpPort = 8765,
    [ValidateRange(120, 1800)][int]$AgentTimeoutSeconds = 600,
    [string]$PromptPath,
    [string]$ExistingSessionKey,
    [string]$TrajectoryBundlePath,
    [string]$TrajectorySessionKey
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($PromptPath)) {
    $PromptPath = Join-Path $PSScriptRoot 'openclaw-android-acceptance-prompt.txt'
}
$openClawPath = $null
$selectedAgentId = $null
$sessionKey = $null
$storePath = $null
$trajectoryEvidence = $null
$cleanupAttempted = $false
$liveRunStarted = $false

function Assert-AndroidAcceptanceEvidence {
    param([Parameter(Mandatory = $true)]$Evidence)

    if (-not $Evidence.ExactToolSet) {
        throw "Trajectory evidence does not contain exactly the required Android tools. Reported tools: $($Evidence.CalledTools -join ', ')."
    }
    if (-not $Evidence.DeviceSelected) {
        throw 'Trajectory evidence does not show successful Android device selection.'
    }
    if (-not $Evidence.SessionCreated) {
        throw 'Trajectory evidence does not show Appium session creation.'
    }
    if (-not $Evidence.SettingsActivated) {
        throw 'Trajectory evidence does not show activation of com.android.settings.'
    }
    if (-not $Evidence.PageSourceNonEmpty) {
        throw 'Trajectory evidence does not contain a successful non-empty Android page-source result.'
    }
    if (-not $Evidence.SettingsInPageSource) {
        throw 'Trajectory page-source evidence does not contain com.android.settings.'
    }
    if (-not $Evidence.SessionDeleted) {
        throw 'Trajectory evidence does not show Appium session deletion.'
    }
    if (-not $Evidence.OrderedWorkflow) {
        throw 'Trajectory evidence does not show the required successful Android operations in order.'
    }
    if (-not $Evidence.ModelCompleted) {
        throw 'Trajectory evidence does not show model.completed with a successful done state after the Android workflow.'
    }
    if (-not $Evidence.SessionEnded) {
        throw 'Trajectory evidence does not show session.ended with status=success after model completion.'
    }
}

function Write-MilestonePassSummary {
    Write-Host 'M1 PASS'
    Write-Host 'M2 PASS'
    Write-Host 'M3 PASS'
    Write-Host 'M4 PASS'
}

function Get-AgentIdFromExactSessionKey {
    param([Parameter(Mandatory = $true)][string]$ExactSessionKey)

    if ($ExactSessionKey -notmatch '^agent:([^:]+):.+$') {
        throw 'The existing session key must be fully qualified as agent:<agent-id>:<session-name>.'
    }
    return [string]$Matches[1]
}

function Invoke-SafeSessionCleanup {
    if (-not $liveRunStarted -or -not $openClawPath -or -not $selectedAgentId -or
        -not $sessionKey -or -not $storePath) {
        return $false
    }

    $script:cleanupAttempted = $true
    Write-Warn 'A created Appium session was not proven deleted; asking the same OpenClaw session to perform cleanup only.'
    $cleanupPrompt = 'Cleanup only: if an Appium session exists, use the configured android appium_session_management tool with action delete. Do not call any other tool and do not perform any other action. Reply exactly: cleanup-complete.'
    $cleanupResult = Invoke-OpenClawCommand -OpenClawPath $openClawPath -Arguments @(
        'agent', '--agent', $selectedAgentId,
        '--session-key', $sessionKey,
        '--message', $cleanupPrompt,
        '--timeout', '120',
        '--json'
    )
    if ($cleanupResult.ExitCode -ne 0) {
        Write-Warn "OpenClaw cleanup turn failed: $(Get-SafeDiagnosticText -Text (($cleanupResult.StdErr, $cleanupResult.StdOut) -join ' '))"
        return $false
    }

    try {
        $cleanupEvidence = Get-AndroidSqliteTrajectoryEvidence `
            -DatabasePath $storePath `
            -ExpectedSessionKey $sessionKey
        if ($cleanupEvidence.SessionDeleted) {
            Write-Pass 'Authoritative SQLite evidence confirms the cleanup turn called Appium session deletion.'
            return $true
        }
    }
    catch {
        Write-Warn "Could not verify cleanup trajectory: $(Get-SafeDiagnosticText -Text $_.Exception.Message)"
    }

    Write-Warn 'Cleanup completed without authoritative proof of Appium session deletion.'
    return $false
}

try {
    . (Join-Path $PSScriptRoot 'lib\OpenClawAndroid.ps1')
    . (Join-Path $PSScriptRoot 'lib\OpenClawTrajectory.ps1')

    $hasTrajectoryBundle = -not [string]::IsNullOrWhiteSpace($TrajectoryBundlePath)
    $hasTrajectorySessionKey = -not [string]::IsNullOrWhiteSpace($TrajectorySessionKey)
    $hasExistingSession = -not [string]::IsNullOrWhiteSpace($ExistingSessionKey)
    if ($hasTrajectoryBundle -xor $hasTrajectorySessionKey) {
        throw 'Pass both -TrajectoryBundlePath and -TrajectorySessionKey to inspect an existing diagnostic export.'
    }
    if ($hasExistingSession -and $hasTrajectoryBundle) {
        throw 'Choose either authoritative -ExistingSessionKey validation or optional diagnostic JSONL inspection.'
    }

    if ($hasTrajectoryBundle) {
        $trajectoryEvidence = Get-AndroidTrajectoryEvidence `
            -BundleDirectory $TrajectoryBundlePath `
            -ExpectedSessionKey $TrajectorySessionKey
        Assert-AndroidAcceptanceEvidence -Evidence $trajectoryEvidence
        Write-Pass "Validated diagnostic trajectory bundle: $($trajectoryEvidence.BundleDirectory)"
        Write-Warn 'Diagnostic JSONL is not authoritative and does not determine Milestone 4 PASS.'
        exit 0
    }

    if ($hasExistingSession) {
        $sessionKey = $ExistingSessionKey
        $selectedAgentId = Get-AgentIdFromExactSessionKey -ExactSessionKey $sessionKey
        if (-not [string]::IsNullOrWhiteSpace($AgentId) -and $AgentId -cne $selectedAgentId) {
            throw "The supplied AgentId '$AgentId' does not match the exact session key's agent '$selectedAgentId'."
        }

        $openClawPath = Resolve-OpenClawCommand
        $storePath = Resolve-OpenClawAgentStorePath `
            -OpenClawPath $openClawPath `
            -AgentId $selectedAgentId
        $trajectoryEvidence = Get-AndroidSqliteTrajectoryEvidence `
            -DatabasePath $storePath `
            -ExpectedSessionKey $sessionKey
        Assert-AndroidAcceptanceEvidence -Evidence $trajectoryEvidence

        Write-Pass 'Resolved the selected agent physical SQLite store through openclaw sessions --json.'
        Write-Pass 'Validated the exact existing session from the OpenClaw 2026.9.7 authoritative runtime trajectory table.'
        Write-Pass "Authoritative Android tools invoked: $($trajectoryEvidence.CalledTools -join ', ')"
        Write-Pass 'SQLite evidence confirms paired successful calls/results in order, model.completed done, and session.ended success.'
        Write-Pass 'Milestone 4 OpenClaw-to-Android acceptance test passed.'
        Write-MilestonePassSummary
        exit 0
    }

    if (-not (Test-Path -LiteralPath $PromptPath -PathType Leaf)) {
        throw "Acceptance prompt file was not found: $PromptPath"
    }

    $preflight = Test-OpenClawAndroidPrerequisites -AgentId $AgentId -McpPort $McpPort
    $openClawPath = $preflight.OpenClawPath
    $selectedAgentId = $preflight.AgentId
    Assert-OpenClawMcpCliCapabilities -OpenClawPath $openClawPath

    [void](Invoke-OpenClawMcpValidation -OpenClawPath $openClawPath)
    Write-Pass 'MCP registry and live probe passed before involving the Android agent turn.'
    $storePath = Resolve-OpenClawAgentStorePath `
        -OpenClawPath $openClawPath `
        -AgentId $selectedAgentId

    $sessionKey = "agent:${selectedAgentId}:m4-android-$([Guid]::NewGuid().ToString('N'))"
    $liveRunStarted = $true
    $agentResult = Invoke-OpenClawCommand -OpenClawPath $openClawPath -Arguments @(
        'agent', '--agent', $selectedAgentId,
        '--session-key', $sessionKey,
        '--message-file', (Resolve-Path -LiteralPath $PromptPath).Path,
        '--timeout', [string]$AgentTimeoutSeconds,
        '--verbose', 'on',
        '--json'
    )

    try {
        $trajectoryEvidence = Get-AndroidSqliteTrajectoryEvidence `
            -DatabasePath $storePath `
            -ExpectedSessionKey $sessionKey
    }
    catch {
        if ($agentResult.ExitCode -ne 0) {
            throw "The OpenClaw agent turn failed and authoritative SQLite evidence was unavailable. Agent diagnostic: $(Get-SafeDiagnosticText -Text (($agentResult.StdErr, $agentResult.StdOut) -join ' ')); SQLite diagnostic: $(Get-SafeDiagnosticText -Text $_.Exception.Message)"
        }
        throw
    }

    if ($agentResult.ExitCode -ne 0) {
        if ($trajectoryEvidence.SessionCreated -and -not $trajectoryEvidence.SessionDeleted) {
            [void](Invoke-SafeSessionCleanup)
        }
        throw "The OpenClaw Android agent turn failed with exit code $($agentResult.ExitCode): $(Get-SafeDiagnosticText -Text (($agentResult.StdErr, $agentResult.StdOut) -join ' '))"
    }

    [void](ConvertFrom-OpenClawJson -Result $agentResult -Operation 'OpenClaw Android agent turn')
    if (-not $trajectoryEvidence.SessionDeleted) {
        [void](Invoke-SafeSessionCleanup)
        throw 'Authoritative SQLite evidence does not show Appium session deletion in the acceptance turn.'
    }
    Assert-AndroidAcceptanceEvidence -Evidence $trajectoryEvidence

    Write-Pass "Selected OpenClaw agent: $selectedAgentId"
    Write-Pass 'Authoritative SQLite evidence was bound to the newly generated fully qualified acceptance session key.'
    Write-Pass "Existing provider/model: $($preflight.Provider) / $($preflight.Model)"
    Write-Pass "Authoritative Android tools invoked: $($trajectoryEvidence.CalledTools -join ', ')"
    Write-Pass 'SQLite evidence confirms paired successful calls/results in order, model.completed done, and session.ended success.'
    Write-Pass 'The constrained allowlist and read-only workflow did not expose a phone-setting, permission, text-entry, shell, installation, or file-transfer tool.'
    Write-Pass 'Milestone 4 OpenClaw-to-Android acceptance test passed.'
    Write-MilestonePassSummary
    exit 0
}
catch {
    if ($liveRunStarted -and $trajectoryEvidence -and $trajectoryEvidence.SessionCreated -and
        -not $trajectoryEvidence.SessionDeleted -and -not $cleanupAttempted) {
        [void](Invoke-SafeSessionCleanup)
    }
    Write-Host "[FAIL] Milestone 4 OpenClaw-to-Android acceptance test failed: $(Get-SafeDiagnosticText -Text $_.Exception.Message)" -ForegroundColor Red
    exit 1
}
