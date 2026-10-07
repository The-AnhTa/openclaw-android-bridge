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

function New-RuntimeEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$SessionKey,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][int]$Sequence,
        [Parameter(Mandatory = $true)]$Data
    )
    return [ordered]@{
        traceSchema = 'openclaw-trajectory'
        schemaVersion = 1
        traceId = $SessionId
        source = 'runtime'
        type = $Type
        ts = '2026-09-07T00:00:00.000Z'
        seq = $Sequence
        sessionId = $SessionId
        sessionKey = $SessionKey
        runId = 'fixture-run'
        data = $Data
    }
}

function New-BaseSpecification {
    param(
        [string]$SessionKey = 'agent:test:m4-current',
        [string]$SessionId = 'fixture-session-current'
    )

    $events = @(
        (New-RuntimeEvent -Type 'tool.call' -SessionKey $SessionKey -SessionId $SessionId -Sequence 1 -Data ([ordered]@{ name = 'android__select_device'; toolCallId = 'call-1'; args = @{} })),
        (New-RuntimeEvent -Type 'tool.result' -SessionKey $SessionKey -SessionId $SessionId -Sequence 2 -Data ([ordered]@{ name = 'android__select_device'; toolCallId = 'call-1'; success = $true; result = @{ status = 'ok' } })),
        (New-RuntimeEvent -Type 'tool.call' -SessionKey $SessionKey -SessionId $SessionId -Sequence 3 -Data ([ordered]@{ name = 'android__appium_session_management'; toolCallId = 'call-2'; args = @{ action = 'create' } })),
        (New-RuntimeEvent -Type 'tool.result' -SessionKey $SessionKey -SessionId $SessionId -Sequence 4 -Data ([ordered]@{ name = 'android__appium_session_management'; toolCallId = 'call-2'; success = $true; result = @{ status = 'completed' } })),
        (New-RuntimeEvent -Type 'tool.call' -SessionKey $SessionKey -SessionId $SessionId -Sequence 5 -Data ([ordered]@{ name = 'android__appium_app_lifecycle'; toolCallId = 'call-3'; args = @{ action = 'activate'; appId = 'com.android.settings' } })),
        (New-RuntimeEvent -Type 'tool.result' -SessionKey $SessionKey -SessionId $SessionId -Sequence 6 -Data ([ordered]@{ name = 'android__appium_app_lifecycle'; toolCallId = 'call-3'; success = $true; result = @{ status = 'ok' } })),
        (New-RuntimeEvent -Type 'tool.call' -SessionKey $SessionKey -SessionId $SessionId -Sequence 7 -Data ([ordered]@{ name = 'android__appium_get_page_source'; toolCallId = 'call-4'; args = @{} })),
        (New-RuntimeEvent -Type 'tool.result' -SessionKey $SessionKey -SessionId $SessionId -Sequence 8 -Data ([ordered]@{ name = 'android__appium_get_page_source'; toolCallId = 'call-4'; success = $true; result = @{ content = '<?xml version="1.0"?><hierarchy package="com.android.settings"><node text="Settings"/></hierarchy>' } })),
        (New-RuntimeEvent -Type 'tool.call' -SessionKey $SessionKey -SessionId $SessionId -Sequence 9 -Data ([ordered]@{ name = 'android__appium_session_management'; toolCallId = 'call-5'; args = @{ action = 'delete' } })),
        (New-RuntimeEvent -Type 'tool.result' -SessionKey $SessionKey -SessionId $SessionId -Sequence 10 -Data ([ordered]@{ name = 'android__appium_session_management'; toolCallId = 'call-5'; success = $true; result = @{ status = 'ok' } })),
        (New-RuntimeEvent -Type 'model.completed' -SessionKey $SessionKey -SessionId $SessionId -Sequence 11 -Data ([ordered]@{ aborted = $false; timedOut = $false; stopReason = 'stop' })),
        (New-RuntimeEvent -Type 'session.ended' -SessionKey $SessionKey -SessionId $SessionId -Sequence 12 -Data ([ordered]@{ status = 'success'; aborted = $false; timedOut = $false }))
    )
    $rows = @()
    for ($index = 0; $index -lt $events.Count; $index++) {
        $rows += [ordered]@{
            sessionId = $SessionId
            seq = $index + 1
            event = $events[$index]
        }
    }
    return [ordered]@{
        sessions = @([ordered]@{ key = $SessionKey; id = $SessionId })
        events = $rows
    }
}

