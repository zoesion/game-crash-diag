' BF6 Monitor - silent launcher (ASCII only, no BOM: VBScript does not accept UTF-8 BOM)
Option Explicit
Dim sh, base
Set sh = CreateObject("WScript.Shell")
base = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
sh.CurrentDirectory = base
sh.Run "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & base & "BF6Monitor.ps1"" -IntervalMs 500", 0, False
