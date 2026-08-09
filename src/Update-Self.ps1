<#
.SYNOPSIS
    Self-update module for AllGet Auto-Update.
.DESCRIPTION
    Checks the GitHub API for the latest release. If a new release is found, it downloads
    the ZIP archive, extracts it, replaces the local files, and updates the `.version` file.
#>
function Invoke-SelfUpdate {
    if (-not $script:autoUpdateSelf) {
        return $false
    }

    Write-Log "Checking for program updates from GitHub Releases..." "INFO"
    $repo = "khonloi/allget-auto-update"
    $apiUrl = "https://api.github.com/repos/$repo/releases/latest"
    
    try {
        $response = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop
        $latestTag = $response.tag_name
        $zipUrl = $response.zipball_url
        
        $versionFile = Join-Path $PSScriptRoot ".version"
        $currentTag = ""
        if (Test-Path $versionFile) {
            $currentTag = Get-Content $versionFile -Raw
        }
        
        if ($latestTag -ne $currentTag) {
            Write-Log "New program version found ($latestTag). Updating..." "INFO"
            
            $tempZip = Join-Path $env:TEMP "allget-update.zip"
            $tempDir = Join-Path $env:TEMP "allget-update-extract"
            
            Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing
            
            if (Test-Path $tempDir) {
                Remove-Item -Path $tempDir -Recurse -Force
            }
            Expand-Archive -Path $tempZip -DestinationPath $tempDir -Force
            
            # The GitHub zip extracts into a single root folder (e.g. khonloi-allget-auto-update-xxxx)
            $extractedRoot = Get-ChildItem -Path $tempDir -Directory | Select-Object -First 1
            
            if ($extractedRoot) {
                # Copy files from the extracted root folder to the script directory
                Copy-Item -Path "$($extractedRoot.FullName)\*" -Destination $PSScriptRoot -Recurse -Force
                
                # Save the new version tag
                $latestTag | Out-File -FilePath $versionFile -Encoding UTF8 -NoNewline
                
                Write-Log "Program successfully updated to $latestTag. Exiting to allow changes to apply on next run." "INFO"
                
                # Clean up
                Remove-Item -Path $tempZip -Force
                Remove-Item -Path $tempDir -Recurse -Force
                
                return $true
            } else {
                Write-Log "Failed to find extracted root folder during update." "ERROR"
            }
        } else {
            Write-Log "Program is up to date ($currentTag)." "INFO"
        }
    }
    catch {
        # Suppress 404 error if there are no releases yet
        if ($_.Exception.Response.StatusCode -eq 404) {
             Write-Log "No GitHub releases found for auto-update." "INFO"
        } else {
             Write-Log "Failed to check for program updates: $_" "WARN"
        }
    }
    return $false
}
