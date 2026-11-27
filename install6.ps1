param(
    [switch]$Silent,
    [string]$InstallDir = '',
    [switch]$Shortcut,
    [switch]$Autostart,
    [switch]$Launch
)

$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $PSCommandPath
if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\GameCrashDiag6' }

function Log([string]$msg) { if (-not $Silent) { Write-Host $msg } else { Write-Host $msg } }

# 结束正在运行的实例，否则文件被占用
$running = Get-Process -Name 'GameCrashDiag6' -ErrorAction SilentlyContinue
if ($running) {
    Log "关闭正在运行的 GameCrashDiag6..."
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 300
        if (-not (Get-Process -Name 'GameCrashDiag6' -ErrorAction SilentlyContinue)) { break }
    }
}

if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null }
Log "安装到: $InstallDir"

function Copy-WithRetry([string]$from, [string]$to) {
    for ($i = 0; $i -lt 4; $i++) {
        try { Copy-Item $from $to -Recurse -Force -ErrorAction Stop; return } catch {
            if ($i -eq 3) { throw }
            Start-Sleep -Milliseconds 800
        }
    }
}

$files = @('GameCrashDiag6.exe', 'uninstall6.ps1', 'README.md', 'LICENSE', 'instance.txt')
foreach ($f in $files) {
    $p = Join-Path $src $f
    if (Test-Path $p) { Copy-WithRetry $p $InstallDir }
}
function Merge-Copy([string]$from, [string]$to) {
    if (-not (Test-Path $to)) { New-Item -ItemType Directory -Force -Path $to | Out-Null }
    Get-ChildItem $from -Force | ForEach-Object {
        $target = Join-Path $to $_.Name
        if ($_.PSIsContainer) {
            Merge-Copy $_.FullName $target
        } else {
            Copy-WithRetry $_.FullName $target
        }
    }
}

foreach ($sub in 'thirdparty', 'lang', 'data', 'docs') {
    $p = Join-Path $src $sub
    if (Test-Path $p) { Merge-Copy $p (Join-Path $InstallDir $sub) }
}

# 测试副本的 instance.txt 不能带到正式安装里
$inst = Join-Path $InstallDir 'instance.txt'
if (Test-Path $inst) { Remove-Item $inst -Force -ErrorAction SilentlyContinue }

# 解除网络文件锁定（MOTW 会让 LHM 的 DLL 加载失败）
try {
    Get-ChildItem $InstallDir -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
} catch { }

$exe = Join-Path $InstallDir 'GameCrashDiag6.exe'
if (-not (Test-Path $exe)) { throw "安装失败: 找不到 $exe" }

$ws = New-Object -ComObject WScript.Shell
$icon = if (Test-Path (Join-Path $InstallDir 'app.ico')) { Join-Path $InstallDir 'app.ico' } else { $exe }

if ($Shortcut) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnk = Join-Path $desktop '游戏崩溃诊断器 v6.lnk'
    $s = $ws.CreateShortcut($lnk)
    $s.TargetPath = $exe
    $s.WorkingDirectory = $InstallDir
    $s.IconLocation = $icon
    $s.Description = '游戏崩溃诊断器 v6（C# 版）'
    $s.Save()
    Log "已创建桌面快捷方式"

    $startDir = Join-Path ([Environment]::GetFolderPath('Programs')) '游戏崩溃诊断器 v6'
    if (-not (Test-Path $startDir)) { New-Item -ItemType Directory -Force -Path $startDir | Out-Null }
    $s2 = $ws.CreateShortcut((Join-Path $startDir '游戏崩溃诊断器 v6.lnk'))
    $s2.TargetPath = $exe
    $s2.WorkingDirectory = $InstallDir
    $s2.IconLocation = $icon
    $s2.Save()
}

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if ($Autostart) {
    Set-ItemProperty -Path $runKey -Name 'GameCrashDiag6' -Value ('"' + $exe + '" -Tray') -Force
    Log "已设置开机自启（进托盘）"
}

# 卸载信息（设置 → 应用 里能看到）
try {
    $uninst = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\GameCrashDiag6'
    if (-not (Test-Path $uninst)) { New-Item -Path $uninst -Force | Out-Null }
    Set-ItemProperty -Path $uninst -Name 'DisplayName' -Value '游戏崩溃诊断器 v6' -Force
    Set-ItemProperty -Path $uninst -Name 'DisplayVersion' -Value '6.0' -Force
    Set-ItemProperty -Path $uninst -Name 'InstallLocation' -Value $InstallDir -Force
    Set-ItemProperty -Path $uninst -Name 'DisplayIcon' -Value $exe -Force
    $uninstCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $InstallDir 'uninstall6.ps1') + '"'
    Set-ItemProperty -Path $uninst -Name 'UninstallString' -Value $uninstCmd -Force
    Set-ItemProperty -Path $uninst -Name 'NoModify' -Value 1 -PropertyType DWord -Force
    Set-ItemProperty -Path $uninst -Name 'NoRepair' -Value 1 -PropertyType DWord -Force
} catch { }

if ($Launch) {
    Start-Process -FilePath $exe -WorkingDirectory $InstallDir
    Log "已启动程序"
}

Log "安装完成"
exit 0