function Copy-Specification {
    param([Parameter(Mandatory = $true)]$Specification)
    return (($Specification | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json)
}

function Add-ToolPairToSpecification {
    param(
        [Parameter(Mandatory = $true)]$Specification,
        [Parameter(Mandatory = $true)][string]$RawName,
        [Parameter(Mandatory = $true)][string]$ToolCallId,
        [hashtable]$Arguments = @{}
    )

    $copy = Copy-Specification -Specification $Specification
    $session = @($copy.sessions | Select-Object -First 1)[0]
    $eventRows = @($copy.events)
    $terminalRows = @($eventRows | Where-Object { $_.event.type -in @('model.completed', 'session.ended') })
    $workflowRows = @($eventRows | Where-Object { $_.event.type -notin @('model.completed', 'session.ended') })
    $callEvent = New-RuntimeEvent `
        -Type 'tool.call' `
        -SessionKey ([string]$session.key) `
        -SessionId ([string]$session.id) `
        -Sequence 1 `
        -Data ([ordered]@{ name = $RawName; toolCallId = $ToolCallId; args = $Arguments })
    $resultEvent = New-RuntimeEvent `
        -Type 'tool.result' `
        -SessionKey ([string]$session.key) `
        -SessionId ([string]$session.id) `
        -Sequence 1 `
        -Data ([ordered]@{ name = $RawName; toolCallId = $ToolCallId; success = $true; result = @{ status = 'ok' } })
    $copy.events = @(
        $workflowRows
        [PSCustomObject]@{ sessionId = [string]$session.id; seq = 1; event = $callEvent }
        [PSCustomObject]@{ sessionId = [string]$session.id; seq = 1; event = $resultEvent }
        $terminalRows
    )
    for ($index = 0; $index -lt $copy.events.Count; $index++) {
        $copy.events[$index].seq = $index + 1
        $copy.events[$index].event.seq = $index + 1
    }
    return $copy
}

function New-SqliteFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Specification,
        [Parameter(Mandatory = $true)][string]$NodePath
    )

    $databasePath = Join-Path $temporaryDirectory ($Name + '.sqlite')
    $specificationPath = Join-Path $temporaryDirectory ($Name + '.json')
    [System.IO.File]::WriteAllText(
        $specificationPath,
        ($Specification | ConvertTo-Json -Depth 30 -Compress),
        (New-Object System.Text.UTF8Encoding($false))
    )
    $builder = Join-Path $PSScriptRoot 'test-openclaw-sqlite-fixture.mjs'
    $result = Invoke-NativeCommand -FilePath $NodePath -Arguments @($builder, $databasePath, $specificationPath)
    Assert-RegressionCondition -Condition ($result.ExitCode -eq 0) -Message "Could not build SQLite fixture '$Name': $(@($result.Lines) -join ' ')"
    return $databasePath
}

function Get-FixtureEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Specification,
        [Parameter(Mandatory = $true)][string]$NodePath,
        [string]$SessionKey = 'agent:test:m4-current'
    )
    $databasePath = New-SqliteFixture -Name $Name -Specification $Specification -NodePath $NodePath
    return Get-AndroidSqliteTrajectoryEvidence -DatabasePath $databasePath -ExpectedSessionKey $SessionKey -NodePath $NodePath
}

