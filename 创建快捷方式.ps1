$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$vbs = Join-Path $root '启动诊断器.vbs'
$icon = Join-Path $root 'app.ico'

if (-not (Test-Path $vbs)) { throw "找不到 启动诊断器.vbs，请把本脚本放在程序目录里运行" }

$ws = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop '游戏崩溃诊断器.lnk'

# 先清掉指向旧位置的同名/同类快捷方式，避免出现多个
Get-ChildItem $desktop -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $sh = $ws.CreateShortcut($_.FullName)
        $all = "$($sh.TargetPath) $($sh.Arguments)"
        if ($all -match 'GameCrashDiag|BF6Monitor|启动诊断器|游戏崩溃诊断器') {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

$s = $ws.CreateShortcut($lnkPath)
$s.TargetPath = "$env:WINDIR\System32\wscript.exe"
$s.Arguments = "`"$vbs`""
$s.WorkingDirectory = $root
if (Test-Path $icon) { $s.IconLocation = "$icon,0" }
$s.Description = '游戏崩溃诊断器 - GPU/CPU 监控与崩溃取证'
$s.Save()

Write-Host ''
Write-Host '  已创建桌面快捷方式：游戏崩溃诊断器' -ForegroundColor Green
Write-Host "  指向：$vbs" -ForegroundColor DarkGray
Write-Host ''
