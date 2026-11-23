' BF6 GPU 监控器 - 静默启动（不弹黑框）
Option Explicit
Dim sh, base
Set sh = CreateObject("WScript.Shell")
base = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
sh.CurrentDirectory = base
sh.Run "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & base & "BF6Monitor.ps1""", 0, False
