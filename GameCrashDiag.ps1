<#
.SYNOPSIS
    BF6 GPU 监控器 —— 战地6 崩溃取证工具（图形界面版）

.DESCRIPTION
    实时显示 GPU 温度/功耗/频率/占用/降频原因，并自动把数据记成 CSV。
    检测到任意全屏游戏运行时自动开始记录，游戏退出（崩溃）时自动生成崩溃报告。

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
    [switch]$Tray,
    [int]$ShowAfter = 0,
    [switch]$TestReport,
    [int]$IntervalMs = 500,
    [switch]$ForceLog,
    [switch]$ForceGeneric
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── 声明 DPI 感知：不做的话 Windows 会把整个窗口拉伸，字体发虚、字号看着不齐 ──
Add-Type -Namespace NativeDpi -Name Helper -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
'@ -ErrorAction SilentlyContinue
if ('NativeDpi.Helper' -as [type]) {
    try { [void][NativeDpi.Helper]::SetProcessDpiAwareness(1) }
    catch { try { [void][NativeDpi.Helper]::SetProcessDPIAware() } catch {} }
}

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

# ── 通用游戏检测 ──
# 不依赖游戏名单：全屏窗口（≥90% 屏幕面积）+ 非系统/工具进程 = 游戏
Add-Type -Namespace W32Game -Name Detect -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
"@ -ErrorAction SilentlyContinue

