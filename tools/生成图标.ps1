Add-Type -AssemblyName System.Drawing

# ── 生成游戏崩溃诊断器图标：深色圆角方块 + 青色心律线 ──
$outIco = 'D:\AI_Work\game-crash-diag\app.ico'
$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs = @()

function New-RoundRect($x, $y, $w, $h, $r) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $path.AddArc($x, $y, $d, $d, 180, 90)
    $path.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $path.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $path.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

foreach ($size in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)

    $s = $size / 256.0
    $pad = [int](14 * $s)
    $w = $size - $pad * 2
    $radius = [int](46 * $s)

    # 底板渐变（深蓝灰）
    $rect = New-Object System.Drawing.Rectangle($pad, $pad, $w, $w)
    $path = New-RoundRect $pad $pad $w $w $radius
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect,
        [System.Drawing.Color]::FromArgb(255, 30, 37, 52),
        [System.Drawing.Color]::FromArgb(255, 16, 20, 30),
        45.0)
    $g.FillPath($brush, $path)

    # 青色描边
    $penB = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(210, 78, 201, 176), [float]([math]::Max(1, 3 * $s)))
    $g.DrawPath($penB, $path)

    # 心律线（青绿）
    $penL = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 78, 201, 176), [float]([math]::Max(1.2, 11 * $s)))
    $penL.StartCap = 'Round'
    $penL.EndCap = 'Round'
    $penL.LineJoin = 'Round'

    $pts = @(
        (New-Object System.Drawing.PointF(($pad + $w * 0.10), ($pad + $w * 0.52))),
        (New-Object System.Drawing.PointF(($pad + $w * 0.28), ($pad + $w * 0.52))),
        (New-Object System.Drawing.PointF(($pad + $w * 0.40), ($pad + $w * 0.30))),
        (New-Object System.Drawing.PointF(($pad + $w * 0.52), ($pad + $w * 0.76))),
        (New-Object System.Drawing.PointF(($pad + $w * 0.64), ($pad + $w * 0.44))),
        (New-Object System.Drawing.PointF(($pad + $w * 0.76), ($pad + $w * 0.52))),
        (New-Object System.Drawing.PointF(($pad + $w * 0.90), ($pad + $w * 0.52)))
    )
    $g.DrawLines($penL, [System.Drawing.PointF[]]$pts)

    # 右下角小蓝点（表示"诊断"）
    $dotR = [float]([math]::Max(1.2, 9 * $s))
    $dotBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 90, 155, 220))
    $g.FillEllipse($dotBrush, ($pad + $w * 0.80 - $dotR), ($pad + $w * 0.72 - $dotR), ($dotR * 2), ($dotR * 2))

    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngs += , ($ms.ToArray())
    $bmp.Dispose()
    $ms.Dispose()
}

# ── 组装 ICO（PNG 载荷）──
$fs = [System.IO.File]::Create($outIco)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([UInt16]0)                 # reserved
$bw.Write([UInt16]1)                 # type = icon
$bw.Write([UInt16]$sizes.Count)

$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $sz = $sizes[$i]
    $bw.Write([Byte]$(if ($sz -ge 256) { 0 } else { $sz }))
    $bw.Write([Byte]$(if ($sz -ge 256) { 0 } else { $sz }))
    $bw.Write([Byte]0)               # color count
    $bw.Write([Byte]0)               # reserved
    $bw.Write([UInt16]1)             # planes
    $bw.Write([UInt16]32)            # bpp
    $bw.Write([UInt32]$pngs[$i].Length)
    $bw.Write([UInt32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($data in $pngs) { $bw.Write($data) }
$bw.Flush()
$bw.Close()
$fs.Close()

# 顺手导出 256 预览
[System.IO.File]::WriteAllBytes((Join-Path (Split-Path $outIco) '_icon_preview.png'), $pngs[$pngs.Count - 1])

Write-Host ("图标已生成: {0}  ({1:N1} KB, {2} 个尺寸)" -f $outIco, ((Get-Item $outIco).Length / 1KB), $sizes.Count) -ForegroundColor Green
