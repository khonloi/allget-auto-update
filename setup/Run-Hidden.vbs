' ==============================================================================
' Seamless Silent Launcher for AllGet Auto-Update
' ==============================================================================
' Why this file?
' Launching powershell.exe directly from Task Scheduler or shortcuts in Windows 10/11
' can cause a brief terminal window flash while .NET and user profiles load.
' Running this script via wscript.exe launches PowerShell with window state 0 (SW_HIDE)
' from the very first nanosecond of process creation, guaranteeing seamless console-less execution!

Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")
strParentDir = objFSO.GetParentFolderName(objFSO.GetParentFolderName(WScript.ScriptFullName))
strScriptPath = strParentDir & "\allget-autoupdate.ps1"

' 0 = SW_HIDE (Hides the window immediately and activates another window)
' False = Do not wait for script completion
objShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & strScriptPath & """", 0, False
