$ErrorActionPreference = 'Stop'
$root = 'D:\AI_Work\game-crash-diag'
$src = Join-Path $root 'src'
$outDir = 'D:\Program Files\GameCrashDiag6'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw 'csc.exe not found' }
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

$files = (Get-ChildItem $src -Filter '*.cs' | ForEach-Object { '"' + $_.FullName + '"' }) -join ' '
$argLine = @(
    '/nologo',
    '/target:winexe',
    '/platform:x64',
    '/optimize+',
    '/out:GameCrashDiag6.exe',
    '/win32icon:D:\AI_Work\game-crash-diag\app.ico',
    '/win32manifest:"D:\AI_Work\game-crash-diag\src\app.manifest"',
    '/reference:System.dll',
    '/reference:System.Core.dll',
    '/reference:System.Drawing.dll',
    '/reference:System.Windows.Forms.dll',
    '/reference:System.Management.dll',
    '/reference:"D:\Program Files\GameCrashDiag6\thirdparty\lhm\LibreHardwareMonitorLib.dll"',
    '/reference:"D:\Program Files\GameCrashDiag6\thirdparty\lhm\HidSharp.dll"',
    $files
) -join ' '

$outFile = Join-Path $env:TEMP 'csc.out'
$errFile = Join-Path $env:TEMP 'csc.err'
$proc = Start-Process -FilePath $csc -ArgumentList $argLine -WorkingDirectory $outDir -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
$stdout = Get-Content $outFile -ErrorAction SilentlyContinue
$stderr = Get-Content $errFile -ErrorAction SilentlyContinue
if ($stdout) { $stdout | Where-Object { $_ -notmatch '^\s*$' } | Select-Object -First 20 | ForEach-Object { '  ' + $_ } }
if ($stderr) { $stderr | Where-Object { $_ -notmatch '^\s*$' } | Select-Object -First 20 | ForEach-Object { '  ' + $_ } }
Write-Output ('exit code: ' + $proc.ExitCode)

$exe = Join-Path $outDir 'GameCrashDiag6.exe'
if (Test-Path $exe) {
    Write-Output ('built: ' + $exe + '  ' + [math]::Round((Get-Item $exe).Length / 1KB, 1) + ' KB')
} else {
    Write-Output 'FAILED: no exe'
}
