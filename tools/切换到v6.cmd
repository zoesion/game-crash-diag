@echo off
chcp 936 >nul
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ÇÐ»»°æ±¾.ps1" -To v6
pause
