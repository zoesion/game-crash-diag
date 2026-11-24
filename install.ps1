<#
exit 0
    $targets = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'GameCrashDiag\.ps1|BF6Monitor\.ps1' -and $_.ProcessId -ne $selfPid -and $_.ProcessId -ne $parentPid })
    foreach ($t in $targets) { Stop-Process -Id $t.ProcessId -Force -ErrorAction SilentlyContinue }
    # 等进程真正退出，否则文件句柄没释放，复制会失败
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $left = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'GameCrashDiag\.ps1|BF6Monitor\.ps1' -and $_.ProcessId -ne $selfPid -and $_.ProcessId -ne $parentPid })
        if ($left.Count -eq 0) { break }
        Start-Sleep -Milliseconds 300
    }
} catch {}
.SYNOPSIS
    游戏崩溃诊断器 安装脚本

.DESCRIPTION
    把程序安装到当前用户目录（不需要管理员权限），并创建快捷方式和卸载入口。
    安装位置：D:\Program Files\GameCrashDiag（可在安装时修改）
#>
[CmdletBinding()]
param(
    [string]$InstallDir = '',
    [switch]$Silent
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = 'D:\Program Files\GameCrashDiag'
}
$src = $PSScriptRoot

# 已经装过就先停掉正在跑的实例
try {
    $selfPid = $PID
    $parentPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue).ParentProcessId
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'GameCrashDiag\.ps1|BF6Monitor\.ps1' -and $_.ProcessId -ne $selfPid -and $_.ProcessId -ne $parentPid } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch {}

Write-Host ''
Write-Host '  ============================================' -ForegroundColor Cyan
Write-Host '   游戏崩溃诊断器  安装' -ForegroundColor Cyan
Write-Host '  ============================================' -ForegroundColor Cyan
Write-Host ''
function Copy-WithRetry {
    param($From, $To, [switch]$Recurse)
    for ($try = 1; $try -le 4; $try++) {
        try {
            if ($Recurse) { Copy-Item $From $To -Recurse -Force -ErrorAction Stop }
            else { Copy-Item $From $To -Force -ErrorAction Stop }
            return $true
        } catch {
            if ($try -eq 4) { Write-Host ("        跳过（被占用）: " + (Split-Path $From -Leaf)) -ForegroundColor DarkYellow; return $false }
            Start-Sleep -Milliseconds 800
        }
    }
}


# ── 1. 复制文件 ──
Write-Host '  [1/4] 复制程序文件...' -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
foreach ($sub in 'logs','reports','backup') {
    New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir $sub) | Out-Null
}
$files = @('GameCrashDiag.ps1','ChartRenderer.cs','启动诊断器.vbs','自启-托盘.vbs','调试启动.cmd','app.ico','README.md')
foreach ($f in $files) {
    $p = Join-Path $src $f
    if (Test-Path $p) { Copy-WithRetry $p $InstallDir | Out-Null }
}
$dataSrc = Join-Path $src 'data'
if (Test-Path $dataSrc) {
    Copy-WithRetry $dataSrc (Join-Path $InstallDir 'data') -Recurse | Out-Null
}
$langSrc = Join-Path $src 'lang'
if (Test-Path $langSrc) {
    Copy-WithRetry $langSrc (Join-Path $InstallDir 'lang') -Recurse | Out-Null
}
$toolSrc = Join-Path $src 'tools'
if (Test-Path $toolSrc) {
    Copy-WithRetry $toolSrc (Join-Path $InstallDir 'tools') -Recurse | Out-Null
}
$toolZip = Join-Path $src 'tools.zip'
if (Test-Path $toolZip) {
    Expand-Archive -Path $toolZip -DestinationPath $InstallDir -Force
}
# 卸载脚本也带一份
Copy-Item (Join-Path $src 'install.ps1') $InstallDir -Force -ErrorAction SilentlyContinue
if (Test-Path (Join-Path $src 'uninstall.ps1')) { Copy-Item (Join-Path $src 'uninstall.ps1') $InstallDir -Force }
Write-Host "        -> $InstallDir" -ForegroundColor Green

