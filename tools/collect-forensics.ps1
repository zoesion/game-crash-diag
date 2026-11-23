<#
.SYNOPSIS
    Battlefield 6 崩溃取证包收集器

.DESCRIPTION
    一条命令把定位 BF6 驱动崩溃所需的全部证据抓到一个文件夹并打包成 zip：
      - 显卡/驱动/系统信息、整机型号、BIOS、电池健康
      - nvlddmkm(事件 13/153/14)、Display、Kernel-PnP 等系统事件
      - 应用错误事件(bf6.exe)、WER 报告
      - 现有的崩溃转储、LocalDumps 配置
      - Afterburner 超频配置、HAGS/TdrDelay 注册表值
      - GPU 驱动崩溃前的 nvidia-smi 完整快照

    纯只读，不修改任何系统设置。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\collect-forensics.ps1
#>
[CmdletBinding()]
param(
    [int]$Days = 30,
    [string]$OutRoot = ''
)

$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($OutRoot)) {
    $OutRoot = Join-Path (Split-Path -Parent $PSCommandPath) 'forensics'
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $OutRoot "bf6-evidence-$stamp"
New-Item -ItemType Directory -Force -Path $out | Out-Null

function Step($msg) { Write-Host ("  -> " + $msg) -ForegroundColor DarkGray }

Write-Host ''
Write-Host '  收集 BF6 崩溃证据...' -ForegroundColor Cyan
Write-Host "  输出: $out" -ForegroundColor DarkGray
Write-Host ''

# ---------- 1. GPU / 驱动 ----------
Step 'GPU 与驱动信息'
& nvidia-smi --query-gpu=name,driver_version,vbios_version,memory.total,power.limit,power.max_limit,temperature.gpu,pstate --format=csv 2>&1 |
    Set-Content (Join-Path $out '01-gpu-summary.txt') -Encoding UTF8
& nvidia-smi -q 2>&1 | Set-Content (Join-Path $out '02-nvidia-smi-full.txt') -Encoding UTF8

# ---------- 2. 系统信息 ----------
Step '系统与硬件信息'
$sys = [ordered]@{
    ComputerName   = $env:COMPUTERNAME
    OS             = (Get-CimInstance Win32_OperatingSystem).Caption
    Version        = (Get-CimInstance Win32_OperatingSystem).Version
    Build          = (Get-CimInstance Win32_OperatingSystem).BuildNumber
    LastBoot       = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    Model          = (Get-CimInstance Win32_ComputerSystem).Model
    Manufacturer   = (Get-CimInstance Win32_ComputerSystem).Manufacturer
    BIOS           = (Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion
    BIOSDate       = (Get-CimInstance Win32_BIOS).ReleaseDate
    CPU            = (Get-CimInstance Win32_Processor).Name
    RAM_GB         = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    CollectedAt    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
}
$sys.GetEnumerator() | ForEach-Object { "{0,-15} : {1}" -f $_.Key, $_.Value } |
    Set-Content (Join-Path $out '03-system.txt') -Encoding UTF8

Step '电池健康 (笔记本降频相关)'
try {
    $bat = Get-CimInstance Win32_Battery -ErrorAction Stop
    if ($bat) {
        "Win32_Battery: {0}" -f ($bat | Select-Object -First 1 | ForEach-Object { "Status=$($_.BatteryStatus) 设计电压=$($_.DesignVoltage)" }) |
            Set-Content (Join-Path $out '04-battery.txt') -Encoding UTF8
    }
    Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue |
        Select-Object DesignedCapacity, DeviceName | Format-List |
        Out-File (Join-Path $out '04-battery.txt') -Append -Encoding UTF8
    Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue |
        Select-Object FullChargedCapacity | Format-List |
        Out-File (Join-Path $out '04-battery.txt') -Append -Encoding UTF8
    if (-not (Test-Path (Join-Path $out '04-battery.txt'))) {
        '本机未暴露电池 WMI 数据' | Set-Content (Join-Path $out '04-battery.txt') -Encoding UTF8
    }
}
catch { "电池信息读取失败: $($_.Exception.Message)" | Set-Content (Join-Path $out '04-battery.txt') -Encoding UTF8 }

# ---------- 3. 关键注册表 ----------
Step 'HAGS / TDR / 转储配置'
$gd = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
$reg = [ordered]@{}
foreach ($n in 'HwSchMode', 'TdrDelay', 'TdrDdiDelay', 'TdrLevel') {
    $v = (Get-ItemProperty -Path $gd -Name $n -ErrorAction SilentlyContinue).$n
    $reg[$n] = if ($null -eq $v) { '<未设置/' + "默认" + '>' } else { $v }
}
$reg.GetEnumerator() | ForEach-Object { "{0,-14} = {1}" -f $_.Key, $_.Value } |
    Set-Content (Join-Path $out '05-registry.txt') -Encoding UTF8
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps' -ErrorAction SilentlyContinue |
    ForEach-Object {
        "[" + $_.PSChildName + "]"
        Get-ItemProperty $_.PSPath | Select-Object DumpFolder, DumpType, DumpCount | Format-List | Out-String
    } | Add-Content (Join-Path $out '05-registry.txt') -Encoding UTF8

# ---------- 4. 事件日志 ----------
Step "系统事件日志 (最近 $Days 天)"
$since = (Get-Date).AddDays(-$Days)
foreach ($p in 'nvlddmkm', 'Display', 'Kernel-PnP') {
    try {
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = $p; StartTime = $since } -ErrorAction Stop |
            Select-Object TimeCreated, Id, LevelDisplayName,
                @{n = 'Props'; e = { (@($_.Properties) | ForEach-Object { $_.Value }) -join ' | ' } },
                @{n = 'Msg'; e = { if ($_.Message) { ($_.Message -replace '\s+', ' ') } else { '' } } } |
            Export-Csv (Join-Path $out "06-event-$p.csv") -NoTypeInformation -Encoding UTF8
    }
    catch { "无 $p 事件" | Set-Content (Join-Path $out "06-event-$p.csv") -Encoding UTF8 }
}

Step '应用崩溃事件 (bf6.exe)'
try {
    Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000; StartTime = $since } -ErrorAction Stop |
        Where-Object { $_.Message -match 'bf6\.exe' } |
        Select-Object TimeCreated, Id,
            @{n = 'Props'; e = { (@($_.Properties) | ForEach-Object { $_.Value }) -join ' | ' } },
            @{n = 'Msg'; e = { ($_.Message -replace '\s+', ' ') } } |
        Export-Csv (Join-Path $out '07-bf6-appcrash.csv') -NoTypeInformation -Encoding UTF8
}
catch { "无 bf6 崩溃事件" | Set-Content (Join-Path $out '07-bf6-appcrash.csv') -Encoding UTF8 }

