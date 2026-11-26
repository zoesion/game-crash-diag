<#
.SYNOPSIS
    GameCrashDiag —— 游戏崩溃诊断器（图形界面版）

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
    [switch]$TestDiagnosis,
    [switch]$TestView,
    [switch]$ShowAbout,
    [switch]$ShowDiagnosis,
    [switch]$TestCrash,
    [switch]$TestClear,
    [switch]$TestGameStart,
    [switch]$TestMarkerShot,
    [switch]$TestRestore,
    [string]$MarkerShotPath = '',
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
# ── 多语言 ──
$script:SettingsDir  = Join-Path $env:LOCALAPPDATA 'GameCrashDiag'
$script:SettingsFile = Join-Path $script:SettingsDir 'settings.json'
$script:LangCode = 'zh-CN'
try {
    if (Test-Path $script:SettingsFile) {
        $st = Get-Content $script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($st.Language) { $script:LangCode = $st.Language }
    }
} catch { }
if (-not (Test-Path (Join-Path $Root "lang\$($script:LangCode).psd1"))) { $script:LangCode = 'zh-CN' }
$script:T = Import-PowerShellDataFile -Path (Join-Path $Root "lang\$($script:LangCode).psd1")
$script:AppVersion = 'v5.97'
$script:BuildDate  = '2026-11-25'

function Set-Language([string]$code) {
    try {
        if (-not (Test-Path $script:SettingsDir)) { New-Item -ItemType Directory -Force -Path $script:SettingsDir | Out-Null }
        $obj = @{ Language = $code; UpdatedAt = (Get-Date).ToString('s') } | ConvertTo-Json
        Set-Content -Path $script:SettingsFile -Value $obj -Encoding UTF8
        return $true
    } catch { return $false }
}

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
        Throttle = if ($throttle.Count) { $throttle -join ' + ' } else { $script:T.ThrottleNone }
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

# ── LibreHardwareMonitor 传感器库（随程序分发，用户无需安装）──
# 用来补齐 nvidia-smi 读不到的数据：AMD / Intel 显卡的温度、功耗、频率，以及 CPU 封装温度。
$script:HasLhm = $false
$script:LastShutdownWasBad = $false
$script:LhmCpuTemp = $null
$script:LhmCpuAt = [datetime]::MinValue
try {
    $lhmDir = Join-Path $Root 'thirdparty\lhm'
    $lhmDll = Join-Path $lhmDir 'LibreHardwareMonitorLib.dll'
    $hidDll = Join-Path $lhmDir 'HidSharp.dll'
    $lhmSrc = Join-Path $Root 'LhmBridge.cs'
    if ((Test-Path $lhmDll) -and (Test-Path $hidDll) -and (Test-Path $lhmSrc)) {
        # 网络下载会带 MOTW，.NET 拒绝加载被锁定的程序集，先解除
        try { Get-ChildItem $lhmDir -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue } catch { }
        [System.Reflection.Assembly]::LoadFrom($hidDll) | Out-Null
        [System.Reflection.Assembly]::LoadFrom($lhmDll) | Out-Null
        if (-not ('LhmBridge' -as [type])) {
            Add-Type -Path $lhmSrc -ReferencedAssemblies @($lhmDll, $hidDll, 'System.dll', 'System.Core.dll')
        }
        if ([LhmBridge]::Init()) { $script:HasLhm = $true }
    }
} catch { $script:LhmError = $_.Exception.Message }


# 通用模式：Windows 自带 GPU 性能计数器（A 卡 / 核显可用，只有占用率和显存）
function Get-GenericGpuSample {
    # 有 LHM 就用它的真实传感器（AMD / Intel 显卡的温度、功耗、频率都能读到）
    if ($script:HasLhm) {
        try {
            $g = [LhmBridge]::ReadGpu()
            if ($null -ne $g) {
                $t = if ([double]::IsNaN($g[0])) { $null } else { [math]::Round($g[0], 1) }
                $pw = if ([double]::IsNaN($g[1])) { $null } else { [math]::Round($g[1], 1) }
                $clk = if ([double]::IsNaN($g[2])) { $null } else { [math]::Round($g[2], 0) }
                $clkm = if ([double]::IsNaN($g[3])) { $null } else { [math]::Round($g[3], 0) }
                $load = if ([double]::IsNaN($g[4])) { $null } else { [math]::Round($g[4], 0) }
                $vr = if ([double]::IsNaN($g[5])) { $null } else { [math]::Round($g[5], 0) }
                $vrt = if ([double]::IsNaN($g[6])) { $null } else { [math]::Round($g[6], 0) }
                if ($null -ne $t -or $null -ne $load) {
                    return [pscustomobject]@{
                        Time = Get-Date; Temp = $t; Power = $pw; ClockSm = $clk; ClockMem = $clkm
                        UtilGpu = $load; UtilMem = $null; MemUsed = $vr; MemTotal = $vrt
                        PState = '-'; Reason = '-'; Throttle = '-'
                        HotSpot = if ([double]::IsNaN($g[7])) { $null } else { [math]::Round($g[7], 1) }
                    }
                }
            }
        } catch { }
    }

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
    'RzChromaStreamServer', 'SyserrorOverlay', 'TranslucentTB', 'Rainmeter',
    # 全屏但不是游戏的应用（实测误报过）
    'ollama', 'ollama app', 'ollama_llama_server', 'SnippingTool', 'ScreenClippingHost',
    'QQMusic', 'QQMusicMini', 'cloudmusic', 'NeteaseCloudMusic', 'KuGou', 'PotPlayerMini64',
    'vlc', 'mpc-hc64', 'mpv', 'obs64', 'OBS', 'Zoom', 'WeChat', 'WeChatAppEx', 'QQ',
    'Photos', 'PhotosApp', 'mspaint', 'Notepad', 'notepad++', 'WINWORD', 'EXCEL', 'POWERPNT',
    'Acrobat', 'AcroRd32', 'SumatraPDF', 'BaiduNetdisk', 'Thunder', 'IDMan',
    'Pixso', 'Figma', 'Photoshop', 'Illustrator', 'AfterFX', 'Premiere Pro',
    'Obsidian', 'Notion', 'Typora', 'wmplayer', 'MusicBee', 'foobar2000',
    # 游戏平台客户端（本身不是游戏）
    'EpicGamesLauncher', 'Battle.net', 'Origin', 'EA Desktop', 'EAapp', 'UbisoftConnect',
    'GalaxyClient', 'RiotClientServices', 'WeGame', 'wegame', 'Steam', 'steamwebhelper'
)
# 这些路径下的进程一律不当游戏（叠加层/启动器/系统组件）
$script:ExcludePaths = @('\Windows\', '\NVIDIA Corporation\', '\Steam\bin\', '\Razer\', '\ProgramData\Microsoft\Windows Defender\',
                        '\Program Files\WindowsApps\', '\AppData\Local\Programs\ollama\', '\AppData\Local\Ollama\')
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
    # 但低于 400MB 的一律不算游戏：音乐播放器、截图工具这类也会全屏
    $best = $candidates | Sort-Object Mem -Descending | Select-Object -First 1
    if ($best.Mem -lt 400MB) { return $null }
    return $best.Proc
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
$script:LastActiveCores = 0
$script:LastViewTouch = $null
$script:Markers = New-Object 'System.Collections.Generic.List[object]'
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
            $maxCore = 0.0
            $readFail = $false
            foreach ($cc in $script:PcCores) {
                try {
                    $v = $cc.NextValue()
                    if ($v -gt $maxCore) { $maxCore = $v }
                    if ($v -gt 20) { $active++ }
                } catch { $readFail = $true }
            }
            $s.Total = $script:PcCores.Count
            # 计数器偶发全 0 或个别核心读取失败时，沿用上一次的有效值，避免闪 0
            if ($active -eq 0 -and ($readFail -or $maxCore -le 0.5) -and $script:LastActiveCores -gt 0) {
                $active = $script:LastActiveCores
            }
            # 系统始终有内核活动，活跃核心不可能是 0
            if ($active -lt 1) { $active = 1 }
            $s.Active = $active
            $script:LastActiveCores = $active
        }
    } catch {}

    # 内存
    try {
        $avail = $script:PcMem.NextValue()
        if ($script:RamTotalMB -gt 0 -and $avail -gt 0) {
            $s.RamPct = [int][math]::Round((1 - ($avail / $script:RamTotalMB)) * 100)
        }
    } catch {}

    # 温度：优先用 LibreHardwareMonitor 的 CPU Package（比 ACPI 热区准），5 秒一采
    $now = Get-Date
    if ($script:HasLhm -and ($now - $script:LhmCpuAt).TotalSeconds -ge 5) {
        try {
            $lt = [LhmBridge]::ReadCpuTemp()
            if (-not [double]::IsNaN($lt) -and $lt -gt 0) { $script:LhmCpuTemp = [math]::Round($lt, 1) }
        } catch { }
        $script:LhmCpuAt = $now
    }
    if ($null -ne $script:LhmCpuTemp) { $s.Temp = $script:LhmCpuTemp } else {
        # 回退：ACPI 热区查询 30ms，缓存 10 秒
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
    }

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
$form.Text = $script:T.AppTitle
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.Size = New-Object System.Drawing.Size(760, 636)
$form.MinimumSize = New-Object System.Drawing.Size(680, 660)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $C.Bg
$form.ForeColor = $C.Text
$form.Font = $FontUI
$form.FormBorderStyle = 'FixedSingle'
try {
    $icoPath = Join-Path $Root 'app.ico'
    if (Test-Path $icoPath) { $form.Icon = New-Object System.Drawing.Icon($icoPath) }
} catch { }
$form.MaximizeBox = $false

$gpuInfo = Get-GpuInfo

# ── 顶部标题 ──
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = $script:T.AppTitle
$lblTitle.Font = $FontTitle
$lblTitle.ForeColor = $C.Text
$lblTitle.Location = New-Object System.Drawing.Point(44, 8)
$lblTitle.AutoSize = $true
$form.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$modeTxt = if ($script:HasNvidia) { '' } else { '    （通用模式）' }
$lblSub.Text = "GPU  ·  $($gpuInfo.Name)    " + $script:T.Driver + " $($gpuInfo.Driver)$modeTxt"
$lblSub.Font = $FontMid
$lblSub.ForeColor = $C.Dim
$lblSub.Location = New-Object System.Drawing.Point(8, 42)
$lblSub.AutoSize = $true
$form.Controls.Add($lblSub)

# ── 状态灯 ──
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = $script:T.StatusIdle
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

$cardTemp  = New-Card 6   66 178 74 $script:T.CardTemp
$cardPower = New-Card 196 66 178 74 $script:T.CardPower
$cardClock = New-Card 386 66 178 74 $script:T.CardClock
$cardUtil  = New-Card 576 66 178 74 $script:T.CardUtil

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

$script:UnitLabels = New-Object System.Collections.Generic.List[object]
function New-UnitLabel($card, $text) {
    $u = New-Object System.Windows.Forms.Label
    $u.Text = $text
    $u.Font = $FontSmall
    $u.ForeColor = $C.Dim
    $u.AutoSize = $true
    $u.Location = New-Object System.Drawing.Point(140, 12)
    $card.Controls.Add($u)
    $script:UnitLabels.Add([pscustomobject]@{ Label = $u; Card = $card })
    return $u
}
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
$chartW, $chartH = 748, 96
$chart = New-Object System.Windows.Forms.PictureBox
$chart.Location = New-Object System.Drawing.Point(6, 146)
$chart.Size = New-Object System.Drawing.Size($chartW, $chartH)
$chart.BackColor = $C.Card
$form.Controls.Add($chart)

$chart.Image = $null


# ── CPU 走势图 ──
$cpuChart = New-Object System.Windows.Forms.PictureBox
$cpuChart.Location = New-Object System.Drawing.Point(6, 350)
$cpuChart.Size = New-Object System.Drawing.Size($chartW, 96)
$cpuChart.BackColor = $C.Card
$form.Controls.Add($cpuChart)
# 位图在 Draw-Chart 里按控件实际像素尺寸懒创建（DPI 缩放后尺寸会变）
$script:chartBmp = $null
$script:cpuBmp = $null

# ── CPU 型号标题 ──
$cpuInfo = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
$cpuNameTxt = if ($cpuInfo) { $cpuInfo.Name.Trim() } else { 'CPU' }
$cpuCoreTxt = if ($cpuInfo) { $script:T.CoresThreads -f $cpuInfo.NumberOfCores, $cpuInfo.NumberOfLogicalProcessors } else { '' }

$lblCpuModel = New-Object System.Windows.Forms.Label
$lblCpuModel.Text = "CPU  ·  $cpuNameTxt    $cpuCoreTxt"
$lblCpuModel.Font = $FontMid
$lblCpuModel.ForeColor = $C.Dim
$lblCpuModel.Location = New-Object System.Drawing.Point(8, 250)
$lblCpuModel.AutoSize = $true
$form.Controls.Add($lblCpuModel)

# ── CPU 四个卡片 ──
$cardCpuTemp  = New-Card 6   270 178 74 $script:T.CardCpuTemp
$cardCpuClock = New-Card 196 270 178 74 $script:T.CardCpuClock
$cardCpuUtil  = New-Card 386 270 178 74 $script:T.CardCpuUtil
$cardCpuCores = New-Card 576 270 178 74 $script:T.CardCores

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
# ── 时间轴滚动条（浏览器样式，自动跟随最新）──
$script:FollowLive = $true
$script:BarTrack   = [System.Drawing.Color]::FromArgb(38, 38, 46)
$script:BarThumb   = [System.Drawing.Color]::FromArgb(112, 112, 126)
$script:BarThumbHot = [System.Drawing.Color]::FromArgb(158, 158, 174)
$script:BarDrag = $false
$script:BarDragX = 0
$script:BarDragShift = 0

# 自绘滚动条：细灰色圆角拖动条（替代系统 HScrollBar）
$script:ChartBar = New-Object System.Windows.Forms.Panel
$script:ChartBar.Location = New-Object System.Drawing.Point(6, 452)
$script:ChartBar.Size = New-Object System.Drawing.Size(748, 10)
$script:ChartBar.BackColor = $script:BarTrack
$script:ChartBar.Visible = $false

$script:ChartThumb = New-Object System.Windows.Forms.Panel
$script:ChartThumb.Size = New-Object System.Drawing.Size(120, 8)
$script:ChartThumb.Location = New-Object System.Drawing.Point(0, 2)
$script:ChartThumb.BackColor = $script:BarThumb
$script:ChartBar.Controls.Add($script:ChartThumb)

function Update-ChartThumbShape {
    try {
        $w = $script:ChartThumb.Width; $h = $script:ChartThumb.Height
        if ($w -lt 8 -or $h -lt 4) { return }
        $r = [int][math]::Min(4, $h / 2)
        $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
        $gp.AddArc(0, 0, $r * 2, $r * 2, 180, 90)
        $gp.AddArc($w - $r * 2, 0, $r * 2, $r * 2, 270, 90)
        $gp.AddArc($w - $r * 2, $h - $r * 2, $r * 2, $r * 2, 0, 90)
        $gp.AddArc(0, $h - $r * 2, $r * 2, $r * 2, 90, 90)
        $gp.CloseFigure()
        $old = $script:ChartThumb.Region
        $script:ChartThumb.Region = New-Object System.Drawing.Region($gp)
        if ($old) { $old.Dispose() }
        $gp.Dispose()
    } catch { }
}

function Get-ChartScrollable {
    $total = $script:TempHist.Count
    $span = [math]::Max(1, [int]$script:ViewSpanPts)
    return [math]::Max(0, $total - $span)
}

function Set-ChartShiftFromThumb {
    $travel = [math]::Max(1, $script:ChartBar.Width - $script:ChartThumb.Width)
    $scrollable = Get-ChartScrollable
    if ($scrollable -le 0) { $script:ViewShiftPts = 0; $script:FollowLive = $true; return }
    $ratio = [math]::Min(1.0, [math]::Max(0.0, $script:ChartThumb.Left / $travel))
    $script:ViewShiftPts = [int][math]::Round((1 - $ratio) * $scrollable)
    $script:FollowLive = ($script:ViewShiftPts -le 0)
    $script:GpuHover = -1
    $script:CpuHover = -1
    Draw-Chart
}

function Update-ChartBar {
    $total = $script:TempHist.Count
    $span = [math]::Max(1, [int]$script:ViewSpanPts)
    if ($total -le $span -or $script:ChartBar.Width -lt 40) { $script:ChartBar.Visible = $false; return }
    $script:ChartBar.Visible = $true
    $w = $script:ChartBar.Width
    $tw = [int][math]::Max(28, [math]::Round($w * ($span / [double]$total)))
    if ($tw -gt $w) { $tw = $w }
    if ($script:ChartThumb.Width -ne $tw) { $script:ChartThumb.Width = $tw; Update-ChartThumbShape }
    $travel = [math]::Max(0, $w - $tw)
    $scrollable = [math]::Max(1, $total - $span)
    $pos = [int][math]::Round($travel * (1 - [math]::Min(1.0, $script:ViewShiftPts / [double]$scrollable)))
    $script:ChartThumb.Left = $pos
    $script:ChartBar.BringToFront()
}

$script:ChartThumb.Add_MouseDown({ param($s, $e)
    $script:BarDrag = $true
    $script:LastViewTouch = Get-Date
    $script:BarDragX = [System.Windows.Forms.Cursor]::Position.X
    $script:BarDragShift = $script:ViewShiftPts
})
$script:ChartThumb.Add_MouseMove({ param($s, $e)
    if (-not $script:BarDrag) { return }
    $dx = [System.Windows.Forms.Cursor]::Position.X - $script:BarDragX
    $travel = [math]::Max(1, $script:ChartBar.Width - $script:ChartThumb.Width)
    $scrollable = Get-ChartScrollable
    if ($scrollable -le 0) { return }
    $shift = $script:BarDragShift - [int][math]::Round($dx / $travel * $scrollable)
    if ($shift -lt 0) { $shift = 0 }
    if ($shift -gt $scrollable) { $shift = $scrollable }
    $script:ViewShiftPts = $shift
    $script:FollowLive = ($shift -le 0)
    $script:LastViewTouch = Get-Date
    $script:GpuHover = -1
    $script:CpuHover = -1
    Draw-Chart
})
$script:ChartThumb.Add_MouseUp({ param($s, $e) $script:BarDrag = $false })
$script:ChartThumb.Add_MouseEnter({ param($s, $e) $script:ChartThumb.BackColor = $script:BarThumbHot })
$script:ChartThumb.Add_MouseLeave({ param($s, $e) if (-not $script:BarDrag) { $script:ChartThumb.BackColor = $script:BarThumb } })

