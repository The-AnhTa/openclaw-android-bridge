Set-StrictMode -Version Latest

function Get-OpenClawTrajectoryBundleDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$OutputName
    )

    if ([string]::IsNullOrWhiteSpace($OutputName) -or
        [System.IO.Path]::IsPathRooted($OutputName) -or
        [System.IO.Path]::GetFileName($OutputName) -cne $OutputName -or
        $OutputName -in @('.', '..')) {
        throw 'The trajectory output name must be one relative directory name.'
    }

    $workspacePath = [System.IO.Path]::GetFullPath($Workspace)
    $exportRoot = Join-Path (Join-Path $workspacePath '.openclaw') 'trajectory-exports'
    return [System.IO.Path]::GetFullPath((Join-Path $exportRoot $OutputName))
}

function Complete-OpenClawAcceptanceWorkspace {
    param(
        [Parameter(Mandatory = $true)][string]$TemporaryDirectory,
        [Parameter(Mandatory = $true)][bool]$AcceptancePassed,
        [Parameter(Mandatory = $true)][string]$ExpectedBundleDirectory,
        [AllowNull()][string]$AcceptanceSessionKey
    )

    $resolvedTemporaryDirectory = [System.IO.Path]::GetFullPath($TemporaryDirectory)
    $resolvedBundleDirectory = [System.IO.Path]::GetFullPath($ExpectedBundleDirectory)
    $expectedEventsPath = Join-Path $resolvedBundleDirectory 'events.jsonl'

    if (-not $AcceptancePassed) {
        Write-Host '[INFO] Retained failed trajectory workspace:' -ForegroundColor Cyan
        Write-Host $resolvedTemporaryDirectory
        Write-Host '[INFO] Expected acceptance trajectory bundle:' -ForegroundColor Cyan
        Write-Host $resolvedBundleDirectory
        Write-Host '[INFO] Expected events file:' -ForegroundColor Cyan
        Write-Host $expectedEventsPath
        if (-not [string]::IsNullOrWhiteSpace($AcceptanceSessionKey)) {
            Write-Host '[INFO] Acceptance session key:' -ForegroundColor Cyan
            Write-Host $AcceptanceSessionKey
        }

        return [PSCustomObject]@{
            Removed = $false
            Retained = $true
            Refused = $false
            Workspace = $resolvedTemporaryDirectory
            BundleDirectory = $resolvedBundleDirectory
            EventsPath = $expectedEventsPath
        }
    }

    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $leaf = Split-Path -Leaf $resolvedTemporaryDirectory
    $safeToRemove = (
        $resolvedTemporaryDirectory.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        $leaf.StartsWith('openclaw-android-m4-', [System.StringComparison]::Ordinal)
    )
    if (-not $safeToRemove) {
        Write-Host "[WARN] Refused to remove unexpected evidence path: $resolvedTemporaryDirectory" -ForegroundColor Yellow
        return [PSCustomObject]@{
            Removed = $false
            Retained = $true
            Refused = $true
            Workspace = $resolvedTemporaryDirectory
            BundleDirectory = $resolvedBundleDirectory
            EventsPath = $expectedEventsPath
        }
    }

    if (Test-Path -LiteralPath $resolvedTemporaryDirectory) {
        Remove-Item -LiteralPath $resolvedTemporaryDirectory -Recurse -Force -ErrorAction Stop
    }
    return [PSCustomObject]@{
        Removed = $true
        Retained = $false
        Refused = $false
        Workspace = $resolvedTemporaryDirectory
        BundleDirectory = $resolvedBundleDirectory
        EventsPath = $expectedEventsPath
    }
}

function Read-OpenClawTrajectoryProjection {
    param(
        [Parameter(Mandatory = $true)][string]$BundleDirectory,
        [string]$NodePath
    )

    $bundlePath = [System.IO.Path]::GetFullPath($BundleDirectory)
    $eventsPath = Join-Path $bundlePath 'events.jsonl'
    if (-not (Test-Path -LiteralPath $eventsPath -PathType Leaf)) {
        throw "The selected trajectory bundle has no events.jsonl file: $bundlePath"
    }

    if ([string]::IsNullOrWhiteSpace($NodePath)) {
        $NodePath = Resolve-ExternalCommand -Names @('node.exe', 'node')
    }
    if (-not $NodePath) {
        throw 'Node.js is required to parse OpenClaw trajectory JSONL safely.'
    }

    $parserPath = Join-Path $PSScriptRoot 'parse-openclaw-trajectory.mjs'
    if (-not (Test-Path -LiteralPath $parserPath -PathType Leaf)) {
        throw "The OpenClaw trajectory JSONL parser is missing: $parserPath"
    }

    $parseResult = Invoke-NativeCommand -FilePath $NodePath -Arguments @($parserPath, $eventsPath)
    if ($parseResult.ExitCode -ne 0) {
        $diagnostic = Get-SafeDiagnosticText -Text (@($parseResult.Lines) -join ' ')
        throw "OpenClaw trajectory JSONL parsing failed: $diagnostic"
    }

    $json = (@($parseResult.Lines) -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw 'OpenClaw trajectory JSONL parsing returned no projection.'
    }
    try {
        return $json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "The trajectory parser returned invalid projection JSON: $(Get-SafeDiagnosticText -Text $_.Exception.Message)"
    }
}