$script:ExcludeProcs = @(
    'explorer', 'dwm', 'powershell', 'pwsh', 'WindowsTerminal', 'cmd', 'conhost',
    'GameCrashDiag', 'chrome', 'msedge', 'firefox', 'iexplore',
    'discord', 'teams', 'slack', 'code', 'devenv',
    'Taskmgr', 'ApplicationFrameHost', 'SearchHost', 'StartMenuExperienceHost',
    'TextInputHost', 'SystemSettings', 'ShellExperienceHost', 'LockApp', 'PhoneExperienceHost',
    # 游戏内叠加层（全屏但绝不能被当成游戏）
    'NVIDIA Overlay', 'NVIDIA Share', 'NVIDIA App', 'nvsphelper64', 'nvcontainer',
    'gameoverlayui', 'gameoverlayui64', 'steamwebhelper', 'steam',
    'RTSS', 'RTSSHooksLoader64', 'MSIAfterburner', 'RivaTuner Statistics Server',
    'wallpaper64', 'wallpaper32', 'wallpaper32', 'RazerAppEngine', 'RzSDKServer',
    'RzChromaStreamServer', 'SyserrorOverlay', 'TranslucentTB', 'Rainmeter'
)
# 这些路径下的进程一律不当游戏（叠加层/启动器/系统组件）
$script:ExcludePaths = @('\Windows\', '\NVIDIA Corporation\', '\Steam\bin\', '\Razer\', '\ProgramData\Microsoft\Windows Defender\')
$script:GameName = $null
$script:GameScanAt = $null
$script:GameScanResult = $null

function Find-RunningGame {
    if (-not ('W32Game.Detect' -as [type])) { return $null }
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $minW = $screen.Width * 0.88
    $minH = $screen.Height * 0.88

    $candidates = @()
    foreach ($proc in [System.Diagnostics.Process]::GetProcesses()) {
        try {
            if ($proc.Id -eq $PID) { continue }
            if ($proc.MainWindowHandle -eq [IntPtr]::Zero) { continue }
            if ($script:ExcludeProcs -contains $proc.ProcessName) { continue }
            $exe = $null
            try { $exe = $proc.MainModule.FileName } catch { $exe = $null }
            # 读不到路径（提权进程，带反作弊的游戏常见）时，不跳过，靠内存占比判断
            if ($exe) {
                $skip = $false
                foreach ($frag in $script:ExcludePaths) { if ($exe -like "*$frag*") { $skip = $true; break } }
                if ($skip) { continue }
            }

            $rect = New-Object W32Game.Detect+RECT
            if (-not [W32Game.Detect]::GetWindowRect($proc.MainWindowHandle, [ref]$rect)) { continue }
            if (($rect.Right - $rect.Left) -lt $minW) { continue }
            if (($rect.Bottom - $rect.Top) -lt $minH) { continue }

            $candidates += [pscustomobject]@{ Proc = $proc; Mem = $proc.WorkingSet64 }
        }
        catch {}
    }
    if ($candidates.Count -eq 0) { return $null }
    # 多个全屏进程时，取内存占用最大的（游戏通常 GB 级，工具类只有几十 MB）
    return ($candidates | Sort-Object Mem -Descending | Select-Object -First 1).Proc
}
# ── CPU 采样：全部走 .NET 性能计数器（单次 <1ms，不再阻塞界面）──
$script:PcPerf = New-Object System.Diagnostics.PerformanceCounter('Processor Information', '% Processor Performance', '_Total')
$script:PcTime = New-Object System.Diagnostics.PerformanceCounter('Processor Information', '% Processor Time', '_Total')
$script:PcUtil = New-Object System.Diagnostics.PerformanceCounter('Processor Information', '% Processor Utility', '_Total')
$script:PcMem  = New-Object System.Diagnostics.PerformanceCounter('Memory', 'Available MBytes')
$script:PcCores = @()
try {
    $catNames = (New-Object System.Diagnostics.PerformanceCounterCategory('Processor Information')).GetInstanceNames()
    foreach ($n in $catNames) {
        if ($n -ne '_Total') {
            $script:PcCores += New-Object System.Diagnostics.PerformanceCounter('Processor Information', '% Processor Time', $n)
        }
    }
} catch {}
$script:RamTotalMB = 0
try {
    $script:RamTotalMB = [int]((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
} catch {}
# 预热：性能计数器第一次 NextValue 返回 0
try { $null = $script:PcPerf.NextValue(); $null = $script:PcTime.NextValue(); $null = $script:PcUtil.NextValue(); $null = $script:PcMem.NextValue()
      foreach ($c0 in $script:PcCores) { $null = $c0.NextValue() } } catch {}
$script:CpuTempCache = $null
$script:CpuTempCacheAt = $null

function Get-CpuSample {
    $s = @{ Temp = $null; MHz = $null; Load = $null; Active = $null; Total = $null; RamPct = $null }

    # 频率 / 占用（性能计数器，~1ms）
    try {
        $perf = $script:PcPerf.NextValue()
        if ($perf -gt 0) { $s.MHz = [int][math]::Round($script:CpuMaxMHz * $perf / 100) }
        # 与任务管理器一致：用 % Processor Utility（含睿频增益），上限 100
        $u = $script:PcUtil.NextValue()
        if ($u -ge 0) { $s.Load = [int][math]::Min(100, [math]::Round($u)) }
        $null = $script:PcTime.NextValue()
    } catch {}

    # 逐核活跃数（~7ms）
    try {
        if ($script:PcCores.Count -gt 0) {
            $active = 0
            foreach ($cc in $script:PcCores) { if ($cc.NextValue() -gt 20) { $active++ } }
            $s.Total = $script:PcCores.Count
            $s.Active = $active
        }
    } catch {}

    # 内存
    try {
        $avail = $script:PcMem.NextValue()
        if ($script:RamTotalMB -gt 0 -and $avail -gt 0) {
            $s.RamPct = [int][math]::Round((1 - ($avail / $script:RamTotalMB)) * 100)
        }
    } catch {}

    # 温度：热区查询 30ms，缓存 10 秒
    $now = Get-Date
    if (-not $script:CpuTempCacheAt -or ($now - $script:CpuTempCacheAt).TotalSeconds -ge 10) {
        try {
            $tz = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction Stop |
                  Sort-Object { $_.HighPrecisionTemperature } -Descending | Select-Object -First 1
            if ($tz -and $tz.HighPrecisionTemperature -gt 2732) {
                $script:CpuTempCache = [math]::Round(($tz.HighPrecisionTemperature / 10) - 273.15, 1)
            }
        } catch {}
        $script:CpuTempCacheAt = $now
    }
    $s.Temp = $script:CpuTempCache

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
# 字号体系：标题 16 / 强调 10 粗 / 正文 9 / 脚注 8
$FontUI    = New-Object System.Drawing.Font('微软雅黑', 9)
$FontBody  = New-Object System.Drawing.Font('微软雅黑', 9)
$FontSmall = $FontBody
$FontMid   = New-Object System.Drawing.Font('微软雅黑', 10, [System.Drawing.FontStyle]::Bold)
$FontTitle = New-Object System.Drawing.Font('微软雅黑', 16, [System.Drawing.FontStyle]::Bold)
$FontVer   = New-Object System.Drawing.Font('微软雅黑', 8)
$FontBig   = New-Object System.Drawing.Font('Consolas', 25, [System.Drawing.FontStyle]::Bold)

$form = New-Object System.Windows.Forms.Form
$form.Text = '游戏崩溃诊断器'
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
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
$lblTitle.Text = '游戏崩溃诊断器'
$lblTitle.Font = $FontTitle
$lblTitle.ForeColor = $C.Text
$lblTitle.Location = New-Object System.Drawing.Point(12, 8)
$lblTitle.AutoSize = $true
$form.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$modeTxt = if ($script:HasNvidia) { '' } else { '    （通用模式）' }
$lblSub.Text = "GPU  ·  $($gpuInfo.Name)    驱动 $($gpuInfo.Driver)$modeTxt"
$lblSub.Font = $FontMid
$lblSub.ForeColor = $C.Dim
$lblSub.Location = New-Object System.Drawing.Point(14, 42)
$lblSub.AutoSize = $true
$form.Controls.Add($lblSub)

# ── 状态灯 ──
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = '○ 待机'
$lblStatus.Font = $FontMid
$lblStatus.ForeColor = $C.Dim
$lblStatus.Location = New-Object System.Drawing.Point(548, 16)
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

$cardTemp  = New-Card 12  66 175 74 '温度'
$cardPower = New-Card 199 66 175 74 '功耗'
$cardClock = New-Card 386 66 175 74 '核心频率'
$cardUtil  = New-Card 573 66 175 74 'GPU 占用'

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
$chartW, $chartH = 736, 120
$chart = New-Object System.Windows.Forms.PictureBox
$chart.Location = New-Object System.Drawing.Point(12, 146)
$chart.Size = New-Object System.Drawing.Size($chartW, $chartH)
$chart.BackColor = $C.Card
$form.Controls.Add($chart)

$chart.Image = $null


# ── CPU 走势图 ──
$cpuChart = New-Object System.Windows.Forms.PictureBox
$cpuChart.Location = New-Object System.Drawing.Point(12, 368)
$cpuChart.Size = New-Object System.Drawing.Size($chartW, 110)
$cpuChart.BackColor = $C.Card
$form.Controls.Add($cpuChart)
# 位图在 Draw-Chart 里按控件实际像素尺寸懒创建（DPI 缩放后尺寸会变）
$script:chartBmp = $null
$script:cpuBmp = $null

# ── CPU 型号标题 ──
$cpuInfo = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
$cpuNameTxt = if ($cpuInfo) { $cpuInfo.Name.Trim() } else { 'CPU' }
$cpuCoreTxt = if ($cpuInfo) { "$($cpuInfo.NumberOfCores) 核 / $($cpuInfo.NumberOfLogicalProcessors) 线程" } else { '' }

$lblCpuModel = New-Object System.Windows.Forms.Label
$lblCpuModel.Text = "CPU  ·  $cpuNameTxt    $cpuCoreTxt"
$lblCpuModel.Font = $FontMid
$lblCpuModel.ForeColor = $C.Dim
$lblCpuModel.Location = New-Object System.Drawing.Point(14, 268)
$lblCpuModel.AutoSize = $true
$form.Controls.Add($lblCpuModel)

# ── CPU 四个卡片 ──
$cardCpuTemp  = New-Card 12  288 175 74 'CPU 温度'
$cardCpuClock = New-Card 199 288 175 74 'CPU 频率'
$cardCpuUtil  = New-Card 386 288 175 74 'CPU 占用'
$cardCpuCores = New-Card 573 288 175 74 '活跃核心'

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
$lblDetail.Location = New-Object System.Drawing.Point(12, 486)
$lblDetail.Size = New-Object System.Drawing.Size(720, 20)
$form.Controls.Add($lblDetail)

$lblStats = New-Object System.Windows.Forms.Label
$lblStats.Text = '本次未记录'
$lblStats.Font = $FontSmall
$lblStats.ForeColor = $C.Dim
$lblStats.Location = New-Object System.Drawing.Point(12, 508)
$lblStats.Size = New-Object System.Drawing.Size(720, 20)
$form.Controls.Add($lblStats)

# ── 按钮 ──
function New-Button($x, $text, $w = 135) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, 536)
    $b.Size = New-Object System.Drawing.Size($w, 34)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = $C.Grid
    $b.BackColor = $C.Card
    $b.ForeColor = $C.Text
    $b.Font = $FontUI
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    # 悬停/按下高亮交给 WinForms 原生处理（不依赖鼠标事件，不会失灵）
    $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(56, 56, 68)
    $b.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(74, 74, 90)
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(64, 64, 78)
    $form.Controls.Add($b)
    $b
}

$btnStart = New-Button 12  '开始记录'
$btnStop  = New-Button 158 '停止'
$btnLogs  = New-Button 304 '打开数据目录'
$btnRep   = New-Button 450 '打开崩溃报告'

# ── 右下角：开机自启 ──
$script:RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:RunName = 'GameCrashDiag'
$script:AutoStartInit = $false

$chkAutoStart = New-Object System.Windows.Forms.CheckBox
$chkAutoStart.Text = '开机自动启动'
$chkAutoStart.Font = $FontBody
$chkAutoStart.ForeColor = $C.Dim
$chkAutoStart.AutoSize = $true
$chkAutoStart.Cursor = [System.Windows.Forms.Cursors]::Hand
$chkAutoStart.Location = New-Object System.Drawing.Point(598, 539)
$form.Controls.Add($chkAutoStart)

$lblMem = New-Object System.Windows.Forms.Label
$lblMem.Text = '程序内存 -- MB'
$lblMem.Font = $FontVer
$lblMem.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 120)
$lblMem.AutoSize = $true
$lblMem.Location = New-Object System.Drawing.Point(600, 561)
$form.Controls.Add($lblMem)

$chkAutoStart.Add_CheckedChanged({
    if (-not $script:AutoStartInit) { return }
    $ok = Set-AutoStart $chkAutoStart.Checked
    if (-not $ok) {
        $lblHint.Text = '设置失败：无法写入注册表启动项。'
        return
    }
    if ($chkAutoStart.Checked) {
        $lblHint.Text = '已设置开机自动启动，开机后会在后台自动开始记录。'
    }
    else {
        $lblHint.Text = '已取消开机自动启动。'
    }
})
function Test-AutoStart {
    $v = (Get-ItemProperty -Path $script:RunKey -Name $script:RunName -ErrorAction SilentlyContinue).$($script:RunName)
    return -not [string]::IsNullOrWhiteSpace($v)
}

function Set-AutoStart([bool]$enable) {
    try {
        if ($enable) {
            $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $appPath = Join-Path $Root 'GameCrashDiag.ps1'
            $cmd = "`"$psExe`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$appPath`" -Tray -IntervalMs 500"
            New-ItemProperty -Path $script:RunKey -Name $script:RunName -Value $cmd -PropertyType String -Force | Out-Null
        }
        else {
            Remove-ItemProperty -Path $script:RunKey -Name $script:RunName -ErrorAction SilentlyContinue
        }
        return $true
    }
    catch { return $false }
}

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = '提示：游戏启动自动记录，退出/崩溃自动生成报告；鼠标移到曲线上可查看该点数值。'
$lblHint.Font = $FontSmall
$lblHint.ForeColor = $C.Dim
$lblHint.Location = New-Object System.Drawing.Point(12, 582)
$lblHint.Size = New-Object System.Drawing.Size(720, 20)
$form.Controls.Add($lblHint)

$lblVer = New-Object System.Windows.Forms.Label
$lblVer.Text = "v3.0   数据目录: $Root"
$lblVer.Font = $FontVer
$lblVer.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 100)
$lblVer.Location = New-Object System.Drawing.Point(12, 618)
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
$script:GpuHover   = -1
$script:CpuHover   = -1
$script:LastHoverMs = 0
$script:BtnRestore = $null
$script:CpuTempHist = New-Object 'System.Collections.Generic.List[double]'
$script:CpuFreqHist = New-Object 'System.Collections.Generic.List[double]'
$script:LastCpuTemp = 0.0
$script:LastCpuFreq = 0.0