try {
    . (Join-Path $PSScriptRoot 'lib\OpenClawAndroid.ps1')
    . (Join-Path $PSScriptRoot 'lib\OpenClawTrajectory.ps1')

    $nodePath = Resolve-ExternalCommand -Names @('node.exe', 'node')
    if (-not $nodePath) {
        throw 'Node.js is required for the SQLite trajectory regression test.'
    }
    $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('openclaw-sqlite-test-' + [Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $temporaryDirectory -ErrorAction Stop)

    $base = New-BaseSpecification
    $unrelatedSessionKey = 'agent:test:unrelated'
    $unrelatedSessionId = 'fixture-session-unrelated'
    $base.sessions += [PSCustomObject]@{ key = $unrelatedSessionKey; id = $unrelatedSessionId }
    $unrelatedEvent = New-RuntimeEvent -Type 'tool.call' -SessionKey $unrelatedSessionKey -SessionId $unrelatedSessionId -Sequence 1 -Data ([ordered]@{ name = 'dangerous_unrelated_tool'; toolCallId = 'other-1'; args = @{} })
    $base.events += [PSCustomObject]@{ sessionId = $unrelatedSessionId; seq = 1; event = $unrelatedEvent }
    [array]::Reverse($base.events)
    $validDatabase = New-SqliteFixture -Name 'valid-exact-session' -Specification $base -NodePath $nodePath
    $hashBefore = (Get-FileHash -LiteralPath $validDatabase -Algorithm SHA256).Hash
    $valid = Get-AndroidSqliteTrajectoryEvidence -DatabasePath $validDatabase -ExpectedSessionKey 'agent:test:m4-current' -NodePath $nodePath
    $hashAfter = (Get-FileHash -LiteralPath $validDatabase -Algorithm SHA256).Hash
    Assert-RegressionCondition -Condition $valid.IsAccepted -Message 'The valid SQLite runtime trajectory was not accepted.'
    Assert-RegressionCondition -Condition ($valid.EventCount -eq 12) -Message 'Exact-session selection did not ignore unrelated session rows.'
    Assert-RegressionCondition -Condition $valid.OrderedWorkflow -Message 'SQLite rows were not evaluated in authoritative storage-sequence order.'
    Assert-RegressionCondition -Condition ($valid.ToolCallCount -eq 5 -and $valid.ToolResultCount -eq 5) -Message 'Expected five correlated tool calls and results.'
    Assert-RegressionCondition -Condition ($valid.SessionCreated -and $valid.SessionDeleted) -Message 'Session create/delete evidence was not detected.'
    Assert-RegressionCondition -Condition ($valid.SettingsActivated -and $valid.SettingsInPageSource) -Message 'Settings activation/page-source evidence was not detected.'
    Assert-RegressionCondition -Condition ($valid.CalledTools.Count -eq 4 -and $valid.ExactToolSet) -Message 'Four Android tools alone did not satisfy the exact Android set.'
    Assert-RegressionCondition -Condition ($valid.InternalToolCallCount -eq 0) -Message 'A four-Android-tool fixture unexpectedly contained internal calls.'
    Assert-RegressionCondition -Condition ($hashBefore -ceq $hashAfter) -Message 'Read-only validation changed the SQLite database content.'
    Assert-RegressionCondition -Condition (-not (Test-Path -LiteralPath ($validDatabase + '-journal'))) -Message 'Read-only validation created a SQLite journal.'
    Assert-RegressionCondition -Condition (-not (Test-Path -LiteralPath ($validDatabase + '-wal'))) -Message 'Read-only validation created a SQLite WAL.'

    $withSearch = Add-ToolPairToSpecification -Specification (New-BaseSpecification) -RawName 'tool_search' -ToolCallId 'internal-search'
    $withSearchEvidence = Get-FixtureEvidence -Name 'with-tool-search' -Specification $withSearch -NodePath $nodePath
    Assert-RegressionCondition -Condition ($withSearchEvidence.IsAccepted -and $withSearchEvidence.ExactToolSet) -Message 'tool_search incorrectly affected the exact Android tool set.'
    Assert-RegressionCondition -Condition ($withSearchEvidence.InternalRawCalledTools -ccontains 'tool_search') -Message 'tool_search was not retained in the internal diagnostic collection.'

    $withDescribeAndCall = Add-ToolPairToSpecification -Specification (New-BaseSpecification) -RawName 'tool_describe' -ToolCallId 'internal-describe'
    $withDescribeAndCall = Add-ToolPairToSpecification -Specification $withDescribeAndCall -RawName 'tool_call' -ToolCallId 'internal-call'
    $withDescribeAndCallEvidence = Get-FixtureEvidence -Name 'with-tool-describe-call' -Specification $withDescribeAndCall -NodePath $nodePath
    Assert-RegressionCondition -Condition ($withDescribeAndCallEvidence.IsAccepted -and $withDescribeAndCallEvidence.ExactToolSet) -Message 'tool_describe or tool_call incorrectly affected the exact Android tool set.'

    $withAllWrappers = Add-ToolPairToSpecification -Specification $withDescribeAndCall -RawName 'tool_search' -ToolCallId 'internal-search-all'
    $withAllWrappersEvidence = Get-FixtureEvidence -Name 'with-all-wrapper-tools' -Specification $withAllWrappers -NodePath $nodePath
    Assert-RegressionCondition -Condition ($withAllWrappersEvidence.IsAccepted -and $withAllWrappersEvidence.ExactToolSet) -Message 'The three internal wrapper tools incorrectly affected Android acceptance.'
    Assert-RegressionCondition -Condition ($withAllWrappersEvidence.InternalToolCallCount -eq 3) -Message 'The three internal wrapper calls were not classified separately.'
    Assert-RegressionCondition -Condition ($withAllWrappersEvidence.AndroidToolCallCount -eq 5) -Message 'Internal wrappers changed the Android call count.'
    Assert-RegressionCondition -Condition ($withAllWrappersEvidence.AllRawCalledTools.Count -eq 7) -Message 'The all-tool diagnostic collection did not retain Android and wrapper tools.'

    $unexpectedAndroid = Add-ToolPairToSpecification -Specification (New-BaseSpecification) -RawName 'android__extra_tool' -ToolCallId 'unexpected-android'
    $unexpectedAndroidEvidence = Get-FixtureEvidence -Name 'unexpected-android-tool' -Specification $unexpectedAndroid -NodePath $nodePath
    Assert-RegressionCondition -Condition (-not $unexpectedAndroidEvidence.ExactToolSet -and -not $unexpectedAndroidEvidence.IsAccepted) -Message 'An unexpected android__ tool was accepted.'
    Assert-RegressionCondition -Condition ($unexpectedAndroidEvidence.UnexpectedAndroidTools -ccontains 'extra_tool') -Message 'The unexpected Android tool was not reported in Android diagnostics.'

    $missingRequired = Copy-Specification -Specification (New-BaseSpecification)
    $missingRequired.events = @($missingRequired.events | Where-Object {
        $nameProperty = $_.event.data.PSObject.Properties['name']
        -not $nameProperty -or [string]$nameProperty.Value -cne 'android__appium_get_page_source'
    })
    $missingRequiredEvidence = Get-FixtureEvidence -Name 'missing-required-android' -Specification $missingRequired -NodePath $nodePath
    Assert-RegressionCondition -Condition (-not $missingRequiredEvidence.ExactToolSet -and -not $missingRequiredEvidence.IsAccepted) -Message 'A missing required Android tool was accepted.'

    $wrapperCannotSubstitute = Copy-Specification -Specification (New-BaseSpecification)
    $wrapperCannotSubstitute.events = @($wrapperCannotSubstitute.events | Where-Object {
        $nameProperty = $_.event.data.PSObject.Properties['name']
        -not $nameProperty -or [string]$nameProperty.Value -cne 'android__select_device'
    })
    $wrapperCannotSubstitute = Add-ToolPairToSpecification `
        -Specification $wrapperCannotSubstitute `
        -RawName 'tool_call' `
        -ToolCallId 'wrapper-select-device' `
        -Arguments @{ name = 'android__select_device' }
    $wrapperCannotSubstituteEvidence = Get-FixtureEvidence -Name 'wrapper-cannot-substitute' -Specification $wrapperCannotSubstitute -NodePath $nodePath
    Assert-RegressionCondition -Condition (-not $wrapperCannotSubstituteEvidence.DeviceSelected -and -not $wrapperCannotSubstituteEvidence.ExactToolSet -and -not $wrapperCannotSubstituteEvidence.IsAccepted) -Message 'A wrapper tool substituted for a missing Android tool.'

    $mismatched = Copy-Specification -Specification (New-BaseSpecification)
    $mismatched.events[3].event.data.toolCallId = 'wrong-call-id'
    $mismatchedEvidence = Get-FixtureEvidence -Name 'mismatched-correlation' -Specification $mismatched -NodePath $nodePath
    Assert-RegressionCondition -Condition (-not $mismatchedEvidence.SessionCreated -and -not $mismatchedEvidence.IsAccepted) -Message 'A mismatched tool-call/result correlation was accepted.'

    $failedResult = Copy-Specification -Specification (New-BaseSpecification)
    $failedResult.events[3].event.data.success = $false
    $failedResult.events[3].event.data | Add-Member -NotePropertyName isError -NotePropertyValue $true
    $failedResultEvidence = Get-FixtureEvidence -Name 'failed-result' -Specification $failedResult -NodePath $nodePath
    Assert-RegressionCondition -Condition (-not $failedResultEvidence.SessionCreated -and -not $failedResultEvidence.IsAccepted) -Message 'A failed tool result was accepted.'

    $emptyPage = Copy-Specification -Specification (New-BaseSpecification)
    $emptyPage.events[7].event.data.result.content = ''
    $emptyPageEvidence = Get-FixtureEvidence -Name 'empty-page-source' -Specification $emptyPage -NodePath $nodePath
    Assert-RegressionCondition -Condition (-not $emptyPageEvidence.PageSourceNonEmpty -and -not $emptyPageEvidence.IsAccepted) -Message 'An empty page source was accepted.'

    $nonSettingsPage = Copy-Specification -Specification (New-BaseSpecification)
    $nonSettingsPage.events[7].event.data.result.content = '<?xml version="1.0"?><hierarchy package="com.example.notes"><node/></hierarchy>'
    $nonSettingsEvidence = Get-FixtureEvidence -Name 'non-settings-page-source' -Specification $nonSettingsPage -NodePath $nodePath
    Assert-RegressionCondition -Condition (-not $nonSettingsEvidence.SettingsInPageSource -and -not $nonSettingsEvidence.IsAccepted) -Message 'A non-Settings page source was accepted.'

    $failedModel = Copy-Specification -Specification (New-BaseSpecification)
    $failedModel.events[10].event.data.aborted = $true
    $failedModelEvidence = Get-FixtureEvidence -Name 'failed-model' -Specification $failedModel -NodePath $nodePath
    Assert-RegressionCondition -Condition (-not $failedModelEvidence.ModelCompleted -and -not $failedModelEvidence.IsAccepted) -Message 'A failed model.completed event was accepted.'

    $failedSession = Copy-Specification -Specification (New-BaseSpecification)
    $failedSession.events[11].event.data.status = 'error'
    $failedSessionEvidence = Get-FixtureEvidence -Name 'failed-session' -Specification $failedSession -NodePath $nodePath
    Assert-RegressionCondition -Condition (-not $failedSessionEvidence.SessionEnded -and -not $failedSessionEvidence.IsAccepted) -Message 'A failed session.ended event was accepted.'

    $missingDelete = Copy-Specification -Specification (New-BaseSpecification)
    $missingDelete.events = @($missingDelete.events | Where-Object {
        $toolCallIdProperty = $_.event.data.PSObject.Properties['toolCallId']
        -not $toolCallIdProperty -or [string]$toolCallIdProperty.Value -cne 'call-5'
    })
    $missingDeleteEvidence = Get-FixtureEvidence -Name 'missing-delete' -Specification $missingDelete -NodePath $nodePath
    Assert-RegressionCondition -Condition ($missingDeleteEvidence.ExactToolSet -and -not $missingDeleteEvidence.SessionDeleted -and -not $missingDeleteEvidence.IsAccepted) -Message 'Create/delete distinction was weakened or missing deletion events were accepted.'

    $unsupported = New-BaseSpecification
    $unsupported.unsupportedSchema = $true
    $unsupportedDatabase = New-SqliteFixture -Name 'unsupported-schema' -Specification $unsupported -NodePath $nodePath
    $unsupportedRejected = $false
    try {
        [void](Read-OpenClawSqliteTrajectoryProjection -DatabasePath $unsupportedDatabase -ExpectedSessionKey 'agent:test:m4-current' -NodePath $nodePath)
    }
    catch {
        $unsupportedRejected = $_.Exception.Message -match 'Unsupported OpenClaw trajectory SQLite schema\.'
    }
    Assert-RegressionCondition -Condition $unsupportedRejected -Message 'An unexpected SQLite trajectory schema did not fail closed.'

    $mockDirectory = Join-Path $temporaryDirectory 'mock-bin'
    [void](New-Item -ItemType Directory -Path $mockDirectory -ErrorAction Stop)
    $mockLog = Join-Path $temporaryDirectory 'openclaw-invocations.log'
    $mockPath = Join-Path $mockDirectory 'openclaw.ps1'
    $mockSource = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Remaining)
[System.IO.File]::AppendAllText($env:OPENCLAW_SQLITE_TEST_LOG, (($Remaining -join ' ') + [Environment]::NewLine))
if ($Remaining.Count -eq 4 -and $Remaining[0] -ceq 'sessions' -and $Remaining[1] -ceq '--agent' -and $Remaining[3] -ceq '--json') {
    [PSCustomObject]@{ path = $env:OPENCLAW_SQLITE_TEST_STORE; sessions = @() } | ConvertTo-Json -Compress
    exit 0
}
Write-Error 'Unexpected mock OpenClaw invocation.'
exit 97
'@
    [System.IO.File]::WriteAllText($mockPath, $mockSource, (New-Object System.Text.UTF8Encoding($false)))
    $windowsPowerShell = Resolve-ExternalCommand -Names @('powershell.exe')
    if ($windowsPowerShell) {
        $oldPath = $env:PATH
        $oldLog = $env:OPENCLAW_SQLITE_TEST_LOG
        $oldStore = $env:OPENCLAW_SQLITE_TEST_STORE
        try {
            $env:PATH = $mockDirectory + [System.IO.Path]::PathSeparator + $oldPath
            $env:OPENCLAW_SQLITE_TEST_LOG = $mockLog
            $env:OPENCLAW_SQLITE_TEST_STORE = $validDatabase
            $offlineHarness = Invoke-NativeCommand -FilePath $windowsPowerShell -Arguments @(
                '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', (Join-Path $PSScriptRoot 'test-openclaw-android.ps1'),
                '-ExistingSessionKey', 'agent:test:m4-current'
            )
        }
        finally {
            $env:PATH = $oldPath
            $env:OPENCLAW_SQLITE_TEST_LOG = $oldLog
            $env:OPENCLAW_SQLITE_TEST_STORE = $oldStore
        }
        Assert-RegressionCondition -Condition ($offlineHarness.ExitCode -eq 0) -Message "The existing-session harness failed: $(@($offlineHarness.Lines) -join ' ')"
        Assert-RegressionCondition -Condition (@($offlineHarness.Lines | Where-Object { $_ -ceq 'M4 PASS' }).Count -eq 1) -Message 'Existing-session validation did not end with M4 PASS.'
        $invocations = @(Get-Content -LiteralPath $mockLog)
        Assert-RegressionCondition -Condition ($invocations.Count -eq 1) -Message 'Existing-session mode made more than one OpenClaw call.'
        Assert-RegressionCondition -Condition ($invocations[0] -ceq 'sessions --agent test --json') -Message 'Existing-session mode invoked agent, MCP, Android, export, or another unexpected OpenClaw command.'
    }

    $harnessText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'test-openclaw-android.ps1') -Raw
    Assert-RegressionCondition -Condition ($harnessText -notmatch "'sessions',\s*'export-trajectory'") -Message 'The normal acceptance harness still invokes trajectory export.'
    Assert-RegressionCondition -Condition ($harnessText -notmatch 'events\.jsonl') -Message 'The normal acceptance harness still depends on events.jsonl.'

    Write-Pass 'SQLite exact-session selection ignored unrelated sessions and preserved storage order.'
    Write-Pass 'Four exact Android tools passed alone and with tool_search, tool_describe, and tool_call wrappers.'
    Write-Pass 'Unexpected android__ tools, missing required Android tools, and wrapper substitution were rejected.'
    Write-Pass 'Correlated tool results, create/delete distinction, Settings activation, and Settings page source passed.'
    Write-Pass 'Failed results, bad correlation, invalid page source, terminal failures, and missing events were rejected.'
    Write-Pass 'Unexpected schema failed closed and the database remained unchanged without journals or WAL files.'
    Write-Pass 'Existing-session mode used only session-store discovery plus read-only SQLite validation; no agent, MCP, Android, JSONL, or export call occurred.'
    exit 0
}
catch {
    Write-Host "[FAIL] OpenClaw SQLite trajectory regression failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    if ($temporaryDirectory -and (Test-Path -LiteralPath $temporaryDirectory)) {
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolved = [System.IO.Path]::GetFullPath($temporaryDirectory)
        $leaf = Split-Path -Leaf $resolved
        if ($resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
            $leaf.StartsWith('openclaw-sqlite-test-', [System.StringComparison]::Ordinal)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
