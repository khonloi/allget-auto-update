# ==============================================================================
# Configuration Loader
# This script is responsible for setting up the logging directory and parsing
# the user's config.json file. It establishes global configuration variables
# that are used across all other scripts in the update pipeline.
# ==============================================================================

# Configure Log File Directory
$script:logsDir = Join-Path $PSScriptRoot "..\logs"
if (-not (Test-Path $script:logsDir)) { New-Item -ItemType Directory -Path $script:logsDir -Force | Out-Null }
$script:logPath = Join-Path $script:logsDir "autoupdate_$((Get-Date).ToString('yyyy-MM-dd')).log"

# Set Default Configuration Values
$script:ignoredPatterns = @()
$script:skipOnMeteredConnection = $true
$script:minBatteryLevel = 50
$script:maxCpuLoad = 80
$script:minStorageGb = 5
$script:delayUpdatesEnabled = $true
$script:delayUpdatesDays = 1

# Load or Create Configuration File (config.json)
$configPath = Join-Path $PSScriptRoot "..\config.json"
if (-not (Test-Path $configPath)) {
    # File doesn't exist, create a default config.json
    $defaultJson = @"
{
  "systemChecks": {
    "skipOnMeteredConnection": true,
    "minBatteryLevel": 50,
    "maxCpuLoad": 80,
    "minStorageGb": 5
  },
  "delayUpdates": {
    "enabled": true,
    "days": 1
  },
  "ignoredPatterns": [
    "^Microsoft\\.Edge",
    "^Microsoft\\.OneDrive",
    "^Microsoft\\.Teams",
    "^Microsoft\\.WindowsStore",
    "^Microsoft\\.Defender"
  ]
}
"@
    $defaultJson | Set-Content -Path $configPath -Encoding UTF8
    
    # Initialize runtime defaults matching the JSON structure
    $script:ignoredPatterns = @(
        '^Microsoft\.Edge',
        '^Microsoft\.OneDrive',
        '^Microsoft\.Teams',
        '^Microsoft\.WindowsStore',
        '^Microsoft\.Defender'
    )
}
else {
    try {
        # Parse the existing config.json
        $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
        if ($null -ne $config) {
            # Map ignored patterns
            if ($null -ne $config.ignoredPatterns) {
                $script:ignoredPatterns = $config.ignoredPatterns
            }
            # Map system checks constraints
            if ($null -ne $config.systemChecks) {
                if ($null -ne $config.systemChecks.skipOnMeteredConnection) {
                    $script:skipOnMeteredConnection = [bool]$config.systemChecks.skipOnMeteredConnection
                }
                if ($null -ne $config.systemChecks.minBatteryLevel) {
                    $script:minBatteryLevel = [int]$config.systemChecks.minBatteryLevel
                }
                if ($null -ne $config.systemChecks.maxCpuLoad) {
                    $script:maxCpuLoad = [int]$config.systemChecks.maxCpuLoad
                }
                if ($null -ne $config.systemChecks.minStorageGb) {
                    $script:minStorageGb = [int]$config.systemChecks.minStorageGb
                }
            }
            # Map update delay settings
            if ($null -ne $config.delayUpdates) {
                if ($null -ne $config.delayUpdates.enabled) {
                    $script:delayUpdatesEnabled = [bool]$config.delayUpdates.enabled
                }
                if ($null -ne $config.delayUpdates.days) {
                    $script:delayUpdatesDays = [int]$config.delayUpdates.days
                }
            }
        }
    }
    catch {
        # Fallback to defaults if the configuration file is malformed
        $timestamp = Get-Date -Format "HH:mm:ss"
        $logLine = "[$timestamp] [ERROR] Failed to parse config.json. Using defaults."
        try { Add-Content -Path $script:logPath -Value $logLine -ErrorAction SilentlyContinue } catch {}
        Write-Host $logLine -ForegroundColor Red
    }
}

# Compile ignored patterns into a single Regex string for O(1) performance matching
if ($script:ignoredPatterns.Count -gt 0) {
    $script:combinedIgnoredPattern = $script:ignoredPatterns -join '|'
}
else {
    $script:combinedIgnoredPattern = '(?!)' # Matches nothing
}
