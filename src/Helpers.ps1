<#
.SYNOPSIS
    Writes a formatted log message to both the console and a persistent log file.
.DESCRIPTION
    This function standardizes logging across the auto-update scripts. It handles
    timestamp generation, coloring for console output based on severity level,
    and safely appends to the log file even if it's temporarily locked.
.PARAMETER message
    The message text to log.
.PARAMETER level
    The severity level of the log (INFO, WARN, ERROR, SUCCESS, SKIP). Defaults to INFO.
#>
function Write-Log ($message, $level = "INFO") {
    $timestamp = Get-Date -Format "HH:mm:ss"
    $logLine = "[$timestamp] [$level] $message"
    
    # Write to persistent daily log file
    $dateStr = Get-Date -Format "yyyy-MM-dd"
    $script:logPath = Join-Path $script:logsDir "autoupdate_$dateStr.log"
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

<#
.SYNOPSIS
    Displays a Windows Toast notification for application update status.
.DESCRIPTION
    Registers a custom AppUserModelId if necessary and triggers a native Windows
    toast notification to alert the user about the success or failure of an app update.
.PARAMETER appName
    The name of the application that was updated.
.PARAMETER isSuccess
    Boolean indicating whether the update was successful.
.PARAMETER errorDesc
    An error message description if the update failed.
#>
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
                
        if ($isSuccess) {
            $statusMessage = "Just got updated, check it out."
        }
        else {
            $statusMessage = "Failed to update: $errorDesc"
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

<#
.SYNOPSIS
    Retrieves a list of running processes that match a given application name or ID.
.DESCRIPTION
    Uses fuzzy matching against ProcessName, MainWindowTitle, and optionally
    FileVersionInfo to determine if an application is currently running. This is used
    to prevent updating applications that the user is actively using.
.PARAMETER appName
    The display name of the application.
.PARAMETER appId
    The package identifier of the application.
.PARAMETER allProcesses
    An optional pre-fetched list of all running processes. If $null, it will fetch them.
.OUTPUTS
    A list of matching System.Diagnostics.Process objects.
#>
function Get-RunningAppProcesses ($appName, $appId, $allProcesses = $null) {
    # Ignore common generic words to avoid false positive process matches
    $ignoreWords = @('microsoft', 'windows', 'client', 'edition', 'studio', 'software', 'desktop', 'full', 'system', 'project', 'common', 'tools', 'server', 'application', 'package', 'update', 'installer')
    
    # Split the app name and ID into unique search tokens
    $words = ($appName + ' ' + $appId.Replace('.', ' ')) -split '\s+' | Where-Object { $_.Length -ge 4 -and $ignoreWords -notcontains $_.ToLower() } | Select-Object -Unique
    
    if ($words.Count -eq 0) { return @() }
    
    # Fetch processes if not provided
    if ($null -eq $allProcesses) {
        # Optimize: Filter out Session 0 (Services/System) to avoid thousands of 'Access Denied' errors later
        $allProcesses = Get-Process | Where-Object { $_.SessionId -ne 0 -and ($_.MainWindowHandle -ne 0 -or $_.CPU -gt 0) }
    }
    
    $matched = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
    $escapedWords = $words | ForEach-Object { [regex]::Escape($_) }
    
    foreach ($proc in $allProcesses) {
        $procName = $proc.ProcessName
        $title = $proc.MainWindowTitle
        
        $isMatch = $false
        
        # Fast matching: check Process Name and Window Title first
        foreach ($regex in $escapedWords) {
            if ($procName -match $regex -or $title -match $regex) {
                $isMatch = $true
                break
            }
        }
        
        # Slow matching: Only check FileDescription if ProcessName and Title didn't match, as it's an expensive call
        if (-not $isMatch) {
            $desc = ''
            try { 
                # Optimize: Skip processes in C:\Windows to avoid Access Denied exceptions on MainModule
                if (-not [string]::IsNullOrWhiteSpace($proc.Path) -and $proc.Path -match '^[A-Za-z]:\\Windows\\') {
                    continue
                }
                $desc = $proc.MainModule.FileVersionInfo.FileDescription 
            }
            catch {}
            
            if (-not [string]::IsNullOrWhiteSpace($desc)) {
                foreach ($regex in $escapedWords) {
                    if ($desc -match $regex) {
                        $isMatch = $true
                        break
                    }
                }
            }
        }
        
        if ($isMatch) {
            $matched.Add($proc)
        }
    }
    
    return $matched | Select-Object -Unique -Property Id, ProcessName, MainWindowTitle, MainWindowHandle
}

<#
.SYNOPSIS
    Formats a raw JSON string into a pretty-printed version with custom indentation.
.DESCRIPTION
    Takes raw JSON, splits it into lines, and meticulously rebuilds the string with
    two-space indentation. Optimized using a Generic List for high performance.
.PARAMETER json
    The raw JSON string to be formatted.
.OUTPUTS
    A formatted, pretty-printed JSON string.
#>
function Format-JsonString ($json) {
    $lines = $json -split "`r?\n"
    $res = [System.Collections.Generic.List[string]]::new()
    $indent = 0
    
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t -eq '') { continue }
        
        # Decrease indent for closing brackets
        if ($t -match '^[}\]]') { $indent = [math]::Max(0, $indent - 1) }
        
        # Format the colon spacing
        $fmt = $t -replace '":\s+', '": '
        $res.Add(('  ' * $indent) + $fmt)
        
        # Increase indent for opening brackets
        if ($t -match '[{\[]$') { $indent++ }
    }
    
    return ($res -join "`r`n")
}

