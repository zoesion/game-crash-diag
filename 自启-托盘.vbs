' GameCrashDiag - silent tray launcher for Windows startup.
' ASCII only, no BOM: VBScript does not accept a UTF-8 BOM.
' Uses window style 0 (hidden) so no console window ever flashes at logon.
' If the main script is missing (e.g. the app was uninstalled), exit quietly
' instead of showing a "script file not found" dialog.
Option Explicit
Dim sh, fso, base, target
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
target = base & "\GameCrashDiag.ps1"
If Not fso.FileExists(target) Then WScript.Quit 0
sh.CurrentDirectory = base
sh.Run "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & target & """ -Tray -IntervalMs 500", 0, False
