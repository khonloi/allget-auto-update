function Write-Log ($message, $level = "INFO") {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$level] $message"
    
    # Write to persistent log file
    try { Add-Content -Path $script:logPath -Value $logLine -ErrorAction SilentlyContinue } catch {}
    
    # Write to console
    switch ($level) {
        "ERROR" { Write-Host $logLine -ForegroundColor Red }
        "WARN" { Write-Host $logLine -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logLine -ForegroundColor Green }
        "SKIP" { Write-Host $logLine -ForegroundColor DarkYellow }
        default { Write-Host $logLine -ForegroundColor Cyan }
    }
}

function Show-AppToastNotification ($appName, $isSuccess, $errorDesc) {
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

        $appId = "WinGet.PackageManager"
        $regPath = "HKCU:\Software\Classes\AppUserModelId\$appId"
        if (-not (Test-Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
        }
        Set-ItemProperty -Path $regPath -Name "DisplayName" -Value "Package Manager" -ErrorAction SilentlyContinue
        
        $wingetExe = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
        if (Test-Path $wingetExe) {
            Set-ItemProperty -Path $regPath -Name "IconUri" -Value $wingetExe -ErrorAction SilentlyContinue
        }
        
        if ($isSuccess) {
            $statusMessage = "Just got updated, check it out."
        }
        else {
            $statusMessage = "Update failed: $errorDesc"
        }

        $template = @"
<toast>
    <visual>
        <binding template="ToastGeneric">
            <text id="1"><![CDATA[$appName]]></text>
            <text id="2"><![CDATA[$statusMessage]]></text>
        </binding>
    </visual>

</toast>
"@

        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($template)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    }
    catch {
        Write-Log "Failed to show toast for $($appName): $_" "WARN"
    }
}

# Helper Function: Get running processes matching an application name/ID
function Get-RunningAppProcesses ($appName, $appId) {
    $ignoreWords = @('microsoft', 'windows', 'client', 'edition', 'studio', 'software', 'desktop', 'full', 'system', 'project', 'common', 'tools', 'server', 'application', 'package', 'update', 'installer')
    $words = ($appName + ' ' + $appId.Replace('.', ' ')) -split '\s+' | Where-Object { $_.Length -ge 4 -and $ignoreWords -notcontains $_.ToLower() } | Select-Object -Unique
    
    if ($words.Count -eq 0) { return @() }
    
    $allProcesses = Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -or $_.CPU -gt 0 }
    $matched = @()
    
    foreach ($proc in $allProcesses) {
        $procName = $proc.ProcessName
        $title = $proc.MainWindowTitle
        $desc = ''
        try { $desc = $proc.MainModule.FileVersionInfo.FileDescription } catch {}
        
        foreach ($word in $words) {
            if ($procName -match [regex]::Escape($word) -or $title -match [regex]::Escape($word) -or $desc -match [regex]::Escape($word)) {
                $matched += $proc
                break
            }
        }
    }
    return $matched | Select-Object -Unique -Property Id, ProcessName, MainWindowTitle, MainWindowHandle
}
