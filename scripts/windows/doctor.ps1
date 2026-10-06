[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    . (Join-Path $PSScriptRoot 'lib\Common.ps1')

    $allChecksPassed = $true

    if (-not (Test-HostCommand -Label 'Git' -CommandNames @('git.exe', 'git') -VersionArguments @('--version'))) {
        $allChecksPassed = $false
    }

    $nodeVersionValidator = {
        param([string]$VersionText)
        if ($VersionText -notmatch '^v?(\d+)\.') {
            return $false
        }
        return ([int]$Matches[1] -ge 22)
    }
    if (-not (Test-HostCommand -Label 'Node.js' -CommandNames @('node.exe', 'node') -VersionArguments @('--version') -VersionValidator $nodeVersionValidator -VersionRequirement 'Node.js 22 or newer')) {
        $allChecksPassed = $false
    }

    if (-not (Test-HostCommand -Label 'npm' -CommandNames @('npm.cmd', 'npm.exe', 'npm') -VersionArguments @('--version'))) {
        $allChecksPassed = $false
    }

    if (-not (Test-HostCommand -Label 'OpenSSH client' -CommandNames @('ssh.exe', 'ssh') -VersionArguments @('-V'))) {
        $allChecksPassed = $false
    }

    $androidEnvironment = Initialize-AndroidEnvironment
    if (-not $androidEnvironment.IsValid) {
        $allChecksPassed = $false
    }

    if ($androidEnvironment.AdbPath) {
        if (-not (Test-ConnectedAndroidDevice -AdbPath $androidEnvironment.AdbPath)) {
            $allChecksPassed = $false
        }
    }

    if ($allChecksPassed) {
        Write-Pass 'All Milestone 1 prerequisite checks passed.'
        exit 0
    }

    Write-Fail 'One or more Milestone 1 prerequisite checks failed.'
    exit 1
}
catch {
    Write-Host "[FAIL] Validation could not complete: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