# ── 2. 快捷方式 ──
Write-Host '  [2/4] 创建快捷方式...' -ForegroundColor Yellow
$ws = New-Object -ComObject WScript.Shell
$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
$vbs = Join-Path $InstallDir '启动诊断器.vbs'
$icon = Join-Path $InstallDir 'app.ico'

function Get-AppVersion {
    try {
        $m = Select-String -Path (Join-Path $src 'GameCrashDiag.ps1') -Pattern "AppVersion = '([^']+)'" -ErrorAction Stop
        if ($m) { return $m.Matches[0].Groups[1].Value.TrimStart('v') }
    } catch {}
    return '1.0'
}

function New-Shortcut($lnkPath, $target, $arguments, $workdir, $iconPath, $desc) {
    $s = $ws.CreateShortcut($lnkPath)
    $s.TargetPath = $target
    $s.Arguments = $arguments
    $s.WorkingDirectory = $workdir
    if (Test-Path $iconPath) { $s.IconLocation = "$iconPath,0" }
    $s.Description = $desc
    $s.Save()
}

$desktop = [Environment]::GetFolderPath('Desktop')

# 先清掉历史版本留下的快捷方式（改名前的、重复的），保证桌面上只有一个
try {
    Get-ChildItem $desktop -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $sh = $ws.CreateShortcut($_.FullName)
            $all = "$($sh.TargetPath) $($sh.Arguments)"
            if ($all -match 'GameCrashDiag|BF6Monitor|启动诊断器|游戏崩溃诊断器') {
                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
} catch {}

New-Shortcut (Join-Path $desktop '游戏崩溃诊断器.lnk') $wscript "`"$vbs`"" $InstallDir $icon '战地6 GPU/CPU 监控与崩溃取证'

$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) '游戏崩溃诊断器'
New-Item -ItemType Directory -Force -Path $startMenu | Out-Null
New-Shortcut (Join-Path $startMenu '游戏崩溃诊断器.lnk') $wscript "`"$vbs`"" $InstallDir $icon '战地6 GPU/CPU 监控与崩溃取证'
New-Shortcut (Join-Path $startMenu '卸载 游戏崩溃诊断器.lnk') 'powershell.exe' `
    "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDir 'uninstall.ps1')`"" $InstallDir $icon '卸载 游戏崩溃诊断器'
Write-Host '        -> 桌面 + 开始菜单' -ForegroundColor Green

# ── 3. 卸载信息 ──
Write-Host '  [3/4] 注册卸载入口...' -ForegroundColor Yellow
$regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\GameCrashDiag'
New-Item -Path $regPath -Force | Out-Null
$size = (Get-ChildItem $InstallDir -Recurse -File | Measure-Object Length -Sum).Sum
$props = @{
    DisplayName     = '游戏崩溃诊断器'
    DisplayVersion  = (Get-AppVersion)
    Publisher       = '本地工具'
    InstallLocation = $InstallDir
    DisplayIcon     = $icon
    UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDir 'uninstall.ps1')`""
    NoModify        = 1
    NoRepair        = 1
}
foreach ($k in $props.Keys) { New-ItemProperty -Path $regPath -Name $k -Value $props[$k] -PropertyType String -Force | Out-Null }
New-ItemProperty -Path $regPath -Name 'EstimatedSize' -Value ([int]($size / 1KB)) -PropertyType DWord -Force | Out-Null
Write-Host '        -> 控制面板可见' -ForegroundColor Green

# ── 4. 完成 ──
Write-Host '  [4/4] 完成' -ForegroundColor Yellow
Write-Host ''
Write-Host '  安装完成！' -ForegroundColor Green
Write-Host "  位置: $InstallDir" -ForegroundColor Gray
Write-Host '  桌面和开始菜单都有快捷方式了。' -ForegroundColor Gray
Write-Host ''

if (-not $Silent) {
    $ans = Read-Host '  现在启动吗？(Y/n)'
    if ($ans -eq '' -or $ans -match '^[Yy]') {
        Start-Process $wscript -ArgumentList "`"$vbs`""
        Write-Host '  已启动。' -ForegroundColor Green
    }
}

exit 0
