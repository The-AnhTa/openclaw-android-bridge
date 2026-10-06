Set-StrictMode -Version Latest

function Write-Pass {
    param([Parameter(Mandatory = $true)][string]$Message)
    $stderrPreference = Get-Variable -Name DiagnosticsToStandardError -Scope Script -ErrorAction SilentlyContinue
    if ($stderrPreference -and $stderrPreference.Value) {
        [Console]::Error.WriteLine("[PASS] $Message")
        return
    }
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([Parameter(Mandatory = $true)][string]$Message)
    $stderrPreference = Get-Variable -Name DiagnosticsToStandardError -Scope Script -ErrorAction SilentlyContinue
    if ($stderrPreference -and $stderrPreference.Value) {
        [Console]::Error.WriteLine("[WARN] $Message")
        return
    }
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    $stderrPreference = Get-Variable -Name DiagnosticsToStandardError -Scope Script -ErrorAction SilentlyContinue
    if ($stderrPreference -and $stderrPreference.Value) {
        [Console]::Error.WriteLine("[FAIL] $Message")
        return
    }
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Resolve-ExternalCommand {
    param([Parameter(Mandatory = $true)][string[]]$Names)

    foreach ($name in $Names) {
        $commands = @(Get-Command -Name $name -CommandType Application, ExternalScript -ErrorAction SilentlyContinue)
        foreach ($command in $commands) {
            if ($command.Path) {
                return $command.Path
            }
        }
    }

    return $null
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $FilePath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    [PSCustomObject]@{
        ExitCode = $exitCode
        Lines    = @($output | ForEach-Object { $_.ToString() })
    }
}

function Get-FirstOutputLine {
    param([Parameter(Mandatory = $true)]$Result)

    $line = $Result.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    if ($null -eq $line) {
        return ''
    }

    return $line.Trim()
}

function Test-HostCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string[]]$CommandNames,
        [Parameter(Mandatory = $true)][string[]]$VersionArguments,
        [scriptblock]$VersionValidator,
        [string]$VersionRequirement
    )

    $commandPath = Resolve-ExternalCommand -Names $CommandNames
    if (-not $commandPath) {
        Write-Fail "$Label is not available on PATH."
        return $false
    }

    $result = Invoke-NativeCommand -FilePath $commandPath -Arguments $VersionArguments
    if ($result.ExitCode -ne 0) {
        Write-Fail "$Label was found at '$commandPath' but did not run successfully."
        return $false
    }

    $versionText = Get-FirstOutputLine -Result $result
    if ($VersionValidator -and -not (& $VersionValidator $versionText)) {
        Write-Fail "$Label $versionText does not meet the requirement: $VersionRequirement."
        return $false
    }

    Write-Pass "$Label available: $versionText"
    return $true
}

function Test-WindowsHostPrerequisites {
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

    return $allChecksPassed
}

