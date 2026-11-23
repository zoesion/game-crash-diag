<#
.SYNOPSIS
    BF6监控器 卸载脚本
.DESCRIPTION
    删除程序文件和快捷方式，保留 logs / reports / backup 三个数据目录。
#>
[CmdletBinding()]
param([switch]$Silent)

$ErrorActionPreference = 'Continue'
$InstallDir = if ($PSScriptRoot) { $PSScriptRoot } else { Join-Path $env:LOCALAPPDATA 'Programs\BF6Monitor' }

if (-not $Silent) {
    Write-Host ''
    Write-Host '  卸载 BF6监控器' -ForegroundColor Yellow
    Write-Host "  位置: $InstallDir" -ForegroundColor Gray
    $ans = Read-Host '  确定卸载吗？(y/N)'
    if ($ans -notmatch '^[Yy]') { Write-Host '  已取消。'; exit 0 }
}

# 停掉正在运行的实例
try {
    $selfPid = $PID
    $parentPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue).ParentProcessId
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'BF6Monitor\.ps1' -and $_.ProcessId -ne $selfPid -and $_.ProcessId -ne $parentPid } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch {}

# 快捷方式
Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) 'BF6监控器.lnk') -Force -ErrorAction SilentlyContinue
$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'BF6监控器'
Remove-Item $startMenu -Recurse -Force -ErrorAction SilentlyContinue

# 注册表
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\BF6Monitor' -Recurse -Force -ErrorAction SilentlyContinue

# 程序文件（保留数据目录）
$keep = @('logs', 'reports', 'backup')
foreach ($f in Get-ChildItem $InstallDir -File -ErrorAction SilentlyContinue) {
    Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
}
foreach ($d in Get-ChildItem $InstallDir -Directory -ErrorAction SilentlyContinue) {
    if ($keep -notcontains $d.Name.ToLower()) {
        Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}
# 如果数据目录也是空的，一并删掉
$leftover = Get-ChildItem $InstallDir -Recurse -ErrorAction SilentlyContinue
if (-not $leftover) { Remove-Item $InstallDir -Force -ErrorAction SilentlyContinue }

if (-not $Silent) {
    Write-Host ''
    Write-Host '  已卸载。' -ForegroundColor Green
    Write-Host "  日志和报告保留在: $InstallDir" -ForegroundColor Gray
    Write-Host ''
}
