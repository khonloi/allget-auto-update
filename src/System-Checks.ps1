<#
.SYNOPSIS
    Evaluates system conditions before allowing package updates.
.DESCRIPTION
    Checks multiple prerequisites including UAC elevation, network connectivity,
    metered connections, battery life, CPU load, free storage space, and the presence of WinGet.
    If any check fails, it logs the reason and returns false to abort the update.
.OUTPUTS
    A boolean indicating whether it is safe to proceed with updates.
#>
function Invoke-PreRequisiteChecks {
    # Ensure script runs with Administrator privileges
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Not running as Administrator. Requesting UAC elevation..." "WARN"
        $scriptPath = $MyInvocation.PSCommandPath
        if (-not $scriptPath) {
            $scriptPath = $MyInvocation.MyCommand.Definition
        }
        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$scriptPath`"" -Verb RunAs
        return $false
    }

    # Concurrency Lock: Prevent overlapping runs
    try {
        $createdNew = $false
        $script:appMutex = New-Object System.Threading.Mutex($false, "Global\AllGetAutoUpdate_Instance_Lock", [ref]$createdNew)
        if (-not $script:appMutex.WaitOne(0, $false)) {
            Write-Log "Another instance of AllGet Auto-Update is already running. Skipping this cycle." "SKIP"
            return $false
        }
    }
    catch {
        # Silently continue if mutex cannot be created
    }

    # 1. Network Check
    if (-not [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()) {
        Write-Log "No network connection detected. Postponing auto-update." "SKIP"
        return $false
    }

    # 1b. Metered Connection Check
    if ($script:skipOnMeteredConnection) {
        try {
            $netCost = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]::GetInternetConnectionProfile().GetConnectionCost().NetworkCostType
            if ($netCost -ne 'Unrestricted' -and $netCost -ne 'Unknown') {
                Write-Log "Running on a metered connection. Postponing auto-update." "SKIP"
                return $false
            }
        }
        catch {
            # Silently ignore if WinRT namespace fails on older systems
        }
    }

    # 2. Power & Battery Check
    if ($script:minBatteryLevel -gt 0) {
        $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
        if ($battery) {
            $isDischarging = ($battery.BatteryStatus -eq 1)
            $chargeRemaining = $battery.EstimatedChargeRemaining
            if ($isDischarging -and $chargeRemaining -lt $script:minBatteryLevel) {
                Write-Log "Running on battery ($chargeRemaining% < $script:minBatteryLevel%). Postponing auto-update to conserve power." "SKIP"
                return $false
            }
        }
    }

    # 3. Performance Check (CPU Load)
    if ($script:maxCpuLoad -gt 0 -and $script:maxCpuLoad -lt 100) {
        $cpuLoad = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Measure-Object -Property LoadPercentage -Average | Select-Object -ExpandProperty Average
        if ($null -ne $cpuLoad -and $cpuLoad -gt $script:maxCpuLoad) {
            Write-Log "System under heavy load (CPU: $cpuLoad% > $script:maxCpuLoad%). Postponing auto-update." "SKIP"
            return $false
        }
    }

    # 4. Storage Check
    if ($script:minStorageGb -gt 0) {
        $systemDrive = $env:SystemDrive
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$systemDrive'" -ErrorAction SilentlyContinue
        if ($disk) {
            $freeSpaceGb = [math]::Round($disk.FreeSpace / 1GB, 2)
            if ($freeSpaceGb -lt $script:minStorageGb) {
                Write-Log "Insufficient storage on $systemDrive (${freeSpaceGb}GB < ${script:minStorageGb}GB). Postponing auto-update." "SKIP"
                return $false
            }
        }
    }

    # Locate winget executable
    $wingetCmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($wingetCmd) {
        $script:winget = $wingetCmd.Source
    }
    else {
        $script:winget = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
    }

    if (-not (Test-Path $script:winget)) {
        Write-Log "WinGet executable not found at '$($script:winget)'." "ERROR"
        return $false
    }
    
    return $true
}