function Get-AndroidStudioInstallPathsFromRegistry {
    $paths = @()
    $directKeys = @(
        'HKLM:\SOFTWARE\Android Studio',
        'HKLM:\SOFTWARE\WOW6432Node\Android Studio',
        'HKCU:\SOFTWARE\Android Studio'
    )

    foreach ($key in $directKeys) {
        $item = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($item) {
            foreach ($propertyName in @('InstallPath', 'Path')) {
                if ($item.PSObject.Properties.Name -contains $propertyName) {
                    $paths += [string]$item.$propertyName
                }
            }
        }
    }

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    foreach ($root in $uninstallRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $item = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if (-not $item) {
                continue
            }

            $displayName = $item.PSObject.Properties['DisplayName']
            $installLocation = $item.PSObject.Properties['InstallLocation']
            if ($displayName -and $installLocation -and
                $displayName.Value -like 'Android Studio*' -and
                -not [string]::IsNullOrWhiteSpace($installLocation.Value)) {
                $paths += [string]$installLocation.Value
            }
        }
    }

    return @($paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Find-AndroidStudioJbr {
    $candidates = @()

    if ($env:ProgramFiles) {
        $candidates += Join-Path $env:ProgramFiles 'Android\Android Studio\jbr'
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates += Join-Path ${env:ProgramFiles(x86)} 'Android\Android Studio\jbr'
    }
    if ($env:LOCALAPPDATA) {
        $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Android Studio\jbr'
    }

    foreach ($installPath in @(Get-AndroidStudioInstallPathsFromRegistry)) {
        $candidates += Join-Path $installPath 'jbr'
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        $javaPath = Join-Path $candidate 'bin\java.exe'
        if (Test-Path -LiteralPath $javaPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Find-AndroidSdk {
    $candidates = @()

    if ($env:ANDROID_HOME) {
        $candidates += $env:ANDROID_HOME
    }
    if ($env:ANDROID_SDK_ROOT) {
        $candidates += $env:ANDROID_SDK_ROOT
    }
    if ($env:LOCALAPPDATA) {
        $candidates += Join-Path $env:LOCALAPPDATA 'Android\Sdk'
    }

    $adbOnPath = Resolve-ExternalCommand -Names @('adb.exe', 'adb')
    if ($adbOnPath) {
        $platformToolsPath = Split-Path -Parent $adbOnPath
        $candidates += Split-Path -Parent $platformToolsPath
    }

    foreach ($candidate in @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        $adbPath = Join-Path $candidate 'platform-tools\adb.exe'
        if (Test-Path -LiteralPath $adbPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Add-ProcessPathEntry {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalizedCandidate = $Path.TrimEnd('\')
    $existingEntries = @($env:Path -split ';')
    foreach ($entry in $existingEntries) {
        if ($entry.Trim().TrimEnd('\') -ieq $normalizedCandidate) {
            return
        }
    }

    if ([string]::IsNullOrWhiteSpace($env:Path)) {
        $env:Path = $Path
    }
    else {
        $env:Path = "$Path;$env:Path"
    }
}

function Initialize-AndroidEnvironment {
    $isValid = $true
    $jbrPath = Find-AndroidStudioJbr
    $sdkPath = Find-AndroidSdk
    $adbPath = $null

    if (-not $jbrPath) {
        Write-Fail 'Android Studio bundled JBR was not found. Install Android Studio in a standard location.'
        $isValid = $false
    }
    else {
        if ($env:JAVA_HOME -ine $jbrPath) {
            $env:JAVA_HOME = $jbrPath
        }
        Add-ProcessPathEntry -Path (Join-Path $jbrPath 'bin')
        Write-Pass "Android Studio bundled JBR found: $jbrPath"

        $javaPath = Join-Path $jbrPath 'bin\java.exe'
        $javaResult = Invoke-NativeCommand -FilePath $javaPath -Arguments @('-version')
        if ($javaResult.ExitCode -ne 0) {
            Write-Fail "Java at '$javaPath' did not run successfully."
            $isValid = $false
        }
        else {
            Write-Pass "Java works: $(Get-FirstOutputLine -Result $javaResult)"
        }
    }

    if (-not $sdkPath) {
        Write-Fail 'Android SDK with platform-tools\adb.exe was not found. Install the SDK Platform-Tools through Android Studio.'
        $isValid = $false
    }
    else {
        if ($env:ANDROID_HOME -ine $sdkPath) {
            $env:ANDROID_HOME = $sdkPath
        }
        $adbPath = Join-Path $sdkPath 'platform-tools\adb.exe'
        Add-ProcessPathEntry -Path (Split-Path -Parent $adbPath)
        Write-Pass "Android SDK found: $sdkPath"

        $adbResult = Invoke-NativeCommand -FilePath $adbPath -Arguments @('version')
        if ($adbResult.ExitCode -ne 0) {
            Write-Fail "ADB at '$adbPath' did not run successfully."
            $isValid = $false
        }
        else {
            Write-Pass "ADB works: $(Get-FirstOutputLine -Result $adbResult)"
        }
    }

    return [PSCustomObject]@{
        IsValid = $isValid
        JbrPath = $jbrPath
        SdkPath = $sdkPath
        AdbPath = $adbPath
    }
}

function Get-AndroidProperty {
    param(
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$Serial,
        [Parameter(Mandatory = $true)][string]$PropertyName
    )

    $result = Invoke-NativeCommand -FilePath $AdbPath -Arguments @('-s', $Serial, 'shell', 'getprop', $PropertyName)
    if ($result.ExitCode -ne 0) {
        return $null
    }

    return (($result.Lines -join "`n").Trim())
}

function Get-AuthorizedAndroidDevice {
    param([Parameter(Mandatory = $true)][string]$AdbPath)

    $result = Invoke-NativeCommand -FilePath $AdbPath -Arguments @('devices', '-l')
    if ($result.ExitCode -ne 0) {
        Write-Fail 'The command "adb devices -l" failed.'
        return $null
    }

    $devices = @()
    foreach ($line in $result.Lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or
            $trimmed -eq 'List of devices attached' -or
            $trimmed.StartsWith('* daemon')) {
            continue
        }

        if ($trimmed -match '^(\S+)\s+(\S+)(?:\s+.*)?$') {
            $devices += [PSCustomObject]@{
                Serial = $Matches[1]
                State  = $Matches[2]
            }
        }
    }

    if ($devices.Count -eq 0) {
        Write-Fail 'No Android device detected. Connect and unlock one USB-debugging-enabled phone.'
        return $null
    }

    if ($devices.Count -gt 1) {
        Write-Fail "Multiple Android devices detected ($($devices.Count)). Connect exactly one device."
        foreach ($device in $devices) {
            Write-Warn "Device '$($device.Serial)' is in state '$($device.State)'."
        }
        return $null
    }

    $device = $devices[0]
    switch ($device.State) {
        'unauthorized' {
            Write-Fail "Android device '$($device.Serial)' is unauthorized. Unlock it and accept the USB-debugging prompt."
            return $null
        }
        'offline' {
            Write-Fail "Android device '$($device.Serial)' is offline. Reconnect it and restart USB debugging if needed."
            return $null
        }
        'device' {
            # Continue with property checks below.
        }
        default {
            Write-Fail "Android device '$($device.Serial)' is in unsupported state '$($device.State)'."
            return $null
        }
    }

    Write-Pass 'Exactly one authorized Android device is connected.'
    Write-Pass "Device serial: $($device.Serial)"

    $properties = @(
        @{ Key = 'Manufacturer'; Label = 'Manufacturer'; Name = 'ro.product.manufacturer' },
        @{ Key = 'Model'; Label = 'Model'; Name = 'ro.product.model' },
        @{ Key = 'AndroidVersion'; Label = 'Android version'; Name = 'ro.build.version.release' },
        @{ Key = 'ApiLevel'; Label = 'Android SDK/API level'; Name = 'ro.build.version.sdk' }
    )

    $allPropertiesAvailable = $true
    $propertyValues = @{}
    foreach ($property in $properties) {
        $value = Get-AndroidProperty -AdbPath $AdbPath -Serial $device.Serial -PropertyName $property.Name
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Fail "$($property.Label) could not be read from the device."
            $allPropertiesAvailable = $false
        }
        else {
            $propertyValues[$property.Key] = $value
            Write-Pass "$($property.Label): $value"
        }
    }

    if (-not $allPropertiesAvailable) {
        return $null
    }

    return [PSCustomObject]@{
        Serial         = $device.Serial
        State          = $device.State
        Manufacturer   = $propertyValues.Manufacturer
        Model          = $propertyValues.Model
        AndroidVersion = $propertyValues.AndroidVersion
        ApiLevel       = $propertyValues.ApiLevel
    }
}

function Test-ConnectedAndroidDevice {
    param([Parameter(Mandatory = $true)][string]$AdbPath)

    $device = Get-AuthorizedAndroidDevice -AdbPath $AdbPath
    return ($null -ne $device)
}
