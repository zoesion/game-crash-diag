<#
.SYNOPSIS
    Battlefield 6 驱动崩溃 —— 系统级缓解措施一键应用（需要管理员/UAC）

.DESCRIPTION
    应用以下改动，全部会先备份：
      1. 关闭硬件加速 GPU 计划   HwSchMode = 1
      2. 放宽 TDR 超时           TdrDelay = 10, TdrDdiDelay = 10
      3. 重置 Afterburner 超频   备份 profile 并清空 CoreClkBoost / VFCurve / MemClkBoost
      4. (可选) 清空 NVIDIA 着色器缓存

    改完必须重启才生效。

.PARAMETER DryRun
    只显示将要做什么，不真正修改。

.PARAMETER SkipHags
    跳过关闭 HAGS。

.PARAMETER SkipTdr
    跳过修改 TdrDelay。

.PARAMETER SkipAfterburner
    跳过重置 Afterburner。

.PARAMETER ClearCache
    同时清空 NVIDIA DXCache / D3DSCache（清完首次进游戏会有编译卡顿）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\apply-fixes.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipHags,
    [switch]$SkipTdr,
    [switch]$SkipAfterburner,
    [switch]$ClearCache
)

$ErrorActionPreference = 'Stop'

# ---------- 提权检查 ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) {
    Write-Host ''
    Write-Host '  需要管理员权限，正在请求 UAC 提权...' -ForegroundColor Yellow
    Write-Host '  (屏幕上会弹出「用户账户控制」窗口，请点「是」)' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($DryRun) { $argList += '-DryRun' }
    if ($SkipHags) { $argList += '-SkipHags' }
    if ($SkipTdr) { $argList += '-SkipTdr' }
    if ($SkipAfterburner) { $argList += '-SkipAfterburner' }
    if ($ClearCache) { $argList += '-ClearCache' }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait
    }
    catch {
        Write-Host "  提权失败或被取消: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    exit 0
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path (Split-Path -Parent $PSCommandPath) "backup\$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null

Write-Host ''
Write-Host '  ================================================' -ForegroundColor Cyan
Write-Host '   战地6 GPU 崩溃缓解措施' -ForegroundColor Cyan
if ($DryRun) { Write-Host '   [演练模式] 不会修改任何东西' -ForegroundColor Yellow }
Write-Host "   备份目录: $backup" -ForegroundColor DarkGray
Write-Host '  ================================================' -ForegroundColor Cyan
Write-Host ''

$changed = @()

# ---------- 1. HAGS ----------
if (-not $SkipHags) {
    $gd = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    $cur = (Get-ItemProperty -Path $gd -Name 'HwSchMode' -ErrorAction SilentlyContinue).HwSchMode
    Write-Host ("  [1] HAGS (硬件加速GPU计划): 当前 = " + $(if ($null -eq $cur) { '<未设置>' } else { "$cur ($(if($cur -eq 2){'开启'}else{'关闭'}))" }))
    if (-not $DryRun) {
        reg export 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' (Join-Path $backup 'GraphicsDrivers.reg') /y | Out-Null
        Set-ItemProperty -Path $gd -Name 'HwSchMode' -Value 1 -Type DWord
        $changed += 'HwSchMode -> 1 (HAGS 关闭)'
        Write-Host '      -> 已设为 1 (关闭)' -ForegroundColor Green
    }
}

# ---------- 2. TDR ----------
if (-not $SkipTdr) {
    $gd = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    $t1 = (Get-ItemProperty -Path $gd -Name 'TdrDelay' -ErrorAction SilentlyContinue).TdrDelay
    Write-Host ("  [2] TdrDelay: 当前 = " + $(if ($null -eq $t1) { '<未设置，默认 2 秒>' } else { "$t1 秒" }))
    if (-not $DryRun) {
        if (-not (Test-Path (Join-Path $backup 'GraphicsDrivers.reg'))) {
            reg export 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' (Join-Path $backup 'GraphicsDrivers.reg') /y | Out-Null
        }
        Set-ItemProperty -Path $gd -Name 'TdrDelay' -Value 10 -Type DWord
        Set-ItemProperty -Path $gd -Name 'TdrDdiDelay' -Value 10 -Type DWord
        $changed += 'TdrDelay/TdrDdiDelay -> 10 秒'
        Write-Host '      -> 已设为 10 秒（给驱动更多恢复时间，减少"设备已移除"）' -ForegroundColor Green
    }
}

# ---------- 3. Afterburner ----------
if (-not $SkipAfterburner) {
    $ab = 'C:\Program Files (x86)\MSI Afterburner\Profiles'
    Write-Host '  [3] Afterburner 超频'
    if (Get-Process 'MSIAfterburner' -ErrorAction SilentlyContinue) {
        Write-Host '      -> Afterburner 正在运行，请先退出它（否则它退出时会覆盖配置文件）' -ForegroundColor Yellow
    }
    if (Test-Path $ab) {
        $gpuCfg = Get-ChildItem $ab -Filter 'VEN_10DE*.cfg' -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 1
        if (-not $gpuCfg) { $gpuCfg = Get-ChildItem $ab -Filter 'VEN_*.cfg' -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 1 }
        if ($gpuCfg) {
            $raw = Get-Content $gpuCfg.FullName
            $curStartup = ($raw | Select-String -Pattern '^CoreClkBoost=' | Select-Object -First 1).Line
            Write-Host "      -> profile: $($gpuCfg.Name)"
            if (-not $DryRun) {
                $abBackup = Join-Path $backup 'afterburner'
                New-Item -ItemType Directory -Force -Path $abBackup | Out-Null
                Copy-Item (Join-Path $ab '*.cfg') $abBackup -Force -ErrorAction SilentlyContinue

                # 只改 [Startup] 段：保证开机/启动后是原厂频率
                $inStartup = $false
                $new = foreach ($ln in $raw) {
                    if ($ln -match '^\[') { $inStartup = ($ln -match '^\[Startup\]') }
                    if ($inStartup -and $ln -match '^CoreClkBoost=') { 'CoreClkBoost=0'; continue }
                    if ($inStartup -and $ln -match '^MemClkBoost=') { 'MemClkBoost=0'; continue }
                    if ($inStartup -and $ln -match '^VFCurve=') { 'VFCurve='; continue }
                    $ln
                }
                Set-Content -Path $gpuCfg.FullName -Value $new -Encoding ASCII
                $changed += "Afterburner [Startup] 段已归零 ($($gpuCfg.Name))"
                Write-Host '      -> [Startup] 段已设为 0（[Defaults]/[ProfileN] 保持原样，已备份）' -ForegroundColor Green
            }
            else { Write-Host "      -> 将把 [Startup] 段的 CoreClkBoost/MemClkBoost 清零、VFCurve 清空" }
        }
        else { Write-Host '      -> 没找到显卡 profile，跳过' -ForegroundColor Yellow }
    }
    else { Write-Host '      -> 未安装 MSI Afterburner，跳过' -ForegroundColor DarkGray }
}

# ---------- 4. 着色器缓存 ----------
if ($ClearCache) {
    Write-Host '  [4] 清空着色器缓存'
    foreach ($p in @("$env:LOCALAPPDATA\NVIDIA\DXCache", "$env:LOCALAPPDATA\NVIDIA\GLCache", "$env:LOCALAPPDATA\D3DSCache")) {
        if (Test-Path $p) {
            $sz = ((Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB)
            if (-not $DryRun) {
                Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                $changed += "已清空 $p ($([math]::Round($sz)) MB)"
                Write-Host ("      -> $p  ($([math]::Round($sz)) MB 已清)" ) -ForegroundColor Green
            }
            else { Write-Host ("      将清空 $p ($([math]::Round($sz)) MB)") }
        }
    }
}

# ---------- 汇总 ----------
Write-Host ''
Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray
if ($DryRun) {
    Write-Host '  演练结束，未做任何修改。去掉 -DryRun 即可真正执行。' -ForegroundColor Yellow
}
elseif ($changed.Count -eq 0) {
    Write-Host '  没有需要修改的项目。' -ForegroundColor DarkGray
}
else {
    Write-Host '  已完成:' -ForegroundColor Green
    $changed | ForEach-Object { Write-Host "    - $_" -ForegroundColor Gray }
    Write-Host ''
    Write-Host '  *** 需要重启电脑才生效 ***' -ForegroundColor Yellow
    Write-Host '  备份在: ' + $backup -ForegroundColor DarkGray
}
Write-Host ''
