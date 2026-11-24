' GameCrashDiag - silent tray launcher for Windows startup.
' ASCII only, no BOM: VBScript does not accept a UTF-8 BOM.
' Uses window style 0 (hidden) so no console window ever flashes at logon.
Option Explicit
Dim sh, fso, base
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = base
sh.Run "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & base & "\GameCrashDiag.ps1"" -Tray -IntervalMs 500", 0, False