function Start-Logging([string]$Category = 'system') {
    $sub = Join-Path $LogDir $Category
    if (-not (Test-Path $sub)) { New-Item -ItemType Directory -Force -Path $sub | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $prefix = if ($Category -eq 'system') { 'sys' } else { $Category }
    $script:LogCategory = $Category
    $script:LogFile = Join-Path $sub "$prefix-$stamp.csv"
    $hdr = '时间,GPU温度(°C),GPU功耗(W),GPU核心频率(MHz),GPU显存频率(MHz),GPU占用(%),显存占用(%),显存已用(MB),电源状态,降频原因码,功耗墙,硬件降频,温度墙,降频说明,CPU温度(°C),CPU频率(MHz),CPU占用(%),活跃核心数,总核心数,内存占用(%)'
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

function Get-DiagnosisLines($logFile, $verdict, $exitTime) {
    $out = New-Object System.Collections.Generic.List[string]

    # ── 读遥测尾部 ──
    $rows = New-Object System.Collections.Generic.List[object]
    if ($logFile -and (Test-Path $logFile)) {
        foreach ($ln in (Get-Content $logFile | Select-Object -Skip 1)) {
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            $p = $ln -split ','
            if ($p.Count -ge 14) { $rows.Add($p) }
        }
    }
    $tail = @($rows | Select-Object -Last 120)

    $maxT = $null; $maxP = $null; $minC = $null; $maxC = $null
    $capCount = 0; $valid = 0
    foreach ($r in $tail) {
        $t = 0.0; $pw = 0.0; $ck = 0
        if ([double]::TryParse($r[1], [ref]$t)) { if ($null -eq $maxT -or $t -gt $maxT) { $maxT = $t }; $valid++ }
        if ([double]::TryParse($r[2], [ref]$pw)) { if ($null -eq $maxP -or $pw -gt $maxP) { $maxP = $pw } }
        if ([int]::TryParse($r[3], [ref]$ck)) {
            if ($null -eq $minC -or $ck -lt $minC) { $minC = $ck }
            if ($null -eq $maxC -or $ck -gt $maxC) { $maxC = $ck }
        }
        if ($r[10] -eq '1') { $capCount++ }
    }

    # ── 驱动事件 ──
    $drvCount = 0
    try {
        $drvCount = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'nvlddmkm'; StartTime = $exitTime.AddMinutes(-10) } -ErrorAction Stop).Count
    } catch {}
    $dumpCount = 0
    try {
        $dd = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Battlefield 6\CrashDumps'
        if (Test-Path $dd) {
            $dumpCount = @(Get-ChildItem $dd -Filter '*.mdmp' -ErrorAction SilentlyContinue |
                           Where-Object { $_.LastWriteTime -ge $exitTime.AddMinutes(-3) }).Count
        }
    } catch {}

    $maxPLimit = 175
    try {
        $ml = & nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits 2>$null
        if ($ml -match '([\d.]+)') { $maxPLimit = [math]::Round([double]$matches[1]) }
    } catch {}

    # ── 判定结论 ──
    [void]$out.Add('判定结论 : ' + $(if ($verdict.IsCrash) { "检测到崩溃（依据：$($verdict.Reason)）" } else { '未检测到崩溃特征' }))
    [void]$out.Add('')

    # ── 证据 ──
    [void]$out.Add('证据：')
    if ($valid -gt 0) {
        if ($null -ne $maxT) {
            $thermalNote = if ($maxT -ge 85) { '偏高，可能触发温度墙' } elseif ($maxT -ge 75) { '略高' } else { '正常，可排除过热' }
            [void]$out.Add(("  · 崩溃前最高温度 {0:N1}°C —— {1}" -f $maxT, $thermalNote))
        }
        if ($null -ne $maxP) {
            $pNote = if ($maxP -gt $maxPLimit) { "超过标称上限 $maxPLimit W，存在瞬态功耗尖峰" } else { "未超过标称上限 $maxPLimit W" }
            [void]$out.Add(("  · 崩溃前最高功耗 {0:N0} W —— {1}" -f $maxP, $pNote))
        }
        if ($null -ne $minC -and $null -ne $maxC -and $minC -gt 0) {
            [void]$out.Add(("  · 核心频率 {0:N0} ~ {1:N0} MHz（波动 {2:N0} MHz）" -f $minC, $maxC, ($maxC - $minC)))
        }
        $capPct = if ($valid -gt 0) { [math]::Round($capCount * 100.0 / $valid) } else { 0 }
        if ($capPct -ge 50) { [void]$out.Add("  · 约 $capPct% 的采样处于「功耗墙」状态") }
    }
    else {
        [void]$out.Add('  · 没有可用的遥测数据')
    }
    if ($drvCount -gt 0) { [void]$out.Add("  · 最近 10 分钟 nvlddmkm 驱动事件 $drvCount 条（GPU 执行单元报错）") }
    if ($dumpCount -gt 0) { [void]$out.Add("  · 游戏生成了 $dumpCount 个崩溃转储（.mdmp）") }
    [void]$out.Add('')

    # ── 可能原因 ──
    [void]$out.Add('可能原因（按可能性排序）：')
    $causes = @()
    if ($null -ne $maxT -and $maxT -ge 85) { $causes += '散热不足：崩溃前温度已接近或超过温度墙' }
    if ($null -ne $maxP -and $maxP -gt $maxPLimit) { $causes += '供电瞬态：功耗尖峰超过上限，电压跌落导致 GPU 计算单元出错' }
    if ($drvCount -gt 0) { $causes += '驱动或硬件：nvlddmkm 报告 GPU 执行单元异常（Graphics Exception）' }
    if ($minC -ne $null -and $minC -gt 0 -and $minC -lt 1000) { $causes += '硬件降频：核心频率曾跌到 1000MHz 以下，供电或温度撑不住' }
    if ($causes.Count -eq 0) { $causes += '遥测数值均在正常范围，更可能是驱动缺陷或 GPU 硬件本身的问题' }
    $i = 1
    foreach ($x in $causes) { [void]$out.Add("  $i. $x"); $i++ }
    [void]$out.Add('')

    # ── 建议动作 ──
    [void]$out.Add('建议动作：')
    $acts = @()
    if ($null -ne $maxP -and $maxP -gt $maxPLimit) { $acts += '降低功耗墙：tools\power-cap.ps1 -Watts 145（削平瞬态尖峰，帧数损失约 5%）' }
    if ($drvCount -gt 0 -or $dumpCount -gt 0) { $acts += '确认没有超频：关闭 MSI Afterburner 的超频，或用 tools\apply-fixes.ps1 一键重置' }
    $acts += '关闭硬件加速GPU计划（HAGS）：tools\apply-fixes.ps1（需重启）'
    if ($dumpCount -gt 0) { $acts += '解析转储拿异常码：tools\analyze-dump.ps1 -DumpPath "<转储路径>" -ShowModules' }
    $acts += '若反复发生：更新或回滚到战地6 支持的驱动版本'
    $i = 1
    foreach ($x in $acts) { [void]$out.Add("  $i. $x"); $i++ }

    return $out
}
function Write-CrashReport($exitTime, $isCrash = $true, $reason = '') {
    $stamp = $exitTime.ToString('yyyyMMdd-HHmmss')
    $prefix = if ($isCrash) { 'crash' } else { 'session' }
    $report = Join-Path $RepDir "$prefix-$stamp.txt"
    $sb = New-Object System.Text.StringBuilder
    function L($t) { [void]$sb.AppendLine($t) }

    $gameLabel = if ($script:LogCategory -and $script:LogCategory -ne 'system') { $script:LogCategory } else { '系统' }
    L ('=' * 66)
    if ($isCrash) {
        L "$gameLabel 崩溃报告  $($exitTime.ToString('yyyy-MM-dd HH:mm:ss'))    [判定依据: $reason]"
    }
    else {
        L "$gameLabel 运行记录（正常退出）  $($exitTime.ToString('yyyy-MM-dd HH:mm:ss'))"
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

    # ── 自动诊断 ──
    L '--- 自动诊断 ---'
    try {
        $verdict = @{ IsCrash = $isCrash; Reason = $reason }
        foreach ($dl in (Get-DiagnosisLines $script:LogFile $verdict $exitTime)) { L $dl }
    }
    catch { L "  (诊断生成失败: $($_.Exception.Message))" }
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

function Ensure-ChartBitmaps {
    # 按控件实际像素尺寸创建位图（DPI 缩放后尺寸会变）
    $w1 = [int]$chart.ClientSize.Width; $h1 = [int]$chart.ClientSize.Height
    if ($w1 -lt 1 -or $h1 -lt 1) { return $false }
    if ($null -eq $script:chartBmp -or $script:chartBmp.Width -ne $w1 -or $script:chartBmp.Height -ne $h1) {
        if ($script:chartBmp) { $script:chartBmp.Dispose() }
        $script:chartBmp = New-Object System.Drawing.Bitmap($w1, $h1)
        $chart.Image = $script:chartBmp
    }
    $w2 = [int]$cpuChart.ClientSize.Width; $h2 = [int]$cpuChart.ClientSize.Height
    if ($w2 -lt 1 -or $h2 -lt 1) { return $false }
    if ($null -eq $script:cpuBmp -or $script:cpuBmp.Width -ne $w2 -or $script:cpuBmp.Height -ne $h2) {
        if ($script:cpuBmp) { $script:cpuBmp.Dispose() }
        $script:cpuBmp = New-Object System.Drawing.Bitmap($w2, $h2)
        $cpuChart.Image = $script:cpuBmp
    }
    return $true
}

function Draw-Chart {
    if ($null -eq $script:TempHist -or $script:TempHist.Count -lt 1) { return }
    if (-not (Ensure-ChartBitmaps)) { return }
    $cnt = $script:TempHist.Count
    $spanMin = [math]::Round($cnt * ($script:IntervalMs / 1000.0) / 60.0, 1)
    $secPerPt = $script:IntervalMs / 1000.0
    $infoTxt = ("每 {0:g} 秒 1 点 · {1:N0} 点 · {2} 分钟" -f $secPerPt, $cnt, $spanMin)

    if ($script:HasNvidia) {
        [ChartRenderer]::Render($script:chartBmp, $script:TempHist.ToArray(), $script:PowerHist.ToArray(), $cnt,
            $C.Card, $C.Grid, $C.Accent, $script:ColGray, $C.Dim, $infoTxt,
            '温度 (°C)', '功耗 (W)', '°C', 'W', $script:GpuHover)
    }
    else {
        [ChartRenderer]::Render($script:chartBmp, $script:TempHist.ToArray(), $script:PowerHist.ToArray(), $cnt,
            $C.Card, $C.Grid, $C.Accent, $script:ColOrange, $C.Dim, $infoTxt,
            'GPU 占用 (%)', '显存 (MB)', '%', 'MB', $script:GpuHover)
    }
    $chart.Refresh()

    if ($script:CpuTempHist.Count -ge 1) {
        $cCnt = $script:CpuTempHist.Count
        $cSpan = [math]::Round($cCnt * ($script:IntervalMs / 1000.0) / 60.0, 1)
        $cInfo = ("每 {0:g} 秒 1 点 · {1:N0} 点 · {2} 分钟" -f $secPerPt, $cCnt, $cSpan)
        [ChartRenderer]::Render($script:cpuBmp, $script:CpuTempHist.ToArray(), $script:CpuFreqHist.ToArray(), $cCnt,
            $C.Card, $C.Grid, $C.Accent, $script:ColOrange, $C.Dim, $cInfo,
            'CPU 温度 (°C)', '频率 (MHz)', '°C', 'MHz', $script:CpuHover)
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
    if (-not $script:CpuLast -or ($script:Tick % 2) -eq 1) { $script:CpuLast = Get-CpuSample }
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
    $pstateTxt = switch -Regex ($s.PState) {
        '^P0$' { 'P0 满速' }
        '^P[1-3]$' { "$($s.PState) 降频" }
        '^P[4-9]$' { "$($s.PState) 待机" }
        default { "$($s.PState)" }
    }
    $lblDetail.Text = "显存 {0:N0} / {1} MB      系统内存 {2}      降频 {3}      性能档 {4}" -f `
        $s.MemUsed, $memTotal, $ramTxt, $s.Throttle, $pstateTxt

    # 记录
    if ($script:Recording) {
        $cpuT = if ($null -ne $cpu.Temp) { $cpu.Temp } else { '' }
        $cpuM = if ($null -ne $cpu.MHz) { $cpu.MHz } else { '' }
        $cpuL = if ($null -ne $cpu.Load) { $cpu.Load } else { '' }
        $cpuA = if ($null -ne $cpu.Active) { $cpu.Active } else { '' }
        $cpuN = if ($null -ne $cpu.Total) { $cpu.Total } else { '' }
        $ramP = if ($null -ne $cpu.RamPct) { $cpu.RamPct } else { '' }

        # 日期与时间分开，Excel/WPS 打开才能正确识别
        $row = @(
            $s.Time.ToString('HH:mm:ss'),
            $s.Temp, $s.Power, $s.ClockSm, $s.ClockMem,
            $s.UtilGpu, $s.UtilMem, $s.MemUsed,
            $s.PState, $s.Reason,
            $(if ($s.Throttle -match '功耗墙') { 1 } else { 0 }),
            $(if ($s.Throttle -match '硬件降频') { 1 } else { 0 }),
            $(if ($s.Throttle -match '温度墙') { 1 } else { 0 }),
            $s.Throttle,
            $cpuT, $cpuM, $cpuL, $cpuA, $cpuN, $ramP
        ) -join ','
        Add-Content -Path $script:LogFile -Value $row -Encoding UTF8
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
    if (-not $script:GameScanAt -or ((Get-Date) - $script:GameScanAt).TotalSeconds -ge 1) {
        $script:GameScanResult = Find-RunningGame
        $script:GameScanAt = Get-Date
    }
    $game = $script:GameScanResult
    if ($game) {
        if (-not $script:GameSeen) {
            $script:GameSeen = $true
            $script:GameStart = $game.StartTime
            if ($script:Recording) { Stop-Logging }
            $script:GameName = $game.ProcessName
            Start-Logging $script:GameName
            $lblHint.Text = "已检测到游戏 $($game.ProcessName)（$($game.MainWindowTitle)），正在记录到 logs\$($game.ProcessName)\。"
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
                        "检测到 $($script:GameName) 异常退出（$($verdict.Reason)）。`n`n崩溃报告已保存：`n$rep`n`n记录条数: $($script:LogCount)",
                        '游戏崩溃诊断器 — 检测到崩溃', 'OK', 'Warning') | Out-Null
                }
                else {
                    $lblHint.Text = "游戏正常退出，对局记录已保存: $(Split-Path $rep -Leaf)"
                    $lblHint.ForeColor = $C.Dim
                }
                $script:GameName = $null
$script:GameScanAt = $null
$script:GameScanResult = $null
                Start-Logging 'system'
                $lblHint.Text = "$($lblHint.Text)  已切回系统监控 logs\system\"
            }
        }
    }

    try {
        $ws = [System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB
        $lblMem.Text = "程序内存 {0:N0} MB" -f $ws
    } catch {}

    if ($script:BtnRestore -and (Get-Date) -ge $script:BtnRestore.At) {
        $script:BtnRestore.Btn.Text = $script:BtnRestore.Text
        $script:BtnRestore.Btn.Enabled = $true
        $script:BtnRestore = $null
    }

    $lblStats.Text = "已记录 {0:N0} 条    报告 {1} 份    文件 {2}" -f `
        $script:LogCount, $script:ReportCount, $(if ($script:LogFile) { Split-Path $script:LogFile -Leaf } else { '—' })
}

# ════════════════════════════════ 鼠标悬停提示 ════════════════════════════════
$tip = New-Object System.Windows.Forms.Label
$tip.AutoSize = $true
$tip.BackColor = [System.Drawing.Color]::FromArgb(52, 52, 60)
$tip.ForeColor = [System.Drawing.Color]::FromArgb(235, 235, 240)
$tip.Font = New-Object System.Drawing.Font('Consolas', 9)
$tip.Padding = New-Object System.Windows.Forms.Padding(7, 3, 7, 3)
$tip.BorderStyle = 'FixedSingle'
$tip.Visible = $false
$form.Controls.Add($tip)

function Show-HoverTip([string]$which, $ctrl, [int]$x, [int]$y = 10) {
    $isGpu = ($which -eq 'gpu')
    $listA = if ($isGpu) { $script:TempHist } else { $script:CpuTempHist }
    $listB = if ($isGpu) { $script:PowerHist } else { $script:CpuFreqHist }
    $n = $listA.Count
    if ($n -lt 2) { return }

    $ratio = [math]::Max(0.0, [math]::Min(1.0, ($x - 6) / ([double]$ctrl.Width - 12)))
    $idx = [int][math]::Round($ratio * ($n - 1))

    if ($isGpu) {
        if ($script:GpuHover -eq $idx) { return }
        $script:GpuHover = $idx
    }
    else {
        if ($script:CpuHover -eq $idx) { return }
        $script:CpuHover = $idx
    }

    $va = [double]$listA[$idx]
    $vb = [double]$listB[$idx]
    $backSec = [int][math]::Round(($n - 1 - $idx) * ($script:IntervalMs / 1000.0))
    $ago = if ($backSec -le 0) { '最新' } else { "-${backSec}s" }

    if ($isGpu) {
        $tip.Text = if ($script:HasNvidia) {
            "温度 {0:N1}°C   功耗 {1:N0}W   {2}" -f $va, $vb, $ago
        } else {
            "占用 {0:N0}%   显存 {1:N0}MB   {2}" -f $va, $vb, $ago
        }
    }
    else {
        $tip.Text = "温度 {0:N0}°C   频率 {1:N0}MHz   {2}" -f $va, $vb, $ago
    }

    if (-not $tip.IsHandleCreated) { $null = $tip.Handle }
    $tip.Visible = $true
    $tip.BringToFront()
    $px = $ctrl.Left + $x - [int]($tip.Width / 2)
    $px = [math]::Max(4, [math]::Min($form.ClientSize.Width - $tip.Width - 4, $px))
    $py = $ctrl.Top + $y - $tip.Height - 12
    if ($py -lt $ctrl.Top + 4) { $py = $ctrl.Top + 4 }
    if ($py -gt ($ctrl.Top + $ctrl.Height - $tip.Height - 4)) { $py = $ctrl.Top + $ctrl.Height - $tip.Height - 4 }
    $tip.Location = New-Object System.Drawing.Point($px, $py)

    # 重绘节流，避免鼠标激动时卡顿
    $nowTick = [Environment]::TickCount
    if (($nowTick - $script:LastHoverMs) -ge 100) {
        $script:LastHoverMs = $nowTick
        Draw-Chart
    }
}

$chart.Add_MouseMove({ param($s, $e) Show-HoverTip 'gpu' $s $e.X $e.Y })
$chart.Add_MouseLeave({
    $script:GpuHover = -1
    $tip.Visible = $false
    Draw-Chart
})
$cpuChart.Add_MouseMove({ param($s, $e) Show-HoverTip 'cpu' $s $e.X $e.Y })
$cpuChart.Add_MouseLeave({
    $script:CpuHover = -1
    $tip.Visible = $false
    Draw-Chart
})
# ════════════════════════════════ 事件绑定 ════════════════════════════════
$btnStart.Add_Click({
    if (-not $script:Recording) {
        $cat = if ($script:GameName) { $script:GameName } else { 'system' }
        Start-Logging $cat
        $lblHint.Text = "已手动开始记录（logs\$cat\）。"
    }
})
$btnStop.Add_Click({
    if ($script:Recording) { Stop-Logging; $lblHint.Text = '已停止记录。' }
})
function Open-FolderWithFeedback($btn, $normalText, $path) {
    $btn.Text = '打开中…'
    $btn.Enabled = $false
    $btn.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    try {
        if (-not (Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$path`""
    } catch {}
    $script:BtnRestore = @{ Btn = $btn; Text = $normalText; At = (Get-Date).AddMilliseconds(900) }
}

