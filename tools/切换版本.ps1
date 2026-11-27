param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('v6', 'v5')]
    [string]$To
)

$ErrorActionPreference = 'Stop'
$V5Dir = 'D:\Program Files\GameCrashDiag'
$V6Dir = 'D:\Program Files\GameCrashDiag6'
$V5Exe = Join-Path $V5Dir 'GameCrashDiag.ps1'
$V6Exe = Join-Path $V6Dir 'GameCrashDiag6.exe'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$Desktop = [Environment]::GetFolderPath('Desktop')
$BackupDir = Join-Path $env:LOCALAPPDATA 'GameCrashDiag'
$BackupFile = Join-Path $BackupDir 'switch-backup.txt'

function Say([string]$m) { Write-Host $m }

if (-not (Test-Path $V5Dir)) { throw "找不到 v5 目录: $V5Dir" }
if (-not (Test-Path $V6Dir)) { throw "找不到 v6 目录: $V6Dir" }

Say '=== 1. 停止正在运行的实例 ==='
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'GameCrashDiag\.ps1' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
Get-Process -Name 'GameCrashDiag6' -ErrorAction SilentlyContinue |
    ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch { } }
Start-Sleep -Seconds 3
Say '  已停止'

Say '=== 2. 备份当前自启与快捷方式状态 ==='
if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null }
$v5Run = (Get-ItemProperty -Path $RunKey -Name 'GameCrashDiag' -ErrorAction SilentlyContinue).GameCrashDiag
$v6Run = (Get-ItemProperty -Path $RunKey -Name 'GameCrashDiag6' -ErrorAction SilentlyContinue).GameCrashDiag6
@(
    "v5Run=$v5Run"
    "v6Run=$v6Run"
    "time=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
) | Set-Content -Path $BackupFile -Encoding UTF8
Say "  已备份到 $BackupFile"

if ($To -eq 'v6') {
    Say '=== 3. 迁移历史数据（让曲线接得上）==='
    $v5Hist = Join-Path $V5Dir 'data\history'
    $v6Hist = Join-Path $V6Dir 'data\history'
    if (-not (Test-Path $v6Hist)) { New-Item -ItemType Directory -Force -Path $v6Hist | Out-Null }
    foreach ($name in 'samples.csv', 'markers.csv') {
        $src = Join-Path $v5Hist $name
        $dst = Join-Path $v6Hist $name
        if (Test-Path $src) {
            $srcSize = (Get-Item $src).Length
            $dstSize = if (Test-Path $dst) { (Get-Item $dst).Length } else { 0 }
            if ($srcSize -gt $dstSize) {
                Copy-Item $src $dst -Force
                Say ("  已迁移 {0}  ({1:N1} MB)" -f $name, ($srcSize / 1MB))
            }
        }
    }
    # 历史日志也带过去，这样「载入更早的记录」能翻到以前的
    $v5Logs = Join-Path $V5Dir 'logs'
    $v6Logs = Join-Path $V6Dir 'logs'
    if (Test-Path $v5Logs) {
        Get-ChildItem $v5Logs -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $target = Join-Path $v6Logs $_.Name
            if (-not (Test-Path $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }
            Get-ChildItem $_.FullName -Filter '*.csv' -ErrorAction SilentlyContinue | ForEach-Object {
                $t = Join-Path $target $_.Name
                if (-not (Test-Path $t)) { Copy-Item $_.FullName $t -Force -ErrorAction SilentlyContinue }
            }
        }
        Say '  已迁移历史日志'
    }

    Say '=== 4. 切换开机自启到 v6 ==='
    Remove-ItemProperty -Path $RunKey -Name 'GameCrashDiag' -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $RunKey -Name 'GameCrashDiag6' -Value ('"' + $V6Exe + '" -Tray') -Force
    Say '  自启 -> v6（启动进托盘）'

    Say '=== 5. 切换桌面快捷方式 ==='
    Get-ChildItem $Desktop -Filter '*.lnk' -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*诊断器*' } |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut((Join-Path $Desktop '游戏崩溃诊断器.lnk'))
    $lnk.TargetPath = $V6Exe
    $lnk.WorkingDirectory = $V6Dir
    $icon = Join-Path $V6Dir 'app.ico'
    $lnk.IconLocation = if (Test-Path $icon) { $icon } else { $V6Exe }
    $lnk.Description = '游戏崩溃诊断器 v6'
    $lnk.Save()
    Say '  桌面快捷方式 -> v6'

    Say '=== 6. 启动 v6（进托盘）==='
    Start-Process -FilePath $V6Exe -ArgumentList '-Tray' -WorkingDirectory $V6Dir
    Start-Sleep -Seconds 4
    Say '  已启动'
}
else {
    Say '=== 3. 恢复开机自启到 v5 ==='
    Remove-ItemProperty -Path $RunKey -Name 'GameCrashDiag6' -ErrorAction SilentlyContinue
    $vbs = Join-Path $V5Dir '自启-托盘.vbs'
    Set-ItemProperty -Path $RunKey -Name 'GameCrashDiag' -Value ('"C:\Windows\System32\wscript.exe" "' + $vbs + '"') -Force
    Say '  自启 -> v5'

    Say '=== 4. 恢复桌面快捷方式 ==='
    Get-ChildItem $Desktop -Filter '*.lnk' -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*诊断器*' } |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut((Join-Path $Desktop '游戏崩溃诊断器.lnk'))
    $lnk.TargetPath = 'C:\Windows\System32\wscript.exe'
    $lnk.Arguments = '"' + (Join-Path $V5Dir '启动诊断器.vbs') + '"'
    $lnk.WorkingDirectory = $V5Dir
    $lnk.IconLocation = if (Test-Path (Join-Path $V5Dir 'app.ico')) { Join-Path $V5Dir 'app.ico' } else { $V5Dir }
    $lnk.Description = '游戏崩溃诊断器 v5.97'
    $lnk.Save()
    Say '  桌面快捷方式 -> v5'

    Say '=== 5. 启动 v5（托盘）==='
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + (Join-Path $V5Dir '自启-托盘.vbs') + '"') -WindowStyle Hidden
    Start-Sleep -Seconds 4
    Say '  已启动'
}

Say ''
Say '=== 完成 ==='
Say "  当前默认版本: $To"
Say "    自启:  $((Get-ItemProperty -Path $RunKey -Name ('GameCrashDiag' + $(if ($To -eq 'v6') { '6' } else { '' })) -ErrorAction SilentlyContinue).('GameCrashDiag' + $(if ($To -eq 'v6') { '6' } else { '' })))"
Say '  回滚方法: tools\切换版本.ps1 -To v5'
Say '  v5 目录没有删除，随时可以切回去'
exit 0
