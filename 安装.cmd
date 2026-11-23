@echo off
chcp 65001 >nul
title BF6监控器 - 安装
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
if errorlevel 1 (
  echo.
  echo 安装过程出现错误，请截图联系。
  pause
)