$btnLogs.Add_Click({
    $cat = if ($script:GameName) { $script:GameName } else { 'system' }
    $target = Join-Path $LogDir $cat
    if (-not (Test-Path $target)) { $target = $LogDir }
    Open-FolderWithFeedback $btnLogs '打开数据目录' $target
})
$btnRep.Add_Click({ Open-FolderWithFeedback $btnRep '打开崩溃报告' $RepDir })

$btnStop.Enabled = $false

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = $script:IntervalMs
$script:Timer.Add_Tick({ try { Update-UI } catch { $lblStatus.Text = '✕ 错误'; $lblStatus.ForeColor = $C.Bad } })

$form.Add_Shown({
    $script:Timer.Start()
    if ($Tray) { $form.Hide() }
    try {
        $chkAutoStart.Checked = Test-AutoStart
        $script:AutoStartInit = $true
    } catch { $script:AutoStartInit = $true }
    $hasGame = $null -ne (Find-RunningGame)
    if (-not $hasGame -and -not $script:Recording) {
        Start-Logging 'system'
        $lblHint.Text = '未检测到游戏，正在做系统监控（logs\system\）。启动任意全屏游戏会自动切换记录。'
    }
    Update-UI
})
$form.Add_FormClosing({
    $script:Timer.Stop()
    if ($script:Recording) { Stop-Logging }
})

