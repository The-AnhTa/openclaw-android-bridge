[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$temporaryDirectory = $null

function Assert-RegressionCondition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-TrajectoryFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines
    )

    $bundle = Get-OpenClawTrajectoryBundleDirectory -Workspace $Workspace -OutputName $Name
    [void](New-Item -ItemType Directory -Path $bundle -Force -ErrorAction Stop)
    [System.IO.File]::WriteAllText(
        (Join-Path $bundle 'events.jsonl'),
        (@($Lines) -join "`n"),
        (New-Object System.Text.UTF8Encoding($false))
    )
    return $bundle
}

function Assert-TrajectoryParseRejected {
    param(
        [Parameter(Mandatory = $true)][string]$BundleDirectory,
        [Parameter(Mandatory = $true)][string]$NodePath,
        [Parameter(Mandatory = $true)][int]$ExpectedLineNumber,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $rejectedAtExpectedLine = $false
    try {
        [void](Read-OpenClawTrajectoryProjection -BundleDirectory $BundleDirectory -NodePath $NodePath)
    }
    catch {
        $rejectedAtExpectedLine = $_.Exception.Message -match "Invalid JSONL at line $ExpectedLineNumber`:"
    }
    Assert-RegressionCondition -Condition $rejectedAtExpectedLine -Message $Message
}

try {
    . (Join-Path $PSScriptRoot 'lib\OpenClawAndroid.ps1')
    . (Join-Path $PSScriptRoot 'lib\OpenClawTrajectory.ps1')

    $nodePath = Resolve-ExternalCommand -Names @('node.exe', 'node')
    if (-not $nodePath) {
        throw 'Node.js is required for the trajectory regression test.'
    }

    $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('openclaw-trajectory-test-' + [Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $temporaryDirectory -ErrorAction Stop)

    $oldBundle = New-TrajectoryFixture `
        -Workspace $temporaryDirectory `
        -Name 'unrelated-old-export' `
        -Lines @('{ unrelated historical malformed JSONL')

    $sessionKey = 'agent:test:m4-current'
    $validLines = @(
        '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"trace.metadata","sessionKey":"agent:test:m4-current","data":{"complex":{"array":[1,{"Id":"upper","id":"lower"},[true,null,{"unicode":"Android \ud83e\udd9e"}]],"escaped":"line1\\nline2"}}}',
        '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"transcript","type":"tool_call","sessionKey":"agent:test:m4-current","data":{"name":"android__select_device","toolCallId":"wrapper-only"}}',
        '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"tool.call","sessionKey":"agent:test:historical","data":{"name":"unrelated_historical_tool","toolCallId":"historical-call","arguments":{}}}',
        '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"tool.call","sessionKey":"agent:test:m4-current","data":{"name":"android__select_device","toolCallId":"call-1","arguments":{}}}',
        '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"tool.result","sessionKey":"agent:test:m4-current","data":{"name":"android__select_device","toolCallId":"call-1","success":true,"contentItems":[{"type":"text","text":"device selected"}]}}',
        '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"tool.call","sessionKey":"agent:test:m4-current","data":{"name":"android__appium_session_management","toolCallId":"call-2","arguments":{"action":"create","capabilities":{"appium:automationName":"UiAutomator2","appium:noReset":true}}}}',
        '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"tool.result","sessionKey":"agent:test:m4-current","data":{"name":"android__appium_session_management","toolCallId":"call-2","status":"completed","isError":false}}',
        '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"tool.call","sessionKey":"agent:test:m4-current","data":{"name":"android__appium_app_lifecycle","toolCallId":"call-3","arguments":{"action":"activate","appId":"com.android.settings"}}}',
        '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"tool.result","sessionKey":"agent:test:m4-current","data":{"name":"android__appium_app_lifecycle","toolCallId":"call-3","success":true}}',
        '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"tool.call","sessionKey":"agent:test:m4-current","data":{"name":"android__appium_get_page_source","toolCallId":"call-4","arguments":{}}}',
        '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"tool.result","sessionKey":"agent:test:m4-current","data":{"name":"android__appium_get_page_source","toolCallId":"call-4","success":true,"contentItems":[{"type":"text","text":"<?xml version=\"1.0\"?><hierarchy package=\"com.android.settings\"><node text=\"Settings\"/></hierarchy>"}],"nested":{"levels":[{"one":{"two":{"three":[1,2,3]}}}]}}}',
        '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"tool.call","sessionKey":"agent:test:m4-current","data":{"name":"android__appium_session_management","toolCallId":"call-5","arguments":{"action":"delete"}}}',
        '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"tool.result","sessionKey":"agent:test:m4-current","data":{"name":"android__appium_session_management","toolCallId":"call-5","success":true}}',
        '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"model.completed","sessionKey":"agent:test:m4-current","provider":"local","modelId":"GLM-5.3","data":{"status":"done","aborted":false,"timedOut":false,"usage":{"input":1000,"output":100}}}',
        '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"session.ended","sessionKey":"agent:test:m4-current","data":{"status":"success"}}',
        ''
    )
    $currentBundle = New-TrajectoryFixture -Workspace $temporaryDirectory -Name 'exact-current-session' -Lines $validLines

    $selectedBundle = Get-OpenClawTrajectoryBundleDirectory -Workspace $temporaryDirectory -OutputName 'exact-current-session'
    Assert-RegressionCondition `
        -Condition ($selectedBundle -ceq [System.IO.Path]::GetFullPath($currentBundle)) `
        -Message 'The deterministic bundle selector did not resolve the exact current-session export.'

    $evidence = Get-AndroidTrajectoryEvidence -BundleDirectory $selectedBundle -ExpectedSessionKey $sessionKey -NodePath $nodePath
    Assert-RegressionCondition -Condition $evidence.IsAccepted -Message 'The valid exact-session trajectory was not accepted.'
    Assert-RegressionCondition -Condition ($evidence.NonBlankLineCount -eq 15) -Message 'The blank final JSONL line was not ignored correctly.'
    Assert-RegressionCondition -Condition ($evidence.CompatibilityRepairs -eq 0) -Message 'Ordinary valid JSONL was unexpectedly modified by the compatibility repair.'
    Assert-RegressionCondition -Condition ($evidence.ToolCallCount -eq 5) -Message 'Expected five current-session tool.call events.'
    Assert-RegressionCondition -Condition ($evidence.ToolResultCount -eq 5) -Message 'Expected five current-session tool.result events.'
    Assert-RegressionCondition -Condition ($evidence.ExactToolSet) -Message 'The trajectory did not preserve the exact four-tool set.'
    Assert-RegressionCondition -Condition ($evidence.ModelCompleted) -Message 'model.completed done evidence was not detected.'
    Assert-RegressionCondition -Condition ($evidence.SessionEnded) -Message 'session.ended success evidence was not detected.'

    $windowsPowerShell = Resolve-ExternalCommand -Names @('powershell.exe')
    if ($windowsPowerShell) {
        $offlineHarness = Invoke-NativeCommand -FilePath $windowsPowerShell -Arguments @(
            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $PSScriptRoot 'test-openclaw-android.ps1'),
            '-TrajectoryBundlePath', $selectedBundle,
            '-TrajectorySessionKey', $sessionKey
        )
        Assert-RegressionCondition -Condition ($offlineHarness.ExitCode -eq 0) -Message 'The optional diagnostic mode rejected the valid existing trajectory bundle.'
        Assert-RegressionCondition `
            -Condition (@($offlineHarness.Lines | Where-Object { $_ -ceq 'M4 PASS' }).Count -eq 0) `
            -Message 'Diagnostic JSONL inspection incorrectly declared Milestone 4 PASS.'
    }

    $singletonBundle = New-TrajectoryFixture `
        -Workspace $temporaryDirectory `
        -Name 'singleton-event' `
        -Lines @(
            '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"session.ended","sessionKey":"agent:test:m4-current","data":{"status":"success"}}',
            ''
        )
    $singletonProjection = Read-OpenClawTrajectoryProjection -BundleDirectory $singletonBundle -NodePath $nodePath
    Assert-RegressionCondition `
        -Condition (@($singletonProjection.sessionEnds).Count -eq 1) `
        -Message 'A singleton event collection did not remain countable as one event.'

    $failedResultLines = @($validLines)
    $failedResultLines[6] = '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"tool.result","sessionKey":"agent:test:m4-current","data":{"name":"android__appium_session_management","toolCallId":"call-2","success":false,"status":"failed","isError":true}}'
    $failedResultBundle = New-TrajectoryFixture -Workspace $temporaryDirectory -Name 'failed-tool-result' -Lines $failedResultLines
    $failedResultEvidence = Get-AndroidTrajectoryEvidence -BundleDirectory $failedResultBundle -ExpectedSessionKey $sessionKey -NodePath $nodePath
    Assert-RegressionCondition -Condition (-not $failedResultEvidence.SessionCreated) -Message 'A failed session-creation result was incorrectly paired as successful.'
    Assert-RegressionCondition -Condition (-not $failedResultEvidence.IsAccepted) -Message 'A failed tool result was incorrectly accepted.'

    $missingDeleteLines = @($validLines[0..10] + $validLines[13..15])
    $missingDeleteBundle = New-TrajectoryFixture -Workspace $temporaryDirectory -Name 'missing-session-deletion' -Lines $missingDeleteLines
    $missingDeleteEvidence = Get-AndroidTrajectoryEvidence -BundleDirectory $missingDeleteBundle -ExpectedSessionKey $sessionKey -NodePath $nodePath
    Assert-RegressionCondition -Condition (-not $missingDeleteEvidence.SessionDeleted) -Message 'A missing session-deletion call was incorrectly inferred.'
    Assert-RegressionCondition -Condition (-not $missingDeleteEvidence.IsAccepted) -Message 'A trajectory without session deletion was incorrectly accepted.'

    $emptyPageSourceLines = @($validLines)
    $emptyPageSourceLines[10] = '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"tool.result","sessionKey":"agent:test:m4-current","data":{"name":"android__appium_get_page_source","toolCallId":"call-4","success":true,"contentItems":[{"type":"text","text":""}]}}'
    $emptyPageSourceBundle = New-TrajectoryFixture -Workspace $temporaryDirectory -Name 'empty-page-source' -Lines $emptyPageSourceLines
    $emptyPageSourceEvidence = Get-AndroidTrajectoryEvidence -BundleDirectory $emptyPageSourceBundle -ExpectedSessionKey $sessionKey -NodePath $nodePath
    Assert-RegressionCondition -Condition (-not $emptyPageSourceEvidence.PageSourceNonEmpty) -Message 'An empty page-source result was incorrectly accepted.'
    Assert-RegressionCondition -Condition (-not $emptyPageSourceEvidence.IsAccepted) -Message 'A trajectory with empty page source was incorrectly accepted.'

    $nonSettingsLines = @($validLines)
    $nonSettingsLines[10] = '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"tool.result","sessionKey":"agent:test:m4-current","data":{"name":"android__appium_get_page_source","toolCallId":"call-4","success":true,"contentItems":[{"type":"text","text":"<?xml version=\"1.0\"?><hierarchy package=\"com.example.notes\"><node text=\"Notes\"/></hierarchy>"}]}}'
    $nonSettingsBundle = New-TrajectoryFixture -Workspace $temporaryDirectory -Name 'non-settings-page-source' -Lines $nonSettingsLines
    $nonSettingsEvidence = Get-AndroidTrajectoryEvidence -BundleDirectory $nonSettingsBundle -ExpectedSessionKey $sessionKey -NodePath $nodePath
    Assert-RegressionCondition -Condition (-not $nonSettingsEvidence.SettingsInPageSource) -Message 'A non-Settings hierarchy was incorrectly accepted as Android Settings.'
    Assert-RegressionCondition -Condition (-not $nonSettingsEvidence.IsAccepted) -Message 'A non-Settings page source was incorrectly accepted.'

    $failedTerminalLines = @($validLines)
    $failedTerminalLines[14] = '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"session.ended","sessionKey":"agent:test:m4-current","data":{"status":"error","promptError":"synthetic failure"}}'
    $failedTerminalBundle = New-TrajectoryFixture -Workspace $temporaryDirectory -Name 'failed-terminal-session' -Lines $failedTerminalLines
    $failedTerminalEvidence = Get-AndroidTrajectoryEvidence -BundleDirectory $failedTerminalBundle -ExpectedSessionKey $sessionKey -NodePath $nodePath
    Assert-RegressionCondition -Condition (-not $failedTerminalEvidence.SessionEnded) -Message 'A failed terminal session was incorrectly accepted as successful.'
    Assert-RegressionCondition -Condition (-not $failedTerminalEvidence.IsAccepted) -Message 'A failed terminal session was incorrectly accepted.'

    $failedModelLines = @($validLines)
    $failedModelLines[13] = '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"model.completed","sessionKey":"agent:test:m4-current","provider":"local","modelId":"GLM-5.3","data":{"status":"aborted","aborted":true,"timedOut":false}}'
    $failedModelBundle = New-TrajectoryFixture -Workspace $temporaryDirectory -Name 'failed-model-completion' -Lines $failedModelLines
    $failedModelEvidence = Get-AndroidTrajectoryEvidence -BundleDirectory $failedModelBundle -ExpectedSessionKey $sessionKey -NodePath $nodePath
    Assert-RegressionCondition -Condition (-not $failedModelEvidence.ModelCompleted) -Message 'An aborted model completion was incorrectly accepted as done.'
    Assert-RegressionCondition -Condition (-not $failedModelEvidence.IsAccepted) -Message 'An aborted model completion was incorrectly accepted.'

    $wrapperOnlyBundle = New-TrajectoryFixture `
        -Workspace $temporaryDirectory `
        -Name 'wrapper-events-only' `
        -Lines @(
            '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"transcript","type":"tool_call","sessionKey":"agent:test:m4-current","data":{"name":"android__select_device","toolCallId":"wrapper-1"}}',
            '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"transcript","type":"tool_search","sessionKey":"agent:test:m4-current","data":{"name":"android__appium_session_management"}}',
            '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"transcript","type":"tool_describe","sessionKey":"agent:test:m4-current","data":{"name":"android__appium_get_page_source"}}',
            '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"model.completed","sessionKey":"agent:test:m4-current","data":{"status":"done","aborted":false,"timedOut":false}}',
            '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"session.ended","sessionKey":"agent:test:m4-current","data":{"status":"success"}}'
        )
    $wrapperOnlyEvidence = Get-AndroidTrajectoryEvidence -BundleDirectory $wrapperOnlyBundle -ExpectedSessionKey $sessionKey -NodePath $nodePath
    Assert-RegressionCondition -Condition ($wrapperOnlyEvidence.ToolCallCount -eq 0) -Message 'Generic wrapper events were incorrectly projected as tool.call events.'
    Assert-RegressionCondition -Condition (-not $wrapperOnlyEvidence.IsAccepted) -Message 'Generic wrapper events were incorrectly accepted as Android tool evidence.'

    $repairedWorkflowLines = @($validLines)
    $repairedWorkflowLines[10] = '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"source":"runtime","type":"tool.result","sessionKey":"agent:test:m4-current","data":{"name":"android__appium_get_page_source","toolCallId":"call-4","success":true,"contentItems":[{"type":"text","text":"<?xml version=\"1.0\"?><hierarchy package=\"com.android.settings\"><node password=***"***\"/><node password=***"***\"/></hierarchy>"}]}}'
    $repairedWorkflowBundle = New-TrajectoryFixture -Workspace $temporaryDirectory -Name 'known-redaction-repair' -Lines $repairedWorkflowLines
    $repairedWorkflowEvidence = Get-AndroidTrajectoryEvidence -BundleDirectory $repairedWorkflowBundle -ExpectedSessionKey $sessionKey -NodePath $nodePath
    Assert-RegressionCondition -Condition $repairedWorkflowEvidence.IsAccepted -Message 'The exact OpenClaw password-redaction corruption was not repaired within an otherwise valid Android workflow.'
    Assert-RegressionCondition -Condition ($repairedWorkflowEvidence.CompatibilityRepairs -eq 2) -Message 'Multiple known corruption occurrences on one line were not all repaired.'

    $wrongTypeRepairBundle = New-TrajectoryFixture `
        -Workspace $temporaryDirectory `
        -Name 'known-corruption-wrong-event-type' `
        -Lines @('{"traceSchema":"openclaw-trajectory","schemaVersion":1,"type":"tool.call","data":{"text":"password=***"***\""}}')
    Assert-TrajectoryParseRejected `
        -BundleDirectory $wrongTypeRepairBundle `
        -NodePath $nodePath `
        -ExpectedLineNumber 1 `
        -Message 'The compatibility repair incorrectly accepted a non-tool.result event.'

    $wrongSchemaRepairBundle = New-TrajectoryFixture `
        -Workspace $temporaryDirectory `
        -Name 'known-corruption-wrong-schema' `
        -Lines @('{"traceSchema":"openclaw-trajectory","schemaVersion":2,"type":"tool.result","data":{"text":"password=***"***\""}}')
    Assert-TrajectoryParseRejected `
        -BundleDirectory $wrongSchemaRepairBundle `
        -NodePath $nodePath `
        -ExpectedLineNumber 1 `
        -Message 'The compatibility repair incorrectly accepted a non-v1 trajectory event.'

    $unrelatedQuoteBundle = New-TrajectoryFixture `
        -Workspace $temporaryDirectory `
        -Name 'unrelated-malformed-quote' `
        -Lines @('{"traceSchema":"openclaw-trajectory","schemaVersion":1,"type":"tool.result","data":{"text":"unrelated="broken\""}}')
    Assert-TrajectoryParseRejected `
        -BundleDirectory $unrelatedQuoteBundle `
        -NodePath $nodePath `
        -ExpectedLineNumber 1 `
        -Message 'An unrelated malformed quote was incorrectly repaired.'

    $similarPasswordBundle = New-TrajectoryFixture `
        -Workspace $temporaryDirectory `
        -Name 'similar-password-corruption' `
        -Lines @('{"traceSchema":"openclaw-trajectory","schemaVersion":1,"type":"tool.result","data":{"text":"password=**"***\""}}')
    Assert-TrajectoryParseRejected `
        -BundleDirectory $similarPasswordBundle `
        -NodePath $nodePath `
        -ExpectedLineNumber 1 `
        -Message 'A similar but nonmatching password corruption was incorrectly repaired.'

    $repairWithOtherErrorBundle = New-TrajectoryFixture `
        -Workspace $temporaryDirectory `
        -Name 'known-repair-plus-other-error' `
        -Lines @(
            '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"type":"trace.metadata","data":{}}',
            '',
            '{"traceSchema":"openclaw-trajectory","schemaVersion":1,"type":"tool.result","data":{"text":"password=***"***\"" "other":true}}'
        )
    Assert-TrajectoryParseRejected `
        -BundleDirectory $repairWithOtherErrorBundle `
        -NodePath $nodePath `
        -ExpectedLineNumber 3 `
        -Message 'The known repair incorrectly concealed another JSON error or lost its original line number.'

    $malformedBundle = New-TrajectoryFixture `
        -Workspace $temporaryDirectory `
        -Name 'malformed-current-session' `
        -Lines @('{"type":"session.started"}', '{ malformed', '')
    $malformedRejected = $false
    try {
        [void](Read-OpenClawTrajectoryProjection -BundleDirectory $malformedBundle -NodePath $nodePath)
    }
    catch {
        $malformedRejected = $_.Exception.Message -match 'Invalid JSONL at line 2'
    }
    Assert-RegressionCondition -Condition $malformedRejected -Message 'Malformed JSONL was not rejected at the correct line.'

    $successfulWorkspace = Join-Path $temporaryDirectory ('openclaw-android-m4-success-' + [Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $successfulWorkspace -ErrorAction Stop)
    $successfulBundle = Get-OpenClawTrajectoryBundleDirectory -Workspace $successfulWorkspace -OutputName 'm4-acceptance-evidence'
    $successfulDisposition = Complete-OpenClawAcceptanceWorkspace `
        -TemporaryDirectory $successfulWorkspace `
        -AcceptancePassed $true `
        -ExpectedBundleDirectory $successfulBundle `
        -AcceptanceSessionKey $sessionKey
    Assert-RegressionCondition -Condition $successfulDisposition.Removed -Message 'A successful acceptance workspace was not permitted to be removed.'
    Assert-RegressionCondition -Condition (-not (Test-Path -LiteralPath $successfulWorkspace)) -Message 'Successful acceptance cleanup did not remove its safe temporary workspace.'

    $failedWorkspace = Join-Path $temporaryDirectory ('openclaw-android-m4-failed-' + [Guid]::NewGuid().ToString('N'))
    $failedBundle = New-TrajectoryFixture `
        -Workspace $failedWorkspace `
        -Name 'm4-acceptance-evidence' `
        -Lines @('{"type":"session.started"}', '{ malformed', '')
    $failedEventsPath = Join-Path $failedBundle 'events.jsonl'
    $failedParserObserved = $false
    try {
        [void](Read-OpenClawTrajectoryProjection -BundleDirectory $failedBundle -NodePath $nodePath)
    }
    catch {
        $failedParserObserved = $_.Exception.Message -match 'Invalid JSONL at line 2'
    }
    Assert-RegressionCondition -Condition $failedParserObserved -Message 'The failed-workspace fixture did not produce the expected parser failure.'
    $failedDisposition = Complete-OpenClawAcceptanceWorkspace `
        -TemporaryDirectory $failedWorkspace `
        -AcceptancePassed $false `
        -ExpectedBundleDirectory $failedBundle `
        -AcceptanceSessionKey $sessionKey
    Assert-RegressionCondition -Condition $failedDisposition.Retained -Message 'A failed acceptance workspace was not retained.'
    Assert-RegressionCondition -Condition (Test-Path -LiteralPath $failedWorkspace -PathType Container) -Message 'Failed acceptance cleanup deleted the temporary workspace.'
    Assert-RegressionCondition -Condition (Test-Path -LiteralPath $failedEventsPath -PathType Leaf) -Message 'Failed parser cleanup deleted events.jsonl.'
    Assert-RegressionCondition -Condition ($failedDisposition.BundleDirectory -ceq [System.IO.Path]::GetFullPath($failedBundle)) -Message 'The retained bundle diagnostic path was not deterministic.'
    Assert-RegressionCondition -Condition ($failedDisposition.EventsPath -ceq [System.IO.Path]::GetFullPath($failedEventsPath)) -Message 'The retained events diagnostic path was not deterministic.'

    $preExportWorkspace = Join-Path $temporaryDirectory ('openclaw-android-m4-pre-export-' + [Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $preExportWorkspace -ErrorAction Stop)
    $preExportBundle = Get-OpenClawTrajectoryBundleDirectory -Workspace $preExportWorkspace -OutputName 'm4-acceptance-evidence'
    $preExportDisposition = Complete-OpenClawAcceptanceWorkspace `
        -TemporaryDirectory $preExportWorkspace `
        -AcceptancePassed $false `
        -ExpectedBundleDirectory $preExportBundle `
        -AcceptanceSessionKey $sessionKey
    Assert-RegressionCondition -Condition (Test-Path -LiteralPath $preExportWorkspace -PathType Container) -Message 'A failed pre-export workspace was not retained.'
    Assert-RegressionCondition -Condition ($preExportDisposition.EventsPath -ceq [System.IO.Path]::GetFullPath((Join-Path $preExportBundle 'events.jsonl'))) -Message 'The absent pre-export events path was not reported deterministically.'

    $unrelatedWorkspace = Join-Path $temporaryDirectory ('unrelated-temp-directory-' + [Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $unrelatedWorkspace -ErrorAction Stop)
    $unrelatedBundle = Get-OpenClawTrajectoryBundleDirectory -Workspace $unrelatedWorkspace -OutputName 'm4-acceptance-evidence'
    $unrelatedDisposition = Complete-OpenClawAcceptanceWorkspace `
        -TemporaryDirectory $unrelatedWorkspace `
        -AcceptancePassed $true `
        -ExpectedBundleDirectory $unrelatedBundle `
        -AcceptanceSessionKey $sessionKey
    Assert-RegressionCondition -Condition $unrelatedDisposition.Refused -Message 'Cleanup did not refuse an unrelated temporary directory.'
    Assert-RegressionCondition -Condition (Test-Path -LiteralPath $unrelatedWorkspace -PathType Container) -Message 'Cleanup deleted an unrelated temporary directory.'

    Write-Pass 'Exact current-session bundle selection ignored the unrelated old export.'
    Write-Pass 'Complex JSONL and a blank final line parsed successfully with Node JSON.parse.'
    Write-Pass 'Malformed JSONL was rejected with its exact line number.'
    Write-Pass 'Paired Android tool evidence and terminal model/session evidence passed.'
    Write-Pass 'Wrapper events were ignored; singleton and multiple-event collections remained countable.'
    Write-Pass 'Failed results, missing deletion, invalid page source, wrapper-only events, and failed terminal states were rejected.'
    Write-Pass 'Strict-first parsing and the exact OpenClaw 2026.9.7 password-redaction compatibility repair passed.'
    Write-Pass 'Nonmatching corruption, wrong envelopes, and additional JSON errors remained rejected at their original lines.'
    Write-Pass 'Successful workspace cleanup, failed-workspace retention, deterministic diagnostics, and path-safety refusal passed.'
    Write-Pass 'Optional bundle diagnostics passed without contacting OpenClaw or Android and did not declare M4 PASS.'
    exit 0
}
catch {
    Write-Host "[FAIL] OpenClaw trajectory regression failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    if ($temporaryDirectory -and (Test-Path -LiteralPath $temporaryDirectory)) {
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolvedTemporaryDirectory = [System.IO.Path]::GetFullPath($temporaryDirectory)
        $leaf = Split-Path -Leaf $resolvedTemporaryDirectory
        if ($resolvedTemporaryDirectory.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
            $leaf.StartsWith('openclaw-trajectory-test-', [System.StringComparison]::Ordinal)) {
            Remove-Item -LiteralPath $resolvedTemporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
