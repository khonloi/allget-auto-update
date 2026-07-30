' ==============================================================================
' Test Script: Seamless Silent Launcher for Test-WinUIDialog.ps1
' ==============================================================================
' Double-click this script or run it via wscript.exe to verify that the WinUI
' preview dialog opens with seamless console-less execution!

Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")
strScriptPath = objFSO.GetParentFolderName(WScript.ScriptFullName) & "\Test-WinUIDialog.ps1"

objShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & strScriptPath & """", 0, False
