@echo off
chcp 65001 >nul
title 创建桌面快捷方式
cd /d "%~dp0"
echo.
echo  正在为「游戏崩溃诊断器」创建桌面快捷方式...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0创建快捷方式.ps1"
if errorlevel 1 (
  echo.
  echo  创建失败，请确认本文件与 启动诊断器.vbs 在同一目录。
  pause
  exit /b 1
)
timeout /t 3 >nul
