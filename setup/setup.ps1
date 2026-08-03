<#
.SYNOPSIS
    Automated Setup, Configuration, and Management script for AllGet Auto-Update.

.DESCRIPTION
    This script installs, configures, tests, or uninstalls the AllGet Auto-Update 
    scheduled task on Windows 10/11. It configures Task Scheduler to run silently via 
    wscript.exe to guarantee seamless console-less execution without terminal flashing.

.PARAMETER Install
    Registers or updates the 'AllGet Auto-Update' scheduled task in Windows Task Scheduler.

.PARAMETER Uninstall
    Removes the 'AllGet Auto-Update' scheduled task from Windows Task Scheduler.

.PARAMETER Test
    Executes a live test run of the AllGet Auto-Update process in the current terminal session.

.PARAMETER TestUI
    Launches the standalone WinUI 3 prompt preview dialog to test aesthetics and controls.

.EXAMPLE
    .\setup.ps1 -Install

.EXAMPLE
    .\setup.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Test,
    [switch]$TestUI,
    [switch]$Logs,
    [switch]$Help
)

# Enable ANSI colors if supported
$Host.UI.RawUI.ForegroundColor = "White"

function Show-Header {
    Clear-Host
    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host "         AllGet Auto-Update - Setup & Management                   " -ForegroundColor Cyan
    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Status {
    param([string]$Message, [string]$Type = "INFO")
    switch ($Type) {
        "SUCCESS" { Write-Host " [+] " -NoNewline -ForegroundColor Green; Write-Host $Message -ForegroundColor White }
        "WARN" { Write-Host " [!] " -NoNewline -ForegroundColor Yellow; Write-Host $Message -ForegroundColor Yellow }
        "ERROR" { Write-Host " [-] " -NoNewline -ForegroundColor Red; Write-Host $Message -ForegroundColor Red }
        "STEP" { Write-Host " [*] " -NoNewline -ForegroundColor Cyan; Write-Host $Message -ForegroundColor White }
        default { Write-Host " [i] " -NoNewline -ForegroundColor DarkGray; Write-Host $Message -ForegroundColor Gray }
    }
}

function Test-AdminPrivileges {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ScriptElevation {
    param([string]$Arguments)
    Write-Status "Requesting Administrator privileges (UAC)..." "WARN"
    $scriptPath = $MyInvocation.MyCommand.Definition
    $cmd = "& '$scriptPath' $Arguments; Write-Host '`nPress Enter to exit...' -ForegroundColor Gray; [void][System.Console]::ReadLine()"
    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -NoProfile -NoExit -Command `"$cmd`"" -Verb RunAs
    exit 0
}

function Test-Prerequisites {
    Write-Status "Checking system prerequisites..." "STEP"
    
    # 1. Check WinGet
    $wingetCmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $wingetCmd) {
        $wingetPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
        if (-not (Test-Path $wingetPath)) {
            Write-Status "WinGet executable was not found on this system. Please install App Installer from Microsoft Store." "ERROR"
            return $false
        }
    }
    Write-Status "WinGet executable detected successfully." "SUCCESS"

    # 2. Check Core Script files
    $rootDir = Split-Path $PSScriptRoot -Parent
    $requiredFiles = @(
        "allget-autoupdate.ps1",
        "setup\Run-Hidden.vbs",
        "src\Dialog.ps1"
    )

    foreach ($file in $requiredFiles) {
        $fullPath = Join-Path $rootDir $file
        if (-not (Test-Path $fullPath)) {
            Write-Status "Missing required component file: '$file'" "ERROR"
            return $false
        }
    }
    Write-Status "All required core script components are present." "SUCCESS"
    return $true
}

function Install-AutoUpdateTask {
    Show-Header
    Write-Status "Starting AllGet Auto-Update Scheduled Task installation..." "STEP"
    
    if (-not (Test-AdminPrivileges)) {
        Invoke-ScriptElevation "-Install"
        return
    }

    if (-not (Test-Prerequisites)) {
        Write-Status "Installation aborted due to missing prerequisites." "ERROR"
        return
    }

    $taskName = "AllGet Auto-Update"
    $vbsPath = Join-Path $PSScriptRoot "Run-Hidden.vbs"
    $xmlTemplatePath = Join-Path (Split-Path $PSScriptRoot -Parent) "config\AllGet Auto-Update.xml"

    Write-Status "Configuring Task Scheduler Settings..." "STEP"

    try {
        # Unregister existing task if present
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        if (Test-Path $xmlTemplatePath) {
            $xmlContent = Get-Content -Path $xmlTemplatePath -Raw
            # Update path to current src\Run-Hidden.vbs location
            $xmlContent = $xmlContent -replace '<Arguments>.*?</Arguments>', "<Arguments>`"$vbsPath`"</Arguments>"
            Register-ScheduledTask -TaskName $taskName -Xml $xmlContent -Force -ErrorAction Stop | Out-Null
        }
        else {
            # Fallback to cmdlet registration
            $action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbsPath`""
            $triggerInterval = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration ([TimeSpan]::MaxValue)
            $triggerInterval.RandomDelay = (New-TimeSpan -Hours 1)
            $triggerLogon = New-ScheduledTaskTrigger -AtLogOn
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries:$false -StopIfGoingOnBatteries -RunOnlyIfNetworkAvailable -StartWhenAvailable -Hidden -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)
            $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest

            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($triggerInterval, $triggerLogon) -Settings $settings -Principal $principal -Description "Silently checks and updates installed WinGet applications in the background without terminal windows." -ErrorAction Stop | Out-Null
        }

        Write-Status "Scheduled Task '$taskName' successfully created and enabled!" "SUCCESS"
        Write-Status "Task will run every 1 hour (with up to 1-hour random delay) and upon user logon." "INFO"
        Write-Status "Launcher: wscript.exe -> '$vbsPath'" "INFO"
        Write-Status "Task is visible in Task Scheduler (taskschd.msc) under 'Task Scheduler Library'." "INFO"
    }
    catch {
        Write-Status "Failed to register Scheduled Task: $_" "ERROR"
    }
}

