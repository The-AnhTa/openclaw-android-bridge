[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^(?!-)[A-Za-z0-9._:-]+$')][string]$VmHost,
    [Parameter(Mandatory = $true)][ValidatePattern('^(?!-)[A-Za-z0-9._-]+$')][string]$VmUser,
    [ValidateRange(1, 65535)][int]$VmSshPort = 22,
    [ValidateRange(1, 65535)][int]$LocalMcpPort = 8765,
    [ValidateRange(1, 65535)][int]$VmMcpPort = 8765,
    [string]$IdentityFile
)

$ErrorActionPreference = 'Stop'

try {
    . (Join-Path $PSScriptRoot 'lib\Common.ps1')
    . (Join-Path $PSScriptRoot 'lib\McpListener.ps1')

    $sshPath = Resolve-ExternalCommand -Names @('ssh.exe', 'ssh')
    if (-not $sshPath) {
        Write-Fail 'The OpenSSH client is unavailable on PATH.'
        exit 1
    }

    $localListener = Get-McpListenerAssessment -Port $LocalMcpPort
    if (-not $localListener.Exists) {
        Write-Fail "No local MCP listener exists on port $LocalMcpPort. Start Appium MCP HTTP first."
        exit 1
    }
    if (-not $localListener.IsLoopbackOnly) {
        Write-Fail "The local MCP listener is not loopback-only: $($localListener.UnsafeAddresses -join ', ')."
        exit 1
    }
    Write-Pass "Local MCP listener on port $LocalMcpPort is loopback-only."

    $sshArguments = @(
        '-N',
        '-T',
        '-o', 'ExitOnForwardFailure=yes',
        '-o', 'ServerAliveInterval=30',
        '-o', 'ServerAliveCountMax=3',
        '-p', [string]$VmSshPort,
        '-R', "127.0.0.1:${VmMcpPort}:127.0.0.1:${LocalMcpPort}"
    )

    if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
        $resolvedIdentityFile = Resolve-Path -LiteralPath $IdentityFile -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $resolvedIdentityFile.Path -PathType Leaf)) {
            Write-Fail "SSH identity file '$IdentityFile' is not a file."
            exit 1
        }
        $sshArguments += @('-i', $resolvedIdentityFile.Path)
    }

    $sshArguments += "${VmUser}@${VmHost}"

    Write-Pass 'Reverse tunnel command is constrained to loopback on both endpoints.'
    Write-Host "VM MCP URL: http://127.0.0.1:${VmMcpPort}/sse"
    Write-Host "Command: ssh -N -T -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -p $VmSshPort -R 127.0.0.1:${VmMcpPort}:127.0.0.1:${LocalMcpPort} <VM_USER>@<VM_HOST>"
    Write-Host 'Authenticate if prompted. The foreground SSH process is the tunnel; press Ctrl+C to stop it.'

    & $sshPath @sshArguments
    $sshExitCode = $LASTEXITCODE
    if ($sshExitCode -ne 0) {
        Write-Fail "SSH tunnel exited with code $sshExitCode. Check authentication, AllowTcpForwarding, and whether the remote port is already in use."
        exit $sshExitCode
    }

    Write-Pass 'SSH tunnel closed cleanly.'
    exit 0
}
catch {
    Write-Host "[FAIL] SSH reverse tunnel could not start: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
