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
    <#
      自动修复 DirectX：
        · 缺 DX9/10/11 扩展库 → 下载微软官方 DirectX 运行库并静默安装
        · 缺核心 DLL（d3d12/d3d11/dxgi 等）→ 用 DISM 修复系统映像
    #>
    $dx = Get-DxStatus
    if ($dx.Missing.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "DirectX 组件齐全，不需要修复。`n`n如果要强制校验系统文件，可以运行：`n  DISM /Online /Cleanup-Image /RestoreHealth",
            'DirectX 检查', 'OK', 'Information') | Out-Null
        return
    }

    $list = ($dx.Missing | ForEach-Object { "  · $($_.Name)（$($_.File)）" }) -join "`n"
    $msg = "检测到 DirectX 缺少以下组件：`n`n$list`n`n是否自动修复？`n`n"
    if ($dx.MissingLegacy.Count -gt 0) {
        $msg += "将下载微软官方 DirectX 运行库（约 300KB）并安装，需要管理员权限。`n"
    }
    if ($dx.MissingCore.Count -gt 0) {
        $msg += "缺少系统核心组件，将尝试用 DISM 修复（耗时较长，需要管理员权限）。`n"
    }

    $ans = [System.Windows.Forms.MessageBox]::Show($msg, '自动修复 DirectX', 'YesNo', 'Question')
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

