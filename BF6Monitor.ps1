<#
.SYNOPSIS
    BF6 GPU 监控器 —— 战地6 崩溃取证工具（图形界面版）

.DESCRIPTION
    实时显示 GPU 温度/功耗/频率/占用/降频原因，并自动把数据记成 CSV。
    检测到 bf6.exe 运行时自动开始记录，游戏退出（崩溃）时自动生成崩溃报告。

.PARAMETER SelfTest
    无界面自检：采样 3 次并写一条测试记录后退出，用于验证环境。

.EXAMPLE
    双击「启动监控器.vbs」
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$UiTest,
    [string]$Shot = '',
    [int]$FillPoints = 0,
    [switch]$Minimized,
    [int]$IntervalMs = 1000,
    [switch]$ForceLog,
    [switch]$ForceGeneric
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 绘图核心编译（C#，避免 PowerShell 逐点解释）
$csPath = Join-Path (Split-Path -Parent $PSCommandPath) 'ChartRenderer.cs'
if (Test-Path $csPath) {
    if (-not ('ChartRenderer' -as [type])) {
        Add-Type -TypeDefinition (Get-Content -Raw -Encoding UTF8 $csPath) -ReferencedAssemblies 'System.Drawing'
    }
}

$Root    = Split-Path -Parent $PSCommandPath
$LogDir  = Join-Path $Root 'logs'
$RepDir  = Join-Path $Root 'reports'
foreach ($d in @($LogDir, $RepDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# ════════════════════════════════ 数据采集 ════════════════════════════════
$Fields = @(
    'temperature.gpu', 'power.draw', 'clocks.sm', 'clocks.mem',
    'utilization.gpu', 'utilization.memory', 'memory.used', 'memory.total',
    'pstate', 'clocks_event_reasons.active',
    'clocks_throttle_reasons.sw_power_cap',
    'clocks_throttle_reasons.hw_slowdown',
    'clocks_throttle_reasons.sw_thermal_slowdown'
)

function Convert-Number($s) {
    $s = "$s".Trim()
    if ($s -eq '[N/A]' -or $s -eq 'N/A' -or $s -eq '') { return $null }
    $v = 0.0
    if ([double]::TryParse($s, [ref]$v)) { return $v }
    return $null
}

function Get-GpuSample {
    if (-not $script:HasNvidia) { return Get-GenericGpuSample }
    $q = $Fields -join ','
    $raw = & nvidia-smi --query-gpu=$q --format=csv,noheader,nounits 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return Get-GenericGpuSample }
    $p = "$raw".Trim().Split(',')
    if ($p.Count -lt 13) { return $null }
    $throttle = @()
    if ("$($p[10])".Trim() -eq 'Active') { $throttle += '功耗墙' }
    if ("$($p[11])".Trim() -eq 'Active') { $throttle += '硬件降频' }
    if ("$($p[12])".Trim() -eq 'Active') { $throttle += '温度墙' }

    [pscustomobject]@{
        Time     = Get-Date
        Temp     = Convert-Number $p[0]
        Power    = Convert-Number $p[1]
        ClockSm  = Convert-Number $p[2]
        ClockMem = Convert-Number $p[3]
        UtilGpu  = Convert-Number $p[4]
        UtilMem  = Convert-Number $p[5]
        MemUsed  = Convert-Number $p[6]
        MemTotal = Convert-Number $p[7]
        PState   = "$($p[8])".Trim()
        Reason   = "$($p[9])".Trim()
        Throttle = if ($throttle.Count) { $throttle -join ' + ' } else { '正常' }
    }
}

function Get-GpuInfo {
    if (-not $script:HasNvidia) {
        $n = (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'Basic|Remote' } | Select-Object -First 1)
        if ($n) { return @{ Name = $n.Name; Driver = "$($n.DriverVersion)" } }
        return @{ Name = '图形适配器'; Driver = '?' }
    }
    $raw = & nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>$null
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{ Name = '未检测到 NVIDIA 显卡'; Driver = '?' } }
    $p = "$raw".Split(',')
    @{ Name = "$($p[0])".Trim(); Driver = if ($p.Count -gt 1) { "$($p[1])".Trim() } else { '?' } }
}
# ── 显卡采集后端探测 ──
$script:HasNvidia = $false
if (-not $ForceGeneric) {
    try {
        $probe = & nvidia-smi --query-gpu=name --format=csv,noheader 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($probe)) { $script:HasNvidia = $true }
    } catch {}
}

