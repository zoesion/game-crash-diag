@echo off
title 游戏崩溃诊断器 - 安装
cd /d "%~dp0"

rem 从网络下载的文件会被打上"锁定"标记，先解除，避免各种安全提示
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
if errorlevel 1 (
  echo.
  echo 安装过程出现错误，请截图联系。
  pause
)