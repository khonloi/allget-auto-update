' ==============================================================================
' AllGet Auto-Update - Elevated Installer Launcher
' ==============================================================================
Set objShell = CreateObject("Shell.Application")
Set objFSO = CreateObject("Scripting.FileSystemObject")

' Resolve project root directory (parent of src folder)
strSrcDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
strRootDir = objFSO.GetParentFolderName(strSrcDir)
strSetupPath = strSrcDir & "\setup.ps1"

' ShellExecute with "runas" triggers Windows UAC elevation seamlessly
objShell.ShellExecute "powershell.exe", "-ExecutionPolicy Bypass -NoProfile -File """ & strSetupPath & """ -Install", strRootDir, "runas", 1
