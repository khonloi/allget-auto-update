function Invoke-PackageUpdates {
    $stats = [PSCustomObject]@{
        Updated = 0
        Skipped = 0
        Failed = 0
    }

    function Test-IsIgnored ($pkgName, $pkgId) {
        if (-not $pkgName) { $pkgName = "" }
        if (-not $pkgId) { $pkgId = "" }
        
        foreach ($pattern in $script:ignoredPatterns) {
            if ($pkgName -match $pattern -or $pkgId -match $pattern) {
                return $true
            }
        }
        return $false
    }

    # ==============================================================================
    # 1. WinGet Updates
    # ==============================================================================
    $updateCheck = & $script:winget upgrade --accept-source-agreements 2>&1

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
        
        for ($j = $headerIndex + 2; $j -lt $updateCheck.Count; $j++) {
            $line = $updateCheck[$j]
            if ([string]::IsNullOrWhiteSpace($line) -or $line -match 'upgrades available|package\(s\) have|package\(s\) are') { continue }
            if ($line.Length -gt $verIdx) {
                $appName = $line.Substring(0, $idIdx).Trim()
                $appId = $line.Substring($idIdx, $verIdx - $idIdx).Trim()
                if ($appName -and $appId) {
                    $appRows += [PSCustomObject]@{ Name = $appName; Id = $appId }
                }
            }
        }
    }

    if ($appRows.Count -eq 0) {
        Write-Log "All WinGet apps are up to date! Nothing to install." "SUCCESS"
    }
    else {
        Write-Log "Found $($appRows.Count) WinGet app(s) with available updates." "INFO"
        
        foreach ($app in $appRows) {
            # Check if the app is in the system/ignored bypass list
            if (Test-IsIgnored -pkgName $app.Name -pkgId $app.Id) {
                Write-Log "Bypassing '$($app.Name)' ($($app.Id)) - System / Self-updating application." "SKIP"
                $stats.Skipped++
                continue
            }

            $activeProcs = Get-RunningAppProcesses -appName $app.Name -appId $app.Id
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
                    foreach ($procInfo in $activeProcs) {
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
            
            $args = @(
                'upgrade', 
                '--id', $app.Id, 
                '--silent', 
                '--disable-interactivity', 
                '--accept-package-agreements', 
                '--accept-source-agreements',
                '--force'
            )
            
            $proc = Start-Process -FilePath $script:winget -ArgumentList $args -Wait -NoNewWindow -PassThru
            if ($proc.ExitCode -eq 0) {
                Write-Log "Updated '$($app.Name)' successfully." "SUCCESS"
                $stats.Updated++
                Show-AppToastNotification -appName $app.Name -isSuccess $true -errorDesc ""
            }
            else {
                $errDesc = switch ($proc.ExitCode) {
                    -1978335090 { "Different install technology (EXE vs MSI/MSIX). Requires uninstalling current version first." }
                    -1978335189 { "Installer scope or format mismatch (e.g., originally installed via EXE, update is MSI)." }
                    -1978335212 { "Package agreements or catalog source error." }
                    -1978334967 { "Installation canceled or timed out." }
                    1603 { "Windows Installer (MSI) fatal error." }
                    default { "WinGet exit code $($proc.ExitCode)." }
                }
                Write-Log "Update for '$($app.Name)' failed: $errDesc" "WARN"
                $stats.Failed++
                Show-AppToastNotification -appName $app.Name -isSuccess $false -errorDesc $errDesc
            }
        }
    }

    # ==============================================================================
    # 2. Additional Package Managers
    # ==============================================================================

    # Chocolatey
    if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
        Write-Log "Checking for Chocolatey updates..." "INFO"
        try {
            $chocoOutdated = choco outdated -r 2>&1
            $packagesToUpdate = @()
            foreach ($line in $chocoOutdated) {
                if ($line -match '^([^|]+)\|([^|]+)\|([^|]+)\|') {
                    $pkgName = $matches[1]
                    if (Test-IsIgnored -pkgName $pkgName -pkgId $pkgName) {
                        Write-Log "Bypassing Chocolatey package '$pkgName' (Matches Ignore List)" "SKIP"
                    } else {
                        $packagesToUpdate += $pkgName
                    }
                }
            }

            if ($packagesToUpdate.Count -eq 0) {
                Write-Log "All Chocolatey packages are up to date or ignored." "SUCCESS"
            } else {
                foreach ($pkg in $packagesToUpdate) {
                    Write-Log "Upgrading Chocolatey package '$pkg'..." "INFO"
                    $proc = Start-Process -FilePath "choco.exe" -ArgumentList "upgrade", $pkg, "-y" -Wait -NoNewWindow -PassThru
                    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 1641 -or $proc.ExitCode -eq 3010) {
                        Write-Log "Chocolatey package '$pkg' updated successfully." "SUCCESS"
                    } else {
                        Write-Log "Chocolatey update for '$pkg' returned exit code $($proc.ExitCode)." "WARN"
                    }
                }
            }
        } catch {
            Write-Log "Chocolatey update failed: $_" "WARN"
        }
    }

    # Scoop
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        Write-Log "Checking for Scoop updates..." "INFO"
        try {
            $scoopUpdateProc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "scoop update" -Wait -NoNewWindow -PassThru
            
            $scoopStatus = & cmd.exe /c "scoop status" 2>&1
            $packagesToUpdate = @()
            $parsing = $false
            foreach ($line in $scoopStatus) {
                if ($line -match '^---') { $parsing = $true; continue }
                if ($parsing -and -not [string]::IsNullOrWhiteSpace($line)) {
                    $parts = $line -split '\s+'
                    if ($parts.Count -gt 0) {
                        $pkgName = $parts[0]
                        if ($pkgName -eq "WARN" -or $pkgName -match "Scoop") { continue }
                        if (Test-IsIgnored -pkgName $pkgName -pkgId $pkgName) {
                            Write-Log "Bypassing Scoop package '$pkgName' (Matches Ignore List)" "SKIP"
                        } else {
                            $packagesToUpdate += $pkgName
                        }
                    }
                }
            }

            if ($packagesToUpdate.Count -eq 0) {
                Write-Log "All Scoop packages are up to date or ignored." "SUCCESS"
            } else {
                foreach ($pkg in $packagesToUpdate) {
                    Write-Log "Upgrading Scoop package '$pkg'..." "INFO"
                    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "scoop update $pkg" -Wait -NoNewWindow -PassThru
                    if ($proc.ExitCode -eq 0) {
                        Write-Log "Scoop package '$pkg' updated successfully." "SUCCESS"
                    } else {
                        Write-Log "Scoop update for '$pkg' returned exit code $($proc.ExitCode)." "WARN"
                    }
                }
            }
        } catch {
            Write-Log "Scoop update failed: $_" "WARN"
        }
    }

    # npm
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        Write-Log "Checking for global npm updates..." "INFO"
        try {
            $npmOutdated = & cmd.exe /c "npm outdated -g --parseable" 2>&1
            $packagesToUpdate = @()
            foreach ($line in $npmOutdated) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $parts = $line -split ':'
                if ($parts.Count -gt 0) {
                    $pkgPath = $parts[0]
                    # path is typically like C:\Users\user\AppData\Roaming\npm\node_modules\package
                    $pkgName = Split-Path $pkgPath -Leaf
                    if (Test-IsIgnored -pkgName $pkgName -pkgId $pkgName) {
                        Write-Log "Bypassing npm package '$pkgName' (Matches Ignore List)" "SKIP"
                    } else {
                        $packagesToUpdate += $pkgName
                    }
                }
            }

            if ($packagesToUpdate.Count -eq 0) {
                Write-Log "All npm packages are up to date or ignored." "SUCCESS"
            } else {
                foreach ($pkg in $packagesToUpdate) {
                    Write-Log "Upgrading npm package '$pkg'..." "INFO"
                    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "npm update -g $pkg" -Wait -NoNewWindow -PassThru
                    if ($proc.ExitCode -eq 0) {
                        Write-Log "npm package '$pkg' updated successfully." "SUCCESS"
                    } else {
                        Write-Log "npm update for '$pkg' returned exit code $($proc.ExitCode)." "WARN"
                    }
                }
            }
        } catch {
            Write-Log "npm update failed: $_" "WARN"
        }
    }

    # yarn
    if (Get-Command yarn -ErrorAction SilentlyContinue) {
        Write-Log "Checking for global yarn updates..." "INFO"
        try {
            $yarnList = & cmd.exe /c "yarn global list --pattern .*" 2>&1
            $packagesToUpdate = @()
            foreach ($line in $yarnList) {
                if ($line -match 'info "([^@]+)@') {
                    $pkgName = $matches[1]
                    if (Test-IsIgnored -pkgName $pkgName -pkgId $pkgName) {
                        Write-Log "Bypassing yarn package '$pkgName' (Matches Ignore List)" "SKIP"
                    } else {
                        $packagesToUpdate += $pkgName
                    }
                }
            }

            if ($packagesToUpdate.Count -eq 0) {
                Write-Log "No non-ignored yarn packages found to check." "INFO"
            } else {
                foreach ($pkg in $packagesToUpdate) {
                    Write-Log "Upgrading yarn package '$pkg'..." "INFO"
                    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "yarn global upgrade $pkg" -Wait -NoNewWindow -PassThru
                    if ($proc.ExitCode -eq 0) {
                        Write-Log "yarn package '$pkg' updated successfully." "SUCCESS"
                    } else {
                        Write-Log "yarn update for '$pkg' returned exit code $($proc.ExitCode)." "WARN"
                    }
                }
            }
        } catch {
            Write-Log "yarn update failed: $_" "WARN"
        }
    }

    # bun
    if (Get-Command bun -ErrorAction SilentlyContinue) {
        Write-Log "Checking for global bun updates..." "INFO"
        try {
            $bunUpdateProc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "bun upgrade" -Wait -NoNewWindow -PassThru
            
            $bunList = & cmd.exe /c "bun pm ls -g" 2>&1
            $packagesToUpdate = @()
            foreach ($line in $bunList) {
                # bun pm ls outputs like:
                # C:\Users\user\.bun\install\global\node_modules (X)
                # ├── package@version
                if ($line -match '^\s*[├└]──\s*([^@]+)@') {
                    $pkgName = $matches[1]
                    if (Test-IsIgnored -pkgName $pkgName -pkgId $pkgName) {
                        Write-Log "Bypassing bun package '$pkgName' (Matches Ignore List)" "SKIP"
                    } else {
                        $packagesToUpdate += $pkgName
                    }
                }
            }

            if ($packagesToUpdate.Count -eq 0) {
                Write-Log "All bun packages are up to date or ignored." "SUCCESS"
            } else {
                foreach ($pkg in $packagesToUpdate) {
                    Write-Log "Upgrading bun package '$pkg'..." "INFO"
                    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "bun update -g $pkg" -Wait -NoNewWindow -PassThru
                    if ($proc.ExitCode -eq 0) {
                        Write-Log "bun package '$pkg' updated successfully." "SUCCESS"
                    } else {
                        Write-Log "bun update for '$pkg' returned exit code $($proc.ExitCode)." "WARN"
                    }
                }
            }
        } catch {
            Write-Log "bun update failed: $_" "WARN"
        }
    }

    return $stats
}
