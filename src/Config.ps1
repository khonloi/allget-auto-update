# ==============================================================================
# Configuration
# ==============================================================================

# Configure Log File
$script:logsDir = Join-Path $PSScriptRoot "..\logs"
if (-not (Test-Path $script:logsDir)) { New-Item -ItemType Directory -Path $script:logsDir -Force | Out-Null }
$script:logPath = Join-Path $script:logsDir "autoupdate.log"

# Default configuration values
$script:ignoredPatterns = @()
$script:skipOnMeteredConnection = $true
$script:minBatteryLevel = 50
$script:maxCpuLoad = 80
$script:delayUpdatesEnabled = $true
$script:delayUpdatesDays = 1

# Load or Create Configuration File
$configPath = Join-Path $PSScriptRoot "..\config.json"
if (-not (Test-Path $configPath)) {
    # Create default config.json
    $defaultJson = @"
{
  "systemChecks": {
    "skipOnMeteredConnection": true,
    "minBatteryLevel": 50,
    "maxCpuLoad": 80
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
        $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
        if ($null -ne $config) {
            if ($null -ne $config.ignoredPatterns) {
                $script:ignoredPatterns = $config.ignoredPatterns
            }
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
            }
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
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logLine = "[$timestamp] [ERROR] Failed to parse config.json. Using defaults."
        try { Add-Content -Path $script:logPath -Value $logLine -ErrorAction SilentlyContinue } catch {}
        Write-Host $logLine -ForegroundColor Red
    }
}
