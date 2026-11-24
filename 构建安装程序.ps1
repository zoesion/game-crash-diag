<#
.SYNOPSIS
    重新构建单文件安装程序（自解压 EXE）

.DESCRIPTION
    用 .NET 自带的 csc.exe 把 setup\Setup.cs 编译成 winexe，
    把整个程序目录压成 app.zip 作为内嵌资源打进去。

    产物：游戏崩溃诊断器-安装程序.exe
    双击后：解压到 %LOCALAPPDATA%\GameCrashDiag\setup → 静默安装到 D:\Program\GameCrashDiag → 弹出完成提示

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\构建安装程序.ps1
#>
param(
    [string]$Csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not (Test-Path $Csc)) { throw "找不到 csc.exe: $Csc" }

$setupDir = Join-Path $root 'setup'
$cs = Join-Path $setupDir 'Setup.cs'
if (-not (Test-Path $cs)) { throw "找不到 setup\Setup.cs" }

# 1) 打包资源
$payload = Join-Path $setupDir 'app.zip'
Remove-Item $payload -Force -ErrorAction SilentlyContinue
$items = @()
foreach ($f in 'GameCrashDiag.ps1', 'ChartRenderer.cs', '启动诊断器.vbs', '调试启动.cmd', 'app.ico',
               'README.md', 'LICENSE', 'install.ps1', 'uninstall.ps1', '安装.cmd', '卸载.cmd',
               '解除锁定.cmd', '推送到GitHub.cmd', '使用说明.txt', 'preview.png',
               '创建快捷方式.ps1', '创建桌面快捷方式.cmd') {
    $p = Join-Path $root $f
    if (Test-Path $p) { $items += $p }
}
$items += (Join-Path $root 'tools')
Compress-Archive -Path $items -DestinationPath $payload -Force
Write-Host "内嵌资源: app.zip  $([math]::Round((Get-Item $payload).Length / 1KB, 1)) KB"

# 2) 编译
$out = Join-Path $root '游戏崩溃诊断器-安装程序.exe'
Remove-Item $out -Force -ErrorAction SilentlyContinue
$refs = @('/r:System.dll', '/r:System.Core.dll', '/r:System.Drawing.dll', '/r:System.Windows.Forms.dll',
          '/r:System.IO.Compression.dll', '/r:System.IO.Compression.FileSystem.dll')
& $Csc /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 `
    "/win32icon:$root\app.ico" "/resource:$payload,app.zip" "/out:$out" @refs $cs
if (-not (Test-Path $out)) { throw "编译失败" }

Write-Host "已生成: $out  ($([math]::Round((Get-Item $out).Length / 1KB, 1)) KB)" -ForegroundColor Green