function Resolve-OpenClawAgentStorePath {
    param(
        [Parameter(Mandatory = $true)][string]$OpenClawPath,
        [Parameter(Mandatory = $true)][string]$AgentId
    )

    $result = Invoke-OpenClawCommand -OpenClawPath $OpenClawPath -Arguments @(
        'sessions', '--agent', $AgentId, '--json'
    )
    $json = ConvertFrom-OpenClawJson -Result $result -Operation "OpenClaw session-store discovery for agent '$AgentId'"
    $pathProperty = $json.PSObject.Properties['path']
    if (-not $pathProperty -or
        $pathProperty.Value -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$pathProperty.Value)) {
        throw "OpenClaw did not report one physical SQLite store path for agent '$AgentId'."
    }

    $storePath = [System.IO.Path]::GetFullPath([string]$pathProperty.Value)
    if ([System.IO.Path]::GetExtension($storePath) -cne '.sqlite' -or
        -not (Test-Path -LiteralPath $storePath -PathType Leaf)) {
        throw "OpenClaw reported an unavailable physical SQLite store for agent '$AgentId'."
    }
    return $storePath
}

function Read-OpenClawSqliteTrajectoryProjection {
    param(
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionKey,
        [string]$NodePath
    )

    if ([string]::IsNullOrWhiteSpace($NodePath)) {
        $NodePath = Resolve-ExternalCommand -Names @('node.exe', 'node')
    }
    if (-not $NodePath) {
        throw 'Node.js is required to read the OpenClaw trajectory SQLite database safely.'
    }

    $readerPath = Join-Path $PSScriptRoot 'read-openclaw-trajectory-sqlite.mjs'
    if (-not (Test-Path -LiteralPath $readerPath -PathType Leaf)) {
        throw "The OpenClaw trajectory SQLite reader is missing: $readerPath"
    }

    $readResult = Invoke-NativeCommand -FilePath $NodePath -Arguments @(
        $readerPath,
        [System.IO.Path]::GetFullPath($DatabasePath),
        $ExpectedSessionKey
    )
    if ($readResult.ExitCode -ne 0) {
        $diagnostic = Get-SafeDiagnosticText -Text (@($readResult.Lines) -join ' ')
        throw "OpenClaw trajectory SQLite validation failed: $diagnostic"
    }

    $json = (@($readResult.Lines) -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw 'OpenClaw trajectory SQLite validation returned no evidence projection.'
    }
    try {
        $projection = $json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "The SQLite reader returned invalid evidence JSON: $(Get-SafeDiagnosticText -Text $_.Exception.Message)"
    }
    if ($projection.databaseReadOnly -ne $true) {
        throw 'The OpenClaw trajectory SQLite reader did not confirm query-only access.'
    }
    return $projection
}