# ---------- 5. WER 报告 ----------
Step 'WER 报告'
$werOut = Join-Path $out '08-wer'
New-Item -ItemType Directory -Force -Path $werOut | Out-Null
foreach ($w in @("$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive")) {
    if (Test-Path $w) {
        Get-ChildItem $w -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'bf6|Battlefield' } |
            Select-Object -First 40 |
            ForEach-Object {
                $dst = Join-Path $werOut $_.Name
                New-Item -ItemType Directory -Force -Path $dst | Out-Null
                Copy-Item (Join-Path $_.FullName '*') $dst -Recurse -Force -ErrorAction SilentlyContinue
                foreach ($f in Get-ChildItem $_.FullName -Filter '*.dmp' -ErrorAction SilentlyContinue) {
                    Remove-Item (Join-Path $dst $f.Name) -Force -ErrorAction SilentlyContinue
                }
            }
    }
}

# ---------- 6. 转储 ----------
Step '现有崩溃转储'
$dumpOut = Join-Path $out '09-dumps'
New-Item -ItemType Directory -Force -Path $dumpOut | Out-Null
($env:LOCALAPPDATA + '\CrashDumps'), 'C:\ProgramData\NVIDIA Corporation\CrashDumps' |
    Where-Object { Test-Path $_ } |
    ForEach-Object {
        Get-ChildItem $_ -Filter '*.dmp' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 10 |
            ForEach-Object {
                "  $($_.LastWriteTime)  $([math]::Round($_.Length/1MB,1)) MB  $($_.Name)" |
                    Add-Content (Join-Path $out '09-dump-index.txt') -Encoding UTF8
            }
    }

# ---------- 7. 超频配置 ----------
Step 'Afterburner 超频配置'
$ab = 'C:\Program Files (x86)\MSI Afterburner\Profiles'
$abOut = Join-Path $out '10-afterburner'
if (Test-Path $ab) {
    New-Item -ItemType Directory -Force -Path $abOut | Out-Null
    Copy-Item (Join-Path $ab '*.cfg') $abOut -Force -ErrorAction SilentlyContinue
}
else { '未安装 MSI Afterburner' | Set-Content (Join-Path $out '10-afterburner.txt') -Encoding UTF8 }

# ---------- 8. 游戏版本 ----------
Step '游戏版本'
$g = 'D:\Program Files (x86)\Steam\steamapps\common\Battlefield 6'
if (Test-Path $g) {
    Get-ChildItem $g -Filter '*.exe' -ErrorAction SilentlyContinue |
        Select-Object Name, Length, LastWriteTime, @{n = 'Version'; e = { $_.VersionInfo.FileVersion } } |
        Format-Table -AutoSize | Out-String | Set-Content (Join-Path $out '11-game.txt') -Encoding UTF8
}

# ---------- 9. 打包 ----------
Step '打包 zip'
$zip = Join-Path $OutRoot "bf6-evidence-$stamp.zip"
try {
    Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip -Force
    Write-Host ''
    Write-Host "  完成: $zip" -ForegroundColor Green
    Write-Host ("  大小: {0:N1} MB" -f ((Get-Item $zip).Length / 1MB)) -ForegroundColor DarkGray
}
catch {
    Write-Host "  打包失败(不影响原始文件): $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  原始目录: $out" -ForegroundColor DarkGray
}
