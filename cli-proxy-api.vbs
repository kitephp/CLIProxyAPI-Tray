Option Explicit

Dim shell, fso, scriptDir, psScript, hostPath, commandLine

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psScript = fso.BuildPath(scriptDir, "cli-proxy-api.ps1")

If WScript.Arguments.Count > 0 Then
    hostPath = WScript.Arguments(0)
Else
    hostPath = ResolvePowerShellHost()
End If

If Not fso.FileExists(hostPath) Then
    hostPath = ResolvePowerShellHost()
End If

If Not fso.FileExists(psScript) Then
    WScript.Quit 1
End If

commandLine = Quote(hostPath) & " -STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " & Quote(psScript)
shell.Run commandLine, 0, False

Function ResolvePowerShellHost()
    Dim candidate

    candidate = FindOnPath("pwsh.exe")
    If candidate <> "" Then
        ResolvePowerShellHost = candidate
        Exit Function
    End If

    candidate = shell.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
    If fso.FileExists(candidate) Then
        ResolvePowerShellHost = candidate
        Exit Function
    End If

    candidate = shell.ExpandEnvironmentStrings("%ProgramFiles(x86)%") & "\PowerShell\7\pwsh.exe"
    If fso.FileExists(candidate) Then
        ResolvePowerShellHost = candidate
        Exit Function
    End If

    ResolvePowerShellHost = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
End Function

Function FindOnPath(exeName)
    Dim paths, item, candidate

    paths = Split(shell.ExpandEnvironmentStrings("%PATH%"), ";")
    For Each item In paths
        If Len(Trim(item)) > 0 Then
            candidate = fso.BuildPath(Trim(item), exeName)
            If fso.FileExists(candidate) Then
                FindOnPath = candidate
                Exit Function
            End If
        End If
    Next

    FindOnPath = ""
End Function

Function Quote(value)
    Quote = """" & Replace(value, """", """""") & """"
End Function