function Get-AndroidTrajectoryEvidenceFromProjection {
    param(
        [Parameter(Mandatory = $true)]$Projection,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionKey,
        [Parameter(Mandatory = $true)][string]$EvidenceSource,
        [Parameter(Mandatory = $true)][string]$EvidenceLocation
    )

    $projection = $Projection
    $calls = @(@($projection.toolCalls) | Where-Object { $_.sessionKey -ceq $ExpectedSessionKey } | ForEach-Object {
        $argumentsProperty = $_.PSObject.Properties['argumentsJson']
        $argumentsJson = if ($argumentsProperty) { [string]$argumentsProperty.Value } else { '' }
        $createProperty = $_.PSObject.Properties['isCreate']
        $deleteProperty = $_.PSObject.Properties['isDelete']
        $settingsProperty = $_.PSObject.Properties['activatesSettings']
        $rawName = [string]$_.name
        [PSCustomObject]@{
            LineNumber = [int]$_.lineNumber
            RawName = $rawName
            NormalizedName = Get-NormalizedMcpToolName -ToolName $rawName
            ToolCallId = [string]$_.toolCallId
            IsCreate = (($createProperty -and $createProperty.Value -eq $true) -or $argumentsJson -match '"action"\s*:\s*"create"')
            IsDelete = (($deleteProperty -and $deleteProperty.Value -eq $true) -or $argumentsJson -match '"action"\s*:\s*"delete"')
            ActivatesSettings = (
                ($settingsProperty -and $settingsProperty.Value -eq $true) -or
                ($argumentsJson -match '"action"\s*:\s*"activate"' -and $argumentsJson -match 'com\.android\.settings')
            )
        }
    })
    $results = @(@($projection.toolResults) | Where-Object { $_.sessionKey -ceq $ExpectedSessionKey } | ForEach-Object {
        $rawName = [string]$_.name
        [PSCustomObject]@{
            LineNumber = [int]$_.lineNumber
            RawName = $rawName
            NormalizedName = Get-NormalizedMcpToolName -ToolName $rawName
            ToolCallId = [string]$_.toolCallId
            Success = $_.success -eq $true
            HasAndroidHierarchy = $_.hasAndroidHierarchy -eq $true
            MentionsAndroidSettings = $_.mentionsAndroidSettings -eq $true
        }
    })

    # Classify on the raw stored name. Normalizing first would erase the
    # security boundary between Android MCP calls and OpenClaw broker tools.
    $androidCalls = @($calls | Where-Object { $_.RawName.StartsWith('android__', [System.StringComparison]::Ordinal) })
    $internalCalls = @($calls | Where-Object { -not $_.RawName.StartsWith('android__', [System.StringComparison]::Ordinal) })
    $androidResults = @($results | Where-Object { $_.RawName.StartsWith('android__', [System.StringComparison]::Ordinal) })

    $pairs = @($androidCalls | ForEach-Object {
        $call = $_
        $matches = @($androidResults | Where-Object {
            $_.ToolCallId -ceq $call.ToolCallId -and
            $_.RawName -ceq $call.RawName -and
            $_.Success -and
            $_.LineNumber -gt $call.LineNumber
        } | Sort-Object LineNumber)
        if ($matches.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($call.ToolCallId)) {
            [PSCustomObject]@{
                Call = $call
                Result = $matches[0]
            }
        }
    })

    $devicePairs = @($pairs | Where-Object { $_.Call.NormalizedName -ceq 'select_device' } | Sort-Object { $_.Call.LineNumber })
    $createPairs = @($pairs | Where-Object {
        $_.Call.NormalizedName -ceq 'appium_session_management' -and
        $_.Call.IsCreate
    } | Sort-Object { $_.Call.LineNumber })
    $settingsPairs = @($pairs | Where-Object {
        $_.Call.NormalizedName -ceq 'appium_app_lifecycle' -and
        $_.Call.ActivatesSettings
    } | Sort-Object { $_.Call.LineNumber })
    $pageSourcePairs = @($pairs | Where-Object {
        $_.Call.NormalizedName -ceq 'appium_get_page_source' -and
        $_.Result.HasAndroidHierarchy -and
        $_.Result.MentionsAndroidSettings
    } | Sort-Object { $_.Call.LineNumber })
    $deletePairs = @($pairs | Where-Object {
        $_.Call.NormalizedName -ceq 'appium_session_management' -and
        $_.Call.IsDelete
    } | Sort-Object { $_.Call.LineNumber })

    $orderedWorkflow = $false
    $lastResultLine = 0
    if ($devicePairs.Count -gt 0 -and $createPairs.Count -gt 0 -and
        $settingsPairs.Count -gt 0 -and $pageSourcePairs.Count -gt 0 -and
        $deletePairs.Count -gt 0) {
        $device = $devicePairs[0]
        $create = @($createPairs | Where-Object { $_.Call.LineNumber -gt $device.Result.LineNumber } | Select-Object -First 1)
        if ($create.Count -gt 0) {
            $settings = @($settingsPairs | Where-Object { $_.Call.LineNumber -gt $create[0].Result.LineNumber } | Select-Object -First 1)
            if ($settings.Count -gt 0) {
                $pageSource = @($pageSourcePairs | Where-Object { $_.Call.LineNumber -gt $settings[0].Result.LineNumber } | Select-Object -First 1)
                if ($pageSource.Count -gt 0) {
                    $delete = @($deletePairs | Where-Object { $_.Call.LineNumber -gt $pageSource[0].Result.LineNumber } | Select-Object -First 1)
                    if ($delete.Count -gt 0) {
                        $orderedWorkflow = $true
                        $lastResultLine = $delete[0].Result.LineNumber
                    }
                }
            }
        }
    }

    $modelCompletions = @($projection.modelCompletions | Where-Object {
        $_.sessionKey -ceq $ExpectedSessionKey -and $_.done -eq $true
    } | Sort-Object lineNumber)
    $completedModelsAfterWorkflow = @($modelCompletions | Where-Object { [int]$_.lineNumber -gt $lastResultLine })
    $modelCompleted = $orderedWorkflow -and $completedModelsAfterWorkflow.Count -gt 0
    $modelLine = if ($modelCompleted) { [int]$completedModelsAfterWorkflow[0].lineNumber } else { 0 }
    $successfulSessionEnds = @($projection.sessionEnds | Where-Object {
        $_.sessionKey -ceq $ExpectedSessionKey -and
        $_.status -ceq 'success' -and
        [int]$_.lineNumber -gt $modelLine
    })
    $sessionEnded = $modelCompleted -and $successfulSessionEnds.Count -gt 0

    $allRawCalledTools = @($calls | ForEach-Object { $_.RawName } | Sort-Object -Unique)
    $androidRawCalledTools = @($androidCalls | ForEach-Object { $_.RawName } | Sort-Object -Unique)
    $internalRawCalledTools = @($internalCalls | ForEach-Object { $_.RawName } | Sort-Object -Unique)
    $calledTools = @($androidCalls | ForEach-Object { $_.NormalizedName } | Sort-Object -Unique)
    $exactToolSet = Test-ExactToolSet -ActualTools $calledTools -ExpectedTools $script:AndroidMcpTools
    $unexpectedAndroidTools = @($calledTools | Where-Object { $_ -cnotin $script:AndroidMcpTools })

    $eventCountProperty = $projection.PSObject.Properties['eventCount']
    $lineCountProperty = $projection.PSObject.Properties['nonBlankLineCount']
    $repairProperty = $projection.PSObject.Properties['compatibilityRepairs']

    return [PSCustomObject]@{
        EvidenceSource = $EvidenceSource
        EvidenceLocation = $EvidenceLocation
        ExpectedSessionKey = $ExpectedSessionKey
        EventCount = if ($eventCountProperty) { [int]$eventCountProperty.Value } elseif ($lineCountProperty) { [int]$lineCountProperty.Value } else { 0 }
        CompatibilityRepairs = if ($repairProperty) { [int]$repairProperty.Value } else { 0 }
        ToolCallCount = $calls.Count
        ToolResultCount = $results.Count
        AndroidToolCallCount = $androidCalls.Count
        InternalToolCallCount = $internalCalls.Count
        AllRawCalledTools = [string[]]@($allRawCalledTools)
        AndroidRawCalledTools = [string[]]@($androidRawCalledTools)
        InternalRawCalledTools = [string[]]@($internalRawCalledTools)
        UnexpectedAndroidTools = [string[]]@($unexpectedAndroidTools)
        CalledTools = [string[]]@($calledTools)
        ExactToolSet = $exactToolSet
        DeviceSelected = $devicePairs.Count -gt 0
        SessionCreated = $createPairs.Count -gt 0
        SettingsActivated = $settingsPairs.Count -gt 0
        PageSourceNonEmpty = $pageSourcePairs.Count -gt 0
        SettingsInPageSource = $pageSourcePairs.Count -gt 0
        SessionDeleted = $deletePairs.Count -gt 0
        OrderedWorkflow = $orderedWorkflow
        ModelCompleted = $modelCompleted
        SessionEnded = $sessionEnded
        IsAccepted = $exactToolSet -and $orderedWorkflow -and $modelCompleted -and $sessionEnded
    }
}

