$ErrorActionPreference = 'Stop'
$root = 'D:\AI_Work\game-crash-diag'
$setupDir = Join-Path $root 'setup'
$appDir = 'D:\Program Files\GameCrashDiag6'
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "csc.exe not found" }

# 1) stage payload
$stage = Join-Path $env:TEMP 'gcd6-payload'
Remove-Item $stage -Recurse -Force -EA 0
New-Item -ItemType Directory -Force -Path $stage | Out-Null

Copy-Item (Join-Path $appDir 'GameCrashDiag6.exe') $stage -Force
foreach ($f in 'app.ico', 'README.md', 'LICENSE') {
    $p = Join-Path $root $f
    if (Test-Path $p) { Copy-Item $p $stage -Force }
}
Copy-Item (Join-Path $root 'install6.ps1') $stage -Force
Copy-Item (Join-Path $root 'uninstall6.ps1') $stage -Force

# thirdparty: whole folder
Copy-Item (Join-Path $appDir 'thirdparty') (Join-Path $stage 'thirdparty') -Recurse -Force

# lang: only .ini files (psd1 belongs to the PowerShell build)
$langDst = Join-Path $stage 'lang'
New-Item -ItemType Directory -Force -Path $langDst | Out-Null
Get-ChildItem (Join-Path $appDir 'lang') -Filter '*.ini' -File | Copy-Item -Destination $langDst -Force

# data: only the error-code tables; never ship history (user data, can be tens of MB)
$dataDst = Join-Path $stage 'data'
New-Item -ItemType Directory -Force -Path $dataDst | Out-Null
Get-ChildItem (Join-Path $appDir 'data') -Filter '*.txt' -File | Copy-Item -Destination $dataDst -Force

$payload = Join-Path $setupDir 'app6.zip'
Remove-Item $payload -Force -EA 0
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $payload -CompressionLevel Optimal
Remove-Item $stage -Recurse -Force -EA 0
Write-Output ("payload: app6.zip  " + [math]::Round((Get-Item $payload).Length / 1KB, 1) + " KB")

# 2) compile the wizard
$out = Join-Path $setupDir 'setup6.exe'
$refs = @('/r:System.dll', '/r:System.Core.dll', '/r:System.Drawing.dll', '/r:System.Windows.Forms.dll',
          '/r:System.IO.Compression.dll', '/r:System.IO.Compression.FileSystem.dll')
$args = @('/nologo', '/target:winexe', '/platform:anycpu', '/optimize+', '/codepage:65001',
          "/win32icon:$root\app.ico",
          "/win32manifest:$root\src\app.manifest",
          "/resource:$payload,app6.zip", '/out:setup6.exe') + $refs + @((Join-Path $setupDir 'Setup6.cs'))

$outFile = Join-Path $env:TEMP 'csc6.out'
$errFile = Join-Path $env:TEMP 'csc6.err'
$proc = Start-Process -FilePath $csc -ArgumentList ($args -join ' ') -WorkingDirectory $setupDir -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput $outFile -RedirectStandardError $errFile
Get-Content $outFile -EA 0 | Where-Object { $_ -notmatch '^\s*$' } | Select-Object -First 10 | ForEach-Object { '  ' + $_ }
Get-Content $errFile -EA 0 | Where-Object { $_ -notmatch '^\s*$' } | Select-Object -First 10 | ForEach-Object { '  ' + $_ }
Write-Output ('exit code: ' + $proc.ExitCode)
if (Test-Path $out) {
    Write-Output ('installer: ' + $out + '  ' + [math]::Round((Get-Item $out).Length / 1KB, 1) + ' KB')
} else {
    Write-Output 'FAILED: no installer'
}
