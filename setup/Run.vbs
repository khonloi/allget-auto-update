' ==============================================================================
' AllGet Auto-Update - Elevated Manual Run Launcher
' ==============================================================================
Set objShell = CreateObject("Shell.Application")
Set objFSO = CreateObject("Scripting.FileSystemObject")

' Resolve project root directory (parent of setup folder)
strSetupDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
strRootDir = objFSO.GetParentFolderName(strSetupDir)
strScriptPath = strRootDir & "\allget-autoupdate.ps1"

' ShellExecute with "runas" triggers Windows UAC elevation
' We use -NoExit so the user can see the final status before closing the window manually
objShell.ShellExecute "powershell.exe", "-ExecutionPolicy Bypass -NoProfile -NoExit -File """ & strScriptPath & """", strRootDir, "runas", 1
