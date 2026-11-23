<#
.SYNOPSIS
    解析 Windows Minidump (.mdmp)，提取异常代码、出错地址、所属模块、已加载模块

.DESCRIPTION
    不依赖 WinDbg。直接按 MINIDUMP 格式读取：
      - ExceptionStream  -> 异常代码 / 异常地址 / 参数
      - ModuleListStream -> 模块列表，用于把地址映射回模块，并检查是否加载了 DLSS 等组件

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\analyze-dump.ps1 -DumpPath "xxx.mdmp"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DumpPath,
    [switch]$ShowModules
)

if (-not (Test-Path $DumpPath)) { Write-Host "文件不存在: $DumpPath" -ForegroundColor Red; exit 1 }

$fs = [System.IO.File]::OpenRead((Resolve-Path $DumpPath))
$br = New-Object System.IO.BinaryReader($fs)

try {
    # ── 文件头 ──
    $sig = $br.ReadUInt32()
    if ($sig -ne 0x504D444D) { throw "不是有效的 minidump（签名 0x$('{0:X}' -f $sig)）" }
    $ver = $br.ReadUInt32()
    $numStreams = $br.ReadUInt32()
    $dirRva = $br.ReadUInt32()
    [void]$br.ReadUInt32()          # CheckSum
    $tds = $br.ReadUInt32()         # TimeDateStamp
    [void]$br.ReadUInt64()          # Flags

    # ── 流目录 ──
    $fs.Position = $dirRva
    $dirs = @()
    for ($i = 0; $i -lt $numStreams; $i++) {
        $dirs += [pscustomobject]@{
            Type = $br.ReadUInt32()
            Size = $br.ReadUInt32()
            Rva  = $br.ReadUInt32()
        }
    }

    function Read-MiniString([uint32]$rva) {
        $fs.Position = $rva
        $len = $br.ReadUInt32()
        if ($len -eq 0 -or $len -gt 4096) { return '' }
        $buf = $br.ReadBytes($len)
        return [System.Text.Encoding]::Unicode.GetString($buf).TrimEnd([char]0)
    }

    # ── 模块列表 ──
    $modules = @()
    $modDir = $dirs | Where-Object { $_.Type -eq 4 } | Select-Object -First 1
    if ($modDir) {
        $fs.Position = $modDir.Rva
        $count = $br.ReadUInt32()
        for ($m = 0; $m -lt $count; $m++) {
            $base = $br.ReadUInt64()
            $size = $br.ReadUInt32()
            [void]$br.ReadUInt32()      # CheckSum
            [void]$br.ReadUInt32()      # TimeDateStamp
            $nameRva = $br.ReadUInt32()
            $fs.Position += 52 + 8 + 8 + 8 + 8   # VersionInfo + CvRecord + MiscRecord + Reserved
            $pos = $fs.Position
            $modName = Read-MiniString $nameRva
            $fs.Position = $pos
            $modules += [pscustomobject]@{
                Base = [uint64]$base
                Size = [uint64]$size
                Name = $modName
            }
        }
    }

    # ── 系统信息 ──
    $sysDir = $dirs | Where-Object { $_.Type -eq 7 } | Select-Object -First 1
    $osInfo = ''
    if ($sysDir) {
        $fs.Position = $sysDir.Rva
        $arch = $br.ReadUInt16(); $lvl = $br.ReadUInt16()
        $rev = $br.ReadUInt16(); $numProc = $br.ReadByte(); $prodType = $br.ReadByte()
        $major = $br.ReadUInt32(); $minor = $br.ReadUInt32(); $build = $br.ReadUInt32()
        $osInfo = "Windows $major.$minor.$build  (架构码 $arch, 处理器 $numProc)"
    }

    # ── 异常信息 ──
    $excDir = $dirs | Where-Object { $_.Type -eq 6 } | Select-Object -First 1
    $exc = $null
    if ($excDir) {
        $fs.Position = $excDir.Rva
        $tid = $br.ReadUInt32()
        [void]$br.ReadUInt32()
        $code = $br.ReadUInt32()
        $flags = $br.ReadUInt32()
        [void]$br.ReadUInt64()          # ExceptionRecord
        $addr = $br.ReadUInt64()
        $nParam = $br.ReadUInt32()
        [void]$br.ReadUInt32()
        $params = @()
        for ($p = 0; $p -lt [Math]::Min(15, $nParam); $p++) { $params += $br.ReadUInt64() }
        $exc = [pscustomobject]@{
            ThreadId  = $tid
            Code      = $code
            Flags     = $flags
            Address   = $addr
            NumParams = $nParam
            Params    = $params
        }
    }

    # ── 地址 -> 模块 ──
    function Find-Module([uint64]$a) {
        foreach ($m in $modules) {
            if ($a -ge $m.Base -and $a -lt ($m.Base + $m.Size)) { return $m }
        }
        return $null
    }

    # ── 输出 ──
    $f = Get-Item $DumpPath
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host "  $($f.Name)" -ForegroundColor White
    Write-Host "  $([math]::Round($f.Length / 1MB, 2)) MB   修改时间 $($f.LastWriteTime)" -ForegroundColor DarkGray
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host "  系统       : $osInfo"
    Write-Host "  进程时间戳 : $(([datetime]'1970-01-01').AddSeconds($tds).ToLocalTime())"
    Write-Host "  模块数量   : $($modules.Count)"

    if ($exc) {
        $mod = Find-Module $exc.Address
        $modName = if ($mod) { $mod.Name } else { '<未知模块>' }
        $offset = if ($mod) { $exc.Address - $mod.Base } else { 0 }

        Write-Host ''
        Write-Host '  ── 异常 ──' -ForegroundColor Yellow
        Write-Host ("  异常代码 : 0x{0:X8}" -f $exc.Code) -ForegroundColor Red
        Write-Host ("  异常地址 : 0x{0:X}" -f $exc.Address)
        Write-Host ("  所属模块 : {0}  +0x{1:X}" -f $modName, $offset) -ForegroundColor Green
        Write-Host "  线程 ID  : $($exc.ThreadId)"
        if ($exc.NumParams -gt 0) {
            $ps = ($exc.Params | ForEach-Object { "0x$('{0:X}' -f $_)" }) -join ', '
            Write-Host "  异常参数 : $ps"
        }

        # 常见代码翻译
        $known = @{
            0x887A0006 = 'DXGI_ERROR_DEVICE_HUNG  (GPU 设备挂死)'
            0x887A0005 = 'DXGI_ERROR_DEVICE_REMOVED  (GPU 设备被移除)'
            0x887A0007 = 'DXGI_ERROR_DEVICE_RESET  (GPU 设备重置)'
            0xC0000005 = 'ACCESS_VIOLATION  (访问违例)'
            0xC0000409 = 'STACK_BUFFER_OVERRUN'
            0xC00000FD = 'STACK_OVERFLOW'
            0x80000003 = 'BREAKPOINT'
            0xE06D7363 = 'C++ 异常'
        }
        if ($known.ContainsKey([long]$exc.Code)) {
            Write-Host "  含义     : $($known[[long]$exc.Code])" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host '  (没有异常流)' -ForegroundColor DarkGray
    }

    # ── 关键组件检查 ──
    $keys = @('nvngx_dlss', 'nvngx_dlssg', 'nvngx_dlssd', 'nvngx', 'd3d12', 'dxgi',
              'nvlddmkm', 'nvd3dum', 'nvwgf2umx', 'amd_fidelityfx', 'xess', 'ffx')
    Write-Host ''
    Write-Host '  ── 加载的关键组件 ──' -ForegroundColor Yellow
    $hit = $false
    foreach ($k in $keys) {
        $found = $modules | Where-Object { $_.Name -like "*$k*" }
        foreach ($mm in $found) {
            Write-Host "    $($mm.Name)" -ForegroundColor Gray
            $hit = $true
        }
    }
    if (-not $hit) { Write-Host '    (未匹配到)' -ForegroundColor DarkGray }

    if ($ShowModules) {
        Write-Host ''
        Write-Host '  ── 全部模块 ──' -ForegroundColor Yellow
        $modules | Sort-Object Base | ForEach-Object {
            Write-Host ("    {0:X16}  {1,10:N0}  {2}" -f $_.Base, $_.Size, $_.Name) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
}
finally {
    $br.Close()
    $fs.Close()
}
