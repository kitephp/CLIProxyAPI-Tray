Dim shell, fso, path
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' Get the path to the .ps1 script in the same folder
path = fso.GetParentFolderName(WScript.ScriptFullName) & "\cli-proxy-api.ps1"

' Run PowerShell hidden (0), do not wait for return (False)
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & path & """", 0, False
