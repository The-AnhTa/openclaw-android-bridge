Set-StrictMode -Version Latest

function Test-LoopbackAddress {
    param([Parameter(Mandatory = $true)][string]$Address)

    try {
        $ipAddress = [System.Net.IPAddress]::Parse($Address)
        return [System.Net.IPAddress]::IsLoopback($ipAddress)
    }
    catch {
        return $false
    }
}

function Get-McpListenerAssessment {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port,
        [ValidateRange(0, [int]::MaxValue)][int]$OwningProcessId = 0
    )

    try {
        $allListeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop)
    }
    catch [Microsoft.PowerShell.Cmdletization.Cim.CimJobException] {
        $allListeners = @()
    }
    catch {
        throw "Could not inspect TCP listeners on port ${Port}: $($_.Exception.Message)"
    }

    $listeners = $allListeners
    if ($OwningProcessId -gt 0) {
        $listeners = @($allListeners | Where-Object { $_.OwningProcess -eq $OwningProcessId })
    }

    $addresses = @($listeners | ForEach-Object { [string]$_.LocalAddress } | Sort-Object -Unique)
    $unsafeAddresses = @($addresses | Where-Object { -not (Test-LoopbackAddress -Address $_) })

    return [PSCustomObject]@{
        Exists               = $listeners.Count -gt 0
        IsLoopbackOnly       = $listeners.Count -gt 0 -and $unsafeAddresses.Count -eq 0
        Addresses            = $addresses
        UnsafeAddresses      = $unsafeAddresses
        Listeners            = $listeners
        OtherProcessListeners = if ($OwningProcessId -gt 0) {
            @($allListeners | Where-Object { $_.OwningProcess -ne $OwningProcessId })
        }
        else {
            @()
        }
    }
}