function Get-AndroidTrajectoryEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$BundleDirectory,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionKey,
        [string]$NodePath
    )

    $bundlePath = [System.IO.Path]::GetFullPath($BundleDirectory)
    $projection = Read-OpenClawTrajectoryProjection -BundleDirectory $bundlePath -NodePath $NodePath
    $evidence = Get-AndroidTrajectoryEvidenceFromProjection `
        -Projection $projection `
        -ExpectedSessionKey $ExpectedSessionKey `
        -EvidenceSource 'diagnostic-jsonl' `
        -EvidenceLocation $bundlePath
    $evidence | Add-Member -NotePropertyName BundleDirectory -NotePropertyValue $bundlePath
    $evidence | Add-Member -NotePropertyName NonBlankLineCount -NotePropertyValue ([int]$evidence.EventCount)
    return $evidence
}

function Get-AndroidSqliteTrajectoryEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionKey,
        [string]$NodePath
    )

    $resolvedDatabasePath = [System.IO.Path]::GetFullPath($DatabasePath)
    $projection = Read-OpenClawSqliteTrajectoryProjection `
        -DatabasePath $resolvedDatabasePath `
        -ExpectedSessionKey $ExpectedSessionKey `
        -NodePath $NodePath
    return Get-AndroidTrajectoryEvidenceFromProjection `
        -Projection $projection `
        -ExpectedSessionKey $ExpectedSessionKey `
        -EvidenceSource 'openclaw-2026.9.7-sqlite' `
        -EvidenceLocation $resolvedDatabasePath
}
