param(
    [switch]$Quiet,
    [switch]$Purge
)

$ErrorActionPreference = 'Continue'
$dir = Split-Path -Parent $PSCommandPath
$exe = Join-Path $dir 'GameCrashDiag6.exe'
$title = '卸载 游戏崩溃诊断器 v6'

function Ask([string]$text) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $r = [System.Windows.Forms.MessageBox]::Show($text, $title,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
    } catch { return $true }
}

function Done([string]$text) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($text, $title) | Out-Null
    } catch { }
}

if (-not $Quiet) {
    $msg = "确定要卸载「游戏崩溃诊断器 v6」吗？`n`n程序目录：$dir`n`n日志（logs）和崩溃报告（reports）会保留。"
    if (-not (Ask $msg)) { exit 0 }
}

# 1) 关闭正在运行的实例
$procs = Get-Process -Name 'GameCrashDiag6' -ErrorAction SilentlyContinue
if ($procs) {
    Write-Host '关闭正在运行的程序...'
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 300
        if (-not (Get-Process -Name 'GameCrashDiag6' -ErrorAction SilentlyContinue)) { break }
    }
}

# 2) 快捷方式
$desktop = [Environment]::GetFolderPath('Desktop')
foreach ($name in '游戏崩溃诊断器 v6.lnk', '游戏崩溃诊断器6.lnk') {
    $p = Join-Path $desktop $name
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue; Write-Host '已删除桌面快捷方式' }
}
$startDir = Join-Path ([Environment]::GetFolderPath('Programs')) '游戏崩溃诊断器 v6'
if (Test-Path $startDir) {
    Remove-Item $startDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '已删除开始菜单项'
}

# 3) 开机自启
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
try {
    if (Get-ItemProperty -Path $runKey -Name 'GameCrashDiag6' -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $runKey -Name 'GameCrashDiag6' -ErrorAction SilentlyContinue
        Write-Host '已移除开机自启'
    }
} catch { }

# 4) 卸载注册项
$uninst = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\GameCrashDiag6'
if (Test-Path $uninst) {
    Remove-Item $uninst -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '已移除卸载项'
}

# 5) 文件：默认保留用户数据（logs / reports / data\history）
$keep = @()
if (-not $Purge) { $keep = @('logs', 'reports', 'data') }

Get-ChildItem $dir -File -ErrorAction SilentlyContinue | ForEach-Object {
    try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch { }
}
Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    if ($keep -contains $_.Name) {
        if ($_.Name -eq 'data' -and -not (Test-Path (Join-Path $_.FullName 'history'))) {
            # data 目录里只留 history，其余（语言包等）删掉
        }
    } else {
        try { Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop } catch { }
    }
}

# data 目录：保留 history，其它是程序资源，删掉
$dataDir = Join-Path $dir 'data'
if ((Test-Path $dataDir) -and -not $Purge) {
    Get-ChildItem $dataDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

$leftFiles = @(Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\logs\\' -and $_.FullName -notmatch '\\reports\\' -and $_.FullName -notmatch '\\data\\history\\' })
$left = $leftFiles.Count
Write-Host "剩余程序文件: $left"

if (-not $Quiet) {
    if ($left -gt 0) {
        Done "卸载完成，但还有 $left 个文件没能删除（可能被占用）。`n`n可以手动删除目录：`n$dir"
    } else {
        try { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        Done "卸载完成。`n`n日志和崩溃报告已保留在卸载前的目录里（如果还想看，请从备份或回收站找回）。"
    }
}
exit 0
