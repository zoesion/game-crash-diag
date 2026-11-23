<#
.SYNOPSIS
    BF6 崩溃自动抓取器 —— 游戏进程一消失，立刻归档崩溃现场

.DESCRIPTION
    后台每 2 秒检查一次 bf6.exe 是否还在。
    进程消失时自动生成一份报告，包含：
      - 退出时刻、本局时长
      - 崩溃前 60 条 GPU 遥测（从 gpu-watch 的 CSV 里读）
      - 最近 10 分钟的系统事件（nvlddmkm / Display / WHEA / Kernel-Power）
      - 最近 10 分钟的 bf6 应用崩溃事件
      - 最新的 WER 报告路径
    抓到一次后退出。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\crash-watch.ps1
#>
[CmdletBinding()]
param(
    [string]$ProcessName = 'bf6',
    [string]$WorkDir = ''
)

$ErrorActionPreference = 'Continue'
if ([string]::IsNullOrWhiteSpace($WorkDir)) { $WorkDir = Split-Path -Parent $PSCommandPath }
$logDir = Join-Path $WorkDir 'logs'
$repDir = Join-Path $WorkDir 'reports'
New-Item -ItemType Directory -Force -Path $logDir, $repDir | Out-Null

Write-Host ''
Write-Host '  崩溃抓取器已启动' -ForegroundColor Green
Write-Host "  监视进程: $ProcessName.exe   每 2 秒检查一次" -ForegroundColor DarkGray
Write-Host "  报告目录: $repDir" -ForegroundColor DarkGray
Write-Host ''

# 等待游戏启动
while (-not (Get-Process $ProcessName -ErrorAction SilentlyContinue)) {
    Start-Sleep -Seconds 3
}
$proc = Get-Process $ProcessName | Select-Object -First 1
$startTime = $proc.StartTime
Write-Host ("  [{0}] 检测到 {1}.exe 运行 (PID {2})" -f (Get-Date -Format 'HH:mm:ss'), $ProcessName, $proc.Id) -ForegroundColor Cyan

# 等待游戏退出
while (Get-Process $ProcessName -ErrorAction SilentlyContinue) {
    Start-Sleep -Seconds 2
}
$exitTime = Get-Date
$duration = $exitTime - $startTime

Write-Host ("  [{0}] 进程消失，开始抓取现场..." -f $exitTime.ToString('HH:mm:ss')) -ForegroundColor Yellow

$stamp = $exitTime.ToString('yyyyMMdd-HHmmss')
$report = Join-Path $repDir "crash-$stamp.txt"
$sb = New-Object System.Text.StringBuilder

function Add-Line($t) { [void]$sb.AppendLine($t) }

Add-Line ('=' * 70)
Add-Line "BF6 崩溃报告  $($exitTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Add-Line ('=' * 70)
Add-Line "进程开始 : $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Add-Line "进程退出 : $($exitTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Add-Line "游戏时长 : $([math]::Round($duration.TotalMinutes,1)) 分钟"
Add-Line "进程 PID : $($proc.Id)"
Add-Line ''

# --- GPU 遥测尾部 ---
Add-Line '--- GPU 遥测 (崩溃前最后 60 条) ---'
$csv = Get-ChildItem $logDir -Filter '*.csv' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($csv) {
    Add-Line "来源: $($csv.Name)"
    Get-Content $csv.FullName | Select-Object -Last 60 | ForEach-Object { Add-Line $_ }
}
else { Add-Line '(无遥测数据)' }
Add-Line ''

# --- 系统事件 ---
$since = $exitTime.AddMinutes(-10)
Add-Line '--- 最近 10 分钟 系统事件 ---'
foreach ($prov in 'nvlddmkm', 'Display', 'Microsoft-Windows-WHEA-Logger') {
    Add-Line "[$prov]"
    try {
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = $prov; StartTime = $since } -ErrorAction Stop |
            ForEach-Object {
                Add-Line ("  {0} Id={1} {2}" -f $_.TimeCreated.ToString('HH:mm:ss'), $_.Id,
                    ((@($_.Properties) | ForEach-Object { $_.Value }) -join ' | '))
            }
    }
    catch { Add-Line '  (无)' }
}
Add-Line ''

# --- 应用崩溃事件 ---
Add-Line '--- 最近 10 分钟 应用错误 ---'
try {
    Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1001; StartTime = $since } -ErrorAction Stop |
        ForEach-Object {
            Add-Line ("  {0} Id={1}" -f $_.TimeCreated.ToString('HH:mm:ss'), $_.Id)
            if ($_.Message) { Add-Line ('    ' + ($_.Message -replace '\s+', ' ')) }
        }
}
catch { Add-Line '  (无)' }
Add-Line ''

# --- WER ---
Add-Line '--- 最新 WER 报告 ---'
$wer = Get-ChildItem "$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive" -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'bf6' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($wer) { Add-Line "  $($wer.FullName)  ($($wer.LastWriteTime))" } else { Add-Line '  (无)' }

Add-Line ''
Add-Line '--- 系统状态快照 ---'
Add-Line (& nvidia-smi --query-gpu=driver_version,temperature.gpu --format=csv,noheader 2>&1)
Add-Line "HwSchMode = $((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -ErrorAction SilentlyContinue).HwSchMode)"
Add-Line "TdrDelay  = $((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name TdrDelay -ErrorAction SilentlyContinue).TdrDelay)"

$sb.ToString() | Set-Content -Path $report -Encoding UTF8
Write-Host ''
Write-Host "  报告已生成: $report" -ForegroundColor Green
Write-Host ''
