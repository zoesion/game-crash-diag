@echo off
chcp 65001 >nul
title BF6¼à¿ØÆ÷ - Ð¶ÔØ
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
pause
