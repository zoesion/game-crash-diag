<#
.SYNOPSIS
    Battlefield 6 GPU 遥测记录器

.DESCRIPTION
    每 N 秒用 nvidia-smi 采样一次，写入 CSV。
    目的是抓到 GPU 挂死(DXGI_ERROR_DEVICE_HUNG / 0x887A0006)前最后几十秒的
    核心频率、温度、功耗、降频原因 —— 这些是判断"超频不稳 / 撞功耗墙 / 撞温度墙"
    的关键证据，事后无法补录。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\gpu-watch.ps1 -IntervalSec 2
#>
[CmdletBinding()]
param(
    [int]$IntervalSec = 2,
    [string]$OutDir = '',
    [string]$Tag = 'bf6'
)

$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path (Split-Path -Parent $PSCommandPath) 'logs'
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csv = Join-Path $OutDir "$Tag-$stamp.csv"

$fields = @(
    'temperature.gpu',
    'power.draw',
    'power.limit',
    'clocks.sm',
    'clocks.mem',
    'utilization.gpu',
    'utilization.memory',
    'memory.used',
    'pstate',
    'fan.speed',
    'clocks_event_reasons.active',
    'clocks_throttle_reasons.gpu_idle',
    'clocks_throttle_reasons.sw_power_cap',
    'clocks_throttle_reasons.hw_slowdown',
    'clocks_throttle_reasons.sw_thermal_slowdown',
    'clocks_throttle_reasons.hw_power_brake_slowdown'
)

'# BF6 GPU telemetry  started=' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "  interval=${IntervalSec}s  driver=" + ((& nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>$null) -join '') |
    Set-Content -Path $csv -Encoding UTF8
('time,' + ($fields -join ',')) | Add-Content -Path $csv -Encoding UTF8

Write-Host ''
Write-Host '  GPU 遥测已开始' -ForegroundColor Green
Write-Host "  文件 : $csv" -ForegroundColor Cyan
Write-Host "  频率 : 每 ${IntervalSec} 秒一次" -ForegroundColor DarkGray
Write-Host '  用法 : 保持此窗口开着，然后启动游戏；玩完按 Ctrl+C 停止。' -ForegroundColor DarkGray
Write-Host ''

$n = 0
$query = $fields -join ','
while ($true) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $line = & nvidia-smi --query-gpu=$query --format=csv,noheader,nounits 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($line)) {
        "$ts,SMI_READ_FAILED" | Add-Content -Path $csv -Encoding UTF8
    }
    else {
        "$ts," + ($line.Trim()) | Add-Content -Path $csv -Encoding UTF8
    }
    $n++
    if ($n % 30 -eq 0) {
        Write-Host ("  [{0}] 已记录 {1} 条" -f (Get-Date -Format 'HH:mm:ss'), $n) -ForegroundColor DarkGray
    }
    Start-Sleep -Seconds $IntervalSec
}