# 通用模式：Windows 自带 GPU 性能计数器（A 卡 / 核显可用，只有占用率和显存）
function Get-GenericGpuSample {
    $util = $null; $mem = $null
    try {
        $s = (Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction Stop).CounterSamples
        if ($s) {
            $sum = ($s | Measure-Object CookedValue -Sum).Sum
            $util = [math]::Round([math]::Min(100, $sum), 0)
        }
    } catch {}
    try {
        $v = (Get-Counter '\GPU Adapter Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples |
             Sort-Object CookedValue -Descending | Select-Object -First 1
        if ($v) { $mem = [math]::Round($v.CookedValue / 1MB, 0) }
    } catch {}
    [pscustomobject]@{
        Time = Get-Date; Temp = $null; Power = $null; ClockSm = $null; ClockMem = $null
        UtilGpu = $util; UtilMem = $null; MemUsed = $mem; MemTotal = $null
        PState = '-'; Reason = '-'; Throttle = '通用模式'
    }
}

# ── CPU 采样 ──
$script:CpuMaxMHz = 2900
try {
    $c0 = Get-CimInstance Win32_Processor | Select-Object -First 1
    if ($c0 -and $c0.MaxClockSpeed) { $script:CpuMaxMHz = [int]$c0.MaxClockSpeed }
} catch {}

function Get-CpuSample {
    $s = @{ Temp = $null; MHz = $null; Load = $null; Active = $null; Total = $null; RamPct = $null }
    # 温度：ACPI 热区（不需要管理员）
    try {
        $tz = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction Stop |
              Sort-Object { $_.HighPrecisionTemperature } -Descending | Select-Object -First 1
        if ($tz -and $tz.HighPrecisionTemperature -gt 2732) {
            $s.Temp = [math]::Round(($tz.HighPrecisionTemperature / 10) - 273.15, 1)
        }
    } catch {}
    # 频率：性能计数器 × 标称频率
    try {
        $perf = (Get-Counter '\Processor Information(_Total)\% Processor Performance' -ErrorAction Stop).CounterSamples[0].CookedValue
        if ($perf -gt 0) { $s.MHz = [int][math]::Round($script:CpuMaxMHz * $perf / 100) }
    } catch {}
    # 占用率
    try {
        $w = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($w) { $s.Load = [int]$w.LoadPercentage }
    } catch {}
    # 活跃核心（单核占用 > 20% 记为活跃）
    try {
        $cores = @(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -ErrorAction Stop | Where-Object { $_.Name -ne '_Total' })
        if ($cores.Count -gt 0) {
            $s.Total = $cores.Count
            $s.Active = @($cores | Where-Object { $_.PercentProcessorTime -gt 20 }).Count
        }
    } catch {}
    # 内存占用
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        if ($os.TotalVisibleMemorySize -gt 0) {
            $s.RamPct = [int][math]::Round((1 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize)) * 100, 0)
        }
    } catch {}
    [pscustomobject]$s
}

