$ErrorActionPreference = 'Stop'
$root = 'D:\AI_Work\game-crash-diag'
$setupDir = Join-Path $root 'setup'
$appDir = 'D:\Program Files\GameCrashDiag6'
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "csc.exe not found" }

# 1) 打包 payload
$stage = Join-Path $env:TEMP 'gcd6-payload'
Remove-Item $stage -Recurse -Force -EA 0
New-Item -ItemType Directory -Force -Path $stage | Out-Null

Copy-Item (Join-Path $appDir 'GameCrashDiag6.exe') $stage -Force
foreach ($f in 'app.ico', 'README.md', 'LICENSE') {
    $p = Join-Path $root $f
    if (Test-Path $p) { Copy-Item $p $stage -Force }
}
Copy-Item (Join-Path $root 'install6.ps1') $stage -Force
foreach ($sub in 'thirdparty', 'lang', 'data') {
    $p = Join-Path $appDir $sub
    if (Test-Path $p) { Copy-Item $p (Join-Path $stage $sub) -Recurse -Force }
}
# 历史数据不要打进安装包
if (Test-Path (Join-Path $stage 'data\history')) { Remove-Item (Join-Path $stage 'data\history') -Recurse -Force -EA 0 }

$payload = Join-Path $setupDir 'app6.zip'
Remove-Item $payload -Force -EA 0
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $payload -CompressionLevel Optimal
Remove-Item $stage -Recurse -Force -EA 0
Write-Output ("payload: app6.zip  " + [math]::Round((Get-Item $payload).Length / 1KB, 1) + " KB")

# 2) 编译安装程序
$outFinal = Join-Path $root '游戏崩溃诊断器-v6-安装程序.exe'
$out = Join-Path $setupDir 'setup6.exe'
$refs = @('/r:System.dll', '/r:System.Core.dll', '/r:System.Drawing.dll', '/r:System.Windows.Forms.dll',
          '/r:System.IO.Compression.dll', '/r:System.IO.Compression.FileSystem.dll')
$args = @('/nologo', '/target:winexe', '/platform:anycpu', '/optimize+', '/codepage:65001',
          "/win32icon:$root\app.ico"
          "/win32manifest:$root\src\app.manifest", "/resource:$payload,app6.zip", "/out:$out") + $refs + @((Join-Path $setupDir 'Setup6.cs'))

$outFile = Join-Path $env:TEMP 'csc6.out'
$errFile = Join-Path $env:TEMP 'csc6.err'
$proc = Start-Process -FilePath $csc -ArgumentList ($args -join ' ') -WorkingDirectory $setupDir -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput $outFile -RedirectStandardError $errFile
Get-Content $outFile -EA 0 | Where-Object { $_ -notmatch '^\s*$' } | Select-Object -First 10 | ForEach-Object { '  ' + $_ }
Get-Content $errFile -EA 0 | Where-Object { $_ -notmatch '^\s*$' } | Select-Object -First 10 | ForEach-Object { '  ' + $_ }
Write-Output ('exit code: ' + $proc.ExitCode)
if (Test-Path $out) {
    Move-Item $out $outFinal -Force
    Write-Output ('installer: ' + $outFinal + '  ' + [math]::Round((Get-Item $outFinal).Length / 1KB, 1) + ' KB')
} else {
    Write-Output 'FAILED: no installer'
}
