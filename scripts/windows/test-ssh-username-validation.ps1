[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    . (Join-Path $PSScriptRoot 'lib\Common.ps1')
    . (Join-Path $PSScriptRoot 'lib\SshTunnel.ps1')

    $validUserNames = @(
        'anh001',
        'nexus\anh001',
        'user@example.com',
        'user.name',
        'user-name'
    )
    $invalidUserNames = @(
        'two words',
        'bad;user',
        'bad|user',
        'bad&user',
        'bad"user',
        "bad'user",
        "bad`nuser",
        "bad$([char]1)user"
    )

    foreach ($userName in $validUserNames) {
        if (-not (Test-SafeSshUserName -UserName $userName)) {
            throw "Expected valid SSH username was rejected: $userName"
        }
        Write-Pass "Accepted valid SSH username: $userName"
    }

    foreach ($userName in $invalidUserNames) {
        if (Test-SafeSshUserName -UserName $userName) {
            throw 'An unsafe SSH username was accepted.'
        }
        Write-Pass 'Rejected unsafe SSH username.'
    }

    Write-Pass 'SSH username validation tests passed.'
    exit 0
}
catch {
    Write-Host "[FAIL] SSH username validation test failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
