# ==============================================================================
# AllGet Auto-Update
# ==============================================================================
# Features:
# 1. Smart Active-App Detection: Skips open apps to prevent work disruption.
# 2. Battery Conservation: Skips updates if running on low battery power.
# 3. Network Verification: Ensures internet connectivity before checking.
# 4. Performance Check: Skips updates if system is under heavy load.
# 5. Per-App Background Upgrades: Updates idle apps individually and silently.
# 6. Comprehensive Logging: Records all activity, status, and errors to autoupdate.log.
# 7. Native Notification: Shows a Windows banner when apps are updated.
# 8. Supports Chocolatey, Scoop, npm, yarn, and bun updates.
# ==============================================================================

# 1. Load Configurations
. (Join-Path $PSScriptRoot "src\Config.ps1")

# 2. Load Helpers
. (Join-Path $PSScriptRoot "src\Helpers.ps1")

$uiModule = Join-Path $PSScriptRoot "src\Dialog.ps1"
if (Test-Path $uiModule) {
    . $uiModule
}
else {
    Write-Log "UI module not found at '$uiModule'." "WARN"
}

# 3. Load Components
. (Join-Path $PSScriptRoot "src\System-Checks.ps1")
. (Join-Path $PSScriptRoot "src\Update-Packages.ps1")

try {
    Write-Log "Starting Auto-Update checks..." "INFO"

    # 4. Perform Pre-requisite Checks
    if (-not (Invoke-PreRequisiteChecks)) {
        exit 0
    }

    # 5. Execute Updates
    $stats = Invoke-PackageUpdates

    # 6. Summary Log
    Write-Log "Auto-Update run completed. Updated: $($stats.Updated), Skipped: $($stats.Skipped), Failed: $($stats.Failed)." "INFO"

}
catch {
    Write-Log "Fatal error during script execution: $_" "ERROR"
    exit 1
}