<#
.SYNOPSIS
    重新构建单文件安装程序（7-Zip SFX 自解压）

.DESCRIPTION
    需要本机安装 7-Zip（默认路径 D:\Program Files\7-Zip）。
    产物：游戏崩溃诊断器-安装程序.exe —— 双击即装到 D:\GameCrashDiag

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\构建安装程序.ps1
#>
param([string]$SevenZip = 'D:\Program Files\7-Zip\7z.exe')

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not (Test-Path $SevenZip)) { throw "找不到 7z.exe，请先安装 7-Zip 或用 -SevenZip 指定路径" }
$sfx = Join-Path (Split-Path $SevenZip) '7z.sfx'
if (-not (Test-Path $sfx)) { throw "找不到 7z.sfx" }

$stage = Join-Path $env:TEMP 'gcd-sfx-stage'
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$files = @(
    'GameCrashDiag.ps1', 'ChartRenderer.cs', '启动诊断器.vbs', '调试启动.cmd', 'app.ico',
    'README.md', 'LICENSE', 'install.ps1', 'uninstall.ps1', '安装.cmd', '卸载.cmd',
    '解除锁定.cmd', '推送到GitHub.cmd', '使用说明.txt', 'preview.png',
    '创建快捷方式.ps1', '创建桌面快捷方式.cmd'
)
foreach ($f in $files) {
    $p = Join-Path $root $f
    if (Test-Path $p) { Copy-Item $p $stage -Force }
}
Copy-Item (Join-Path $root 'tools') $stage -Recurse -Force

$setupCmd = "
@echo off
chcp 65001 >nul
title 游戏崩溃诊断器 - 安装
cd /d `"%~dp0`"
powershell -NoProfile -ExecutionPolicy Bypass -Command `"Get-ChildItem -LiteralPath '%~dp0' -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue`" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0install.ps1`" -Silent
if errorlevel 1 ( echo 安装失败 & pause & exit /b 1 )
start `"`" wscript.exe `"D:\GameCrashDiag\启动诊断器.vbs`"
timeout /t 3 >nul
"
[System.IO.File]::WriteAllText((Join-Path $stage 'setup.cmd'), $setupCmd, [System.Text.Encoding]::GetEncoding(936))

$config = @"
;!@Install@!UTF-8!
Title="GameCrashDiag Setup"
RunProgram="cmd /c setup.cmd"
GUIMode="1"
;!@InstallEnd@!
"@
$cfgPath = Join-Path $env:TEMP 'gcd-sfx-config.txt'
[System.IO.File]::WriteAllText($cfgPath, $config, [System.Text.Encoding]::UTF8)

$payload = Join-Path $env:TEMP 'gcd-sfx-payload.7z'
Remove-Item $payload -Force -ErrorAction SilentlyContinue
Push-Location $stage
& $SevenZip a -t7z -mx=9 $payload '*' | Out-Null
Pop-Location

$out = Join-Path $root '游戏崩溃诊断器-安装程序.exe'
Remove-Item $out -Force -ErrorAction SilentlyContinue
cmd /c "copy /b `"$sfx`" + `"$cfgPath`" + `"$payload`" `"$out`"" | Out-Null

Remove-Item $stage, $cfgPath, $payload -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "已生成: $out  ($([math]::Round((Get-Item $out).Length/1KB,1)) KB)" -ForegroundColor Green
