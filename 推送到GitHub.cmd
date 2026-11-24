@echo off
title 推送到 GitHub - 游戏崩溃诊断器
cd /d "%~dp0"

echo.
echo  ============================================
echo    游戏崩溃诊断器 GameCrashDiag
echo    推送到 GitHub
echo  ============================================
echo.

where git >nul 2>&1
if errorlevel 1 (
  echo  [错误] 没找到 git，请先安装 Git for Windows
  pause
  exit /b 1
)

git remote get-url github >nul 2>&1
if not errorlevel 1 goto do_push

echo  第一次使用，需要配置你的 GitHub 仓库
echo.
set /p GHUSER=  请输入你的 GitHub 用户名:
if "%GHUSER%"=="" (
  echo  [错误] 用户名不能为空
  pause
  exit /b 1
)
git remote add github https://github.com/%GHUSER%/game-crash-diag.git
echo.
echo  已添加远程仓库: https://github.com/%GHUSER%/game-crash-diag.git
echo  提示: 请先在 GitHub 网页上创建同名空仓库（不要勾选 README）
echo.

:do_push
echo  === 正在推送 ===
git push -u github main
if errorlevel 1 (
  echo.
  echo  [失败] 推送没有成功，常见原因:
  echo    1. GitHub 上还没创建 game-crash-diag 这个仓库
  echo    2. 首次推送需要在弹出的浏览器窗口里登录 GitHub 授权
  echo    3. 网络访问 github.com 不通
  echo.
  pause
  exit /b 1
)

echo.
echo  ============================================
echo    推送成功！
echo    仓库地址: github.com 上查看 game-crash-diag
echo  ============================================
echo.
pause
