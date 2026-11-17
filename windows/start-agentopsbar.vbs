Set fso = CreateObject("Scripting.FileSystemObject")
Set WshShell = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
appPath = fso.BuildPath(scriptDir, "agentopsbar.py")
WshShell.Run "pythonw.exe """ & appPath & """", 0, False