# ── 按系统 DPI 等比缩放整个界面（字体是点数，天然跟着 DPI 走）──
$script:DpiScale = 1.0
try {
    $gs = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $script:DpiScale = [math]::Round($gs.DpiX / 96.0, 2)
    $gs.Dispose()
} catch {}
if ($script:DpiScale -gt 1.01) {
    $sz = New-Object System.Drawing.SizeF($script:DpiScale, $script:DpiScale)
    $form.Scale($sz)
}
# ── 单实例保护：重复点图标只保留一个实例 ──
if (-not ($SelfTest -or $UiTest -or $Shot -or $ForceLog)) {
    $script:SingleMutex = New-Object System.Threading.Mutex($false, 'Local\GameCrashDiag_SingleInstance')
    if (-not $script:SingleMutex.WaitOne(0)) {
        # 已有实例：把它的窗口拉到前台，然后静默退出（开机自启时不打扰）
        if (-not $Tray) {
        try {
            Add-Type -Namespace W32Win -Name Fg -MemberDefinition @"
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
"@ -ErrorAction SilentlyContinue
            $h = [W32Win.Fg]::FindWindow($null, '游戏崩溃诊断器')
            if ($h -ne [IntPtr]::Zero) {
                [void][W32Win.Fg]::ShowWindow($h, 9)
                [void][W32Win.Fg]::SetForegroundWindow($h)
            }
        } catch {}
        }
        exit
    }
}
if ($TestReport) {
    Start-Logging 'system'
    for ($i = 0; $i -lt 6; $i++) { Update-UI; Start-Sleep -Milliseconds 400 }
    $script:LogCount = 6
    Stop-Logging
    $rep = Write-CrashReport (Get-Date) $true '测试样本'
    Write-Output "报告已生成: $rep"
    exit 0
}
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
    if ($FillPoints -gt 0) {
        Show-HoverTip 'gpu' $chart ([int]($chart.Width * 0.62)) 40
        [System.Windows.Forms.Application]::DoEvents()
        Write-Output ("提示框: visible={0} size={1}x{2} pos=({3},{4}) text={5}" -f `
            $tip.Visible, $tip.Width, $tip.Height, $tip.Left, $tip.Top, $tip.Text)
    }
    $bmp2 = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp2, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bmp2.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp2.Dispose()
    Write-Output "截图已保存: $Shot"
    $form.Dispose()
    exit 0
}

# ════════════════════════════════ 托盘图标 ════════════════════════════════
$script:ExitFlag = $false
$trayIcon = New-Object System.Windows.Forms.NotifyIcon
try {
    $icoPath = Join-Path $Root 'app.ico'
    if (Test-Path $icoPath) { $trayIcon.Icon = New-Object System.Drawing.Icon($icoPath) }
    else { $trayIcon.Icon = [System.Drawing.SystemIcons]::Application }
} catch { $trayIcon.Icon = [System.Drawing.SystemIcons]::Application }
$trayIcon.Text = '游戏崩溃诊断器'
$trayIcon.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = $trayMenu.Items.Add('显示主界面')
$miFolder = $trayMenu.Items.Add('打开数据目录')
[void]$trayMenu.Items.Add('-')
$miExit = $trayMenu.Items.Add('退出')
$trayIcon.ContextMenuStrip = $trayMenu

function Show-MainWindow {
    try {
        $form.ShowInTaskbar = $true
        $form.Show()
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        # 手动居中（Form 没有 CenterToScreen 方法）
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $form.StartPosition = 'Manual'
        $form.Location = New-Object System.Drawing.Point(
            [int](($wa.Width - $form.Width) / 2 + $wa.X),
            [int](($wa.Height - $form.Height) / 2 + $wa.Y))
        $form.Activate()
        $form.BringToFront()
    } catch {}
}

$miShow.Add_Click({ Show-MainWindow })
$miFolder.Add_Click({
    $cat = if ($script:GameName) { $script:GameName } else { 'system' }
    $target = Join-Path $LogDir $cat
    if (-not (Test-Path $target)) { $target = $LogDir }
    Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$target`""
})
$miExit.Add_Click({
    $script:ExitFlag = $true
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
    $form.Close()
})
$trayIcon.Add_DoubleClick({ Show-MainWindow })

