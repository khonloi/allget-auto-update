# ==============================================================================
# Test Script: Native WinUI 3 Styled Auto-Update Dialog Preview
# ==============================================================================
# Run this script to test and preview the shared modern adaptive WinUI prompt,
# native footer bar, system accent color, light/dark theme, and countdown timer.

# Dynamically load the shared UI component from the src directory
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
if (-not $scriptDir) { $scriptDir = "." }

$rootDir = Split-Path -Parent (Resolve-Path $scriptDir)
$uiModule = Join-Path $rootDir "src\Dialog.ps1"
. $uiModule

# Run Demo Test
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " Launching Native WinUI 3 Auto-Update Preview..." -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "Notice the system accent color, clean app name, and adaptive theme!" -ForegroundColor DarkGray

$response = Dialog -appName "Discord" -appId "Discord.Discord" -timeoutSeconds 15

Write-Host "`nDialog Closed!" -ForegroundColor Cyan
if ($response) {
    Write-Host "[Result]: You clicked 'Close & Update' -> Script would proceed with update." -ForegroundColor Green
}
else {
    Write-Host "[Result]: You clicked 'Skip for Now' or let it time out -> Script would skip update." -ForegroundColor Yellow
}
Write-Host "==================================================`n" -ForegroundColor Cyan