# ════════════════════════════════ 自检模式 ════════════════════════════════
if ($SelfTest) {
    $info = Get-GpuInfo
    Write-Output "GPU   : $($info.Name)"
    Write-Output "驱动  : $($info.Driver)"
    $ok = 0
    for ($i = 1; $i -le 3; $i++) {
        $s = Get-GpuSample
        if ($s) {
            Write-Output ("采样{0}: {1:HH:mm:ss}  {2}°C  {3}W  {4}MHz  占用{5}%  显存{6}MB  {7}" -f `
                $i, $s.Time, $s.Temp, $s.Power, $s.ClockSm, $s.UtilGpu, $s.MemUsed, $s.Throttle)
            $ok++
        }
        else { Write-Output "采样$i : 失败" }
        Start-Sleep -Milliseconds 700
    }
    Write-Output "自检结果: $ok/3 成功"
    exit $(if ($ok -gt 0) { 0 } else { 1 })
}

# ════════════════════════════════ 界面 ════════════════════════════════
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$C = @{
    Bg      = [System.Drawing.Color]::FromArgb(24, 24, 28)
    Card    = [System.Drawing.Color]::FromArgb(34, 34, 40)
    Text    = [System.Drawing.Color]::FromArgb(228, 228, 231)
    Dim     = [System.Drawing.Color]::FromArgb(138, 138, 148)
    Accent  = [System.Drawing.Color]::FromArgb(78, 201, 176)
    Warn    = [System.Drawing.Color]::FromArgb(230, 170, 60)
    Bad     = [System.Drawing.Color]::FromArgb(230, 90, 90)
    Grid    = [System.Drawing.Color]::FromArgb(48, 48, 56)
}
$FontUI   = New-Object System.Drawing.Font('微软雅黑', 9)
$FontBig  = New-Object System.Drawing.Font('Consolas', 22, [System.Drawing.FontStyle]::Bold)
$FontMid  = New-Object System.Drawing.Font('微软雅黑', 10, [System.Drawing.FontStyle]::Bold)
$FontSmall= New-Object System.Drawing.Font('微软雅黑', 8)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'BF6监控器'
$form.Size = New-Object System.Drawing.Size(760, 700)
$form.MinimumSize = New-Object System.Drawing.Size(680, 660)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $C.Bg
$form.ForeColor = $C.Text
$form.Font = $FontUI
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

$gpuInfo = Get-GpuInfo

# ── 顶部标题 ──
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'BF6监控器'
$lblTitle.Font = New-Object System.Drawing.Font('微软雅黑', 14, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $C.Text
$lblTitle.Location = New-Object System.Drawing.Point(20, 14)
$lblTitle.AutoSize = $true
$form.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$modeTxt = if ($script:HasNvidia) { 'NVIDIA 模式' } else { '通用模式（无 nvidia-smi）' }
$lblSub.Text = "$($gpuInfo.Name)   驱动 $($gpuInfo.Driver)   ·   $modeTxt"
$lblSub.Font = $FontSmall
$lblSub.ForeColor = $C.Dim
$lblSub.Location = New-Object System.Drawing.Point(22, 44)
$lblSub.AutoSize = $true
$form.Controls.Add($lblSub)

# ── 状态灯 ──
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = '○ 待机'
$lblStatus.Font = $FontMid
$lblStatus.ForeColor = $C.Dim
$lblStatus.Location = New-Object System.Drawing.Point(560, 22)
$lblStatus.Size = New-Object System.Drawing.Size(170, 24)
$lblStatus.TextAlign = 'MiddleRight'
$form.Controls.Add($lblStatus)

# ── 四个大数字卡片 ──
function New-Card($x, $y, $w, $h, $title) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point($x, $y)
    $p.Size = New-Object System.Drawing.Size($w, $h)
    $p.BackColor = $C.Card
    $t = New-Object System.Windows.Forms.Label
    $t.Text = $title
    $t.Font = $FontSmall
    $t.ForeColor = $C.Dim
    $t.Location = New-Object System.Drawing.Point(10, 6)
    $t.AutoSize = $true
    $p.Controls.Add($t)
    $form.Controls.Add($p)
    $p
}

$cardTemp  = New-Card 20  66 170 74 '温度'
$cardPower = New-Card 200 66 170 74 '功耗'
$cardClock = New-Card 380 66 170 74 '核心频率'
$cardUtil  = New-Card 560 66 172 74 'GPU 占用'

function Add-BigValue($panel, $name) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = '--'
    $l.Font = $FontBig
    $l.ForeColor = $C.Accent
    $l.Location = New-Object System.Drawing.Point(8, 22)
    $l.AutoSize = $true
    $l.Name = $name
    $panel.Controls.Add($l)
    $l
}

$valTemp  = Add-BigValue $cardTemp  'v'
$valPower = Add-BigValue $cardPower 'v'
$valClock = Add-BigValue $cardClock 'v'
$valUtil  = Add-BigValue $cardUtil  'v'

$unitTemp  = New-Object System.Windows.Forms.Label
$unitTemp.Text = '°C'; $unitTemp.Font = $FontSmall; $unitTemp.ForeColor = $C.Dim
$unitTemp.Location = New-Object System.Drawing.Point(146, 12); $unitTemp.AutoSize = $true
$cardTemp.Controls.Add($unitTemp)

$unitPower = New-Object System.Windows.Forms.Label
$unitPower.Text = 'W'; $unitPower.Font = $FontSmall; $unitPower.ForeColor = $C.Dim
$unitPower.Location = New-Object System.Drawing.Point(146, 12); $unitPower.AutoSize = $true
$cardPower.Controls.Add($unitPower)

$unitClock = New-Object System.Windows.Forms.Label
$unitClock.Text = 'MHz'; $unitClock.Font = $FontSmall; $unitClock.ForeColor = $C.Dim
$unitClock.Location = New-Object System.Drawing.Point(140, 12); $unitClock.AutoSize = $true
$cardClock.Controls.Add($unitClock)

$unitUtil = New-Object System.Windows.Forms.Label
$unitUtil.Text = '%'; $unitUtil.Font = $FontSmall; $unitUtil.ForeColor = $C.Dim
$unitUtil.Location = New-Object System.Drawing.Point(150, 12); $unitUtil.AutoSize = $true
$cardUtil.Controls.Add($unitUtil)

# ── 曲线图 ──
$chartW, $chartH = 720, 120
$chart = New-Object System.Windows.Forms.PictureBox
$chart.Location = New-Object System.Drawing.Point(20, 146)
$chart.Size = New-Object System.Drawing.Size($chartW, $chartH)
$chart.BackColor = $C.Card
$form.Controls.Add($chart)

$chartBmp = New-Object System.Drawing.Bitmap($chartW, $chartH)
$chart.Image = $chartBmp

# ── CPU 走势图 ──
$cpuChart = New-Object System.Windows.Forms.PictureBox
$cpuChart.Location = New-Object System.Drawing.Point(20, 352)
$cpuChart.Size = New-Object System.Drawing.Size($chartW, 110)
$cpuChart.BackColor = $C.Card
$form.Controls.Add($cpuChart)
$cpuChartBmp = New-Object System.Drawing.Bitmap($chartW, 110)
$cpuChart.Image = $cpuChartBmp

# ── CPU 四个卡片 ──
$cardCpuTemp  = New-Card 20  272 170 74 'CPU 温度'
$cardCpuClock = New-Card 200 272 170 74 'CPU 频率'
$cardCpuUtil  = New-Card 380 272 170 74 'CPU 占用'
$cardCpuCores = New-Card 560 272 172 74 '活跃核心'

$valCpuTemp  = Add-BigValue $cardCpuTemp  'v'
$valCpuClock = Add-BigValue $cardCpuClock 'v'
$valCpuUtil  = Add-BigValue $cardCpuUtil  'v'
$valCpuCores = Add-BigValue $cardCpuCores 'v'

foreach ($pair in @(
    @($cardCpuTemp,  '°C',  146, 12),
    @($cardCpuClock, 'MHz', 136, 12),
    @($cardCpuUtil,  '%',   150, 12),
    @($cardCpuCores, '',    150, 12)
)) {
    if ($pair[1] -ne '') {
        $u = New-Object System.Windows.Forms.Label
        $u.Text = $pair[1]; $u.Font = $FontSmall; $u.ForeColor = $C.Dim
        $u.Location = New-Object System.Drawing.Point($pair[2], $pair[3]); $u.AutoSize = $true
        $pair[0].Controls.Add($u)
    }
}

# ── 底部信息 ──
$lblDetail = New-Object System.Windows.Forms.Label
$lblDetail.Text = 'CPU -- / -- / --      显存 -- / -- MB      降频 --'
$lblDetail.Font = $FontSmall
$lblDetail.ForeColor = $C.Dim
$lblDetail.Location = New-Object System.Drawing.Point(20, 470)
$lblDetail.Size = New-Object System.Drawing.Size(720, 20)
$form.Controls.Add($lblDetail)

$lblStats = New-Object System.Windows.Forms.Label
$lblStats.Text = '本次未记录'
$lblStats.Font = $FontSmall
$lblStats.ForeColor = $C.Dim
$lblStats.Location = New-Object System.Drawing.Point(20, 492)
$lblStats.Size = New-Object System.Drawing.Size(720, 20)
$form.Controls.Add($lblStats)

# ── 按钮 ──
function New-Button($x, $text, $w = 130) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, 520)
    $b.Size = New-Object System.Drawing.Size($w, 34)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = $C.Grid
    $b.BackColor = $C.Card
    $b.ForeColor = $C.Text
    $b.Font = $FontUI
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($b)
    $b
}

$btnStart = New-Button 20  '开始记录'
$btnStop  = New-Button 160 '停止'
$btnLogs  = New-Button 290 '打开数据目录'
$btnRep   = New-Button 430 '打开崩溃报告'

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = '提示：游戏启动后会自动开始记录；游戏退出或崩溃时自动生成报告。'
$lblHint.Font = $FontSmall
$lblHint.ForeColor = $C.Dim
$lblHint.Location = New-Object System.Drawing.Point(20, 566)
$lblHint.Size = New-Object System.Drawing.Size(720, 20)
$form.Controls.Add($lblHint)

$lblVer = New-Object System.Windows.Forms.Label
$lblVer.Text = "v1.3   数据目录: $Root"
$lblVer.Font = New-Object System.Drawing.Font('微软雅黑', 7)
$lblVer.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 100)
$lblVer.Location = New-Object System.Drawing.Point(20, 602)
$lblVer.Size = New-Object System.Drawing.Size(720, 18)
$form.Controls.Add($lblVer)

# ════════════════════════════════ 运行状态 ════════════════════════════════
$script:Recording  = $false
$script:LogFile    = $null
$script:LogCount   = 0
$script:LogCategory = 'system'
$script:ReportCount= 0
$script:GameSeen   = $false
$script:GameStart  = $null
$script:IntervalMs = $IntervalMs
$script:MaxPoints  = [math]::Max(1000, [int](3000000 / [math]::Max(100, $IntervalMs)))          # 曲线缓存点数（1 秒 1 点 ≈ 2.8 小时）
$script:TempHist   = New-Object 'System.Collections.Generic.List[double]'
$script:PowerHist  = New-Object 'System.Collections.Generic.List[double]'
$script:LastSample = $null
$script:Tick       = 0
$script:CpuLast    = $null
$script:CpuTempHist = New-Object 'System.Collections.Generic.List[double]'
$script:CpuFreqHist = New-Object 'System.Collections.Generic.List[double]'
$script:LastCpuTemp = 0.0
$script:LastCpuFreq = 0.0

function Start-Logging([string]$Category = 'system') {
    $sub = Join-Path $LogDir $Category
    if (-not (Test-Path $sub)) { New-Item -ItemType Directory -Force -Path $sub | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $prefix = if ($Category -eq 'bf6') { 'bf6' } else { 'sys' }
    $script:LogCategory = $Category
    $script:LogFile = Join-Path $sub "$prefix-$stamp.csv"
    $hdr = 'time,temp_c,power_w,clock_sm_mhz,clock_mem_mhz,util_gpu_pct,util_mem_pct,mem_used_mb,pstate,event_reason,power_cap,hw_slowdown,thermal_throttle,throttle_text,cpu_temp_c,cpu_mhz,cpu_load_pct,cpu_cores_active,cpu_cores_total,ram_pct'
    Set-Content -Path $script:LogFile -Value $hdr -Encoding UTF8
    $script:LogCount = 0
    $script:Recording = $true
    $script:TempHist.Clear()
    $script:PowerHist.Clear()
    $btnStart.Enabled = $false
    $btnStop.Enabled = $true
    $lblStatus.Text = '● 记录中'
    $lblStatus.ForeColor = $C.Accent
}

function Stop-Logging {
    if (-not $script:Recording) { return }
    $script:Recording = $false
    $btnStart.Enabled = $true
    $btnStop.Enabled = $false
    $lblStatus.Text = '○ 已停止'
    $lblStatus.ForeColor = $C.Dim
}

function Test-IsCrash($exitTime) {
    # 判断这次退出到底是崩溃还是正常关闭：三选一命中就算崩溃
    $since = $exitTime.AddMinutes(-2)
    $docDir = [Environment]::GetFolderPath('MyDocuments')
    $dumpDir = Join-Path $docDir 'Battlefield 6\CrashDumps'
    if (Test-Path $dumpDir) {
        $newDump = Get-ChildItem $dumpDir -Filter '*.mdmp' -ErrorAction SilentlyContinue |
                   Where-Object { $_.LastWriteTime -ge $since }
        if ($newDump) { return @{ IsCrash = $true; Reason = "产生崩溃转储 $($newDump[-1].Name)" } }
    }
    try {
        $appErr = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000; StartTime = $since } -ErrorAction Stop |
                  Where-Object { $_.Message -match 'bf6' }
        if ($appErr) { return @{ IsCrash = $true; Reason = '应用错误事件 1000' } }
    } catch {}
    try {
        $drvErr = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'nvlddmkm'; StartTime = $since } -ErrorAction Stop
        if ($drvErr) { return @{ IsCrash = $true; Reason = 'nvlddmkm 驱动事件' } }
    } catch {}
    return @{ IsCrash = $false; Reason = '无崩溃特征' }
}

function Write-CrashReport($exitTime, $isCrash = $true, $reason = '') {
    $stamp = $exitTime.ToString('yyyyMMdd-HHmmss')
    $prefix = if ($isCrash) { 'crash' } else { 'session' }
    $report = Join-Path $RepDir "$prefix-$stamp.txt"
    $sb = New-Object System.Text.StringBuilder
    function L($t) { [void]$sb.AppendLine($t) }

    L ('=' * 66)
    if ($isCrash) {
        L "BF6 崩溃报告  $($exitTime.ToString('yyyy-MM-dd HH:mm:ss'))    [判定依据: $reason]"
    }
    else {
        L "BF6 对局记录（正常退出）  $($exitTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    }
    L ('=' * 66)
    if ($script:GameStart) {
        L "游戏开始 : $($script:GameStart.ToString('yyyy-MM-dd HH:mm:ss'))"
        L "运行时长 : $([math]::Round(($exitTime - $script:GameStart).TotalMinutes,1)) 分钟"
    }
    L "记录条数 : $($script:LogCount)"
    L "遥测文件 : $($script:LogFile)"
    L ''

    L '--- 崩溃前最后 40 条遥测 ---'
    if ($script:LogFile -and (Test-Path $script:LogFile)) {
        Get-Content $script:LogFile | Select-Object -Last 40 | ForEach-Object { L $_ }
    }
    L ''

    L '--- 最近 10 分钟 系统事件 ---'
    $since = $exitTime.AddMinutes(-10)
    foreach ($prov in 'nvlddmkm', 'Display', 'Microsoft-Windows-WHEA-Logger') {
        L "[$prov]"
        try {
            Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = $prov; StartTime = $since } -ErrorAction Stop |
                ForEach-Object {
                    L ("  {0} Id={1} {2}" -f $_.TimeCreated.ToString('HH:mm:ss'), $_.Id,
                        ((@($_.Properties) | ForEach-Object { $_.Value }) -join ' | '))
                }
        }
        catch { L '  (无)' }
    }
    L ''

    L '--- 最近 10 分钟 应用错误 ---'
    try {
        Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1001; StartTime = $since } -ErrorAction Stop |
            ForEach-Object {
                L ("  {0} Id={1}" -f $_.TimeCreated.ToString('HH:mm:ss'), $_.Id)
                if ($_.Message) { L ('    ' + ($_.Message -replace '\s+', ' ')) }
            }
    }
    catch { L '  (无)' }
    L ''

    L '--- 系统状态 ---'
    L (& nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>&1)
    $gd = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    L "HwSchMode = $((Get-ItemProperty $gd -Name HwSchMode -ErrorAction SilentlyContinue).HwSchMode)"
    L "TdrDelay  = $((Get-ItemProperty $gd -Name TdrDelay -ErrorAction SilentlyContinue).TdrDelay)"

    $sb.ToString() | Set-Content -Path $report -Encoding UTF8
    $script:ReportCount++
    return $report
}

$script:ColGray   = [System.Drawing.Color]::FromArgb(150, 150, 160)
$script:ColOrange = [System.Drawing.Color]::FromArgb(255, 170, 70)

function Draw-Chart {
    if ($null -eq $script:TempHist -or $script:TempHist.Count -lt 1) { return }
    $cnt = $script:TempHist.Count
    $spanMin = [math]::Round($cnt * ($script:IntervalMs / 1000.0) / 60.0, 1)
    $infoTxt = ("缓存 {0:N0} 点 / 跨度 {1} 分钟 / 采样 {2}ms" -f $cnt, $spanMin, $script:IntervalMs)

    if ($script:HasNvidia) {
        [ChartRenderer]::Render($chartBmp, $script:TempHist.ToArray(), $script:PowerHist.ToArray(), $cnt,
            $C.Card, $C.Grid, $C.Accent, $script:ColGray, $C.Dim, $infoTxt,
            '温度 (°C)', '功耗 (W)', '°C', 'W')
    }
    else {
        [ChartRenderer]::Render($chartBmp, $script:TempHist.ToArray(), $script:PowerHist.ToArray(), $cnt,
            $C.Card, $C.Grid, $C.Accent, $script:ColOrange, $C.Dim, $infoTxt,
            'GPU 占用 (%)', '显存 (MB)', '%', 'MB')
    }
    $chart.Refresh()

    if ($script:CpuTempHist.Count -ge 1) {
        $cCnt = $script:CpuTempHist.Count
        $cSpan = [math]::Round($cCnt * ($script:IntervalMs / 1000.0) / 60.0, 1)
        $cInfo = ("缓存 {0:N0} 点 / 跨度 {1} 分钟" -f $cCnt, $cSpan)
        [ChartRenderer]::Render($cpuChartBmp, $script:CpuTempHist.ToArray(), $script:CpuFreqHist.ToArray(), $cCnt,
            $C.Card, $C.Grid, $C.Accent, $script:ColOrange, $C.Dim, $cInfo,
            'CPU 温度 (°C)', '频率 (MHz)', '°C', 'MHz')
        $cpuChart.Refresh()
    }
}
# ════════════════════════════════ 定时刷新 ════════════════════════════════
function Update-UI {
    $s = Get-GpuSample
    if (-not $s) {
        $lblStatus.Text = '✕ 读取失败'
        $lblStatus.ForeColor = $C.Bad
        return
    }
    $script:LastSample = $s

    # CPU 每 4 个 tick 采一次（默认 500ms → 约 2 秒）
    $script:Tick++
    if (-not $script:CpuLast -or ($script:Tick % 4) -eq 1) { $script:CpuLast = Get-CpuSample }
    $cpu = $script:CpuLast
    if ($null -ne $cpu.Temp) { $script:LastCpuTemp = [double]$cpu.Temp }
    if ($null -ne $cpu.MHz)  { $script:LastCpuFreq = [double]$cpu.MHz }

    $valTemp.Text  = if ($null -ne $s.Temp)  { '{0:N1}' -f $s.Temp }  else { '--' }
    $valPower.Text = if ($null -ne $s.Power) { '{0:N0}' -f $s.Power } else { '--' }
    $valClock.Text = if ($null -ne $s.ClockSm) { '{0:F0}' -f $s.ClockSm } else { '--' }
    $valUtil.Text  = if ($null -ne $s.UtilGpu) { '{0:N0}' -f $s.UtilGpu } else { '--' }

    if ($null -ne $s.Temp) {
        if ($s.Temp -ge 85) { $valTemp.ForeColor = $C.Bad }
        elseif ($s.Temp -ge 75) { $valTemp.ForeColor = $C.Warn }
        else { $valTemp.ForeColor = $C.Accent }
    }

    $memTotal = if ($s.MemTotal) { '{0:N0}' -f $s.MemTotal } else { '--' }
    # CPU 卡片
    $valCpuTemp.Text  = if ($null -ne $cpu.Temp) { '{0:N0}' -f $cpu.Temp } else { '--' }
    $valCpuClock.Text = if ($null -ne $cpu.MHz) { '{0:N0}' -f $cpu.MHz } else { '--' }
    $valCpuUtil.Text  = if ($null -ne $cpu.Load) { '{0}' -f $cpu.Load } else { '--' }
    $valCpuCores.Text = if ($null -ne $cpu.Active) { '{0}/{1}' -f $cpu.Active, $cpu.Total } else { '--' }

    if ($null -ne $cpu.Temp) {
        if ($cpu.Temp -ge 95) { $valCpuTemp.ForeColor = $C.Bad }
        elseif ($cpu.Temp -ge 85) { $valCpuTemp.ForeColor = $C.Warn }
        else { $valCpuTemp.ForeColor = $C.Accent }
    }
    if ($null -ne $cpu.Load) {
        if ($cpu.Load -ge 90) { $valCpuUtil.ForeColor = $C.Bad }
        elseif ($cpu.Load -ge 70) { $valCpuUtil.ForeColor = $C.Warn }
        else { $valCpuUtil.ForeColor = $C.Accent }
    }

    $ramTxt = if ($null -ne $cpu.RamPct) { "{0}%" -f $cpu.RamPct } else { "--" }
    $lblDetail.Text = "显存 {0:N0} / {1} MB      内存 {2}      降频 {3}      电源 {4}" -f `
        $s.MemUsed, $memTotal, $ramTxt, $s.Throttle, $s.PState

    # 记录
    if ($script:Recording) {
        $line = '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12}' -f `
            $s.Time.ToString('yyyy-MM-dd HH:mm:ss.fff'), $s.Temp, $s.Power, $s.ClockSm, $s.ClockMem,
            $s.UtilGpu, $s.UtilMem, $s.MemUsed, $s.PState, $s.Reason,
            $(if ($s.Throttle -match '功耗墙') { 1 } else { 0 }),
            $(if ($s.Throttle -match '硬件降频') { 1 } else { 0 }),
            $(if ($s.Throttle -match '温度墙') { 1 } else { 0 })
        $cpuT = if ($null -ne $cpu.Temp) { $cpu.Temp } else { '' }
        $cpuM = if ($null -ne $cpu.MHz) { $cpu.MHz } else { '' }
        $cpuL = if ($null -ne $cpu.Load) { $cpu.Load } else { '' }
        $cpuA = if ($null -ne $cpu.Active) { $cpu.Active } else { '' }
        $cpuN = if ($null -ne $cpu.Total) { $cpu.Total } else { '' }
        $ramP = if ($null -ne $cpu.RamPct) { $cpu.RamPct } else { '' }
        Add-Content -Path $script:LogFile -Value ($line + ',' + $s.Throttle + ',' + $cpuT + ',' + $cpuM + ',' + $cpuL + ',' + $cpuA + ',' + $cpuN + ',' + $ramP) -Encoding UTF8
        $script:LogCount++
    }

    # 曲线历史始终更新（N 卡存温度/功耗，通用模式存占用/显存）
    if ($script:HasNvidia) {
        if ($null -ne $s.Temp) { [void]$script:TempHist.Add($s.Temp) } else { [void]$script:TempHist.Add(0) }
        if ($null -ne $s.Power) { [void]$script:PowerHist.Add($s.Power) } else { [void]$script:PowerHist.Add(0) }
    }
    else {
        if ($null -ne $s.UtilGpu) { [void]$script:TempHist.Add($s.UtilGpu) } else { [void]$script:TempHist.Add(0) }
        if ($null -ne $s.MemUsed) { [void]$script:PowerHist.Add($s.MemUsed) } else { [void]$script:PowerHist.Add(0) }
    }
    while ($script:TempHist.Count -gt $script:MaxPoints) { $script:TempHist.RemoveAt(0) }
    while ($script:PowerHist.Count -gt $script:MaxPoints) { $script:PowerHist.RemoveAt(0) }

    # CPU 曲线：沿用最近一次有效值，保证和 GPU 曲线等宽
    [void]$script:CpuTempHist.Add([double]$script:LastCpuTemp)
    [void]$script:CpuFreqHist.Add([double]$script:LastCpuFreq)
    while ($script:CpuTempHist.Count -gt $script:MaxPoints) { $script:CpuTempHist.RemoveAt(0) }
    while ($script:CpuFreqHist.Count -gt $script:MaxPoints) { $script:CpuFreqHist.RemoveAt(0) }

    Draw-Chart

    # 游戏进程检测（自动记录 + 崩溃报告）
    $game = Get-Process bf6 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($game) {
        if (-not $script:GameSeen) {
            $script:GameSeen = $true
            $script:GameStart = $game.StartTime
            if ($script:Recording) { Stop-Logging }
            Start-Logging 'bf6'
            $lblHint.Text = "已检测到 bf6.exe 运行，正在记录到 logs\bf6\。"
        }
        $elapsed = [math]::Round(((Get-Date) - $script:GameStart).TotalMinutes, 1)
        if ($script:Recording) {
            $lblStatus.Text = "● 记录中  $($elapsed) 分"
        }
    }
    else {
        if ($script:GameSeen) {
            $script:GameSeen = $false
            $exitTime = Get-Date
            if ($script:Recording) {
                Stop-Logging
                $verdict = Test-IsCrash $exitTime
                $rep = Write-CrashReport $exitTime $verdict.IsCrash $verdict.Reason
                if ($verdict.IsCrash) {
                    $lblHint.Text = "⚠ 判定为崩溃（$($verdict.Reason)），报告: $(Split-Path $rep -Leaf)"
                    $lblHint.ForeColor = $C.Bad
                    [System.Windows.Forms.MessageBox]::Show(
                        "检测到 bf6.exe 异常退出（$($verdict.Reason)）。`n`n崩溃报告已保存：`n$rep`n`n记录条数: $($script:LogCount)",
                        'BF6监控器 — 检测到崩溃', 'OK', 'Warning') | Out-Null
                }
                else {
                    $lblHint.Text = "游戏正常退出，对局记录已保存: $(Split-Path $rep -Leaf)"
                    $lblHint.ForeColor = $C.Dim
                }
                Start-Logging 'system'
                $lblHint.Text = "$($lblHint.Text)  已切回系统监控 logs\system\"
            }
        }
    }

    $lblStats.Text = "已记录 {0:N0} 条    报告 {1} 份    文件 {2}" -f `
        $script:LogCount, $script:ReportCount, $(if ($script:LogFile) { Split-Path $script:LogFile -Leaf } else { '—' })
}

# ════════════════════════════════ 事件绑定 ════════════════════════════════
$btnStart.Add_Click({
    if (-not $script:Recording) {
        $cat = if (Get-Process bf6 -ErrorAction SilentlyContinue) { 'bf6' } else { 'system' }
        Start-Logging $cat
        $lblHint.Text = "已手动开始记录（logs\$cat\）。"
    }
})
$btnStop.Add_Click({
    if ($script:Recording) { Stop-Logging; $lblHint.Text = '已停止记录。' }
})
$btnLogs.Add_Click({ Start-Process explorer.exe $LogDir })
$btnRep.Add_Click({ Start-Process explorer.exe $RepDir })

$btnStop.Enabled = $false

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = $script:IntervalMs
$script:Timer.Add_Tick({ try { Update-UI } catch { $lblStatus.Text = '✕ 错误'; $lblStatus.ForeColor = $C.Bad } })

$form.Add_Shown({
    $script:Timer.Start()
    $hasGame = $null -ne (Get-Process bf6 -ErrorAction SilentlyContinue)
    if (-not $hasGame -and -not $script:Recording) {
        Start-Logging 'system'
        $lblHint.Text = '未检测到游戏，正在做系统监控（logs\system\）。启动战地6 会自动切换到 logs\bf6\。'
    }
    Update-UI
})
$form.Add_FormClosing({
    $script:Timer.Stop()
    if ($script:Recording) { Stop-Logging }
})

if ($ForceLog -and -not $script:Recording) { Start-Logging }
if ($UiTest) {
    # 离屏自检：构建全部控件 + 绘图 + 两次刷新，不弹窗、不抢焦点
    Draw-Chart
    Update-UI
    Start-Sleep -Milliseconds 400
    Update-UI
    Write-Output "UI 自检通过"
    Write-Output "  控件数: $($form.Controls.Count)"
    Write-Output "  采样值: 温度=$($valTemp.Text) 功耗=$($valPower.Text) 频率=$($valClock.Text) 占用=$($valUtil.Text)"
    Write-Output "  记录中: $($script:Recording)   条数: $($script:LogCount)"
    Write-Output "  日志文件: $($script:LogFile)"
    $form.Dispose()
    exit 0
}

if ($Shot) {
    # 离屏截图：不显示窗口，直接把界面渲染成 PNG（不抢游戏焦点）
    if ($FillPoints -gt 0) {
        # 压测：灌入 N 个合成点，验证 1 万点缓存的绘制性能
        $script:TempHist.Clear(); $script:PowerHist.Clear()
        $rnd = New-Object System.Random 42
        for ($i = 0; $i -lt $FillPoints; $i++) {
            [void]$script:TempHist.Add(58 + 4 * [math]::Sin($i / 90.0) + $rnd.NextDouble() * 0.8)
            [void]$script:PowerHist.Add(145 + 20 * [math]::Sin($i / 40.0) + $rnd.NextDouble() * 6)
        }
        $script:CpuTempHist.Clear(); $script:CpuFreqHist.Clear()
        for ($i = 0; $i -lt $FillPoints; $i++) {
            [void]$script:CpuTempHist.Add(64 + 6 * [math]::Sin($i / 55.0) + $rnd.NextDouble() * 1.5)
            [void]$script:CpuFreqHist.Add(3300 + 700 * [math]::Sin($i / 30.0) + $rnd.NextDouble() * 120)
        }
        $wasRec2 = $script:Recording
        $script:Recording = $false
        Update-UI
        $script:Recording = $wasRec2
    }
    else {
        $wasRec = $script:Recording
        $script:Recording = $false
        for ($i = 0; $i -lt 30; $i++) { Update-UI; Start-Sleep -Milliseconds 70 }
        $script:Recording = $wasRec
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Draw-Chart
    $sw.Stop()
    Write-Output ("绘制耗时: {0:N1} ms  (缓存 {1:N0} 点)" -f $sw.Elapsed.TotalMilliseconds, $script:TempHist.Count)
    $null = $form.Handle
    function Initialize-Handles($ctrl) {
        foreach ($ch in $ctrl.Controls) {
            try { $null = $ch.Handle } catch {}
            Initialize-Handles $ch
        }
    }
    Initialize-Handles $form
    $form.PerformLayout()
    [System.Windows.Forms.Application]::DoEvents()
    $bmp2 = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp2, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bmp2.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp2.Dispose()
    Write-Output "截图已保存: $Shot"
    $form.Dispose()
    exit 0
}

if ($Minimized) {
    $form.WindowState = 'Minimized'
    $form.ShowInTaskbar = $true
}
[System.Windows.Forms.Application]::Run($form)
