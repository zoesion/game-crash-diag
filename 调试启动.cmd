@echo off
chcp 65001 >nul
title BF6 GPU 监控器 - 调试模式
echo.
echo  ==========================================
echo   BF6 GPU 监控器  (调试启动)
echo   会保留窗口显示错误信息
echo  ==========================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0BF6Monitor.ps1"
echo.
echo  程序已退出。
pause
