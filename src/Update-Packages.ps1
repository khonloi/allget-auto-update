<#
.SYNOPSIS
    Orchestrates the entire package update process across multiple package managers.
.DESCRIPTION
    Checks WinGet, Chocolatey, Scoop, NPM, Yarn, and Bun for available updates. 
    It respects the configured ignore lists, delayed update preferences, and actively 
    checks for running application processes to avoid forcefully closing foreground apps.
    If an app is running in the background, it prompts the user before proceeding.
.OUTPUTS
    A PSCustomObject containing statistics for Updated, Skipped, and Failed packages.
#>
function Invoke-PackageUpdates {
    $stats = [PSCustomObject]@{
        Updated = 0
        Skipped = 0
        Failed  = 0
    }

    function Test-IsIgnored ($pkgName, $pkgId) {
        if (-not $pkgName) { $pkgName = "" }
        if (-not $pkgId) { $pkgId = "" }
        
        if ($pkgName -match $script:combinedIgnoredPattern -or $pkgId -match $script:combinedIgnoredPattern) {
            return $true
        }
        return $false
    }

    $script:pendingUpdatesFile = Join-Path $script:logsDir "pending-updates.json"
    $script:pendingUpdates = @{}
    $script:pendingUpdatesChanged = $false

    if (Test-Path $script:pendingUpdatesFile) {
        try {
            $content = Get-Content $script:pendingUpdatesFile -Raw | ConvertFrom-Json
            if ($content) {
                $content.psobject.properties | ForEach-Object {
                    $script:pendingUpdates[$_.Name] = [PSCustomObject]@{
                        Version      = $_.Value.Version
                        DiscoveredAt = $_.Value.DiscoveredAt
                        FailCount    = if ($null -ne $_.Value.FailCount) { [int]$_.Value.FailCount } else { 0 }
                        LastFailCode = if ($null -ne $_.Value.LastFailCode) { $_.Value.LastFailCode } else { $null }
                    }
                }
            }
        }
        catch {
            Write-Log "Failed to parse pending-updates.json. Starting fresh." "WARN"
        }
    }

    function Save-PendingUpdates {
        if ($script:pendingUpdatesChanged) {
            try {
                $rawJson = $script:pendingUpdates | ConvertTo-Json -Depth 3
                $prettyJson = Format-JsonString $rawJson
                $prettyJson | Set-Content $script:pendingUpdatesFile -Encoding UTF8
                $script:pendingUpdatesChanged = $false
            }
            catch {
                Write-Log "Failed to save pending-updates.json" "WARN"
            }
        }
    }

    function Test-IsUpdateDelayed ($manager, $pkgId, $version) {
        if (-not $script:delayUpdatesEnabled) { return $false }
        $key = "$manager`:$pkgId"
        $now = Get-Date
        
        if ($script:pendingUpdates.ContainsKey($key)) {
            $entry = $script:pendingUpdates[$key]
            if ($entry.Version -eq $version) {
                $daysPassed = ($now - [datetime]$entry.DiscoveredAt).TotalDays
                if ($daysPassed -lt $script:delayUpdatesDays) {
                    return $true
                }
                return $false
            }
        }
        
        $script:pendingUpdates[$key] = [PSCustomObject]@{
            Version      = $version
            DiscoveredAt = $now.ToString("o")
            FailCount    = 0
            LastFailCode = $null
        }
        $script:pendingUpdatesChanged = $true
        return $true
    }

    function Remove-PendingUpdate ($manager, $pkgId) {
        $key = "$manager`:$pkgId"
        if ($script:pendingUpdates.ContainsKey($key)) {
            $script:pendingUpdates.Remove($key)
            $script:pendingUpdatesChanged = $true
        }
    }

    function Test-IsPersistentFailure ($manager, $pkgId, $version) {
        if ($script:maxConsecutiveFailures -le 0) { return $false }
        $key = "$manager`:$pkgId"
        if ($script:pendingUpdates.ContainsKey($key)) {
            $entry = $script:pendingUpdates[$key]
            # If the upstream version changed, reset counter so the new version is attempted
            if ($entry.Version -ne $version) {
                $entry.Version = $version
                $entry.FailCount = 0
                $entry.LastFailCode = $null
                $script:pendingUpdatesChanged = $true
                return $false
            }
            if ($entry.FailCount -ge $script:maxConsecutiveFailures) {
                return $true
            }
        }
        return $false
    }

    function Set-PackageFailure ($manager, $pkgId, $version, $exitCode) {
        $key = "$manager`:$pkgId"
        $now = Get-Date
        if ($script:pendingUpdates.ContainsKey($key)) {
            $entry = $script:pendingUpdates[$key]
            if ($entry.Version -ne $version) {
                $entry.Version = $version
                $entry.FailCount = 1
                $entry.DiscoveredAt = $now.ToString("o")
            }
            else {
                $entry.FailCount++
            }
            $entry.LastFailCode = $exitCode
        }
        else {
            $script:pendingUpdates[$key] = [PSCustomObject]@{
                Version      = $version
                DiscoveredAt = $now.ToString("o")
                FailCount    = 1
                LastFailCode = $exitCode
            }
        }
        $script:pendingUpdatesChanged = $true
    }

    function Set-PackageSuccess ($manager, $pkgId) {
        Remove-PendingUpdate -manager $manager -pkgId $pkgId
    }

    function Get-WinGetErrorDescription ($exitCode) {
        switch ($exitCode) {
            0 { "Success" }
            3010 { "Installation successful, reboot pending." }
            1641 { "Installation successful, reboot initiated." }
            2359302 { "Update already installed." }
            -1978335005 { "Reboot required to complete installation." }
            -1978335189 { "Package is already up to date or no newer update available." }
            -1978335090 { "Different install technology (EXE vs MSI/MSIX). Requires uninstalling current version first." }
            -1978335212 { "Package agreements or catalog source error." }
            -1978334969 { "Application or service is currently running in the background." }
            -1978334967 { "Installation canceled or timed out." }
            -1978335229 { "Another installer or Windows Update is currently running." }
            -1978335226 { "No applicable installer found for this system architecture." }
            -1978335146 { "Package installer failed (app-specific error)." }
            -2147012889 { "Network connection timed out or lost during download." }
            -2145844845 { "Installer hash mismatch, download forbidden (HTTP 403), or tampered package." }
            1603 { "Windows Installer (MSI) fatal error." }
            1618 { "Another installation is already in progress." }
            default { "WinGet exit code $exitCode." }
        }
    }

    # ==============================================================================
    # 0. Update Discovery Phase (Parallelized)
    # ==============================================================================
    Write-Log "Checking for updates across package managers concurrently..." "INFO"
    $discoveryJobs = @{}
    $tempFiles = @{}

    # WinGet
    $tempFiles["winget"] = New-TemporaryFile
    $discoveryJobs["winget"] = Start-Process -FilePath $script:winget -ArgumentList "upgrade", "--accept-source-agreements" -NoNewWindow -PassThru -RedirectStandardOutput $tempFiles["winget"].FullName

    # Chocolatey
    if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
        $tempFiles["choco"] = New-TemporaryFile
        $discoveryJobs["choco"] = Start-Process -FilePath "choco.exe" -ArgumentList "outdated", "-r" -NoNewWindow -PassThru -RedirectStandardOutput $tempFiles["choco"].FullName
    }

    # Scoop
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        $tempFiles["scoop"] = New-TemporaryFile
        $discoveryJobs["scoop"] = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "scoop update >nul 2>&1 && scoop status" -NoNewWindow -PassThru -RedirectStandardOutput $tempFiles["scoop"].FullName
    }

    # npm
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        $tempFiles["npm"] = New-TemporaryFile
        $discoveryJobs["npm"] = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "npm outdated -g --parseable" -NoNewWindow -PassThru -RedirectStandardOutput $tempFiles["npm"].FullName
    }

    # yarn
    if (Get-Command yarn -ErrorAction SilentlyContinue) {
        $tempFiles["yarn"] = New-TemporaryFile
        $discoveryJobs["yarn"] = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "yarn global list --pattern .*" -NoNewWindow -PassThru -RedirectStandardOutput $tempFiles["yarn"].FullName
    }

    # bun
    if (Get-Command bun -ErrorAction SilentlyContinue) {
        $tempFiles["bun"] = New-TemporaryFile
        $discoveryJobs["bun"] = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "bun upgrade >nul 2>&1 && bun pm ls -g" -NoNewWindow -PassThru -RedirectStandardOutput $tempFiles["bun"].FullName
    }

    # Wait for all background discovery jobs to complete
    $activeJobs = @($discoveryJobs.Values)
    if ($activeJobs.Count -gt 0) {
        $activeJobs | Wait-Process -ErrorAction SilentlyContinue
    }

    # ==============================================================================
    # 1. WinGet Updates
    # ==============================================================================
    $updateCheck = @()
    if ($tempFiles.ContainsKey("winget")) {
        $updateCheck = Get-Content -Path $tempFiles["winget"].FullName -ErrorAction SilentlyContinue
        Remove-Item -Path $tempFiles["winget"].FullName -Force -ErrorAction SilentlyContinue
    }

    # Parse table output to find specific apps needing upgrade
    $appRows = @()
    $headerIndex = -1
    for ($i = 0; $i -lt $updateCheck.Count; $i++) {
        if ($updateCheck[$i] -match '^-+$') {
            $headerIndex = $i - 1
            break
        }
    }

    if ($headerIndex -ge 0) {
        $header = $updateCheck[$headerIndex]
        $idIdx = $header.IndexOf('Id')
        $verIdx = $header.IndexOf('Version')
        $availIdx = $header.IndexOf('Available')
        $sourceIdx = $header.IndexOf('Source')
        
        for ($j = $headerIndex + 2; $j -lt $updateCheck.Count; $j++) {
            $line = $updateCheck[$j]
            if ([string]::IsNullOrWhiteSpace($line) -or $line -match 'upgrades available|package\(s\) have|package\(s\) are') { continue }
            if ($line.Length -gt $verIdx) {
                $appName = $line.Substring(0, $idIdx).Trim()
                $appId = $line.Substring($idIdx, $verIdx - $idIdx).Trim()
                $appAvail = "UNKNOWN"
                if ($availIdx -gt 0 -and $line.Length -gt $availIdx) {
                    if ($sourceIdx -gt $availIdx -and $line.Length -gt $sourceIdx) {
                        $appAvail = $line.Substring($availIdx, $sourceIdx - $availIdx).Trim()
                    }
                    else {
                        $appAvail = $line.Substring($availIdx).Trim()
                    }
                }
                if ($appName -and $appId) {
                    $appRows += [PSCustomObject]@{ Name = $appName; Id = $appId; Available = $appAvail }
                }
            }
        }
    }

    if ($appRows.Count -eq 0) {
        Write-Log "All WinGet apps are up to date! Nothing to install." "SUCCESS"
    }
    else {
        Write-Log "Found $($appRows.Count) WinGet app(s) with available updates." "INFO"
        $allSystemProcesses = Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -or $_.CPU -gt 0 }
        
        foreach ($app in $appRows) {
            # Check if the app is in the system/ignored bypass list
            if (Test-IsIgnored -pkgName $app.Name -pkgId $app.Id) {
                Write-Log "Bypassing '$($app.Name)' ($($app.Id)) - System / Self-updating application." "SKIP"
                $stats.Skipped++
                continue
            }

            if (Test-IsPersistentFailure -manager "winget" -pkgId $app.Id -version $app.Available) {
                $entry = $script:pendingUpdates["winget:$($app.Id)"]
                $failDesc = Get-WinGetErrorDescription $entry.LastFailCode
                Write-Log "Auto-skipping '$($app.Name)' ($($app.Id)) - Failed $($entry.FailCount) consecutive times with error: $failDesc. Will retry when a new version is released." "SKIP"
                $stats.Skipped++
                continue
            }

            if (Test-IsUpdateDelayed -manager "winget" -pkgId $app.Id -version $app.Available) {
                $discovered = [datetime]$script:pendingUpdates["winget:$($app.Id)"].DiscoveredAt
                $daysRemaining = [math]::Ceiling($script:delayUpdatesDays - ((Get-Date) - $discovered).TotalDays)
                Write-Log "Delaying update for '$($app.Name)' ($($app.Id)) - $daysRemaining day(s) remaining." "SKIP"
                $stats.Skipped++
                continue
            }

            $activeProcs = Get-RunningAppProcesses -appName $app.Name -appId $app.Id -allProcesses $allSystemProcesses
            if ($activeProcs.Count -gt 0) {
                # Check if any process has an active, visible main window open on screen
                $activeWindows = $activeProcs | Where-Object { $_.MainWindowHandle -ne 0 -and -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle) }
                
                if ($activeWindows.Count -gt 0) {
                    # Program is actively open and running in foreground -> skip automatically without prompting
                    Write-Log "Skipping '$($app.Name)' ($($app.Id)) - Program is actively open and running ($($activeWindows[0].MainWindowTitle))." "SKIP"
                    $stats.Skipped++
                    continue
                }

                # Program is running in background (no active open window) -> prompt user
                Write-Log "'$($app.Name)' is running in background. Prompting user for permission to close background processes..." "WARN"
                
                # Prompt user with 30-second timeout using native WinUI styled dialog
                $allowed = Dialog -appName $app.Name -appId $app.Id -timeoutSeconds 30
                
                if ($allowed) {
                    # User clicked Close & Update
                    Write-Log "User allowed updating '$($app.Name)'. Closing background processes..." "INFO"
                    
                    # Fetch all processes including Session 0 (Services) to completely quit the application
                    $allMatchingProcs = Get-RunningAppProcesses -appName $app.Name -appId $app.Id -allProcesses (Get-Process)
                    foreach ($procInfo in $allMatchingProcs) {
                        try {
                            $p = Get-Process -Id $procInfo.Id -ErrorAction SilentlyContinue
                            if ($p) {
                                $p | Stop-Process -Force -ErrorAction SilentlyContinue
                            }
                        }
                        catch {}
                    }
                    Start-Sleep -Seconds 2
                }
                else {
                    # User clicked No or Timed out
                    Write-Log "'$($app.Name)' skipped (User declined or prompt timed out)." "SKIP"
                    $stats.Skipped++
                    continue
                }
            }
            
            Write-Log "Upgrading '$($app.Name)' ($($app.Id)) in background..." "INFO"
            
            $wingetArgs = @(
                'upgrade', 
                '--id', $app.Id, 
                '--silent', 
                '--disable-interactivity', 
                '--accept-package-agreements', 
                '--accept-source-agreements',
                '--force'
            )
            
            $proc = Start-Process -FilePath $script:winget -ArgumentList $wingetArgs -Wait -NoNewWindow -PassThru
            $isSuccess = ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010 -or $proc.ExitCode -eq 1641 -or $proc.ExitCode -eq 2359302 -or $proc.ExitCode -eq -1978335005 -or $proc.ExitCode -eq -1978335189)

            # Retry transient errors once after delay
            $retryCodes = @(-2147012889, -1978335229, 1618, -1978335212, -1978334967)
            if (-not $isSuccess -and $retryCodes -contains $proc.ExitCode) {
                $transientDesc = Get-WinGetErrorDescription $proc.ExitCode
                Write-Log "Transient error updating '$($app.Name)' ($transientDesc). Retrying in 10 seconds..." "WARN"
                Start-Sleep -Seconds 10
                $proc = Start-Process -FilePath $script:winget -ArgumentList $wingetArgs -Wait -NoNewWindow -PassThru
                $isSuccess = ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010 -or $proc.ExitCode -eq 1641 -or $proc.ExitCode -eq 2359302 -or $proc.ExitCode -eq -1978335005 -or $proc.ExitCode -eq -1978335189)
            }

            if ($isSuccess) {
                $successMsg = if ($proc.ExitCode -eq 3010 -or $proc.ExitCode -eq -1978335005) {
                    "Updated '$($app.Name)' successfully (Reboot pending)."
                }
                elseif ($proc.ExitCode -eq -1978335189) {
                    "'$($app.Name)' is already up to date."
                }
                else {
                    "Updated '$($app.Name)' successfully."
                }
                Write-Log $successMsg "SUCCESS"
                $stats.Updated++
                Show-AppToastNotification -appName $app.Name -isSuccess $true -errorDesc ""
                Set-PackageSuccess -manager "winget" -pkgId $app.Id
            }
            else {
                $errDesc = Get-WinGetErrorDescription $proc.ExitCode
                Write-Log "Update for '$($app.Name)' failed: $errDesc" "WARN"
                $stats.Failed++
                Show-AppToastNotification -appName $app.Name -isSuccess $false -errorDesc $errDesc
                Set-PackageFailure -manager "winget" -pkgId $app.Id -version $app.Available -exitCode $proc.ExitCode
            }
        }
    }

    # ==============================================================================
    # 2. Additional Package Managers
    # ==============================================================================

    # Chocolatey
    if ($tempFiles.ContainsKey("choco")) {
        Write-Log "Processing Chocolatey updates..." "INFO"
        try {
            $chocoOutdated = Get-Content -Path $tempFiles["choco"].FullName -ErrorAction SilentlyContinue
            Remove-Item -Path $tempFiles["choco"].FullName -Force -ErrorAction SilentlyContinue
            $packagesToUpdate = @()
            foreach ($line in $chocoOutdated) {
                if ($line -match '^([^|]+)\|([^|]+)\|([^|]+)\|') {
                    $pkgName = $matches[1]
                    $availVer = $matches[3]
                    if (Test-IsIgnored -pkgName $pkgName -pkgId $pkgName) {
                        Write-Log "Bypassing Chocolatey package '$pkgName' (Matches Ignore List)" "SKIP"
                        $stats.Skipped++
                    }
                    elseif (Test-IsPersistentFailure -manager "choco" -pkgId $pkgName -version $availVer) {
                        $entry = $script:pendingUpdates["choco:$pkgName"]
                        Write-Log "Auto-skipping Chocolatey package '$pkgName' - Failed $($entry.FailCount) consecutive times with code $($entry.LastFailCode). Will retry when a new version is released." "SKIP"
                        $stats.Skipped++
                    }
                    elseif (Test-IsUpdateDelayed -manager "choco" -pkgId $pkgName -version $availVer) {
                        $discovered = [datetime]$script:pendingUpdates["choco:$pkgName"].DiscoveredAt
                        $daysRemaining = [math]::Ceiling($script:delayUpdatesDays - ((Get-Date) - $discovered).TotalDays)
                        Write-Log "Delaying update for '$pkgName' - $daysRemaining day(s) remaining." "SKIP"
                        $stats.Skipped++
                    }
                    else {
                        $packagesToUpdate += [PSCustomObject]@{ Name = $pkgName; Version = $availVer }
                    }
                }
            }

            if ($packagesToUpdate.Count -eq 0) {
                Write-Log "All Chocolatey packages are up to date or ignored." "SUCCESS"
            }
            else {
                foreach ($pkg in $packagesToUpdate) {
                    Write-Log "Upgrading Chocolatey package '$($pkg.Name)'..." "INFO"
                    $proc = Start-Process -FilePath "choco.exe" -ArgumentList "upgrade", $pkg.Name, "-y" -Wait -NoNewWindow -PassThru
                    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 1641 -or $proc.ExitCode -eq 3010) {
                        Write-Log "Chocolatey package '$($pkg.Name)' updated successfully." "SUCCESS"
                        Set-PackageSuccess -manager "choco" -pkgId $pkg.Name
                        $stats.Updated++
                    }
                    else {
                        Write-Log "Chocolatey update for '$($pkg.Name)' returned exit code $($proc.ExitCode)." "WARN"
                        Set-PackageFailure -manager "choco" -pkgId $pkg.Name -version $pkg.Version -exitCode $proc.ExitCode
                        $stats.Failed++
                    }
                }
            }
        }
        catch {
            Write-Log "Chocolatey update failed: $_" "WARN"
        }
    }

    # Scoop
    if ($tempFiles.ContainsKey("scoop")) {
        Write-Log "Processing Scoop updates..." "INFO"
        try {
            $scoopStatus = Get-Content -Path $tempFiles["scoop"].FullName -ErrorAction SilentlyContinue
            Remove-Item -Path $tempFiles["scoop"].FullName -Force -ErrorAction SilentlyContinue
            $packagesToUpdate = @()
            $parsing = $false
            foreach ($line in $scoopStatus) {
                if ($line -match '^---') { $parsing = $true; continue }
                if ($parsing -and -not [string]::IsNullOrWhiteSpace($line)) {
                    $parts = $line -split '\s+'
                    if ($parts.Count -gt 0) {
                        $pkgName = $parts[0]
                        $availVer = if ($parts.Count -gt 1) { $parts[1] } else { "UNKNOWN" }
                        if ($pkgName -eq "WARN" -or $pkgName -match "Scoop") { continue }
                        if (Test-IsIgnored -pkgName $pkgName -pkgId $pkgName) {
                            Write-Log "Bypassing Scoop package '$pkgName' (Matches Ignore List)" "SKIP"
                            $stats.Skipped++
                        }
                        elseif (Test-IsPersistentFailure -manager "scoop" -pkgId $pkgName -version $availVer) {
                            $entry = $script:pendingUpdates["scoop:$pkgName"]
                            Write-Log "Auto-skipping Scoop package '$pkgName' - Failed $($entry.FailCount) consecutive times with code $($entry.LastFailCode). Will retry when a new version is released." "SKIP"
                            $stats.Skipped++
                        }
                        elseif (Test-IsUpdateDelayed -manager "scoop" -pkgId $pkgName -version $availVer) {
                            $discovered = [datetime]$script:pendingUpdates["scoop:$pkgName"].DiscoveredAt
                            $daysRemaining = [math]::Ceiling($script:delayUpdatesDays - ((Get-Date) - $discovered).TotalDays)
                            Write-Log "Delaying update for '$pkgName' - $daysRemaining day(s) remaining." "SKIP"
                            $stats.Skipped++
                        }
                        else {
                            $packagesToUpdate += [PSCustomObject]@{ Name = $pkgName; Version = $availVer }
                        }
                    }
                }
            }

            if ($packagesToUpdate.Count -eq 0) {
                Write-Log "All Scoop packages are up to date or ignored." "SUCCESS"
            }
            else {
                foreach ($pkg in $packagesToUpdate) {
                    Write-Log "Upgrading Scoop package '$($pkg.Name)'..." "INFO"
                    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "scoop update $($pkg.Name)" -Wait -NoNewWindow -PassThru
                    if ($proc.ExitCode -eq 0) {
                        Write-Log "Scoop package '$($pkg.Name)' updated successfully." "SUCCESS"
                        Set-PackageSuccess -manager "scoop" -pkgId $pkg.Name
                        $stats.Updated++
                    }
                    else {
                        Write-Log "Scoop update for '$($pkg.Name)' returned exit code $($proc.ExitCode)." "WARN"
                        Set-PackageFailure -manager "scoop" -pkgId $pkg.Name -version $pkg.Version -exitCode $proc.ExitCode
                        $stats.Failed++
                    }
                }
            }
        }
        catch {
            Write-Log "Scoop update failed: $_" "WARN"
        }
    }

    # npm
    if ($tempFiles.ContainsKey("npm")) {
        Write-Log "Processing global npm updates..." "INFO"
        try {
            $npmOutdated = Get-Content -Path $tempFiles["npm"].FullName -ErrorAction SilentlyContinue
            Remove-Item -Path $tempFiles["npm"].FullName -Force -ErrorAction SilentlyContinue
            $packagesToUpdate = @()
            foreach ($line in $npmOutdated) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $pkgName = $null
                # Match path:wanted:current:latest:type, handling Windows drive letter colons correctly
                if ($line -match '^(.+):([^:]+):([^:]+):([^:]+):([^:]+)$') {
                    $pkgPath = $matches[1]
                    $wantedSpec = $matches[2]
                    $availSpec = $matches[4]
                    $lastAt = $wantedSpec.LastIndexOf('@')
                    if ($lastAt -gt 0) {
                        $pkgName = $wantedSpec.Substring(0, $lastAt)
                    }
                    else {
                        $pkgName = Split-Path $pkgPath -Leaf
                    }
                    $availAt = $availSpec.LastIndexOf('@')
                    if ($availAt -gt 0) {
                        $availVer = $availSpec.Substring($availAt + 1)
                    }
                }
                else {
                    $parts = $line -split ':'
                    if ($parts.Count -gt 0) {
                        $pkgName = Split-Path $parts[0] -Leaf
                    }
                }

                if ($pkgName) {
                    if (Test-IsIgnored -pkgName $pkgName -pkgId $pkgName) {
                        Write-Log "Bypassing npm package '$pkgName' (Matches Ignore List)" "SKIP"
                        $stats.Skipped++
                    }
                    elseif (Test-IsPersistentFailure -manager "npm" -pkgId $pkgName -version $availVer) {
                        $entry = $script:pendingUpdates["npm:$pkgName"]
                        Write-Log "Auto-skipping npm package '$pkgName' - Failed $($entry.FailCount) consecutive times with code $($entry.LastFailCode). Will retry when a new version is released." "SKIP"
                        $stats.Skipped++
                    }
                    elseif (Test-IsUpdateDelayed -manager "npm" -pkgId $pkgName -version $availVer) {
                        $discovered = [datetime]$script:pendingUpdates["npm:$pkgName"].DiscoveredAt
                        $daysRemaining = [math]::Ceiling($script:delayUpdatesDays - ((Get-Date) - $discovered).TotalDays)
                        Write-Log "Delaying update for '$pkgName' - $daysRemaining day(s) remaining." "SKIP"
                        $stats.Skipped++
                    }
                    else {
                        $packagesToUpdate += [PSCustomObject]@{ Name = $pkgName; Version = $availVer }
                    }
                }
            }
            if ($packagesToUpdate.Count -eq 0) {
                Write-Log "All npm packages are up to date or ignored." "SUCCESS"
            }
            else {
                foreach ($pkg in $packagesToUpdate) {
                    Write-Log "Upgrading npm package '$($pkg.Name)'..." "INFO"
                    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "npm install -g $($pkg.Name)" -Wait -NoNewWindow -PassThru
                    if ($proc.ExitCode -eq 0) {
                        Write-Log "npm package '$($pkg.Name)' updated successfully." "SUCCESS"
                        Set-PackageSuccess -manager "npm" -pkgId $pkg.Name
                        $stats.Updated++
                    }
                    else {
                        Write-Log "npm update for '$($pkg.Name)' returned exit code $($proc.ExitCode)." "WARN"
                        Set-PackageFailure -manager "npm" -pkgId $pkg.Name -version $pkg.Version -exitCode $proc.ExitCode
                        $stats.Failed++
                    }
                }
            }
        }
        catch {
            Write-Log "npm update failed: $_" "WARN"
        }
    }

    # yarn
    if ($tempFiles.ContainsKey("yarn")) {
        Write-Log "Processing global yarn updates..." "INFO"
        try {
            $yarnList = Get-Content -Path $tempFiles["yarn"].FullName -ErrorAction SilentlyContinue
            Remove-Item -Path $tempFiles["yarn"].FullName -Force -ErrorAction SilentlyContinue
            $packagesToUpdate = @()
            foreach ($line in $yarnList) {
                if ($line -match 'info "([^@]+)@([^"]+)"') {
                    $pkgName = $matches[1]
                    $availVer = $matches[2]
                    if (Test-IsIgnored -pkgName $pkgName -pkgId $pkgName) {
                        Write-Log "Bypassing yarn package '$pkgName' (Matches Ignore List)" "SKIP"
                        $stats.Skipped++
                    }
                    elseif (Test-IsPersistentFailure -manager "yarn" -pkgId $pkgName -version $availVer) {
                        $entry = $script:pendingUpdates["yarn:$pkgName"]
                        Write-Log "Auto-skipping yarn package '$pkgName' - Failed $($entry.FailCount) consecutive times with code $($entry.LastFailCode). Will retry when a new version is released." "SKIP"
                        $stats.Skipped++
                    }
                    elseif (Test-IsUpdateDelayed -manager "yarn" -pkgId $pkgName -version $availVer) {
                        $discovered = [datetime]$script:pendingUpdates["yarn:$pkgName"].DiscoveredAt
                        $daysRemaining = [math]::Ceiling($script:delayUpdatesDays - ((Get-Date) - $discovered).TotalDays)
                        Write-Log "Delaying update for '$pkgName' - $daysRemaining day(s) remaining." "SKIP"
                        $stats.Skipped++
                    }
                    else {
                        $packagesToUpdate += [PSCustomObject]@{ Name = $pkgName; Version = $availVer }
                    }
                }
            }

            if ($packagesToUpdate.Count -eq 0) {
                Write-Log "No non-ignored yarn packages found to check." "INFO"
            }
            else {
                foreach ($pkg in $packagesToUpdate) {
                    Write-Log "Upgrading yarn package '$($pkg.Name)'..." "INFO"
                    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "yarn global upgrade $($pkg.Name)" -Wait -NoNewWindow -PassThru
                    if ($proc.ExitCode -eq 0) {
                        Write-Log "yarn package '$($pkg.Name)' updated successfully." "SUCCESS"
                        Set-PackageSuccess -manager "yarn" -pkgId $pkg.Name
                        $stats.Updated++
                    }
                    else {
                        Write-Log "yarn update for '$($pkg.Name)' returned exit code $($proc.ExitCode)." "WARN"
                        Set-PackageFailure -manager "yarn" -pkgId $pkg.Name -version $pkg.Version -exitCode $proc.ExitCode
                        $stats.Failed++
                    }
                }
            }
        }
        catch {
            Write-Log "yarn update failed: $_" "WARN"
        }
    }

    # bun
    if ($tempFiles.ContainsKey("bun")) {
        Write-Log "Processing global bun updates..." "INFO"
        try {
            $bunList = Get-Content -Path $tempFiles["bun"].FullName -ErrorAction SilentlyContinue
            Remove-Item -Path $tempFiles["bun"].FullName -Force -ErrorAction SilentlyContinue
            $packagesToUpdate = @()
            foreach ($line in $bunList) {
                if ($line -match '([^@\s]+)@(.+)') {
                    $pkgName = $matches[1]
                    $availVer = $matches[2].Trim()
                    if (Test-IsIgnored -pkgName $pkgName -pkgId $pkgName) {
                        Write-Log "Bypassing bun package '$pkgName' (Matches Ignore List)" "SKIP"
                        $stats.Skipped++
                    }
                    elseif (Test-IsPersistentFailure -manager "bun" -pkgId $pkgName -version $availVer) {
                        $entry = $script:pendingUpdates["bun:$pkgName"]
                        Write-Log "Auto-skipping bun package '$pkgName' - Failed $($entry.FailCount) consecutive times with code $($entry.LastFailCode). Will retry when a new version is released." "SKIP"
                        $stats.Skipped++
                    }
                    elseif (Test-IsUpdateDelayed -manager "bun" -pkgId $pkgName -version $availVer) {
                        $discovered = [datetime]$script:pendingUpdates["bun:$pkgName"].DiscoveredAt
                        $daysRemaining = [math]::Ceiling($script:delayUpdatesDays - ((Get-Date) - $discovered).TotalDays)
                        Write-Log "Delaying update for '$pkgName' - $daysRemaining day(s) remaining." "SKIP"
                        $stats.Skipped++
                    }
                    else {
                        $packagesToUpdate += [PSCustomObject]@{ Name = $pkgName; Version = $availVer }
                    }
                }
            }

            if ($packagesToUpdate.Count -eq 0) {
                Write-Log "All bun packages are up to date or ignored." "SUCCESS"
            }
            else {
                foreach ($pkg in $packagesToUpdate) {
                    Write-Log "Upgrading bun package '$($pkg.Name)'..." "INFO"
                    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "bun update -g $($pkg.Name)" -Wait -NoNewWindow -PassThru
                    if ($proc.ExitCode -eq 0) {
                        Write-Log "bun package '$($pkg.Name)' updated successfully." "SUCCESS"
                        Set-PackageSuccess -manager "bun" -pkgId $pkg.Name
                        $stats.Updated++
                    }
                    else {
                        Write-Log "bun update for '$($pkg.Name)' returned exit code $($proc.ExitCode)." "WARN"
                        Set-PackageFailure -manager "bun" -pkgId $pkg.Name -version $pkg.Version -exitCode $proc.ExitCode
                        $stats.Failed++
                    }
                }
            }
        }
        catch {
            Write-Log "bun update failed: $_" "WARN"
        }
    }

    Save-PendingUpdates
    return $stats
}
