Option Explicit
Dim sh, fs, folder, command
Set sh = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
folder = fs.GetParentFolderName(WScript.ScriptFullName)
command = """" & sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & folder & "\Launcher.ps1"""
sh.Run command, 0, False