$script:ChartBar.Add_MouseDown({ param($s, $e)
    # 点空白处：跳到该位置
    $travel = [math]::Max(1, $script:ChartBar.Width - $script:ChartThumb.Width)
    $x = $e.X - [int]($script:ChartThumb.Width / 2)
    if ($x -lt 0) { $x = 0 }
    if ($x -gt $travel) { $x = $travel }
    $script:ChartThumb.Left = $x
    $script:LastViewTouch = Get-Date
    Set-ChartShiftFromThumb
})
$form.Controls.Add($script:ChartBar)
$script:ColRed    = [System.Drawing.Color]::FromArgb(90, 155, 220)     # 功耗曲线（冷蓝）
$script:ColPurple = [System.Drawing.Color]::FromArgb(150, 130, 220)    # 频率曲线（淡紫）

$lblDetail = New-Object System.Windows.Forms.Label
$lblDetail.Text = 'CPU -- / -- / --      显存 -- / -- MB      降频 --'
$lblDetail.Font = $FontSmall
$lblDetail.ForeColor = $C.Dim
$lblDetail.Location = New-Object System.Drawing.Point(6, 476)
$lblDetail.Size = New-Object System.Drawing.Size(720, 20)
$form.Controls.Add($lblDetail)

$lblStats = New-Object System.Windows.Forms.Label
$lblStats.Text = '本次未记录'
$lblStats.Font = $FontSmall
$lblStats.ForeColor = $C.Dim
$lblStats.Location = New-Object System.Drawing.Point(6, 500)
$lblStats.Size = New-Object System.Drawing.Size(720, 20)
$form.Controls.Add($lblStats)

# ── 按钮 ──
function New-Button($x, $text, $w = 120) {
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

# ── 左上角：设置菜单 ──
$script:RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:RunName = 'GameCrashDiag'
$script:AutoStartInit = $false

$btnMenu = New-Object System.Windows.Forms.Button
$btnMenu.Text = '☰'
$btnMenu.Size = New-Object System.Drawing.Size(32, 28)
$btnMenu.Location = New-Object System.Drawing.Point(6, 10)
$btnMenu.FlatStyle = 'Flat'
$btnMenu.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 12)
$btnMenu.BackColor = [System.Drawing.Color]::FromArgb(34, 34, 40)
$btnMenu.ForeColor = $C.Text
$btnMenu.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(64, 64, 78)
$btnMenu.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(56, 56, 68)
$btnMenu.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnMenu)
$btnMenu.BringToFront()

$script:MainMenu = New-Object System.Windows.Forms.ContextMenuStrip
$script:MainMenu.Font = $FontBody
$miStart = $script:MainMenu.Items.Add($script:T.MenuStart)
$miStop  = $script:MainMenu.Items.Add($script:T.MenuStop)
[void]$script:MainMenu.Items.Add('-')
$miLogs  = $script:MainMenu.Items.Add($script:T.MenuLogs)
$miRep   = $script:MainMenu.Items.Add($script:T.MenuReports)
$miDiag  = $script:MainMenu.Items.Add($script:T.MenuDiag)
# ── 清空数据 ──
$miClear = $script:MainMenu.Items.Add($script:T.MenuClear)
$miClearChart = $miClear.DropDownItems.Add($script:T.ClearChart)
$miClearAll   = $miClear.DropDownItems.Add($script:T.ClearAll)

# ── 载入更早的记录（从 logs 往前拼） ──
$miLoadOlder = $script:MainMenu.Items.Add($script:T.MenuLoadOlder)
$miLoadOlder.Add_Click({
    $script:Timer.Stop()
    try {
        $before = $script:TempHist.Count
        $added = Load-OlderHistory 6
        $script:FollowLive = $false
        $script:ViewShiftPts = [int]$script:ViewShiftPts + $added
        Draw-Chart
        if ($added -gt 0) {
            $hours = [math]::Round((Get-LoadedHours), 1)
            $lblHint.Text = $script:T.LoadOlderHint -f $added, $hours
            $lblHint.ForeColor = $C.Accent
        } elseif ($script:LoadOlderStatus -eq 'cap') {
            $lblHint.Text = $script:T.LoadOlderCap
            $lblHint.ForeColor = $C.Warn
        } else {
            $lblHint.Text = $script:T.LoadOlderNone
            $lblHint.ForeColor = $C.Dim
        }
    } catch {} finally { $script:Timer.Start() }
})

$miClearChart.Add_Click({
    $script:Timer.Stop()
    try {
        Clear-ChartData
        Draw-Chart
        $lblHint.Text = $script:T.ClearChartDone
        $lblStatus.Text = $(if ($script:Recording) { $script:T.StatusRec } else { $script:T.StatusIdle })
        $lblStatus.ForeColor = $C.Accent
    } catch {} finally { $script:Timer.Start() }
})