# 测试钩子：-ShowAfter N 启动 N 秒后模拟托盘唤出
if ($ShowAfter -gt 0) {
    $script:ShowTimer = New-Object System.Windows.Forms.Timer
    $script:ShowTimer.Interval = $ShowAfter * 1000
    $script:ShowTimer.Add_Tick({
        $script:ShowTimer.Stop()
        Show-MainWindow
    })
    $script:ShowTimer.Start()
}
$trayIcon.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-MainWindow }
})

# 点 X 不退出，收到托盘继续记录
$form.Add_FormClosing({
    param($s, $e)
    if (-not $script:ExitFlag) {
        $e.Cancel = $true
        $form.Hide()
        $form.ShowInTaskbar = $false
        try {
            $trayIcon.ShowBalloonTip(1500, '游戏崩溃诊断器', '已最小化到托盘，仍在后台记录。双击图标可重新打开。', [System.Windows.Forms.ToolTipIcon]::Info)
        } catch {}
    }
})
if ($Minimized) {
    $form.WindowState = 'Minimized'
    $form.ShowInTaskbar = $true
}
if ($Tray) {
    # 开机自启：不占任务栏，直接藏到托盘
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point(-32000, -32000)
    $form.ShowInTaskbar = $false
}
[System.Windows.Forms.Application]::Run($form)