function Uninstall-AutoUpdateTask {
    Show-Header
    Write-Status "Removing AllGet Auto-Update Scheduled Task..." "STEP"

    if (-not (Test-AdminPrivileges)) {
        Invoke-ScriptElevation "-Uninstall"
        return
    }

    $taskName = "AllGet Auto-Update"
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

    if ($existingTask) {
        try {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
            Write-Status "Scheduled Task '$taskName' removed successfully." "SUCCESS"
        }
        catch {
            Write-Status "Failed to remove Scheduled Task: $_" "ERROR"
        }
    }
    else {
        Write-Status "Scheduled Task '$taskName' is not registered on this system." "WARN"
    }
}

function Invoke-TestRun {
    Show-Header
    Write-Status "Running standalone execution of AllGet Auto-Update..." "STEP"
    $scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) "allget-autoupdate.ps1"
    & powershell.exe -ExecutionPolicy Bypass -NoProfile -File $scriptPath
    Write-Host ""
    Write-Host "Execution completed." -ForegroundColor Green
    Read-Host "Press Enter to exit..."
}

function Invoke-TestUI {
    Show-Header
    Write-Status "Launching WinUI 3 Prompt Dialog Preview..." "STEP"
    $testUiPath = Join-Path (Split-Path $PSScriptRoot -Parent) "tests\Test-WinUIDialog.ps1"
    & powershell.exe -ExecutionPolicy Bypass -NoProfile -File $testUiPath
}

function Show-Logs {
    Show-Header
    $logsDir = Join-Path (Split-Path $PSScriptRoot -Parent) "logs"
    $latestLog = Get-ChildItem -Path $logsDir -Filter "autoupdate*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -ne $latestLog) {
        $logPath = $latestLog.FullName
        Write-Status "Displaying last 30 log lines from '$($latestLog.Name)':" "INFO"
        Write-Host "--------------------------------------------------------------------------" -ForegroundColor DarkGray
        Get-Content -Path $logPath -Tail 30 | ForEach-Object {
            if ($_ -match '\[ERROR\]') { Write-Host $_ -ForegroundColor Red }
            elseif ($_ -match '\[WARN\]') { Write-Host $_ -ForegroundColor Yellow }
            elseif ($_ -match '\[SUCCESS\]') { Write-Host $_ -ForegroundColor Green }
            elseif ($_ -match '\[SKIP\]') { Write-Host $_ -ForegroundColor DarkYellow }
            else { Write-Host $_ -ForegroundColor Cyan }
        }
        Write-Host "--------------------------------------------------------------------------" -ForegroundColor DarkGray
    }
    else {
        Write-Status "No log files found in '$logsDir' yet." "WARN"
    }
}

# Parameter evaluation
if ($Help) {
    Get-Help $MyInvocation.MyCommand.Definition -Detailed
    exit 0
}

if ($Install) {
    Install-AutoUpdateTask
    exit 0
}

if ($Uninstall) {
    Uninstall-AutoUpdateTask
    exit 0
}

if ($Test) {
    Invoke-TestRun
    exit 0
}

if ($TestUI) {
    Invoke-TestUI
    exit 0
}

if ($Logs) {
    Show-Logs
    exit 0
}

# Interactive CLI Menu loop if run without arguments
while ($true) {
    Show-Header
    Write-Host " Please select an option:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   [1] Install / Register Scheduled Task (Seamless Silent Execution)" -ForegroundColor Green
    Write-Host "   [2] Run Live Auto-Update Test" -ForegroundColor Cyan
    Write-Host "   [3] Preview WinUI 3 Prompt Dialog" -ForegroundColor Cyan
    Write-Host "   [4] View Execution Logs" -ForegroundColor Magenta
    Write-Host "   [5] Uninstall Scheduled Task" -ForegroundColor Red
    Write-Host "   [6] Exit" -ForegroundColor Gray
    Write-Host ""
    
    $selection = Read-Host " Enter choice (1-6)"
    
    switch ($selection) {
        "1" {
            Install-AutoUpdateTask
            Read-Host "Press Enter to return to menu..."
        }
        "2" {
            Invoke-TestRun
            Read-Host "Press Enter to return to menu..."
        }
        "3" {
            Invoke-TestUI
            Read-Host "Press Enter to return to menu..."
        }
        "4" {
            Show-Logs
            Read-Host "Press Enter to return to menu..."
        }
        "5" {
            Uninstall-AutoUpdateTask
            Read-Host "Press Enter to return to menu..."
        }
        "6" {
            Write-Host "Exiting setup." -ForegroundColor Gray
            break
        }
        default {
            Write-Host "Invalid option. Please try again." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }

    if ($selection -eq "6") {
        break
    }
}