$miClearAll.Add_Click({
    $ans = [System.Windows.Forms.MessageBox]::Show($script:T.ClearAsk, $script:T.AppTitle, 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { return }
    $script:Timer.Stop()
    try {
        Clear-AllData
        Draw-Chart
        $lblHint.Text = $script:T.ClearDone
        $lblStatus.Text = $script:T.StatusRec
        $lblStatus.ForeColor = $C.Accent
    } catch {} finally { $script:Timer.Start() }
})
$miDxStatus = $script:MainMenu.Items.Add($script:T.DxChecking)
$miDxStatus.Enabled = $false
$miDxFix = $script:MainMenu.Items.Add($script:T.DxView)
[void]$script:MainMenu.Items.Add('-')
$miAuto  = $script:MainMenu.Items.Add($script:T.MenuAuto)
$miAuto.CheckOnClick = $true
$miMem   = $script:MainMenu.Items.Add(($script:T.MenuMem -f 0))
$miMem.Enabled = $false
[void]$script:MainMenu.Items.Add('-')
[void]$script:MainMenu.Items.Add('-')
$miLang  = $script:MainMenu.Items.Add($script:T.MenuLang)
$miZh    = $miLang.DropDownItems.Add('简体中文')
$miEn    = $miLang.DropDownItems.Add('English')
$miZh.Checked = ($script:LangCode -eq 'zh-CN')
$miEn.Checked = ($script:LangCode -eq 'en-US')

$applyLang = {
    param($code, $label)
    if (Set-Language $code) {
        $lblHint.Text = "Language: $label  ·  Restarting..."
        Start-Sleep -Milliseconds 400
        Start-Process 'wscript.exe' -ArgumentList "`"$(Join-Path $Root '启动诊断器.vbs')`""
        $script:ExitFlag = $true
        $form.Close()
    }
}
$miZh.Add_Click({ & $applyLang 'zh-CN' '简体中文' })
$miEn.Add_Click({ & $applyLang 'en-US' 'English' })
$miAbout = $script:MainMenu.Items.Add($script:T.MenuAbout)

$btnMenu.Add_Click({
    try { $miAuto.Checked = Test-AutoStart } catch {}
    $script:MainMenu.Show($btnMenu, (New-Object System.Drawing.Point(0, $btnMenu.Height)))
})

$miStart.Add_Click({ if (-not $script:Recording) { Start-Logging 'system'; $lblHint.Text = $script:T.HintManual } })
$miStop.Add_Click({ if ($script:Recording) { Stop-Logging; $lblHint.Text = $script:T.HintStopped } })
$miLogs.Add_Click({ Open-FolderWithFeedback $null '打开数据目录' $LogDir })
$miRep.Add_Click({ Open-FolderWithFeedback $null '打开崩溃报告' $RepDir })
$miDiag.Add_Click({ Show-DiagnosisWindow })
$miDxFix.Add_Click({ Show-DxAction })
$miAbout.Add_Click({ Show-AboutDialog })

$miAuto.Add_CheckedChanged({
    if (-not $script:AutoStartInit) { return }
    $ok = Set-AutoStart $miAuto.Checked
    if (-not $ok) { $lblHint.Text = $script:T.HintAutoFail; return }
    if ($miAuto.Checked) { $lblHint.Text = $script:T.HintAutoOn }
    else { $lblHint.Text = $script:T.HintAutoOff }
})
function Test-AutoStart {
    $v = (Get-ItemProperty -Path $script:RunKey -Name $script:RunName -ErrorAction SilentlyContinue).$($script:RunName)
    return -not [string]::IsNullOrWhiteSpace($v)
}

function Set-AutoStart([bool]$enable) {
    try {
        if ($enable) {
            # 用 wscript 启动，避免开机时 PowerShell 控制台窗口闪一下
            $vbs = Join-Path $Root '自启-托盘.vbs'
            if (Test-Path $vbs) {
                $wsExe = Join-Path $env:WINDIR 'System32\wscript.exe'
                $cmd = "`"$wsExe`" `"$vbs`""
            } else {
                $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $appPath = Join-Path $Root 'GameCrashDiag.ps1'
                $cmd = "`"$psExe`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$appPath`" -Tray -IntervalMs 500"
            }
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
$lblHint.Location = New-Object System.Drawing.Point(6, 524)
$lblHint.Size = New-Object System.Drawing.Size(720, 20)
$form.Controls.Add($lblHint)

# ── DirectX 状态行 + 修复按钮 ──
$lblVer = New-Object System.Windows.Forms.Label
$lblVer.Text = $script:AppVersion + "   " + $script:T.DataDir + ": " + $Root
$lblVer.Font = $FontVer
$lblVer.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 100)
$lblVer.Location = New-Object System.Drawing.Point(6, 572)
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
$script:MaxPoints  = [math]::Max(1000, [int](21600000 / [math]::Max(100, $IntervalMs)))         # 曲线缓存点数（覆盖 6 小时）
$script:ViewSpanMin  = 5                        # 当前窗口跨度（分钟）
$script:ViewSpanPts  = 600                      # 由 ViewSpanMin 换算，见下方初始化
$script:ViewShiftPts = 0                        # 距最新数据的偏移点数，0 = 跟随最新
$script:HistTime   = New-Object 'System.Collections.Generic.List[datetime]'
$script:TempHist   = New-Object 'System.Collections.Generic.List[double]'
$script:PowerHist  = New-Object 'System.Collections.Generic.List[double]'
$script:LastSample = $null
$script:Tick       = 0
$script:CpuLast    = $null
$script:GpuHover   = -1
$script:CpuHover   = -1
$script:LastHoverMs = 0
$script:BtnRestore = $null
$script:CpuHistTime = New-Object 'System.Collections.Generic.List[datetime]'
$script:CpuTempHist = New-Object 'System.Collections.Generic.List[double]'
$script:CpuFreqHist = New-Object 'System.Collections.Generic.List[double]'
$script:LastCpuTemp = 0.0
$script:LastCpuFreq = 0.0

function Get-HistStorePath {
    $dir = Join-Path $Root 'data\history'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return (Join-Path $dir 'samples.csv')
}

function Get-MarkerStorePath {
    $dir = Join-Path $Root 'data\history'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return (Join-Path $dir 'markers.csv')
}

function Save-MarkersToDisk {
    <# 把事件标记落盘，重启后仍能看到崩溃/宕机竖线 #>
    try {
        $path = Get-MarkerStorePath
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($m in $script:Markers) {
            $lines.Add(('{0:o}|{1}' -f $m.Time, $m.Kind))
        }
        [System.IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

function Load-MarkersFromDisk {
    <# 只取 24 小时内的标记 #>
    try {
        $path = Get-MarkerStorePath
        if (-not (Test-Path $path)) { return }
        $cut = (Get-Date).AddHours(-24)
        foreach ($line in [System.IO.File]::ReadAllLines($path)) {
            $p = $line -split '\|'
            if ($p.Count -lt 2) { continue }
            $t = $null
            try { $t = [datetime]::Parse($p[0], $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { continue }
            if ($t -lt $cut) { continue }
            [void]$script:Markers.Add([pscustomobject]@{ Kind = $p[1]; Time = $t })
        }
    } catch {}
}

function Write-HistSample([datetime]$time, $gpuT, $gpuW, $gpuClk, $util, $vram, $cpuT, $cpuClk, $cpuLoad, $active, $total, $ram) {
    <# 追加一行到 data\history\samples.csv，用于重启后接续 6 小时曲线 #>
    try {
        if (-not $script:HistWriter) {
            $script:HistWriter = New-Object System.IO.StreamWriter((Get-HistStorePath), $true, (New-Object System.Text.UTF8Encoding($false)))
            $script:HistWriter.AutoFlush = $true
            $script:HistWriteCount = 0
        }
        $fmt = '{0:yyyy-MM-dd HH:mm:ss}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}|{11}'
        $script:HistWriter.WriteLine(($fmt -f $time,
            $(if ($null -ne $gpuT) { [math]::Round([double]$gpuT, 1) } else { '' }),
            $(if ($null -ne $gpuW) { [math]::Round([double]$gpuW, 1) } else { '' }),
            $(if ($null -ne $gpuClk) { [int]$gpuClk } else { '' }),
            $(if ($null -ne $util) { [int]$util } else { '' }),
            $(if ($null -ne $vram) { [int]$vram } else { '' }),
            $(if ($null -ne $cpuT) { [math]::Round([double]$cpuT, 1) } else { '' }),
            $(if ($null -ne $cpuClk) { [int]$cpuClk } else { '' }),
            $(if ($null -ne $cpuLoad) { [int]$cpuLoad } else { '' }),
            $(if ($null -ne $active) { [int]$active } else { '' }),
            $(if ($null -ne $total) { [int]$total } else { '' }),
            $(if ($null -ne $ram) { [int]$ram } else { '' })))
        $script:HistWriteCount++

        # 每 5 分钟检查一次文件体积，超过上限就压缩成最近 6 小时
        if ($script:HistWriteCount % 600 -eq 0) { Compress-HistStore }
    } catch {}
}

function Compress-HistStore {
    <# 只保留最近 6 小时的采样，防止文件无限增长 #>
    try {
        $path = Get-HistStorePath
        if (-not (Test-Path $path)) { return }
        if ((Get-Item $path).Length -lt 8MB) { return }
        if ($script:HistWriter) { $script:HistWriter.Flush() }

        $cut = (Get-Date).AddHours(-6)
        $keep = New-Object System.Collections.Generic.List[string]
        foreach ($line in [System.IO.File]::ReadAllLines($path)) {
            $p = $line -split '\|'
            if ($p.Count -lt 2) { continue }
            $t = $null
            try { $t = [datetime]::ParseExact($p[0], 'yyyy-MM-dd HH:mm:ss', $null) } catch { continue }
            if ($t -ge $cut) { $keep.Add($line) }
        }
        if ($script:HistWriter) { $script:HistWriter.Close(); $script:HistWriter = $null }
        [System.IO.File]::WriteAllLines($path, $keep, (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

function Get-LoadedHours {
    <# 当前曲线覆盖多少小时 #>
    try {
        if ($script:HistTime.Count -lt 2) { return 0 }
        return [math]::Round(($script:HistTime[$script:HistTime.Count - 1] - $script:HistTime[0]).TotalHours, 1)
    } catch { return 0 }
}

function Load-OlderHistory([double]$Hours = 6) {
    <# 从 logs\ 里再往前读一段 CSV，拼到曲线左边；返回新增点数 #>
    try {
        if ($script:HistTime.Count -lt 1) { return 0 }
        $earliest = $script:HistTime[0]
        $need = [int]($Hours * 3600.0 / ($script:IntervalMs / 1000.0))
        if ($need -le 0) { return 0 }

        # 总量上限 24 小时，避免内存无限增长
        $cap = [int](24 * 3600.0 / ($script:IntervalMs / 1000.0))
        if ($script:TempHist.Count -ge $cap) { $script:LoadOlderStatus = 'cap'; return 0 }
        $script:LoadOlderStatus = 'none'
        if (($cap - $script:TempHist.Count) -lt $need) { $need = $cap - $script:TempHist.Count; $script:LoadOlderStatus = 'cap' }

        $files = Get-ChildItem $LogDir -Recurse -Filter '*.csv' -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -ne $script:LogFile -and $_.Length -gt 500 } |
                 Sort-Object LastWriteTime -Descending
        if (-not $files) { return 0 }

        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($f in $files) {
            if ($rows.Count -ge $need) { break }
            $day = $null
            $m = [regex]::Match($f.BaseName, '(\d{8})-\d{6}')
            if ($m.Success) { try { $day = [datetime]::ParseExact($m.Groups[1].Value, 'yyyyMMdd', $null) } catch { } }
            if (-not $day) { continue }
            $lines = $null
            try { $lines = [System.IO.File]::ReadAllLines($f.FullName) } catch { continue }
            $chunk = New-Object System.Collections.Generic.List[object]
            for ($k = $lines.Count - 1; $k -ge 1; $k--) {
                $a = $lines[$k] -split ','
                if ($a.Count -lt 16) { continue }
                $t = $null
                try { $t = [datetime]::ParseExact($a[0], 'HH:mm:ss', $null) } catch { continue }
                $dt = $day.AddHours($t.Hour).AddMinutes($t.Minute).AddSeconds($t.Second)
                if ($dt -ge $earliest) { continue }
                if (($earliest - $dt).TotalHours -gt $Hours) { break }
                $gt = 0.0; $gw = 0.0; $ct = 0.0; $cf = 0.0
                [void][double]::TryParse($a[1], [ref]$gt)
                [void][double]::TryParse($a[2], [ref]$gw)
                [void][double]::TryParse($a[14], [ref]$ct)
                [void][double]::TryParse($a[15], [ref]$cf)
                $chunk.Add([pscustomobject]@{ T = $dt; GT = $gt; GW = $gw; CT = $ct; CF = $cf })
                if ($rows.Count + $chunk.Count -ge $need) { break }
            }
            if ($chunk.Count -gt 0) {
                $chunk.Reverse()
                foreach ($r in $chunk) { $rows.Add($r) }
            }
        }
        if ($rows.Count -eq 0) { return 0 }

        # 按时间排序、去重（多个文件拼起来顺序会乱），只取离当前最近的 need 个
        $sorted = @($rows | Sort-Object T)
        if ($sorted.Count -gt $need) { $sorted = $sorted[($sorted.Count - $need)..($sorted.Count - 1)] }
        $added = 0
        if ($sorted.Count -gt 0) { $script:RestoreLastTime = $sorted[0].T }
        for ($i = $sorted.Count - 1; $i -ge 0; $i--) {
            $r = $sorted[$i]
            if ($r.T -ge $earliest) { continue }
            $script:HistTime.Insert(0, $r.T)
            $script:TempHist.Insert(0, $r.GT)
            $script:PowerHist.Insert(0, $r.GW)
            $script:CpuHistTime.Insert(0, $r.T)
            $script:CpuTempHist.Insert(0, $r.CT)
            $script:CpuFreqHist.Insert(0, $r.CF)
            $added++
        }
        # 扩大上限，别让新的裁剪逻辑立刻把老数据裁掉
        $script:MaxPoints = [math]::Max($script:MaxPoints, $script:TempHist.Count + 600)
        if ($added -gt 0) { $script:LoadOlderStatus = 'ok' }
        return $added
    } catch { return 0 }
}

function Restore-HistoryFromStore {
    <# 启动时从 data\history\samples.csv 读回最近 6 小时，接上曲线 #>
    try {
        $path = Get-HistStorePath
        if (-not (Test-Path $path)) { return 0 }
        $cut = (Get-Date).AddHours(-6)
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($line in [System.IO.File]::ReadAllLines($path)) {
            $p = $line -split '\|'
            if ($p.Count -lt 12) { continue }
            $t = $null
            try { $t = [datetime]::ParseExact($p[0], 'yyyy-MM-dd HH:mm:ss', $null) } catch { continue }
            if ($t -lt $cut) { continue }
            $rows.Add($p)
        }
        if ($rows.Count -eq 0) { return 0 }
        # 只保留最后 MaxPoints 个点
        $skip = [math]::Max(0, $rows.Count - $script:MaxPoints)
        $added = 0
        for ($i = $skip; $i -lt $rows.Count; $i++) {
            $p = $rows[$i]
            $t = [datetime]::ParseExact($p[0], 'yyyy-MM-dd HH:mm:ss', $null)
            $gt = 0.0; $gw = 0.0; $gc = 0.0; $gu = 0.0; $gv = 0.0
            $ct = 0.0; $cf = 0.0; $cl = 0.0; $ca = 0.0
            [void][double]::TryParse($p[1], [ref]$gt)
            [void][double]::TryParse($p[2], [ref]$gw)
            [void][double]::TryParse($p[3], [ref]$gc)
            [void][double]::TryParse($p[4], [ref]$gu)
            [void][double]::TryParse($p[5], [ref]$gv)
            [void][double]::TryParse($p[6], [ref]$ct)
            [void][double]::TryParse($p[7], [ref]$cf)
            [void][double]::TryParse($p[8], [ref]$cl)
            [void][double]::TryParse($p[9], [ref]$ca)
            [void]$script:HistTime.Add($t)
            [void]$script:TempHist.Add($gt)
            [void]$script:PowerHist.Add($gw)
            [void]$script:CpuHistTime.Add($t)
            [void]$script:CpuTempHist.Add($ct)
            [void]$script:CpuFreqHist.Add($cf)
            $script:RestoreLastTime = $t
            $added++
        }
        return $added
    } catch { return 0 }
}
function Restore-HistoryFromLastLog {
    <# 重启后把上一次记录的最后一段接回曲线，避免一开机就是空白 #>
    param([int]$MaxPoints = 1200)
    try {
        $last = Get-ChildItem $LogDir -Recurse -Filter '*.csv' -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -ne $script:LogFile -and $_.Length -gt 2000 } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $last) { return 0 }
        if (((Get-Date) - $last.LastWriteTime).TotalDays -gt 7) { return 0 }

        # 文件名形如 sys-20261125-185640.csv，从中取日期
        $day = $null
        $m = [regex]::Match($last.BaseName, '(\d{8})-\d{6}')
        if ($m.Success) {
            try { $day = [datetime]::ParseExact($m.Groups[1].Value, 'yyyyMMdd', $null) } catch {}
        }
        if (-not $day) { $day = $last.LastWriteTime.Date }

        $rows = @(Get-Content $last.FullName -Tail ($MaxPoints + 1) -ErrorAction SilentlyContinue | Select-Object -Skip 1)
        $added = 0
        foreach ($row in $rows) {
            $a = $row -split ','
            if ($a.Count -lt 19) { continue }
            $t = $null
            try { $t = [datetime]::ParseExact($a[0], 'HH:mm:ss', $null) } catch { continue }
            $dt = $day.AddHours($t.Hour).AddMinutes($t.Minute).AddSeconds($t.Second)
            if ($dt -gt (Get-Date)) { $dt = $dt.AddDays(-1) }
            $tv = 0.0; $pv = 0.0; $cv = 0.0; $fv = 0.0
            if (-not [double]::TryParse($a[1], [ref]$tv)) { continue }
            [void][double]::TryParse($a[2], [ref]$pv)
            [void][double]::TryParse($a[14], [ref]$cv)
            [void][double]::TryParse($a[15], [ref]$fv)
            [void]$script:HistTime.Add($dt)
            [void]$script:TempHist.Add($tv)
            [void]$script:PowerHist.Add($pv)
            [void]$script:CpuHistTime.Add($dt)
            [void]$script:CpuTempHist.Add($cv)
            [void]$script:CpuFreqHist.Add($fv)
            $script:RestoreLastTime = $dt
            $added++
        }
        return $added
    }
    catch { return 0 }
}

function Clear-ChartData {
    # 只清内存里的曲线，不动磁盘文件
    $script:Clearing = $true
    try {
        $script:TempHist.Clear(); $script:PowerHist.Clear()
        $script:CpuTempHist.Clear(); $script:CpuFreqHist.Clear()
        $script:HistTime.Clear(); $script:CpuHistTime.Clear()
        $script:RestoredCount = 0
        $script:SessionGapMin = 0
        $script:GpuHover = -1
        $script:CpuHover = -1
    }
    finally { $script:Clearing = $false }
}

function Clear-AllData {
    # 清空历史：停记录 → 删文件 → 清内存 → 重新开始记录
    if ($script:Recording) { Stop-Logging }
    foreach ($sub in @('logs', 'reports')) {
        $path = Join-Path $Root $sub
        if (Test-Path $path) {
            Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
    Clear-ChartData
    $script:LogCount = 0
    $script:ReportCount = 0
    Start-Logging 'system'
}

function Start-Logging([string]$Category = 'system') {
    $sub = Join-Path $LogDir $Category
    if (-not (Test-Path $sub)) { New-Item -ItemType Directory -Force -Path $sub | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $prefix = if ($Category -eq 'system') { 'sys' } else { $Category }
    $script:LogCategory = $Category
    $script:LogFile = Join-Path $sub "$prefix-$stamp.csv"
    $hdr = if ($script:T.LanguageCode -eq 'en-US') {
        'Time,GPU_Temp(C),GPU_Power(W),GPU_Clock(MHz),GPU_MemClock(MHz),GPU_Usage(%),VRAM_Usage(%),VRAM_Used(MB),PState,ThrottleMask,PowerLimit,HW_Slowdown,ThermalLimit,ThrottleText,CPU_Temp(C),CPU_Clock(MHz),CPU_Usage(%),ActiveCores,TotalCores,RAM_Usage(%)'
    } else {
        '时间,GPU温度(°C),GPU功耗(W),GPU核心频率(MHz),GPU显存频率(MHz),GPU占用(%),显存占用(%),显存已用(MB),电源状态,降频原因码,功耗墙,硬件降频,温度墙,降频说明,CPU温度(°C),CPU频率(MHz),CPU占用(%),活跃核心数,总核心数,内存占用(%)'
    }
    Set-Content -Path $script:LogFile -Value $hdr -Encoding UTF8
    $script:LogCount = 0
    $script:Recording = $true
    # 六条曲线必须等长，否则 CPU 曲线会跟 GPU 错位（显示到旧数据）
    $script:TempHist.Clear()
    $script:PowerHist.Clear()
    $script:CpuTempHist.Clear()
    $script:CpuFreqHist.Clear()
    $script:HistTime.Clear()
    $script:CpuHistTime.Clear()
    $script:RestoredCount = 0
    $script:SessionGapMin = 0
    $script:LastActiveCores = 0
    $miStart.Enabled = $false
    $miStop.Enabled = $true
    $lblStatus.Text = $script:T.StatusRec
    $lblStatus.ForeColor = $C.Accent
}

function Stop-Logging {
    if (-not $script:Recording) { return }
    $script:Recording = $false
    $miStart.Enabled = $true
    $miStop.Enabled = $false
    $lblStatus.Text = '○ 已停止'
    $lblStatus.ForeColor = $C.Dim
}

function Test-IsCrash($exitTime, $procName = '') {
    # 判断这次退出到底是崩溃还是正常关闭：三选一命中就算崩溃
    $since = $exitTime.AddMinutes(-2)
    $docDir = [Environment]::GetFolderPath('MyDocuments')
    $dumpDir = Join-Path $docDir 'Battlefield 6\CrashDumps'
    if (Test-Path $dumpDir) {
        $newDump = Get-ChildItem $dumpDir -Filter '*.mdmp' -ErrorAction SilentlyContinue |
                   Where-Object { $_.LastWriteTime -ge $since }
        if ($newDump) { return @{ IsCrash = $true; Reason = "产生崩溃转储 $($newDump[-1].Name)" } }
    }
    # 应用错误事件：按退出进程名匹配（以前只认 bf6，其它游戏会漏判）
    try {
        $pat = if ($procName) { [regex]::Escape($procName) } else { 'bf6' }
        $appErr = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000; StartTime = $since } -ErrorAction Stop |
                  Where-Object { $_.Message -match $pat }
        if ($appErr) { return @{ IsCrash = $true; Reason = '应用错误事件 1000' } }
    } catch {}
    # 显卡驱动错误：只在「错误/严重」级别、且离退出时间很近时才算，
    # 否则一次普通驱动警告会让所有正常退出的程序都被判成崩溃
    try {
        $drvErr = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'nvlddmkm'; StartTime = $exitTime.AddSeconds(-90); Level = 1, 2, 3 } -ErrorAction Stop |
                  Select-Object -First 1
        if ($drvErr) { return @{ IsCrash = $true; Reason = 'nvlddmkm 驱动错误' } }
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

    L '--- 错误代码解读 ---'
    try { foreach ($cl in (Get-CodeExplanationLines)) { L $cl } } catch { L '  (读取失败)' }
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

function Get-ViewRange {
    <# 计算当前图表窗口在历史里的起点/终点（0-based，不含终点） #>
    $cnt = $script:TempHist.Count
    if ($cnt -le 0) { return @{ From = 0; To = 0; Count = 0; Shift = 0; Span = 0 } }

    $span = [int]$script:ViewSpanPts
    if ($span -le 0 -or $span -gt $cnt) { $span = $cnt }

    $shift = [int]$script:ViewShiftPts
    if ($shift -lt 0) { $shift = 0 }
    $maxShift = [math]::Max(0, $cnt - $span)
    if ($shift -gt $maxShift) { $shift = $maxShift }

    $to = $cnt - $shift
    $from = $to - $span
    if ($from -lt 0) { $from = 0 }
    return @{ From = $from; To = $to; Count = ($to - $from); Shift = $shift; Span = $span }
}

function Get-Slice([object]$list, $range) {
    <# 从 List 里截取 [From, To) 段，返回数组 #>
    if ($list -eq $null -or $list.Count -eq 0) { return @() }
    $n = $list.Count
    $from = [math]::Max(0, [math]::Min($range.From, $n))
    $to = [math]::Max($from, [math]::Min($range.To, $n))
    $len = $to - $from
    if ($len -le 0) { return @() }
    $arr = New-Object 'double[]' $len
    $list.CopyTo($from, $arr, 0, $len)
    return $arr
}

function Set-ViewSpan([int]$minutes) {
    $script:ViewSpanMin = $minutes
    $script:ViewSpanPts = [int]($minutes * 60.0 / ($script:IntervalMs / 1000.0))
    $script:ViewShiftPts = 0
    $script:GpuHover = -1
    $script:CpuHover = -1
    Draw-Chart
}

function Shift-View([int]$delta) {
    <# 正值 = 往更早的数据翻（像往左拖） #>
    $r = Get-ViewRange
    $step = [math]::Max(1, [int]($r.Span / 4))
    $maxShift = [math]::Max(0, $script:TempHist.Count - $r.Span)
    $script:ViewShiftPts = [math]::Max(0, [math]::Min($maxShift, $script:ViewShiftPts + $delta * $step))
    $script:LastViewTouch = Get-Date
    # 拖动/滚轮只负责平移，不再自动去 logs 里载入；
    # 载入历史改成显式操作（菜单 ☰ → 载入更早的记录），免得一滚就被暂停
    $script:FollowLive = ($script:ViewShiftPts -le 0)
    if (-not $script:FollowLive) {
        $lblHint.Text = $script:T.HintPaused
        $lblHint.ForeColor = $C.Dim
    }
    $script:GpuHover = -1
    $script:CpuHover = -1
    Draw-Chart
}

function Zoom-View([int]$dir) {
    <# dir=+1 放大（跨度变小），dir=-1 缩小 #>
    $cycle = @(1, 5, 15, 30, 60, 360, 1440)
    $cur = [array]::IndexOf($cycle, [int]$script:ViewSpanMin)
    if ($cur -lt 0) { $cur = 1 }
    $next = $cur - $dir
    if ($next -lt 0) { $next = 0 }
    if ($next -ge $cycle.Count) { $next = $cycle.Count - 1 }
    Set-ViewSpan $cycle[$next]

}
function Reset-View {
    $script:ViewShiftPts = 0
    $script:GpuHover = -1
    $script:CpuHover = -1
    Draw-Chart
}

function Add-Marker([string]$kind, $time) {
    <# 在曲线上记一个事件标记：crash=崩溃（红）、down=死机/断电（橙）、gap=普通中断（灰） #>
    try {
        if (-not $time) { $time = Get-Date }
        if (-not $script:Markers) { $script:Markers = New-Object 'System.Collections.Generic.List[object]' }
        [void]$script:Markers.Add([pscustomobject]@{ Kind = $kind; Time = [datetime]$time })
        while ($script:Markers.Count -gt 30) { $script:Markers.RemoveAt(0) }
        Save-MarkersToDisk
    } catch { }
}

function Get-MarkerLabel([string]$kind) {
    switch ($kind) {
        'crash' { return $(if ($script:T.MarkerCrash) { $script:T.MarkerCrash } else { '崩溃' }) }
        'down'  { return $(if ($script:T.MarkerDown) { $script:T.MarkerDown } else { '宕机' }) }
        default { return $(if ($script:T.MarkerGap) { $script:T.MarkerGap } else { '中断' }) }
    }
}

function Get-MarkerColor([string]$kind) {
    switch ($kind) {
        'crash' { return [System.Drawing.Color]::FromArgb(220, 235, 90, 90) }
        'down'  { return [System.Drawing.Color]::FromArgb(220, 232, 150, 70) }
        default { return [System.Drawing.Color]::FromArgb(120, 150, 150, 172) }
    }
}

function Draw-SessionMarker($bmp, $from, $cnt) {
    <# 画所有事件标记：崩溃（红实线）、死机（橙实线）、普通中断（灰虚线） #>
    try {
        if (-not $bmp -or $cnt -lt 2) { return }
        if (-not $script:Markers -or $script:Markers.Count -eq 0) { return }
        if ($script:HistTime.Count -lt 2) { return }

        $to = $from + $cnt - 1
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $font = New-Object System.Drawing.Font('微软雅黑', 7)
        foreach ($m in $script:Markers) {
            # 只画落在当前可视窗口内的标记：比窗口还早的标记直接跳过，
            # 否则会被"第一个大于等于它的点"钉在最左边，看起来永远卡在左侧
            if ($m.Time -lt $script:HistTime[$from]) { continue }
            if ($m.Time -gt $script:HistTime[$to]) { continue }
            $idx = -1
            for ($q = $from; $q -le $to -and $q -lt $script:HistTime.Count; $q++) {
                if ($script:HistTime[$q] -ge $m.Time) { $idx = $q; break }
            }
            if ($idx -lt $from -or $idx -gt $to) { continue }

            $frac = ($idx - $from) / [double]($cnt - 1)
            $x = [int](6 + $frac * ($bmp.Width - 12))
            $col = Get-MarkerColor $m.Kind
            $pen = New-Object System.Drawing.Pen($col, $(if ($m.Kind -eq 'gap') { 1 } else { 1.6 }))
            if ($m.Kind -eq 'gap') { $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash }
            $g.DrawLine($pen, $x, 4, $x, $bmp.Height - 4)
            $pen.Dispose()

            $txt = Get-MarkerLabel $m.Kind
            if ($m.Kind -eq 'gap' -and $script:SessionGapMin -ge 1) {
                $span = if ($script:SessionGapMin -ge 60) { '{0:0.#} h' -f ($script:SessionGapMin / 60.0) } else { '{0} min' -f $script:SessionGapMin }
                $txt = $script:T.GapLabel -f $span
            }
            $brush = New-Object System.Drawing.SolidBrush($col)
            $sz = $g.MeasureString($txt, $font)
            $tx = $x - $sz.Width - 4
            if ($tx -lt 2) { $tx = $x + 4 }
            $g.DrawString($txt, $font, $brush, $tx, ($bmp.Height - 18))
            $brush.Dispose()
        }
        $font.Dispose()
        $g.Dispose()
    } catch {}
}

if ($env:GCD_NODRAW -eq '1') { return }
function Draw-Chart {
    if ($null -eq $script:TempHist -or $script:TempHist.Count -lt 1) { return }
    if (-not (Ensure-ChartBitmaps)) { return }

    # 自愈：六条曲线长度必须一致。GPU/CPU 各自成对，任何一条短了都会让渲染器越界
    try {
        # GPU 两条对齐
        $dPow = $script:PowerHist.Count - $script:TempHist.Count
        if ($dPow -gt 0) { $script:PowerHist.RemoveRange(0, [math]::Min($dPow, $script:PowerHist.Count)) }
        elseif ($dPow -lt 0 -and $script:PowerHist.Count -gt 0) {
            $fillP = [double]($script:PowerHist[$script:PowerHist.Count - 1])
            for ($q = 0; $q -lt (-$dPow); $q++) { [void]$script:PowerHist.Insert(0, $fillP) }
        }
        # CPU 三条对齐到 CPU 温度条数
        $dTemp = $script:CpuTempHist.Count - $script:TempHist.Count
        if ($dTemp -gt 0) {
            $script:CpuTempHist.RemoveRange(0, [math]::Min($dTemp, $script:CpuTempHist.Count))
            if ($script:CpuFreqHist.Count -ge $dTemp) { $script:CpuFreqHist.RemoveRange(0, $dTemp) }
            if ($script:CpuHistTime.Count -ge $dTemp) { $script:CpuHistTime.RemoveRange(0, $dTemp) }
        }
        elseif ($dTemp -lt 0) {
            $need = -$dTemp
            if ($script:CpuTempHist.Count -gt 0) {
                $fill = [double]($script:CpuTempHist[$script:CpuTempHist.Count - 1])
                $fillF = if ($script:CpuFreqHist.Count -gt 0) { [double]($script:CpuFreqHist[$script:CpuFreqHist.Count - 1]) } else { 0.0 }
                for ($q = 0; $q -lt $need; $q++) {
                    [void]$script:CpuTempHist.Insert(0, $fill)
                    [void]$script:CpuFreqHist.Insert(0, $fillF)
                    [void]$script:CpuHistTime.Insert(0, $script:HistTime[0])
                }
            }
        }
        # 频率曲线补齐到温度条数（这条以前没检查，是崩溃的直接原因）
        $dFreq = $script:CpuTempHist.Count - $script:CpuFreqHist.Count
        if ($dFreq -gt 0 -and $script:CpuFreqHist.Count -gt 0) {
            $fillF2 = [double]($script:CpuFreqHist[$script:CpuFreqHist.Count - 1])
            for ($q = 0; $q -lt $dFreq; $q++) { [void]$script:CpuFreqHist.Insert(0, $fillF2) }
        }
        elseif ($dFreq -lt 0) {
            $script:CpuFreqHist.RemoveRange(0, [math]::Min(-$dFreq, $script:CpuFreqHist.Count))
        }
    } catch { }

    $secPerPt = $script:IntervalMs / 1000.0
    $r = Get-ViewRange
    $cnt = [int]$r.Count
    if ($cnt -lt 1) { return }

    # 同步自绘滚动条
    try { Update-ChartBar } catch { }

    $spanMin = [math]::Round($cnt * $secPerPt / 60.0, 1)
    $infoTxt = (("{0} · {1} · {2}" -f ($script:T.ChartPerPoint -f $secPerPt), ($script:T.ChartPoints -f $cnt), ($script:T.ChartMinutes -f $spanMin)))
    if ($r.Shift -gt 0 -and $script:HistTime.Count -gt 0) {
        $t0 = $script:HistTime[[math]::Min($r.From, $script:HistTime.Count - 1)]
        $t1 = $script:HistTime[[math]::Min($r.To - 1, $script:HistTime.Count - 1)]
        $infoTxt = ($script:T.ChartPaused -f $t0.ToString('HH:mm:ss'), $t1.ToString('HH:mm:ss'), $cnt)
    }

    $aGpu = Get-Slice $script:TempHist $r
    $bGpu = Get-Slice $script:PowerHist $r
    # 两条曲线长度必须一致，渲染器按同一个 count 取下标，短了就越界
    $nGpu = [math]::Min($aGpu.Count, $bGpu.Count)
    if ($nGpu -ge 1) {
        # 图例文字直接带上最高/最低（颜色由渲染器按曲线色绘制）
        $mnA = ($aGpu | Measure-Object -Minimum).Minimum
        $mxA = ($aGpu | Measure-Object -Maximum).Maximum
        $mnB = ($bGpu | Measure-Object -Minimum).Minimum
        $mxB = ($bGpu | Measure-Object -Maximum).Maximum
        $hvg = -1
        if ($script:GpuHover -ge 0) { $hl = $script:GpuHover - $r.From; if ($hl -ge 0 -and $hl -lt $nGpu) { $hvg = $hl } }
        if ($script:HasNvidia) {
            $labA = ('{0}   {1} {2:N0}  {3} {4:N0}' -f $script:T.LegendGpuTemp, $script:T.StatMax, $mxA, $script:T.StatMin, $mnA)
            $labB = ('{0}   {1} {2:N0}  {3} {4:N0}' -f $script:T.LegendPower, $script:T.StatMax, $mxB, $script:T.StatMin, $mnB)
            [ChartRenderer]::Render($script:chartBmp, $aGpu, $bGpu, $nGpu,
                $C.Card, $C.Grid, $C.Accent, $script:ColRed, $C.Dim, $infoTxt,
                $labA, $labB, '°C', 'W', $hvg)
        }
        else {
            $labA = 'GPU 占用 %   最高 {0:N0}  最低 {1:N0}' -f $mxA, $mnA
            $labB = '显存 MB   最高 {0:N0}  最低 {1:N0}' -f $mxB, $mnB
            [ChartRenderer]::Render($script:chartBmp, $aGpu, $bGpu, $nGpu,
                $C.Card, $C.Grid, $C.Accent, $script:ColRed, $C.Dim, $infoTxt,
                $labA, $labB, '%', 'MB', $hvg)
        }
        Draw-SessionMarker $script:chartBmp $r.From $nGpu
        $chart.Refresh()
    }

    if ($script:CpuTempHist.Count -ge 1) {
        $aCpu = Get-Slice $script:CpuTempHist $r
        $bCpu = Get-Slice $script:CpuFreqHist $r
        $cCnt = [math]::Min($aCpu.Count, $bCpu.Count)
        if ($cCnt -ge 1) {
            $cSpan = [math]::Round($cCnt * $secPerPt / 60.0, 1)
            $cInfo = (("{0} · {1} · {2}" -f ($script:T.ChartPerPoint -f $secPerPt), ($script:T.ChartPoints -f $cCnt), ($script:T.ChartMinutes -f $cSpan)))
            if ($r.Shift -gt 0 -and $script:CpuHistTime.Count -gt 0) {
                $t0 = $script:CpuHistTime[[math]::Min($r.From, $script:CpuHistTime.Count - 1)]
                $t1 = $script:CpuHistTime[[math]::Min($r.To - 1, $script:CpuHistTime.Count - 1)]
                $cInfo = ($script:T.ChartPaused -f $t0.ToString('HH:mm:ss'), $t1.ToString('HH:mm:ss'), $cCnt)
            }
            $mnC = ($aCpu | Measure-Object -Minimum).Minimum
            $mxC = ($aCpu | Measure-Object -Maximum).Maximum
            $mnF = ($bCpu | Measure-Object -Minimum).Minimum
            $mxF = ($bCpu | Measure-Object -Maximum).Maximum
            $labC = ('{0}   {1} {2:N0}  {3} {4:N0}' -f $script:T.LegendCpuTemp, $script:T.StatMax, $mxC, $script:T.StatMin, $mnC)
            $labF = ('{0}   {1} {2:N0}  {3} {4:N0}' -f $script:T.LegendFreq, $script:T.StatMax, $mxF, $script:T.StatMin, $mnF)
            $hvc = -1
            if ($script:CpuHover -ge 0) { $hl2 = $script:CpuHover - $r.From; if ($hl2 -ge 0 -and $hl2 -lt $cCnt) { $hvc = $hl2 } }
            [ChartRenderer]::Render($script:cpuBmp, $aCpu, $bCpu, $cCnt,
                $C.Card, $C.Grid, $C.Accent, $script:ColPurple, $C.Dim, $cInfo,
                $labC, $labF, '°C', 'MHz', $hvc)
            Draw-SessionMarker $script:cpuBmp $r.From $cCnt
            $cpuChart.Refresh()

            $cpuChart.Refresh()
        }
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

    $ramTxt = if ($null -ne $cpu.RamPct) {
        $usedGB = [math]::Round(($cpu.RamPct / 100.0) * $script:RamTotalMB / 1024.0, 1)
        $totalGB = [math]::Round($script:RamTotalMB / 1024.0, 1)
        "{0}%  {1:N1}G/{2:N0}G" -f $cpu.RamPct, $usedGB, $totalGB
    } else { "--" }
    $pstateTxt = switch -Regex ($s.PState) {
        '^P0$' { $script:T.PStateFull }
        '^P[1-3]$' { $script:T.PStateMid -f $s.PState }
        '^P[4-9]$' { $script:T.PStateIdle -f $s.PState }
        '^P1[0-5]$' { $script:T.PStateDeep -f $s.PState }
        default { "$($s.PState)" }
    }
    $lblDetail.Text = ("{0} {1:N0} / {2} MB      {3} {4}      {5} {6}      {7} {8}" -f $script:T.RowVram, [double]$s.MemUsed, $memTotal, $script:T.RowSysMem, $ramTxt, $script:T.ThrottleGpu, $s.Throttle, $script:T.RowPower, $pstateTxt)

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
        [void]$script:HistTime.Add((Get-Date))
    if ($null -ne $s.Temp) { [void]$script:TempHist.Add($s.Temp) } else { [void]$script:TempHist.Add(0) }
        if ($null -ne $s.Power) { [void]$script:PowerHist.Add($s.Power) } else { [void]$script:PowerHist.Add(0) }
    }
    else {
        if ($null -ne $s.UtilGpu) { [void]$script:TempHist.Add($s.UtilGpu) } else { [void]$script:TempHist.Add(0) }
        if ($null -ne $s.MemUsed) { [void]$script:PowerHist.Add($s.MemUsed) } else { [void]$script:PowerHist.Add(0) }
    }
    if ($script:TempHist.Count -gt ($script:MaxPoints + 600)) {
        $drop = $script:TempHist.Count - $script:MaxPoints
        $script:TempHist.RemoveRange(0, $drop)
        $script:PowerHist.RemoveRange(0, [math]::Min($drop, $script:PowerHist.Count))
        if ($script:HistTime.Count -ge $drop) { $script:HistTime.RemoveRange(0, $drop) }
    }
    while ($script:HistTime.Count -gt $script:MaxPoints) { $script:HistTime.RemoveAt(0) }
    while ($script:PowerHist.Count -gt $script:MaxPoints) { $script:PowerHist.RemoveAt(0) }

    # CPU 曲线：沿用最近一次有效值，保证和 GPU 曲线等宽
    if ($script:FollowLive) { $script:ViewShiftPts = 0 }
    elseif ($script:LastViewTouch -and ((Get-Date) - $script:LastViewTouch).TotalSeconds -ge 45) {
        # 回看超过 45 秒没动过，自动回到跟随最新，避免一直停在"已暂停"
        $script:ViewShiftPts = 0
        $script:FollowLive = $true
        $lblHint.Text = $script:T.HintLive
        $lblHint.ForeColor = $C.Dim
    }
    [void]$script:CpuHistTime.Add((Get-Date))
    [void]$script:CpuTempHist.Add([double]$script:LastCpuTemp)
    [void]$script:CpuFreqHist.Add([double]$script:LastCpuFreq)
    # 落盘：重启后能从 data\history\samples.csv 接回 6 小时曲线
    try {
        Write-HistSample (Get-Date) $s.Temp $s.Power $s.ClockSm $s.UtilGpu $s.MemUsed $script:LastCpuTemp $script:LastCpuFreq $cpu.Load $cpu.Active $cpu.Total $cpu.RamPct
    } catch {}
    if ($script:CpuTempHist.Count -gt ($script:MaxPoints + 600)) {
        $cdrop = $script:CpuTempHist.Count - $script:MaxPoints
        $script:CpuTempHist.RemoveRange(0, $cdrop)
        $script:CpuFreqHist.RemoveRange(0, [math]::Min($cdrop, $script:CpuFreqHist.Count))
        if ($script:CpuHistTime.Count -ge $cdrop) { $script:CpuHistTime.RemoveRange(0, $cdrop) }
    }
    while ($script:CpuHistTime.Count -gt $script:MaxPoints) { $script:CpuHistTime.RemoveAt(0) }
    while ($script:CpuFreqHist.Count -gt $script:MaxPoints) { $script:CpuFreqHist.RemoveAt(0) }

    Draw-Chart

    # 游戏进程检测（自动记录 + 崩溃报告）
    if (-not $script:GameScanAt -or ((Get-Date) - $script:GameScanAt).TotalSeconds -ge 1) {
        if ($env:GCD_NOSCAN -eq '1') { $script:GameScanResult = $null } else { $script:GameScanResult = Find-RunningGame }
        $script:GameScanAt = Get-Date
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
            $lblHint.Text = $script:T.HintGame -f $game.ProcessName, $game.ProcessName
        }
        $elapsed = [math]::Round(((Get-Date) - $script:GameStart).TotalMinutes, 1)
        if ($script:Recording) {
            $lblStatus.Text = $script:T.StatusGame + "  $($elapsed) min"
        }
    }
    else {
        if ($script:GameSeen) {
            $script:GameSeen = $false
            $exitTime = Get-Date
            if ($script:Recording) {
                Stop-Logging
                $verdict = Test-IsCrash $exitTime $(if ($script:GameName) { $script:GameName } else { "" })
                $rep = Write-CrashReport $exitTime $verdict.IsCrash $verdict.Reason
                  if ($verdict.IsCrash) {
                      $lblHint.Text = "⚠ 判定为崩溃（$($verdict.Reason)），报告: $(Split-Path $rep -Leaf)"
                      $lblHint.ForeColor = $C.Bad
                      $snap = Save-CrashSnapshot -Stamp ($exitTime.ToString('yyyyMMdd-HHmmss'))
                  }
                else {
                    $lblHint.Text = "游戏正常退出，对局记录已保存: $(Split-Path $rep -Leaf)"
                    $lblHint.ForeColor = $C.Dim
                }
                $script:GameName = $null
$script:GameScanAt = $null
$script:GameScanResult = $null
                # 崩溃/正常退出都在曲线上留个标记；先恢复记录，卡片不阻塞
                try {
                    if ($verdict.IsCrash) { Add-Marker 'crash' $exitTime } else { Add-Marker 'gap' $exitTime }
                } catch {}
                Start-Logging 'system'
                $lblHint.Text = $(if ($verdict.IsCrash) { "⚠ 判定为崩溃（$($verdict.Reason)）  报告: $(Split-Path $rep -Leaf)  已切回系统监控 logs\system\" } else { "游戏正常退出，记录已保存: $(Split-Path $rep -Leaf)  已切回系统监控 logs\system\" })
                # 卡片放在恢复记录之后弹出，且非阻塞，避免采样停摆
                if ($verdict.IsCrash) { try { Show-CrashCard -ReportPath $rep -SnapshotPath $snap -Reason $verdict.Reason } catch {} }
            }
        }
    }

    try {
        $ws = [System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB
        $miMem.Text = $script:T.MenuMem -f $ws
    } catch {}

    # 收到"显示窗口"请求（用户重复点了图标）
    $reqFile = Join-Path $Root 'show.request'
    if (Test-Path -LiteralPath $reqFile) {
        Remove-Item -LiteralPath $reqFile -Force -ErrorAction SilentlyContinue
        Show-MainWindow
    }

    if ($script:BtnRestore -and (Get-Date) -ge $script:BtnRestore.At) {
        $script:BtnRestore.Btn.Text = $script:BtnRestore.Text
        $script:BtnRestore.Btn.Enabled = $true
        $script:BtnRestore = $null
    }

    $lblStats.Text = ("{0} {1:N0}{2}    {3} {4}    {5} {6}" -f $script:T.RowLogCount, [int]$script:LogCount, $script:T.StatsThis, $script:T.RowReports, [int]$script:ReportCount, $script:T.RowFile, $(if ($script:LogFile) { Split-Path $script:LogFile -Leaf } else { "-" }))
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

    # 鼠标 X 坐标映射到「当前可视窗口」内的采样点（与曲线绘制一致）
    $vr = Get-ViewRange
    $vcnt = [int]$vr.Count
    if ($vcnt -lt 2) { return }
    $ratio = [math]::Max(0.0, [math]::Min(1.0, ($x - 6) / ([double]$ctrl.Width - 12)))
    $localIdx = [int][math]::Round($ratio * ($vcnt - 1))
    $idx = [int]$vr.From + $localIdx
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -ge $n) { $idx = $n - 1 }
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
    # 显示该采样点的时间（时:分:秒）
    $timeList = if ($isGpu) { $script:HistTime } else { $script:CpuHistTime }
    $ago = '--:--:--'
    if ($timeList -and $timeList.Count -gt 0) {
        $ti = [math]::Min($idx, $timeList.Count - 1)
        $ago = $timeList[$ti].ToString('HH:mm:ss')
    }

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

$chart.Add_MouseWheel({
    param($s, $e)
    if ($e.Delta -gt 0) { Zoom-View 1 } else { Zoom-View -1 }
})
$cpuChart.Add_MouseWheel({
    param($s, $e)
    if ($e.Delta -gt 0) { Zoom-View 1 } else { Zoom-View -1 }
})
$chart.Add_DoubleClick({ Reset-View })
$cpuChart.Add_DoubleClick({ Reset-View })
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
function Open-FolderWithFeedback($btn, $normalText, $path) {
    try {
        if (-not (Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$path`""
    } catch {}
}

$miStop.Enabled = $false

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = $script:IntervalMs
$script:Timer.Add_Tick({
    if ($script:Clearing) { return }
    try { Update-UI }
    catch {
        $lblStatus.Text = '✕ 错误'
        $lblStatus.ForeColor = $C.Bad
        try { Set-Content (Join-Path $env:TEMP 'gcd-ui-error.txt') -Value ((Get-Date).ToString('HH:mm:ss') + " " + ($_ | Out-String) + "`n" + $_.ScriptStackTrace) -Encoding UTF8 } catch {}
    }
})

$form.Add_Shown({
    $script:Timer.Start()
    if ($Tray) { $form.Hide() }
    # 启动时检测一次 DirectX（异步，不阻塞界面）
    try { Update-DxIndicator } catch {}
    try {
        $miAuto.Checked = Test-AutoStart
        $script:AutoStartInit = $true
    } catch { $script:AutoStartInit = $true }

    $hasGame = $null -ne (Find-RunningGame)
    if (-not $hasGame -and -not $script:Recording) {
        Start-Logging 'system'
        # 接上上次的曲线：Start-Logging 会清空缓冲，必须放在它之后
        # 优先用 data\history\samples.csv（完整 6 小时），没有才退回读 CSV 尾部
        try { $script:RestoredCount = Restore-HistoryFromStore } catch { $script:RestoredCount = 0 }
        if ($script:RestoredCount -lt 2) {
            try { $script:RestoredCount = Restore-HistoryFromLastLog } catch { $script:RestoredCount = 0 }
        }
        try { Load-MarkersFromDisk } catch { }
        if ($script:RestoredCount -gt 0 -and $script:RestoreLastTime) {
            $script:SessionGapMin = [int][math]::Round(((Get-Date) - $script:RestoreLastTime).TotalMinutes)
            # 上次是正常关机、还是死机/蓝屏/断电？查事件日志判断
            $kind = 'gap'
            try {
                $since = $script:RestoreLastTime.AddMinutes(-2)
                $bad = Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $since; Id = 41, 1001, 6008 } -ErrorAction SilentlyContinue |
                       Select-Object -First 1
                if ($bad) { $kind = 'down' }
            } catch { }
            # 5 分钟内已有中断标记就不重复画
            $dup = $false
            foreach ($mk in $script:Markers) { if ([math]::Abs(($mk.Time - $script:RestoreLastTime).TotalMinutes) -lt 5) { $dup = $true; break } }
            if (-not $dup) { Add-Marker $kind $script:RestoreLastTime }
            if ($kind -eq 'down') { $script:LastShutdownWasBad = $true }
        }
        $lblHint.Text = $script:T.HintNoGame
        if ($script:RestoredCount -gt 0) { $lblHint.Text += ($script:T.RestoredHint -f $script:RestoredCount) }
        if ($script:LastShutdownWasBad) {
            $lblHint.Text += "  ⚠ " + $(if ($script:T.HintBadShutdown) { $script:T.HintBadShutdown } else { '上次会话异常结束（死机 / 断电），曲线分界处已标注' })
            $lblHint.ForeColor = $C.Warn
        }
    }
    Update-UI
})
$form.Add_FormClosing({
    param($s, $e)
    # 只在真正退出时停止；点 X 收托盘不算退出（有另一个处理器负责隐藏）
    if ($script:ExitFlag) {
        $script:Timer.Stop()
        if ($script:Recording) { Stop-Logging }
        # 收尾：把采样落盘句柄关掉，顺手压缩一次历史文件
        try { if ($script:HistWriter) { $script:HistWriter.Flush(); $script:HistWriter.Close(); $script:HistWriter = $null } } catch {}
        try { Save-MarkersToDisk } catch {}
    }
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

# ── 按缩放后的实际客户区重新排布，保证左右边距严格相等、右边不被裁掉 ──
try {
    $cw = $form.ClientSize.Width
    $M = [int](7 * $script:DpiScale)      # 左右统一边距
    $inner = $cw - 2 * $M
    $gap = [int](12 * $script:DpiScale)

    # 4 张卡片等宽铺满
    $cardW = [int](($inner - 3 * $gap) / 4)
    $rowGpu = @($cardTemp, $cardPower, $cardClock, $cardUtil)
    $rowCpu = @($cardCpuTemp, $cardCpuClock, $cardCpuUtil, $cardCpuCores)
    for ($k = 0; $k -lt 4; $k++) {
        $x = $M + $k * ($cardW + $gap)
        foreach ($row in @($rowGpu, $rowCpu)) {
            $row[$k].Left = $x
            $row[$k].Width = $cardW
        }
    }

    # 两张曲线图撑满
    $chart.Left = $M;      $chart.Width = $inner
    $cpuChart.Left = $M;   $cpuChart.Width = $inner
    # 自绘滚动条与图表同宽
    if ($script:ChartBar) { $script:ChartBar.Left = $M; $script:ChartBar.Width = $inner }

    # 左侧文字
    foreach ($l in @($lblSub, $lblCpuModel, $lblDetail, $lblStats, $lblHint, $lblVer)) {
        if ($l) { $l.Left = $M; $l.Width = $inner }
    }
    # 卡片内单位标签统一右对齐
    try {
        foreach ($item in $script:UnitLabels) {
            $w = $item.Card.Width - $item.Label.PreferredWidth - [int](14 * $script:DpiScale)
            if ($w -lt 0) { $w = 0 }
            $item.Label.Left = $w
        }
    }
    catch { }
    $lblTitle.Left = [int](44 * $script:DpiScale)

    # 右侧控件贴右边
}
catch { }

# ── 单实例保护：重复点图标只保留一个实例 ──
if (-not ($SelfTest -or $UiTest -or $Shot -or $ForceLog -or $TestDiagnosis -or $TestReport -or $TestView -or $TestCrash -or $TestClear -or $TestGameStart -or $TestMarkerShot -or $ShowAbout -or $ShowDiagnosis)) {
    $script:SingleMutex = New-Object System.Threading.Mutex($false, 'Local\GameCrashDiag_SingleInstance')
    if (-not $script:SingleMutex.WaitOne(0)) {
        # 已有实例：写信号文件让它把窗口弹出来，然后静默退出
        if (-not $Tray) {
        try {
            $reqFile = Join-Path $Root 'show.request'
            Set-Content -Path $reqFile -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Encoding UTF8 -Force
        } catch {}
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
    Write-Output "  采样值: 温度=$($valTemp.Text) 功耗=$($valPower.Text) 频率=$($valClock.Text) 占用=$($valUtil.Text) 活跃核心=$($valCpuCores.Text)"
    Write-Output "  CPU卡片: $($valCpuTemp.Text)   曲线末值: $($script:CpuTempHist[$script:CpuTempHist.Count-1])"
    Write-Output "  数据源: HasNvidia=$($script:HasNvidia)  HasLhm=$($script:HasLhm)  LhmError=$($script:LhmError)"
    Write-Output "  状态行: $($lblDetail.Text)"
    Write-Output "  GPU曲线: $($script:TempHist.Count) 点   CPU曲线: $($script:CpuTempHist.Count) 点   恢复=$($script:RestoredCount)"
    Write-Output "  历史文件: $(Get-HistStorePath)  存在=$(Test-Path (Get-HistStorePath))"
    Write-Output "  记录中: $($script:Recording)   条数: $($script:LogCount)"
    Write-Output "  日志文件: $($script:LogFile)"
    $form.Dispose()
    exit 0
}

function Get-DxStatus {
    <# 检查 DirectX 关键组件是否齐全 #>
    $sys = Join-Path $env:WINDIR 'System32'
    $items = @(
        @{ File = 'd3d12.dll';          Name = 'DirectX 12';      Kind = 'core' }
        @{ File = 'd3d12core.dll';      Name = 'DX12 Core';       Kind = 'core' }
        @{ File = 'd3d11.dll';          Name = 'DirectX 11';      Kind = 'core' }
        @{ File = 'd3d10_1.dll';        Name = 'DirectX 10.1';    Kind = 'core' }
        @{ File = 'd3d9.dll';           Name = 'DirectX 9';       Kind = 'core' }
        @{ File = 'dxgi.dll';           Name = 'DXGI';            Kind = 'core' }
        @{ File = 'd3dcompiler_47.dll'; Name = '着色器编译器';     Kind = 'core' }
        @{ File = 'd3dx9_43.dll';       Name = 'DX9 扩展库';      Kind = 'legacy' }
        @{ File = 'd3dx10_43.dll';      Name = 'DX10 扩展库';     Kind = 'legacy' }
        @{ File = 'd3dx11_43.dll';      Name = 'DX11 扩展库';     Kind = 'legacy' }
        @{ File = 'XInput1_4.dll';      Name = '手柄支持';         Kind = 'core' }
        @{ File = 'xaudio2_9.dll';      Name = '音频引擎';         Kind = 'core' }
    )
    $result = @{ All = @(); Missing = @(); MissingLegacy = @(); MissingCore = @() }
    foreach ($it in $items) {
        $p = Join-Path $sys $it.File
        $ok = Test-Path $p
        $ver = if ($ok) { (Get-Item $p).VersionInfo.FileVersion } else { '' }
        $row = [pscustomobject]@{ File = $it.File; Name = $it.Name; Kind = $it.Kind; Ok = $ok; Version = $ver }
        $result.All += $row
        if (-not $ok) {
            $result.Missing += $row
            if ($it.Kind -eq 'legacy') { $result.MissingLegacy += $row } else { $result.MissingCore += $row }
        }
    }
    return $result
}

function Invoke-DxRepair {
    param([switch]$Force)
    <#
      自动修复 DirectX：
        · 缺 DX9/10/11 扩展库 → 下载微软官方 DirectX 运行库并静默安装
        · 缺核心 DLL（d3d12/d3d11/dxgi 等）→ 用 DISM 修复系统映像
    #>
    $dx = Get-DxStatus
    if ($dx.Missing.Count -eq 0 -and -not $Force) {
        [System.Windows.Forms.MessageBox]::Show(
            $(if ($script:T.LanguageCode -eq 'en-US') { "DirectX components are complete - no repair needed.`n`nTo force a system file check, run:`n  DISM /Online /Cleanup-Image /RestoreHealth" } else { "DirectX 组件齐全，不需要修复。`n`n如果要强制校验系统文件，可以运行：`n  DISM /Online /Cleanup-Image /RestoreHealth" }),
              $(if ($script:T.LanguageCode -eq 'en-US') { 'DirectX check' } else { 'DirectX 检查' }), 'OK', 'Information') | Out-Null
        return
    }

    $list = ($dx.Missing | ForEach-Object { "  · $($_.Name)（$($_.File)）" }) -join "`n"
      $msg = $(if ($script:T.LanguageCode -eq 'en-US') { "Missing DirectX components detected:`n`n$list`n`nRepair automatically?`n`n" } else { "检测到 DirectX 缺少以下组件：`n`n$list`n`n是否自动修复？`n`n" })
    if ($dx.MissingLegacy.Count -gt 0) {
          $msg += $(if ($script:T.LanguageCode -eq 'en-US') { "Will download the official Microsoft DirectX runtime (~300KB) and install it. Admin rights required.`n" } else { "将下载微软官方 DirectX 运行库（约 300KB）并安装，需要管理员权限。`n" })
    }
    if ($dx.MissingCore.Count -gt 0) {
          $msg += $(if ($script:T.LanguageCode -eq 'en-US') { "Core system components are missing - will try a DISM repair (slow, needs admin).`n" } else { "缺少系统核心组件，将尝试用 DISM 修复（耗时较长，需要管理员权限）。`n" })
    }

      $title = if ($script:T.LanguageCode -eq 'en-US') { 'Repair DirectX' } else { '自动修复 DirectX' }
      $ans = [System.Windows.Forms.MessageBox]::Show($msg, $title, 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }

    $log = New-Object System.Collections.Generic.List[string]
    $okAll = $true

    # ── 1. 扩展库：官方运行库 ──
    if ($dx.MissingLegacy.Count -gt 0) {
        $url = 'https://download.microsoft.com/download/1/7/1/1718CCC4-6315-4D8E-9543-8E28A4E18C4C/dxwebsetup.exe'
        $tmp = Join-Path $env:TEMP 'dxwebsetup.exe'
        try {
            $log.Add('· 正在下载 DirectX 运行库...')
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
            Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
            $log.Add('  下载完成')
            $log.Add('· 正在安装（可能弹出管理员确认）...')
            $p = Start-Process -FilePath $tmp -ArgumentList '/Q' -Verb RunAs -Wait -PassThru -ErrorAction Stop
            $log.Add("  安装退出码: $($p.ExitCode)")
            if ($p.ExitCode -ne 0) { $okAll = $false }
        }
        catch {
            $okAll = $false
            $log.Add("  ❌ 失败: $($_.Exception.Message)")
            $log.Add('  可手动处理：搜索 "DirectX 最终用户运行时" 下载安装')
        }
        finally {
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
        }
    }

    # ── 2. 核心组件：DISM ──
    if ($dx.MissingCore.Count -gt 0) {
        try {
            $log.Add('· 正在用 DISM 修复系统映像（可能需要几分钟）...')
            $p = Start-Process -FilePath 'dism.exe' -ArgumentList '/Online','/Cleanup-Image','/RestoreHealth' `
                 -Verb RunAs -Wait -PassThru -WindowStyle Minimized -ErrorAction Stop
            $log.Add("  DISM 退出码: $($p.ExitCode)（0 或 3010 表示成功）")
            if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { $okAll = $false }
        }
        catch {
            $okAll = $false
            $log.Add("  ❌ DISM 失败: $($_.Exception.Message)")
            $log.Add('  可手动处理：以管理员身份运行 cmd，执行 dism /online /cleanup-image /restorehealth')
        }
    }

    # ── 3. 复查 ──
    $after = Get-DxStatus
    $log.Add('')
    if ($after.Missing.Count -eq 0) {
        $log.Add('✅ 修复完成，所有组件现已齐全。')
        $log.Add('  建议重启一次电脑让改动生效。')
    }
    else {
        $log.Add("复查：仍有 $($after.Missing.Count) 个组件缺失：")
        foreach ($m in $after.Missing) { $log.Add("  · $($m.Name)（$($m.File)）") }
        $log.Add('')
        $log.Add('建议：')
        $log.Add('  1. 手动安装微软 DirectX 最终用户运行时')
        $log.Add('  2. 以管理员运行 sfc /scannow')
        $log.Add('  3. 检查 Windows 更新是否装全')
    }

    $icon = if ($after.Missing.Count -eq 0) { 'Information' } else { 'Warning' }
    [System.Windows.Forms.MessageBox]::Show(($log -join "`r`n"), 'DirectX 修复结果', 'OK', $icon) | Out-Null
}

function Update-DxIndicator {
    <# 刷新菜单里的 DirectX 状态项 #>
    $dx = Get-DxStatus
    $script:DxStatus = $dx
    if ($null -eq $miDxStatus) { return }

    if ($dx.Missing.Count -eq 0) {
        $miDxStatus.Text = $script:T.DxOk
        $miDxStatus.ForeColor = $C.Accent
        $miDxFix.Text = $script:T.DxView
        $miDxFix.ForeColor = $C.Text
    }
    else {
        $names = ($dx.Missing | ForEach-Object { $_.Name }) -join '、'
        $miDxStatus.Text = $script:T.DxMissing -f $dx.Missing.Count, $names
        $miDxStatus.ForeColor = $C.Warn
        $miDxFix.Text = $script:T.DxFix
        $miDxFix.ForeColor = $C.Warn
    }
}

function Show-DxAction {
    <# 点击主界面 DirectX 按钮：完整就给说明，不完整就修复 #>
    $dx = Get-DxStatus
      if ($dx.Missing.Count -eq 0) {
        $en = ($script:T.LanguageCode -eq 'en-US')
        $lines = if ($en) { @(
            'DirectX runtime check: complete',
            '',
            'All 12 components installed:',
            '  - DirectX 12 (d3d12.dll / d3d12core.dll)',
            '  - DirectX 11 (d3d11.dll)',
            '  - DirectX 10.1 (d3d10_1.dll)',
            '  - DirectX 9 (d3d9.dll)',
            '  - DXGI (dxgi.dll)',
            '  - Shader compiler (d3dcompiler_47.dll)',
            '  - DX9/10/11 extension libraries (d3dx9_43 / d3dx10_43 / d3dx11_43)',
            '  - Gamepad support (XInput1_4.dll)',
            '  - Audio engine (xaudio2_9.dll)',
            '',
            'Everything is present, so a missing DirectX component is NOT the cause.',
            '',
            'If the game still reports DirectX errors, check in this order:',
            '  1. Game files - verify integrity in Steam / EA App',
            '  2. GPU driver - clean uninstall with DDU, then install the latest',
            '  3. System files - run sfc /scannow as administrator',
            '  4. System image - DISM /Online /Cleanup-Image /RestoreHealth as administrator',
            '',
            'Click Yes to force a reinstall of the DirectX runtime.'
        ) } else { @(
            'DirectX 运行库检查结果：完整',
            '',
            "已安装的 12 项组件：",
            '  · DirectX 12（d3d12.dll / d3d12core.dll）',
            '  · DirectX 11（d3d11.dll）',
            '  · DirectX 10.1（d3d10_1.dll）',
            '  · DirectX 9（d3d9.dll）',
            '  · DXGI 交换链（dxgi.dll）',
            '  · 着色器编译器（d3dcompiler_47.dll）',
            '  · DX9/10/11 扩展库（d3dx9_43 / d3dx10_43 / d3dx11_43）',
            '  · 手柄支持（XInput1_4.dll）',
            '  · 音频引擎（xaudio2_9.dll）',
            '',
            '组件都在，说明不是 DirectX 缺失的问题。',
            '',
            '如果游戏仍然报 DirectX 相关错误，按这个顺序排查：',
            '  1. 游戏文件完整性 —— 在 Steam / EA App 里"验证游戏文件"',
            '  2. 显卡驱动 —— 用 DDU 干净卸载后装最新版',
            '  3. 系统文件 —— 以管理员运行 sfc /scannow',
            '  4. 系统映像 —— 以管理员运行 DISM /Online /Cleanup-Image /RestoreHealth',
            '',
            '如果你想强制重装一遍 DirectX 运行库，点"是"。'

        ) }
        $title = if ($en) { 'DirectX check result' } else { 'DirectX 检查结果' }
        $r = [System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"), $title, 'YesNo', 'Information')
        if ($r -eq 'Yes') {
            $script:DxForceReinstall = $true
            Invoke-DxRepair -Force
            Update-DxIndicator
        }
        return
    }
    Invoke-DxRepair
    Update-DxIndicator
}

function Get-ErrorCodeTable {
    <# 读取 data\error-codes.txt（code|名称|含义|原因|建议），带缓存 #>
    if ($script:CodeTable -and $script:CodeTableLang -eq $script:T.LanguageCode) { return $script:CodeTable }
    $table = @{}
    $codeFile = if ($script:T.LanguageCode -eq 'en-US') { 'error-codes.en.txt' } else { 'error-codes.txt' }
    $path = Join-Path $Root ('data\' + $codeFile)
    if (Test-Path $path) {
        foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
            $p = $line -split '\|'
            if ($p.Count -ge 5) {
                $table[$p[0].Trim().ToLower()] = [pscustomobject]@{
                    Code   = $p[0].Trim()
                    Name   = $p[1].Trim()
                    Mean   = $p[2].Trim()
                    Cause  = $p[3].Trim()
                    Advice = $p[4].Trim()
                }
            }
        }
    }
    $script:CodeTable = $table
    $script:CodeTableLang = $script:T.LanguageCode
    return $table
}

function Get-CrashEvidence {
    <# 从事件日志和崩溃报告提取错误码，带出现次数与最近时间 #>
    $found = @{}
    $since = (Get-Date).AddDays(-7)

    $addCode = {
        param($code, $source, $provider, $eventId, $when)
        $k = "$code"
        if (-not $found.ContainsKey($k)) {
            $found[$k] = [pscustomobject]@{
                Code = $code.ToLower(); Raw = $code
                Count = 0; Last = $when; Source = $source
                Provider = $provider; EventId = $eventId
            }
        }
        $e = $found[$k]
        $e.Count++
        if ($when -gt $e.Last) { $e.Last = $when }
    }

    # 1) 系统日志：显卡驱动 / 蓝屏 / 意外断电
    try {
        $evts = Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $since } -ErrorAction Stop |
                Where-Object { $_.ProviderName -eq 'nvlddmkm' -or $_.Id -in 41, 1001, 4101 } |
                Select-Object -First 2000
        foreach ($e in $evts) {
            if ($e.ProviderName -eq 'nvlddmkm') {
                & $addCode "nvlddmkm-$($e.Id)" $(if ($script:T.LanguageCode -eq 'en-US') { 'System event log' } else { '系统事件日志' }) 'nvlddmkm' $e.Id $e.TimeCreated
            }
            elseif ($e.Id -eq 41) {
                & $addCode 'event-41' '系统事件日志' 'Kernel-Power' 41 $e.TimeCreated
            }
            elseif ($e.Id -eq 4101) {
                & $addCode 'nvlddmkm-4101' '系统事件日志' 'Display' 4101 $e.TimeCreated
            }
            elseif ($e.Id -eq 1001) {
                $m = [regex]::Match($e.Message, '0x[0-9A-Fa-f]{8}')
                if ($m.Success) { & $addCode $m.Value '系统事件日志' 'BugCheck' 1001 $e.TimeCreated }
            }
        }
    }
    catch { }

    # 2) LiveKernelEvent
    try {
        $lk = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-LiveDump'; StartTime = $since } -ErrorAction SilentlyContinue
        foreach ($e in $lk) {
            foreach ($pat in '141', '117', '1a1') {
                if ($e.Message -match $pat) { & $addCode "livekernel-$pat" '系统事件日志' 'LiveKernelEvent' $pat $e.TimeCreated }
            }
        }
    }
    catch { }

    # 3) 崩溃报告文本里的异常码
    try {
        $rep = Get-ChildItem $RepDir -Filter 'crash-*.txt' -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 5
        foreach ($f in $rep) {
            $txt = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $txt) { continue }
            foreach ($m in [regex]::Matches($txt, '0x[0-9A-Fa-f]{8}')) {
                & $addCode $m.Value ("崩溃报告 " + $f.Name) 'bench' 0 $f.LastWriteTime
            }
        }
    }
    catch { }

    return @($found.Values | Sort-Object Last -Descending)
}

function Get-CodeExplanationLines {
    <# 把证据翻译成人能看懂的解释，标明来源、次数、时间 #>
    $e = ($script:T.LanguageCode -eq 'en-US')
    $LANG_ = { param($zh, $en) if ($e) { $en } else { $zh } }
    $table = Get-ErrorCodeTable
    $ev = Get-CrashEvidence
    $out = New-Object System.Collections.Generic.List[string]

    $reportCount = @(Get-ChildItem $RepDir -Filter 'crash-*.txt' -ErrorAction SilentlyContinue).Count
    [void]$out.Add((& $LANG_ '  数据来源：Windows 系统事件日志（最近 7 天） + reports 目录的崩溃报告' '  Source: Windows System event log (last 7 days) + crash reports in reports\'))
    if ($reportCount -eq 0) {
        [void]$out.Add((& $LANG_ '  本次没有崩溃报告，下面都是系统日志里的历史驱动事件，不是这段时间新发生的' '  No crash reports this time - the entries below are historical driver events from the log'))
    }
    [void]$out.Add('')

    if ($ev.Count -eq 0) {
        [void]$out.Add((& $LANG_ '  最近 7 天没有捕获到错误代码。' '  No error codes captured in the last 7 days.'))
        return $out
    }

    $matched = 0
    foreach ($e in $ev) {
        $info = $table[$e.Code]
        if (-not $info) { continue }
        $matched++

        $ago = [math]::Round(((Get-Date) - $e.Last).TotalHours, 1)
        $agoTxt = if ($ago -lt 1) { "$([math]::Round($ago * 60)) 分钟前" }
                  elseif ($ago -lt 48) { "$([math]::Round($ago)) 小时前" }
                  else { "$([math]::Round($ago / 24)) 天前" }
        $agoTxtEn = if ($ago -lt 1) { "$([math]::Round($ago * 60)) min ago" }
                    elseif ($ago -lt 48) { "$([math]::Round($ago)) hours ago" }
                    else { "$([math]::Round($ago / 24)) days ago" }

        [void]$out.Add("  【$($info.Code)】$($info.Name)")
        [void]$out.Add((& $LANG_ "      记录：出现 $($e.Count) 次，最近一次 $($e.Last.ToString('MM-dd HH:mm'))（$agoTxt）" "      Count: $($e.Count), last seen $($e.Last.ToString('MM-dd HH:mm')) ($agoTxtEn)"))
        [void]$out.Add((& $LANG_ ("      来源：" + $($e.Source) + $(if ($e.Provider -eq 'bench') { '（本次软件生成）' } else { "（$($e.Provider) 事件 ID $($e.EventId)）" })) ("      Source: " + $($e.Source) + $(if ($e.Provider -eq 'bench') { ' (generated by this app)' } else { " ($($e.Provider) event ID $($e.EventId))" }))))
        [void]$out.Add((& $LANG_ "      含义：$($info.Mean)" "      Meaning: $($info.Mean)"))
        [void]$out.Add((& $LANG_ "      常见原因：$($info.Cause)" "      Likely cause: $($info.Cause)"))
        [void]$out.Add((& $LANG_ "      建议：$($info.Advice)" "      Advice: $($info.Advice)"))
        [void]$out.Add('')
    }

    if ($matched -eq 0) {
        [void]$out.Add('  捕获到这些代码，但本地代码库还没有对应说明：')
        foreach ($e in $ev) { [void]$out.Add("    · $($e.Raw)（$($e.Source)，$($e.Count) 次）") }
        [void]$out.Add('')
        [void]$out.Add('  可以把它发出来，加到 data\error-codes.txt 里就能自动解读。')
        [void]$out.Add('')
    }

    return $out
}
function Get-TempProfile {
    <#
      分别统计「空闲」和「游戏内」的温度，用于基线对比。
      空闲 = logs\system\   游戏 = 最近写入的 logs\<游戏名>\
    #>
    $result = @{
        IdleCpuMed = $null; IdleCpuMax = $null; IdleGpuMed = $null; IdleGpuMax = $null; IdleCount = 0
        GameCpuMed = $null; GameCpuMax = $null; GameGpuMed = $null; GameGpuMax = $null; GameCount = 0
        GameName   = $null
    }

    $readStats = {
        param($files, [int]$maxRows = 4000)
        $cpu = New-Object System.Collections.Generic.List[double]
        $gpu = New-Object System.Collections.Generic.List[double]
        $total = 0
        foreach ($f in $files) {
            try {
                $lines = Get-Content -LiteralPath $f.FullName -ErrorAction Stop
                $step = [Math]::Max(1, [int]($lines.Count / 1200))
                for ($i = 1; $i -lt $lines.Count; $i += $step) {
                    $a = $lines[$i] -split ','
                    if ($a.Count -lt 15) { continue }
                    $t = 0.0
                    if ([double]::TryParse($a[14], [ref]$t) -and $t -gt 0 -and $t -lt 130) { $cpu.Add($t) }
                    if ([double]::TryParse($a[1], [ref]$t) -and $t -gt 0 -and $t -lt 130) { $gpu.Add($t) }
                    $total++
                    if ($total -ge $maxRows) { break }
                }
            } catch {}
            if ($total -ge $maxRows) { break }
        }
        $med = { param($list) if ($list.Count -eq 0) { return $null }; $s = $list | Sort-Object; return [math]::Round($s[[int]($s.Count / 2)], 0) }
        $mx = { param($list) if ($list.Count -eq 0) { return $null }; return [math]::Round(($list | Measure-Object -Maximum).Maximum, 0) }
        return @{
            CpuMed = & $med $cpu; CpuMax = & $mx $cpu
            GpuMed = & $med $gpu; GpuMax = & $mx $gpu
            Count  = $cpu.Count
        }
    }

    # 空闲：system 目录最近 2 个文件
    $sysDir = Join-Path $LogDir 'system'
    if (Test-Path $sysDir) {
        $files = @(Get-ChildItem $sysDir -Filter '*.csv' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 2)
        if ($files.Count -gt 0) {
            $s = & $readStats $files
            $result.IdleCpuMed = $s.CpuMed; $result.IdleCpuMax = $s.CpuMax
            $result.IdleGpuMed = $s.GpuMed; $result.IdleGpuMax = $s.GpuMax
            $result.IdleCount = $s.Count
        }
    }

    # 游戏：最近写入的非 system 目录
    $gameDirs = @(Get-ChildItem $LogDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'system' } |
                  Sort-Object LastWriteTime -Descending)
    foreach ($gd in $gameDirs) {
        $files = @(Get-ChildItem $gd.FullName -Filter '*.csv' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3)
        if ($files.Count -gt 0) {
            $s = & $readStats $files
            if ($s.Count -gt 0) {
                $result.GameCpuMed = $s.CpuMed; $result.GameCpuMax = $s.CpuMax
                $result.GameGpuMed = $s.GpuMed; $result.GameGpuMax = $s.GpuMax
                $result.GameCount = $s.Count
                $result.GameName = $gd.Name
                break
            }
        }
    }
    return $result
}
function Get-HealthReportText {
    $e = ($script:T.LanguageCode -eq 'en-US')
    $LANG_ = { param($zh, $en) if ($e) { $en } else { $zh } }

    $L_ = New-Object System.Collections.Generic.List[string]
    $now = Get-Date
    $ln = ('=' * 60)
    [void]$L_.Add($ln)
    [void]$L_.Add((& $LANG_ "  游戏崩溃诊断器 · 诊断报告" "  GameCrashDiag - Diagnosis Report"))
    [void]$L_.Add((& $LANG_ "  生成时间: $($now.ToString('yyyy-MM-dd HH:mm:ss'))" "  Generated: $($now.ToString('yyyy-MM-dd HH:mm:ss'))"))
    [void]$L_.Add($ln)
    [void]$L_.Add('')

    # ══ 1. 硬件与驱动 ══
    [void]$L_.Add((& $LANG_ '【硬件 / 驱动】' '[Hardware / Driver]'))
    $gpuName = '--'; $drvVer = '--'; $drvDate = $null
    try {
        $g = & nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>$null
        if ($g) { $parts = $g -split ','; $gpuName = $parts[0].Trim(); $drvVer = $parts[1].Trim() }
    } catch {}
    try {
        $vc = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA|AMD|Radeon|Intel' } | Select-Object -First 1
        if ($vc) { if ($gpuName -eq '--') { $gpuName = $vc.Name }; $drvDate = $vc.DriverDate }
    } catch {}
    $cpuName = try { (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim() } catch { '--' }

    [void]$L_.Add((& $LANG_ "  显卡    : $gpuName" "  GPU      : $gpuName"))
    $drvLine = if ($drvDate) { " ($($drvDate.ToString('yyyy-MM-dd')))" } else { '' }
    [void]$L_.Add((& $LANG_ "  驱动    : $drvVer$drvLine" "  Driver   : $drvVer$drvLine"))
    [void]$L_.Add((& $LANG_ "  处理器  : $cpuName" "  CPU      : $cpuName"))

    if ($drvDate) {
        $ageDays = [math]::Round(($now - $drvDate).TotalDays)
        if ($ageDays -gt 365) {
            [void]$L_.Add((& $LANG_ "  ! 驱动已 $ageDays 天未更新（超过一年），建议更新到最新稳定版" "  ! Driver is $ageDays days old (over a year) - consider updating"))
        } elseif ($ageDays -gt 180) {
            [void]$L_.Add((& $LANG_ "  驱动 $ageDays 天未更新，可以考虑更新" "  Driver is $ageDays days old - updating is optional"))
        } else {
            [void]$L_.Add((& $LANG_ "  驱动较新（$ageDays 天），暂无更新必要" "  Driver is recent ($ageDays days) - no update needed"))
        }
    }

    $dxVer = $null
    try { $dxVer = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\DirectX' -Name Version -ErrorAction Stop).Version } catch {}
    if ($dxVer) {
        [void]$L_.Add((& $LANG_ "  DirectX : $dxVer" "  DirectX  : $dxVer"))
    } else {
        [void]$L_.Add((& $LANG_ "  ! 读不到 DirectX 版本，可能缺少 DX 运行库" "  ! Cannot read DirectX version - the runtime may be incomplete"))
    }
    $dxs = Get-DxStatus
    if ($dxs.Missing.Count -eq 0) {
        [void]$L_.Add((& $LANG_ '  DirectX 组件 : 12 项全部齐全' '  DirectX components : all 12 present'))
    }
    else {
        [void]$L_.Add((& $LANG_ "  DirectX 组件 : 缺 $($dxs.Missing.Count) 项（菜单里可一键修复）" "  DirectX components : $($dxs.Missing.Count) missing (repair from the menu)"))
        foreach ($m in $dxs.Missing) { [void]$L_.Add((& $LANG_ "            - $($m.Name)（$($m.File)）" "            - $($m.Name) ($($m.File))")) }
    }

    $abRun = $null -ne (Get-Process MSIAfterburner -ErrorAction SilentlyContinue)
    $abProfile = 'C:\Program Files (x86)\MSI Afterburner\Profiles'
    $abOc = $false
    if (Test-Path $abProfile) {
        $f = Get-ChildItem $abProfile -Filter 'VEN_10DE*.cfg' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) {
            $txt = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($txt -match 'CoreClkBoost=(-?\d+)' -and [int]$matches[1] -ne 0) { $abOc = $true }
        }
    }
    $abTxt = if ($abRun) { (& $LANG_ '正在运行' 'running') } else { (& $LANG_ '未运行' 'not running') }
    if ($abOc) { $abTxt += (& $LANG_ '（配置里有非零偏移）' ' (non-zero offset found)') }
    [void]$L_.Add((& $LANG_ "  超频软件: $abTxt" "  Overclocking: $abTxt"))
    [void]$L_.Add('')

    # ══ 2. 当前状态 ══
    [void]$L_.Add((& $LANG_ '【当前状态】' '[Current status]'))
    if ($script:LastSample) {
        $s = $script:LastSample
        [void]$L_.Add((& $LANG_ ("  GPU : {0}°C   {1}W   {2}MHz   占用 {3}%   降频 {4}" -f $s.Temp, $s.Power, $s.ClockSm, $s.UtilGpu, $s.Throttle) `
                           ("  GPU : {0}C   {1}W   {2}MHz   usage {3}%   throttle {4}" -f $s.Temp, $s.Power, $s.ClockSm, $s.UtilGpu, $s.Throttle)))
    }
    if ($script:CpuLast) {
        $cu = $script:CpuLast
        [void]$L_.Add((& $LANG_ ("  CPU : {0}°C   {1}MHz   占用 {2}%   活跃核心 {3}/{4}" -f $cu.Temp, $cu.MHz, $cu.Load, $cu.Active, $cu.Total) `
                           ("  CPU : {0}C   {1}MHz   usage {2}%   active cores {3}/{4}" -f $cu.Temp, $cu.MHz, $cu.Load, $cu.Active, $cu.Total)))
    }
    [void]$L_.Add('')

    # ══ 3. 本次记录统计 ══
    [void]$L_.Add((& $LANG_ '【本次记录统计】' '[This session]'))
    $maxT = 0; $maxP = 0; $capN = 0; $n = 0; $minC = 99999; $maxC = 0
    if ($script:LogFile -and (Test-Path $script:LogFile)) {
        foreach ($line in (Get-Content $script:LogFile | Select-Object -Skip 1)) {
            $a = $line -split ','
            if ($a.Count -lt 14) { continue }
            $n++
            $tv = 0.0; $pv = 0.0; $cv = 0
            if ([double]::TryParse($a[1], [ref]$tv)) { if ($tv -gt $maxT) { $maxT = $tv } }
            if ([double]::TryParse($a[2], [ref]$pv)) { if ($pv -gt $maxP) { $maxP = $pv } }
            if ([int]::TryParse($a[3], [ref]$cv)) { if ($cv -lt $minC) { $minC = $cv }; if ($cv -gt $maxC) { $maxC = $cv } }
            if ($a[10] -eq '1') { $capN++ }
        }
    }
    $capPct = if ($n -gt 0) { $capN * 100.0 / $n } else { 0 }
    if ($n -gt 0) {
        [void]$L_.Add((& $LANG_ ("  采样 {0:N0} 条   最高温度 {1:N1}°C   最高功耗 {2:N0}W" -f $n, $maxT, $maxP) `
                           ("  Samples {0:N0}   max temp {1:N1}C   max power {2:N0}W" -f $n, $maxT, $maxP)))
        [void]$L_.Add((& $LANG_ ("  核心频率 {0:N0} ~ {1:N0} MHz   撞功耗墙 {2:N0}% 的采样" -f $minC, $maxC, $capPct) `
                           ("  Core clock {0:N0} ~ {1:N0} MHz   power-limited {2:N0}% of samples" -f $minC, $maxC, $capPct)))
    } else {
        [void]$L_.Add((& $LANG_ '  （还没开始记录）' '  (not recording yet)'))
    }
    [void]$L_.Add('')

    # ══ 4. 崩溃历史 ══
    [void]$L_.Add((& $LANG_ '【崩溃历史】' '[Crash history]'))
    $crashes = @(Get-ChildItem $RepDir -Filter 'crash-*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    $recent7 = @($crashes | Where-Object { $_.LastWriteTime -ge $now.AddDays(-7) })
    [void]$L_.Add((& $LANG_ "  累计崩溃报告: $($crashes.Count) 份    最近 7 天: $($recent7.Count) 份" "  Total crash reports: $($crashes.Count)   last 7 days: $($recent7.Count)"))
    if ($crashes.Count -gt 0) {
        $crashes | Select-Object -First 5 | ForEach-Object {
            [void]$L_.Add("    - $($_.LastWriteTime.ToString('MM-dd HH:mm'))  $($_.Name)")
        }
    }
    [void]$L_.Add('')

    # ══ 4.5 错误代码解读 ══
    [void]$L_.Add((& $LANG_ '【错误代码解读】' '[Error code analysis]'))
    try {
        foreach ($cl in (Get-CodeExplanationLines)) { [void]$L_.Add($cl) }
    }
    catch { [void]$L_.Add((& $LANG_ '  （读取错误码失败）' '  (failed to read error codes)')) }
    [void]$L_.Add('')

    # ══ 5. 温度基线对比 ══
    $tp = Get-TempProfile
    [void]$L_.Add((& $LANG_ '【温度基线对比】' '[Temperature baseline]'))
    [void]$L_.Add((& $LANG_ '  （判断散热好坏要拿"不玩游戏时"当基线，不能只看绝对值）' '  (Compare idle vs in-game: absolute numbers alone are misleading)'))
    if ($tp.IdleCount -gt 0) {
        [void]$L_.Add((& $LANG_ ("  空闲时   CPU 均值 {0}°C  峰值 {1}°C      GPU 均值 {2}°C  峰值 {3}°C" -f $tp.IdleCpuMed, $tp.IdleCpuMax, $tp.IdleGpuMed, $tp.IdleGpuMax) `
                           ("  Idle     CPU avg {0}C  peak {1}C      GPU avg {2}C  peak {3}C" -f $tp.IdleCpuMed, $tp.IdleCpuMax, $tp.IdleGpuMed, $tp.IdleGpuMax)))
    } else {
        [void]$L_.Add((& $LANG_ '  空闲时   （还没有 logs\system 记录，关掉游戏跑一会儿再来看）' '  Idle     (no logs\system data yet - run without a game for a while)'))
    }
    if ($tp.GameCount -gt 0) {
        [void]$L_.Add((& $LANG_ ("  游戏内   CPU 均值 {0}°C  峰值 {1}°C      GPU 均值 {2}°C  峰值 {3}°C   （{4}）" -f $tp.GameCpuMed, $tp.GameCpuMax, $tp.GameGpuMed, $tp.GameGpuMax, $tp.GameName) `
                           ("  In-game  CPU avg {0}C  peak {1}C      GPU avg {2}C  peak {3}C   ({4})" -f $tp.GameCpuMed, $tp.GameCpuMax, $tp.GameGpuMed, $tp.GameGpuMax, $tp.GameName)))
    } else {
        [void]$L_.Add((& $LANG_ '  游戏内   （还没记录到游戏数据）' '  In-game  (no game data recorded yet)'))
    }
    if ($tp.IdleCount -gt 0 -and $tp.GameCount -gt 0) {
        $dCpu = $tp.GameCpuMed - $tp.IdleCpuMed
        $dGpu = $tp.GameGpuMed - $tp.IdleGpuMed
        [void]$L_.Add((& $LANG_ ("  温升     CPU +{0}°C                        GPU +{1}°C" -f $dCpu, $dGpu) `
                           ("  Rise     CPU +{0}C                         GPU +{1}C" -f $dCpu, $dGpu)))
        if ($tp.IdleCpuMed -lt 68 -and $tp.GameCpuMax -lt 93 -and $tp.GameGpuMax -lt 85) {
            [void]$L_.Add((& $LANG_ '  评估     正常 —— 空闲温度低、游戏内温升合理，散热没问题' '  Verdict  OK - idle cool, in-game rise reasonable, cooling is fine'))
        }
        elseif ($tp.IdleCpuMed -lt 68) {
            [void]$L_.Add((& $LANG_ '  评估     空闲正常，但游戏内偏高 —— 散热余量不足，建议限制帧率/降画质' '  Verdict  Idle OK but hot in game - limited thermal headroom, cap FPS or lower settings'))
        }
        else {
            [void]$L_.Add((& $LANG_ '  评估     空闲温度就已经偏高 —— 散热本身有问题，优先处理清灰/硅脂/风道' '  Verdict  Idle is already hot - fix cooling first (dust, thermal paste, airflow)'))
        }
    }
    [void]$L_.Add('')

    # ══ 6. 诊断结论 ══
    [void]$L_.Add((& $LANG_ '【诊断结论】' '[Findings]'))
    $issues = @()
    $advice = @()

    if ($tp.IdleCount -gt 0) {
        if ($tp.IdleCpuMed -ge 75) {
            $issues += (& $LANG_ "CPU 空闲温度偏高（均值 $($tp.IdleCpuMed)°C，正常应在 40~60°C）" "CPU idles hot (avg $($tp.IdleCpuMed)C, expected 40-60C)")
            $advice += (& $LANG_ 'CPU 散热需要处理：检查风扇转速、硅脂是否涂匀、电源模式是否锁了高性能' 'Fix CPU cooling: check fan curve, thermal paste, power plan')
        } elseif ($tp.IdleCpuMed -ge 68) {
            $issues += (& $LANG_ "CPU 空闲温度略高（均值 $($tp.IdleCpuMed)°C）" "CPU idle temp slightly high (avg $($tp.IdleCpuMed)C)")
            $advice += (& $LANG_ '留意 CPU 空闲温度，若持续上升再考虑清理散热' 'Watch the CPU idle temp; clean cooling if it keeps rising')
        }
        if ($tp.IdleGpuMed -ge 60) {
            $issues += (& $LANG_ "GPU 空闲温度偏高（均值 $($tp.IdleGpuMed)°C，正常应在 35~50°C）" "GPU idles hot (avg $($tp.IdleGpuMed)C, expected 35-50C)")
            $advice += (& $LANG_ 'GPU 空闲温度高通常是风扇停转策略或机箱风道问题，可检查是否开了"零风扇"模式' 'High idle GPU temp usually means zero-fan mode or poor airflow')
        }
    }
    if ($tp.GameCount -gt 0) {
        $dCpu = if ($null -ne $tp.IdleCpuMed) { $tp.GameCpuMed - $tp.IdleCpuMed } else { $null }
        $dGpu = if ($null -ne $tp.IdleGpuMed) { $tp.GameGpuMed - $tp.IdleGpuMed } else { $null }
        if ($tp.GameCpuMax -ge 95) {
            $issues += (& $LANG_ "CPU 游戏内峰值 $($tp.GameCpuMax)°C，已到笔记本安全线（95°C 以上会明显降频）" "CPU peak in game $($tp.GameCpuMax)C - at the laptop limit (throttling above 95C)")
            $advice += (& $LANG_ '限制帧率或降低画质，减轻 CPU 负载；确认电源模式没锁在超频档' 'Cap FPS or lower settings to reduce CPU load; check the power plan')
        } elseif ($tp.GameCpuMed -ge 90) {
            $issues += (& $LANG_ "CPU 游戏内均值 $($tp.GameCpuMed)°C，长时间处于高位" "CPU averages $($tp.GameCpuMed)C in game - sustained high")
            $advice += (& $LANG_ '把帧率限制到 60~90，能明显压低 CPU 温度' 'Limit FPS to 60-90 to bring CPU temps down')
        } elseif ($null -ne $dCpu -and $dCpu -ge 45) {
            $issues += (& $LANG_ "CPU 游戏内温升 +$dCpu°C（空闲 $($tp.IdleCpuMed) → 游戏 $($tp.GameCpuMed)），偏高" "CPU rises +$dCpuC in game ($($tp.IdleCpuMed) -> $($tp.GameCpuMed)) - high")
            $advice += (& $LANG_ 'CPU 散热余量不足：清理风道、垫高机身、控制帧率' 'Limited CPU thermal headroom: clean airflow, raise the laptop, cap FPS')
        }
        if ($tp.GameGpuMax -ge 85) {
            $issues += (& $LANG_ "GPU 游戏内峰值 $($tp.GameGpuMax)°C，偏高" "GPU peak in game $($tp.GameGpuMax)C - high")
            $advice += (& $LANG_ '降低功耗墙或限制帧率，改善散热通风' 'Lower the power limit or cap FPS; improve airflow')
        } elseif ($null -ne $dGpu -and $dGpu -ge 45) {
            $issues += (& $LANG_ "GPU 游戏内温升 +$dGpu°C（空闲 $($tp.IdleGpuMed) → 游戏 $($tp.GameGpuMed)），偏高" "GPU rises +$dGpuC in game ($($tp.IdleGpuMed) -> $($tp.GameGpuMed)) - high")
            $advice += (& $LANG_ 'GPU 散热余量不足：清理风扇积灰、垫高机身' 'Limited GPU thermal headroom: clean fans, raise the laptop')
        }
    } elseif ($null -ne $maxT -and $maxT -ge 90) {
        $issues += (& $LANG_ "本次记录 GPU 最高 $([math]::Round($maxT))°C" "GPU reached $([math]::Round($maxT))C this session")
        $advice += (& $LANG_ '温度偏高，注意散热' 'High temperature - check cooling')
    }
    if ($n -gt 0 -and ($capN * 100.0 / $n) -ge 70 -and $maxP -gt 170) {
        $issues += (& $LANG_ "长期撞功耗墙（$([math]::Round($capPct))% 采样），功耗峰值 $([math]::Round($maxP))W" "Power-limited most of the time ($([math]::Round($capPct))% of samples), peak $([math]::Round($maxP))W")
        $advice += (& $LANG_ '降功耗：tools\power-cap.ps1 -Watts 145；或开垂直同步/限制帧率，减轻供电压力' 'Lower the power limit: tools\power-cap.ps1 -Watts 145, or enable V-Sync')
    }
    if ($dxs.Missing.Count -gt 0) {
        $names = ($dxs.Missing | ForEach-Object { $_.Name }) -join (& $LANG_ '、' ', ')
        $issues += (& $LANG_ "DirectX 缺少 $($dxs.Missing.Count) 个组件（$names）" "DirectX is missing $($dxs.Missing.Count) component(s): $names")
        $advice += (& $LANG_ '点「查看 / 重装 DirectX」自动安装官方运行库；也可手动装 DirectX 最终用户运行时' 'Use "View / reinstall DirectX" to install the official runtime')
    }
    if ($abOc) {
        $issues += (& $LANG_ '检测到 Afterburner 配置里有超频偏移' 'MSI Afterburner profile contains an overclock offset')
        $advice += (& $LANG_ '关闭超频：打开 Afterburner 点 Reset，或运行 tools\apply-fixes.ps1' 'Reset the overclock in Afterburner, or run tools\apply-fixes.ps1')
    }
    if ($recent7.Count -ge 3) {
        $issues += (& $LANG_ "最近 7 天崩了 $($recent7.Count) 次，属于高频复发" "$($recent7.Count) crashes in the last 7 days - frequent")
        $advice += (& $LANG_ '高频复发说明不是偶发：优先按散热→超频→驱动顺序逐项排除' 'Not a one-off: rule out cooling, then overclocking, then drivers')
    } elseif ($recent7.Count -ge 1) {
        $issues += (& $LANG_ "最近 7 天崩了 $($recent7.Count) 次" "$($recent7.Count) crash(es) in the last 7 days")
    }
    if ($drvDate -and ($now - $drvDate).TotalDays -gt 365) {
        $issues += (& $LANG_ '驱动超过一年未更新' 'Driver has not been updated in over a year')
        $advice += (& $LANG_ '更新显卡驱动到游戏官方推荐的版本' 'Update the GPU driver to the version recommended by the game')
    }
    if ($n -gt 0 -and $maxC -gt 0 -and ($maxC - $minC) -gt 400) {
        $issues += (& $LANG_ "核心频率波动大（$([math]::Round($minC))~$([math]::Round($maxC)) MHz）" "Large core clock swings ($([math]::Round($minC))~$([math]::Round($maxC)) MHz)")
        $advice += (& $LANG_ '频率大幅抖动通常是撞温度墙或功耗墙，先解决散热再谈超频' 'Big clock swings usually mean thermal or power limits - fix cooling first')
    }

    if ($issues.Count -eq 0) {
        [void]$L_.Add((& $LANG_ '  没有发现明显问题' '  No obvious problems found'))
    } else {
        $i = 1
        foreach ($x in $issues) { [void]$L_.Add("  $i. $x"); $i++ }
    }
    [void]$L_.Add('')

    [void]$L_.Add((& $LANG_ '【建议】' '[Suggestions]'))
    if ($advice.Count -eq 0) {
        [void]$L_.Add((& $LANG_ '  · 继续观察；如果再次崩溃，回来点「诊断报告」查看新数据' '  - Keep monitoring; run the diagnosis again after the next crash'))
        [void]$L_.Add((& $LANG_ '  · 崩溃后请保留 reports\ 目录里的报告' '  - Keep the reports\ folder for reference'))
    } else {
        $i = 1
        foreach ($x in $advice) { [void]$L_.Add("  $i. $x"); $i++ }
    }
    [void]$L_.Add('')
    [void]$L_.Add((& $LANG_ '提示：以上是程序基于遥测数据的自动判断，供参考。' 'Note: these findings are rule-based guesses from telemetry, for reference only.'))
    [void]$L_.Add((& $LANG_ '      若多次出现同类问题，建议把 reports 目录的报告一起提供给懂行的人。' '      If the same issue keeps happening, share the reports\ files with someone experienced.'))

    return $L_
}
function Save-CrashSnapshot {
    <# 崩溃时把最近 5 分钟的曲线渲染成一张 PNG，存到 reports\ 里供报告引用 #>
    param([string]$Stamp, [int]$Points = 600)

    try {
        if ($script:TempHist.Count -lt 5) { return $null }
        $take = [math]::Min($Points, $script:TempHist.Count)
        $from = $script:TempHist.Count - $take

        $w = 1200; $h = 340
        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $vals = New-Object 'double[]' $take
        $vals2 = New-Object 'double[]' $take
        $script:TempHist.CopyTo($from, $vals, 0, $take)
        if ($script:PowerHist.Count -ge $script:TempHist.Count) {
            $script:PowerHist.CopyTo($from, $vals2, 0, $take)
        }

        $t0 = $null; $t1 = $null
        if ($script:HistTime.Count -ge $script:TempHist.Count) {
            $t0 = $script:HistTime[$from]
            $t1 = $script:HistTime[$script:TempHist.Count - 1]
        }
        $label = if ($t0 -and $t1) { "$($t0.ToString('HH:mm:ss')) - $($t1.ToString('HH:mm:ss'))" } else { '' }

        [ChartRenderer]::Render($bmp, $vals, $vals2, $take,
            $C.Card, $C.Grid, $C.Accent, $script:ColRed, $C.Dim,
            '崩溃前 5 分钟 GPU 曲线   ' + $label,
            '温度 (°C)', '功耗 (W)', '°C', 'W', -1)

        $path = Join-Path $RepDir ("crash-$Stamp.png")
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        return $path
    }
    catch { return $null }
}

function Show-CrashCard {
    <# 崩溃后弹一个精简结论卡片：一句话原因 + 建议 #>
    param([string]$ReportPath, [string]$SnapshotPath, [string]$Reason = '')

    $title = '⚠ 检测到游戏崩溃'
    $verdict = ''
    $advice = @()
    try {
        $lines = Get-Content $ReportPath -Encoding UTF8
        $inFind = $false
        foreach ($l in $lines) {
            if ($l -match '【诊断结论】|\[Findings\]') { $inFind = $true; continue }
            if ($l -match '^【建议】|^\[Suggestions\]') { $inFind = $false }
            if ($inFind -and $l -match '^\s+\d+\.\s*(.+)$') {
                if (-not $verdict) { $verdict = $matches[1] }
                elseif ($advice.Count -lt 2) { $advice += $matches[1] }
            }
        }
        if (-not $verdict) {
            $verdict = if ($Reason) { "崩溃特征：$Reason（未发现明显异常指标）" } else { '已生成诊断报告' }
        }
    }
    catch { $verdict = '已生成诊断报告' }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $script:T.AppTitle
    $dlg.Size = New-Object System.Drawing.Size(560, 300)
    $dlg.StartPosition = 'CenterScreen'
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)
    $dlg.ForeColor = $C.Text
    $dlg.TopMost = $true
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    try { $dlg.Icon = $form.Icon } catch {}

    $lblHead = New-Object System.Windows.Forms.Label
    $lblHead.Text = $title
    $lblHead.Font = New-Object System.Drawing.Font('微软雅黑', 14, [System.Drawing.FontStyle]::Bold)
    $lblHead.ForeColor = $C.Warn
    $lblHead.AutoSize = $true
    $lblHead.Location = New-Object System.Drawing.Point(20, 18)
    $dlg.Controls.Add($lblHead)

    $lblWhy = New-Object System.Windows.Forms.Label
    $lblWhy.Text = $verdict
    $lblWhy.Font = New-Object System.Drawing.Font('微软雅黑', 10)
    $lblWhy.ForeColor = $C.Text
    $lblWhy.Size = New-Object System.Drawing.Size(510, 60)
    $lblWhy.Location = New-Object System.Drawing.Point(20, 58)
    $dlg.Controls.Add($lblWhy)

    $y = 122
    foreach ($a in $advice) {
        $lblA = New-Object System.Windows.Forms.Label
        $lblA.Text = '· ' + $a
        $lblA.Font = New-Object System.Drawing.Font('微软雅黑', 9)
        $lblA.ForeColor = $C.Accent
        $lblA.Size = New-Object System.Drawing.Size(510, 22)
        $lblA.Location = New-Object System.Drawing.Point(20, $y)
        $dlg.Controls.Add($lblA)
        $y += 26
    }

    $btnOpen = New-Object System.Windows.Forms.Button
    $btnOpen.Text = '查看完整报告'
    $btnOpen.Size = New-Object System.Drawing.Size(140, 34)
    $btnOpen.Location = New-Object System.Drawing.Point(232, ($y + 10))
    $btnOpen.FlatStyle = 'Flat'
    $btnOpen.BackColor = [System.Drawing.Color]::FromArgb(34, 34, 40)
    $btnOpen.ForeColor = $C.Accent
    $btnOpen.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(64, 64, 78)
    $btnOpen.Add_Click({
        try { Start-Process 'notepad.exe' -ArgumentList "`"$ReportPath`"" } catch {}
        if ($SnapshotPath -and (Test-Path $SnapshotPath)) {
            try { Start-Process $SnapshotPath } catch {}
        }
        $dlg.Close()
    })
    $dlg.Controls.Add($btnOpen)

    $btnClose2 = New-Object System.Windows.Forms.Button
    $btnClose2.Text = '关闭'
    $btnClose2.Size = New-Object System.Drawing.Size(100, 34)
    $btnClose2.Location = New-Object System.Drawing.Point(382, ($y + 10))
    $btnClose2.FlatStyle = 'Flat'
    $btnClose2.BackColor = [System.Drawing.Color]::FromArgb(34, 34, 40)
    $btnClose2.ForeColor = $C.Text
    $btnClose2.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(64, 64, 78)
    $btnClose2.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($btnClose2)

    # 非模态显示：模态会卡住 500ms 采样循环，导致"崩溃后就不记录了"
    try { $dlg.TopMost = $true } catch {}
    $dlg.Show()
}
function Show-AboutDialog {
    $aboutEn = @(
        ("GameCrashDiag  " + $script:AppVersion),
        "",
        "[What it is]",
        "A lightweight local monitor and crash forensics tool. While a game runs it records GPU and CPU temperature, power, clocks and usage; after a crash it produces a report you can actually read.",
        "",
        "[Why it exists]",
        "It started as a way to debug DXGI_ERROR_DEVICE_HUNG crashes in Battlefield 6. After digging through hundreds of crash dumps, driver events and telemetry logs, most problems fell into three buckets: unstable overclocking, insufficient thermal headroom, and driver/OS mismatch. This tool automates that workflow.",
        "",
        "[What it does]",
        "- Live monitoring of 12 GPU/CPU metrics with trend charts; hover to read exact values and time",
        "- Detects any fullscreen game automatically and records into logs\<game>\; up to 6h of history",
        "- Generates a crash report with verdict, error code explanations and temperature baseline comparison",
        "- Built-in explanations for 25 common error codes (DXGI, bugchecks, driver events)",
        "- DirectX component check with one-click repair",
        "- Everything stays local: no network, no uploads, no injection into the game",
        "",
        "[Who it is for]",
        "Players who see crashes, freezes or artifacts and cannot read a dump file. Reports are plain text - paste them into a forum or send them to a friend.",
        "",
        "[About the findings]",
        "Diagnosis is rule-based reasoning over telemetry, not a professional repair service. If the same issue keeps happening, combine the report with official support or a repair shop.",
        "",
        "[Source]",
        "GitHub: https://github.com/zoesion/game-crash-diag",
        "",
        "This tool only monitors and collects evidence. It does not modify game files."
    )


    $about = @(
        ('游戏崩溃诊断器  GameCrashDiag  ' + $script:AppVersion),
        '',
        '【它是什么】',
        '一个轻量的本地监控与崩溃取证工具。游戏运行时自动记录显卡和 CPU 的温度、功耗、频率、占用；游戏闪退后自动生成一份能直接看懂的诊断报告。',
        '',
        '【为什么会有它】',
        '最早是为了排查《战地 6》的 DXGI_ERROR_DEVICE_HUNG 闪退写的。在翻了几百个崩溃转储、显卡驱动事件和遥测数据之后，发现绝大多数问题都集中在三个地方：超频不稳、散热余量不足、驱动与系统不匹配。于是把这套排查流程做成了自动化工具，省掉人工比对数据的功夫。',
        '',
        '【能做什么】',
        '· 实时监控 GPU / CPU 共 12 项指标，双曲线走势，鼠标悬停看具体数值和时间',
        '· 自动识别正在运行的全屏游戏，按游戏名分目录记录，可回看最近 6 小时',
        '· 游戏闪退时自动生成报告：判定结论、错误代码解读、温度基线对比',
        '· 内置 25 条常见错误码释义（DXGI 错误、蓝屏码、显卡驱动事件）',
        '· DirectX 组件完整性检查，缺组件可一键修复',
        '· 全部数据保存在本地，不联网、不上传、不注入游戏进程',
        '',
        '【适合谁】',
        '遇到游戏闪退、卡死、花屏，又看不懂 dump 文件的玩家。报告是纯文本，可以直接贴到论坛，或者发给懂行的朋友。',
        '',
        '【关于结论】',
        '诊断结论是基于遥测数据的规则判断，不是专业检修，仅供参考。如果反复出现同类问题，建议结合报告去找维修或官方支持。',
        '',
        '【开源地址】',
        'GitHub: https://github.com/zoesion/game-crash-diag',
        '',
        '本工具只做监控与取证，不修改游戏文件，不涉及任何破解。'
    )

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $script:T.AboutTitle
    $dlg.Size = New-Object System.Drawing.Size(660, 580)
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)
    $dlg.ForeColor = $C.Text
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    try { $dlg.Icon = $form.Icon } catch {}

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true
    $tb.ReadOnly = $true
    $tb.ScrollBars = 'Vertical'
    $tb.Dock = 'Fill'
    $tb.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 34)
    $tb.ForeColor = [System.Drawing.Color]::FromArgb(214, 216, 222)
    $tb.BorderStyle = 'None'
    $tb.Font = New-Object System.Drawing.Font('微软雅黑', 9.5)
    $tb.Text = if ($script:T.LanguageCode -eq 'en-US') { ($aboutEn -join "`r`n") } else { ($about -join "`r`n") }
    $tb.SelectionStart = 0
    $tb.SelectionLength = 0
    $tb.ScrollToCaret()

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = 'Bottom'
    $panel.Height = 46
    $panel.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = $script:T.BtnClose
    $btnOk.Size = New-Object System.Drawing.Size(132, 32)
    $btnOk.Location = New-Object System.Drawing.Point(492, 8)
    $btnOk.FlatStyle = 'Flat'
    $btnOk.BackColor = [System.Drawing.Color]::FromArgb(34, 34, 40)
    $btnOk.ForeColor = $C.Text
    $btnOk.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(64, 64, 78)
    $btnOk.Add_Click({ $dlg.Close() })

    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = $script:T.BtnCopy
    $btnCopy.Size = New-Object System.Drawing.Size(132, 32)
    $btnCopy.Location = New-Object System.Drawing.Point(348, 8)
    $btnCopy.FlatStyle = 'Flat'
    $btnCopy.BackColor = [System.Drawing.Color]::FromArgb(34, 34, 40)
    $btnCopy.ForeColor = $C.Text
    $btnCopy.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(64, 64, 78)
    $btnCopy.Add_Click({
        try {
            $lines = @(
                "游戏崩溃诊断器 $($script:AppVersion)",
                "系统: " + (Get-CimInstance Win32_OperatingSystem).Caption + " " + [Environment]::OSVersion.Version.ToString(),
                "显卡: " + $(try { (& nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>$null) -join '; ' } catch { '未知' }),
                "DirectX: " + $(if ($script:DxStatus -and $script:DxStatus.Missing.Count -eq 0) { '12 项组件齐全' } elseif ($script:DxStatus) { "缺 $($script:DxStatus.Missing.Count) 项" } else { '未检测' }),
                "崩溃记录: 累计 $(@(Get-ChildItem $RepDir -Filter 'crash-*.txt' -ErrorAction SilentlyContinue).Count) 次",
                "数据目录: $Root",
                '',
                '========== 诊断参考 =========='
            )
            try {
                $rep = Get-HealthReportText
                # 跳过报告开头的标题和分隔线，从【硬件 / 驱动】开始
                $body = @()
                $started = $false
                foreach ($l in $rep) {
                    if ($l -match '【硬件 / 驱动】') { $started = $true }
                    if ($started) { $body += $l }
                }
                if ($body.Count -gt 0) { $lines += $body } else { $lines += $rep }
            }
            catch { $lines += '（诊断信息生成失败）' }
            [System.Windows.Forms.Clipboard]::SetText(($lines -join "`r`n"))
            $btnCopy.Text = '已复制'
        } catch { }
    })

    $panel.Controls.Add($btnCopy)
    $panel.Controls.Add($btnOk)
    $dlg.Controls.Add($tb)
    $dlg.Controls.Add($panel)
    [void]$dlg.ShowDialog($form)
}

function Show-DiagnosisWindow {
    $lines = Get-HealthReportText
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $script:T.DiagTitle
    try { $dlg.Icon = $form.Icon } catch {}
    $dlg.Size = New-Object System.Drawing.Size(700, 620)
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)
    $dlg.ForeColor = [System.Drawing.Color]::FromArgb(228, 228, 231)
    $dlg.Font = New-Object System.Drawing.Font('微软雅黑', 9)
    $dlg.MinimizeBox = $false

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true
    $tb.ReadOnly = $true
    $tb.ScrollBars = 'Vertical'
    $tb.Dock = 'Fill'
    $tb.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 36)
    $tb.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 226)
    $tb.BorderStyle = 'None'
    $tb.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $tb.Text = ($lines -join "`r`n")
    $tb.SelectionStart = 0
    $tb.SelectionLength = 0
    $tb.ScrollToCaret()

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = 'Bottom'
    $panel.Height = 48
    $panel.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)

    $btnFix = New-Object System.Windows.Forms.Button
    $btnFix.Text = '修复 DirectX'
    $btnFix.Size = New-Object System.Drawing.Size(150, 32)
    $btnFix.Location = New-Object System.Drawing.Point(12, 8)
    $btnFix.FlatStyle = 'Flat'
    $btnFix.BackColor = [System.Drawing.Color]::FromArgb(30, 58, 42)
    $btnFix.ForeColor = [System.Drawing.Color]::FromArgb(150, 230, 180)
    $btnFix.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(52, 110, 78)
    $btnFix.Add_Click({ try { Invoke-DxRepair } catch { [System.Windows.Forms.MessageBox]::Show("修复失败：" + $_.Exception.Message, '错误') | Out-Null } })

    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = '复制报告'
    $btnCopy.Size = New-Object System.Drawing.Size(120, 32)
    $btnCopy.Location = New-Object System.Drawing.Point(452, 8)
    $btnCopy.FlatStyle = 'Flat'
    $btnCopy.BackColor = [System.Drawing.Color]::FromArgb(34, 34, 40)
    $btnCopy.ForeColor = [System.Drawing.Color]::FromArgb(228, 228, 231)
    $btnCopy.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(64, 64, 78)
    $btnCopy.Add_Click({ try { [System.Windows.Forms.Clipboard]::SetText($tb.Text); $btnCopy.Text = '已复制' } catch {} })

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = '关闭'
    $btnClose.Size = New-Object System.Drawing.Size(120, 32)
    $btnClose.Location = New-Object System.Drawing.Point(580, 8)
    $btnClose.FlatStyle = 'Flat'
    $btnClose.BackColor = [System.Drawing.Color]::FromArgb(34, 34, 40)
    $btnClose.ForeColor = [System.Drawing.Color]::FromArgb(228, 228, 231)
    $btnClose.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(64, 64, 78)
    $btnClose.Add_Click({ $dlg.Close() })

    $panel.Controls.Add($btnFix)
    $panel.Controls.Add($btnCopy)
    $panel.Controls.Add($btnClose)
    $dlg.Controls.Add($tb)
    $dlg.Controls.Add($panel)
    [void]$dlg.ShowDialog($form)
}

# ════════════════════════════════ 托盘图标 ════════════════════════════════
$script:ExitFlag = $false
$trayIcon = New-Object System.Windows.Forms.NotifyIcon
try {
    $icoPath = Join-Path $Root 'app.ico'
    if (Test-Path $icoPath) { $trayIcon.Icon = New-Object System.Drawing.Icon($icoPath) }
    else { $trayIcon.Icon = [System.Drawing.SystemIcons]::Application }
} catch { $trayIcon.Icon = [System.Drawing.SystemIcons]::Application }
$trayIcon.Text = $script:T.AppTitle
$trayIcon.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = $trayMenu.Items.Add($script:T.TrayShow)
$miFolder = $trayMenu.Items.Add($script:T.MenuLogs)
[void]$trayMenu.Items.Add('-')
$miExit = $trayMenu.Items.Add($script:T.TrayExit)
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
            $trayIcon.ShowBalloonTip(1500, $script:T.AppTitle, $script:T.TrayBalloon, [System.Windows.Forms.ToolTipIcon]::Info)
        } catch {}
    }


})
if ($Shot) {
    try { Update-DxIndicator } catch {}
    # 离屏截图：不显示窗口，直接把界面渲染成 PNG（不抢游戏焦点）
    if ($FillPoints -gt 0) {
        # 压测：灌入 N 个合成点，验证 1 万点缓存的绘制性能
        $script:TempHist.Clear(); $script:PowerHist.Clear()
        $rnd = New-Object System.Random 42
        for ($i = 0; $i -lt $FillPoints; $i++) {
            [void]$script:HistTime.Add((Get-Date).AddSeconds(-($FillPoints - $i) * 0.5))
            [void]$script:TempHist.Add(58 + 4 * [math]::Sin($i / 90.0) + $rnd.NextDouble() * 0.8)
            [void]$script:PowerHist.Add(145 + 20 * [math]::Sin($i / 40.0) + $rnd.NextDouble() * 6)
        }
        $script:CpuTempHist.Clear(); $script:CpuFreqHist.Clear()
        for ($i = 0; $i -lt $FillPoints; $i++) {
            [void]$script:CpuHistTime.Add((Get-Date).AddSeconds(-($FillPoints - $i) * 0.5))
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


if ($TestDiagnosis) {
    Start-Logging 'system'
    for ($i = 0; $i -lt 4; $i++) { Update-UI; Start-Sleep -Milliseconds 350 }
    Get-HealthReportText | ForEach-Object { Write-Output $_ }
    exit 0
}
if ($TestView) {
    # 灌 3000 个合成点，验证窗口计算
    for ($i = 0; $i -lt 3000; $i++) {
        [void]$script:TempHist.Add(50 + ($i % 10))
        [void]$script:PowerHist.Add(100 + ($i % 20))
        [void]$script:HistTime.Add((Get-Date).AddSeconds(-($3000 - $i) * 0.5))
        [void]$script:CpuTempHist.Add(60 + ($i % 8))
        [void]$script:CpuFreqHist.Add(3000 + ($i % 100))
        [void]$script:CpuHistTime.Add((Get-Date).AddSeconds(-($3000 - $i) * 0.5))
    }
    $script:IntervalMs = 500
    Set-ViewSpan 10
    $r = Get-ViewRange
    Write-Output ("窗口默认: from={0} to={1} count={2} shift={3}" -f $r.From, $r.To, $r.Count, $r.Shift)
    Shift-View 1
    $r = Get-ViewRange
    Write-Output ("左移一次: from={0} to={1} count={2} shift={3}" -f $r.From, $r.To, $r.Count, $r.Shift)
    Shift-View 5
    $r = Get-ViewRange
    Write-Output ("再左移5次: from={0} to={1} shift={2} (应被夹在 {3})" -f $r.From, $r.To, $r.Shift, (3000 - $r.Span))
    Reset-View
    $r = Get-ViewRange
    Write-Output ("重置最新: from={0} to={1} shift={2}" -f $r.From, $r.To, $r.Shift)
    Set-ViewSpan 30
    $r = Get-ViewRange
    Write-Output ("切到30分钟: count={0} (期望 3600 被裁到 3000)" -f $r.Count)
    exit 0
}
if ($ShowAbout -or $ShowDiagnosis) {
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 800
    try { Update-DxIndicator } catch {}
    if ($ShowAbout) { Show-AboutDialog } else { Show-DiagnosisWindow }
    exit 0
}
if ($TestRestore) {
    # 验证：从 data\history\samples.csv 接回 6 小时曲线
    $path = Get-HistStorePath
    Write-Output ("历史文件: " + $path + "  存在=" + (Test-Path $path))
    if (Test-Path $path) {
        $all = [System.IO.File]::ReadAllLines($path)
        Write-Output ("文件行数: " + $all.Count)
        if ($all.Count -gt 0) { Write-Output ("首行: " + $all[0]); Write-Output ("末行: " + $all[-1]) }
    }
    $n = Restore-HistoryFromStore
    Write-Output ("恢复到: " + $script:TempHist.Count + " 点，覆盖 " + (Get-LoadedHours) + " 小时")
    $more = Load-OlderHistory 6
    Write-Output ("载入更早: " + $more + " 点，现在共 " + $script:TempHist.Count + " 点，覆盖 " + (Get-LoadedHours) + " 小时")
    $more2 = Load-OlderHistory 6
    Write-Output ("再载入: " + $more2 + " 点，覆盖 " + (Get-LoadedHours) + " 小时")
    Load-MarkersFromDisk
    Write-Output ("标记数: " + $script:Markers.Count)
    if ($script:TempHist.Count -ge 2) { Draw-Chart; Write-Output "绘制完成（无异常）" }
    exit 0
}

if ($TestMarkerShot) {
    # 画出三种标记，存成图片用于核对
    $bmp = New-Object System.Drawing.Bitmap(900, 160)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(24, 24, 28))
    $g.Dispose()
    $base = (Get-Date).AddMinutes(-10)
    for ($k = 0; $k -lt 600; $k++) { [void]$script:HistTime.Add($base.AddSeconds($k)) }
    Add-Marker 'gap'   $base.AddSeconds(120)
    Add-Marker 'crash' $base.AddSeconds(300)
    Add-Marker 'down'  $base.AddSeconds(480)
    Add-Marker 'crash' $base.AddSeconds(560)
    $script:SessionGapMin = 47
    Draw-SessionMarker $bmp 0 600
    $bmp.Save($MarkerShotPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Output ("已保存: " + $MarkerShotPath)
    exit 0
}

if ($TestGameStart) {
    # 复现「游戏中开局」场景：先记录一段，再 Start-Logging（模拟检测到游戏），检查四条曲线是否等长
    Start-Logging 'system'
    for ($i = 0; $i -lt 6; $i++) { Update-UI; Start-Sleep -Milliseconds 200 }
    Write-Output ("开局前: GPU=$($script:TempHist.Count) CPU=$($script:CpuTempHist.Count) 时间GPU=$($script:HistTime.Count) 时间CPU=$($script:CpuHistTime.Count)")
    Start-Logging 'system'
    Write-Output ("Start-Logging 后: GPU=$($script:TempHist.Count) CPU=$($script:CpuTempHist.Count)")
    for ($i = 0; $i -lt 6; $i++) { Update-UI; Start-Sleep -Milliseconds 200 }
    Write-Output ("再采 6 次后: GPU=$($script:TempHist.Count) CPU=$($script:CpuTempHist.Count) 时间GPU=$($script:HistTime.Count) 时间CPU=$($script:CpuHistTime.Count)")
    $ok = ($script:TempHist.Count -eq $script:CpuTempHist.Count -and $script:HistTime.Count -eq $script:CpuHistTime.Count)
    Write-Output ("四条曲线等长: " + $ok)
    Draw-Chart
    Write-Output "绘制完成"
    exit 0
}

if ($TestClear) {
    Start-Logging 'system'
    for ($i = 0; $i -lt 8; $i++) { Update-UI; Start-Sleep -Milliseconds 200 }
    Write-Output "清空前: 缓冲=$($script:TempHist.Count) 时间=$($script:HistTime.Count) 记录=$($script:LogCount)"
    Clear-AllData
    Write-Output "清空后: 缓冲=$($script:TempHist.Count) 时间=$($script:HistTime.Count) 记录=$($script:LogCount) 文件=$($script:LogFile)"
    for ($i = 0; $i -lt 6; $i++) {
        try { Update-UI; Draw-Chart; Write-Output "  刷新 $($i+1) 正常" }
        catch { Write-Output ("  刷新 $($i+1) 异常: " + $_.Exception.Message); Write-Output ("    " + $_.ScriptStackTrace) }
        Start-Sleep -Milliseconds 400
    }
    exit 0
}
if ($TestCrash) {
    Start-Logging 'system'
    for ($i = 0; $i -lt 240; $i++) { Update-UI; Start-Sleep -Milliseconds 60 }
    $exitTime = Get-Date
    Stop-Logging
    $rep = Write-CrashReport $exitTime $true '测试模拟崩溃'
    $snap = Save-CrashSnapshot -Stamp ($exitTime.ToString('yyyyMMdd-HHmmss'))
    Write-Output "报告: $rep"
    Write-Output "快照: $snap"
    Show-CrashCard -ReportPath $rep -SnapshotPath $snap -Reason $verdict.Reason
    exit 0
}
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
