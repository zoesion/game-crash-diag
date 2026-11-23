@echo off
chcp 65001 >nul
title GPU Watch - BF6 遥测记录（游戏期间勿关）
echo.
echo  ============================================
echo   战地6 GPU 遥测记录器
echo   保持本窗口开启，然后去启动游戏
echo   玩完回来按 Ctrl+C 停止
echo  ============================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gpu-watch.ps1" -IntervalSec 2
echo.
echo  已停止。日志在 logs\ 目录。
pause
