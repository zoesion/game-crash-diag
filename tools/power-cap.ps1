<#
.SYNOPSIS
    GPU 功耗墙调节（战地6 稳定性缓解）

.DESCRIPTION
    通过 nvidia-smi 调整 GPU 的功耗上限。降低功耗墙可以：
      - 减小供电模块(VRM)的瞬态压力
      - 降低峰值功耗带来的电压跌落
      - 间接让核心频率更稳（减少大幅跳动）
    代价是帧数会略降（通常 5~10%），温度也会更低。

    本机实测：默认 150W，当前 161.93W（Dynamic Boost），上限 175W，下限 1W。

.PARAMETER Watts
    目标功耗上限（瓦）。建议 140~150。不填则只显示当前状态。

.PARAMETER Reset
    恢复成默认值。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\power-cap.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\power-cap.ps1 -Watts 145
    powershell -NoProfile -ExecutionPolicy Bypass -File .\power-cap.ps1 -Reset
#>
[CmdletBinding()]
param(
    [int]$Watts = 0,
    [switch]$Reset
)

$ErrorActionPreference = 'Continue'

function Show-Power {
    $q = & nvidia-smi --query-gpu=power.default_limit,power.max_limit,power.min_limit --format=csv,noheader,nounits 2>$null
    if (-not $q) { Write-Host '  读取失败（nvidia-smi 无响应）' -ForegroundColor Red; return }
    $p = "$q".Split(',')
    # 当前值只能从 -q 输出里解析（query 接口在笔记本上返回 N/A）
    $line = (& nvidia-smi -q -d POWER 2>$null | Select-String 'Current Power Limit' | Select-Object -First 1)
    $cur = 'N/A'
    if ($line -and $line.Line -match '([\d.]+)\s*W') { $cur = $matches[1] }
    Write-Host "  当前功耗墙 : $cur W" -ForegroundColor Cyan
    Write-Host "  默认/最大/最小 : $($p[0].Trim()) / $($p[1].Trim()) / $($p[2].Trim()) W" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  === GPU 功耗墙 ===' -ForegroundColor Cyan
Show-Power

if ($Reset) {
    $d = (& nvidia-smi --query-gpu=power.default_limit --format=csv,noheader,nounits 2>$null).Trim()
    Write-Host "`n  恢复默认: $d W" -ForegroundColor Yellow
    $r = & nvidia-smi -pl $d 2>&1
    Write-Host "  $r"
}
elseif ($Watts -gt 0) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "`n  需要管理员权限，正在请求 UAC..." -ForegroundColor Yellow
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Watts', $Watts)
        try { Start-Process powershell.exe -ArgumentList $args -Verb RunAs -Wait }
        catch { Write-Host "  提权失败: $($_.Exception.Message)" -ForegroundColor Red }
        exit
    }
    Write-Host "`n  设置功耗墙: $Watts W" -ForegroundColor Yellow
    $r = & nvidia-smi -pl $Watts 2>&1
    Write-Host "  $r"
    Write-Host ''
    Show-Power
    Write-Host "`n  注意: 重启后会恢复，需要重新设置。" -ForegroundColor DarkGray
}
else {
    Write-Host "`n  用法:" -ForegroundColor DarkGray
    Write-Host '    -Watts 145    设成 145W（缓解崩溃）' -ForegroundColor DarkGray
    Write-Host '    -Reset        恢复默认' -ForegroundColor DarkGray
}

Write-Host ''
