[CmdletBinding()]
param(
    [ValidateRange(1, 65535)][int]$Port = 8765,
    [ValidateRange(10, 600)][int]$StartupTimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
$serverProcess = $null

try {
    . (Join-Path $PSScriptRoot 'lib\Common.ps1')
    . (Join-Path $PSScriptRoot 'lib\AppiumMcp.ps1')
    . (Join-Path $PSScriptRoot 'lib\McpListener.ps1')

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

    $installation = Get-LocalAppiumMcpInstallation -RepositoryRoot $repositoryRoot
    if (-not $installation) {
        exit 1
    }
    Write-Pass "appium-mcp $($installation.Version) available"

    $existingListener = Get-McpListenerAssessment -Port $Port
    if ($existingListener.Exists) {
        $owners = @($existingListener.Listeners | ForEach-Object { $_.OwningProcess } | Sort-Object -Unique)
        Write-Fail "Port $Port is already in use by process ID(s): $($owners -join ', ')."
        exit 1
    }

    $nodePath = Resolve-ExternalCommand -Names @('node.exe', 'node')
    if (-not $nodePath) {
        Write-Fail 'Node.js is unavailable after prerequisite validation.'
        exit 1
    }

    Set-AppiumMcpHttpProcessEnvironment
    $endpoint = '/sse'
    Write-Pass "Starting pinned appium-mcp at 127.0.0.1:$Port$endpoint with Streamable HTTP semantics."

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $nodePath
    $startInfo.Arguments = "`"$($installation.EntryPoint)`" --httpStream --port=$Port"
    $startInfo.WorkingDirectory = $repositoryRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $serverProcess = New-Object System.Diagnostics.Process
    $serverProcess.StartInfo = $startInfo
    if (-not $serverProcess.Start()) {
        Write-Fail 'The appium-mcp process could not be started.'
        exit 1
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    $assessment = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($serverProcess.HasExited) {
            Write-Fail "appium-mcp exited before opening its HTTP listener (exit code $($serverProcess.ExitCode))."
            exit 1
        }

        $assessment = Get-McpListenerAssessment -Port $Port -OwningProcessId $serverProcess.Id
        if ($assessment.Exists) {
            break
        }
        Start-Sleep -Milliseconds 250
    }

    if (-not $assessment -or -not $assessment.Exists) {
        Write-Fail "appium-mcp did not open port $Port within $StartupTimeoutSeconds seconds."
        exit 1
    }

    if (-not $assessment.IsLoopbackOnly) {
        Write-Fail "Unsafe listener detected on $($assessment.UnsafeAddresses -join ', '). Stopping appium-mcp."
        exit 1
    }

    foreach ($address in $assessment.Addresses) {
        Write-Pass "Verified loopback-only listener: ${address}:$Port"
    }
    Write-Host "MCP URL: http://127.0.0.1:$Port$endpoint"
    Write-Pass 'Appium MCP is running in the foreground. Press Ctrl+C to stop it.'

    $serverProcess.WaitForExit()
    if ($serverProcess.ExitCode -ne 0) {
        Write-Fail "appium-mcp exited with code $($serverProcess.ExitCode)."
        exit $serverProcess.ExitCode
    }
    exit 0
}
catch {
    Write-Host "[FAIL] Appium MCP HTTP startup failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    if ($serverProcess -and -not $serverProcess.HasExited) {
        try {
            $serverProcess.Kill()
            $serverProcess.WaitForExit(5000) | Out-Null
        }
        catch {
            Write-Host "[WARN] Could not stop appium-mcp process $($serverProcess.Id): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}
