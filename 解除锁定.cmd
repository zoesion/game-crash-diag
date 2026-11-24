@echo off
title 解除文件锁定
cd /d "%~dp0"
echo.
echo  正在解除本文件夹所有文件的"网络下载"锁定标记...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$n=0; Get-ChildItem -LiteralPath '%~dp0' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { try { Unblock-File -LiteralPath $_.FullName -ErrorAction Stop; $n++ } catch {} }; Write-Host ('  已处理 ' + $n + ' 个文件')"
echo.
echo  完成。现在可以双击「安装.cmd」了。
echo.
pause