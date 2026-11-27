// BF6 监控器 —— 曲线绘制核心（编译成 .NET 类型，避免 PowerShell 逐点解释的开销）
// 由 BF6Monitor.ps1 通过 Add-Type 加载
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;

public static class ChartRenderer
{
    /// <summary>Minimum Y span for the primary/secondary series so small noise is not magnified.</summary>
    public static double MinSpanA = 10.0;
    public static double MinSpanB = 10.0;

    public static int LastPointCount = 0;

    /// <summary>
    /// 通用双曲线渲染：主曲线 colorA（按 unitA 刻度）+ 副曲线 colorB（按 unitB 刻度）
    /// 左上角画彩色图例，右上角画缓存/跨度信息
    /// </summary>
    public static void Render(Bitmap bmp, double[] a, double[] b, int count,
                              Color card, Color grid, Color colorA, Color colorB, Color dim,
                              string info, string labelA, string labelB, string unitA, string unitB,
                              int hover = -1)
    {
        using (Graphics g = Graphics.FromImage(bmp))
        using (Pen penGrid = new Pen(grid, 1f))
        using (SolidBrush brushDim = new SolidBrush(dim))
        using (SolidBrush brushA = new SolidBrush(colorA))
        using (SolidBrush brushB = new SolidBrush(colorB))
        using (Font font = new Font("Microsoft YaHei", 9f))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            g.Clear(card);

            int w = bmp.Width, h = bmp.Height;

            // 网格
            for (int i = 1; i < 4; i++)
            {
                int y = h * i / 4;
                g.DrawLine(penGrid, 0, y, w, y);
            }

            // 图例（左上）
            float lx = 8f;
            g.FillRectangle(brushA, lx, 9f, 9f, 9f);
            g.DrawString(labelA, font, brushA, lx + 13f, 5f);
            lx += 13f + g.MeasureString(labelA, font).Width + 14f;
            g.FillRectangle(brushB, lx, 9f, 9f, 9f);
            g.DrawString(labelB, font, brushB, lx + 13f, 5f);

            // 信息（右上）
            if (!string.IsNullOrEmpty(info))
            {
                SizeF sz = g.MeasureString(info, font);
                g.DrawString(info, font, brushDim, w - sz.Width - 8f, 5f);
            }

            if (count < 2)
            {
                g.DrawString("等待数据...", font, brushDim, 8f, h / 2f - 8f);
                LastPointCount = 0;
                return;
            }

            int SoftLimit = 2000;
            List<int> idx = new List<int>();
            if (count <= SoftLimit)
            {
                for (int i = 0; i < count; i++) idx.Add(i);
            }
            else
            {
                int bucket = (int)Math.Ceiling(count / (double)(SoftLimit / 2));
                if (bucket < 2) bucket = 2;
                for (int s = 0; s < count; s += bucket)
                {
                    int e = Math.Min(count - 1, s + bucket - 1);
                    int iMin = s, iMax = s;
                    for (int i = s; i <= e; i++)
                    {
                        if (a[i] < a[iMin]) iMin = i;
                        if (a[i] > a[iMax]) iMax = i;
                    }
                    if (iMin == iMax) { idx.Add(iMin); }
                    else if (iMin < iMax) { idx.Add(iMin); idx.Add(iMax); }
                    else { idx.Add(iMax); idx.Add(iMin); }
                }
                if (idx.Count == 0 || idx[idx.Count - 1] != count - 1) idx.Add(count - 1);
            }
            int n = idx.Count;
            LastPointCount = n;

            double maxA = double.MinValue, minA = double.MaxValue;
            double maxB = double.MinValue, minB = double.MaxValue;
            for (int k = 0; k < n; k++)
            {
                double va = a[idx[k]];
                double vb = b[idx[k]];
                if (va > maxA) maxA = va;
                if (va < minA) minA = va;
                if (vb > maxB) maxB = vb;
                if (vb < minB) minB = vb;
            }

            // 主曲线刻度（最小跨度保护：1°C 的抖动不该被放大成满屏锯齿）
            double spanA = maxA - minA;
            if (spanA < 1e-6) { maxA = minA + 1; spanA = 1; }
            double minSpanA = MinSpanA > 0 ? MinSpanA : 10.0;
            if (spanA < minSpanA)
            {
                double mid = (maxA + minA) / 2;
                maxA = mid + minSpanA / 2;
                minA = mid - minSpanA / 2;
                spanA = minSpanA;
            }
            double padA = spanA * 0.15;
            double loA = minA - padA, hiA = maxA + padA;

            // 副曲线刻度
            double spanB = maxB - minB;
            if (spanB < 1e-6) { maxB = minB + 1; spanB = 1; }
            double minSpanB = MinSpanB > 0 ? MinSpanB : 10.0;
            if (spanB < minSpanB)
            {
                double midB = (maxB + minB) / 2;
                maxB = midB + minSpanB / 2;
                minB = midB - minSpanB / 2;
                spanB = minSpanB;
            }
            double padB = spanB * 0.15;
            double loB = Math.Max(0, minB - padB), hiB = maxB + padB;
            if (hiB - loB < 1e-6) hiB = loB + 1;

            PointF[] ptsA = new PointF[n];
            PointF[] ptsB = new PointF[n];
            double spanX = (count - 1);
            for (int k = 0; k < n; k++)
            {
                int i = idx[k];
                float x = 6f + (float)((w - 12) * (i / spanX));
                double yA = h - 14 - ((a[i] - loA) / (hiA - loA)) * (h - 42);
                double yB = h - 14 - ((b[i] - loB) / (hiB - loB)) * (h - 42);
                ptsA[k] = new PointF(x, (float)yA);
                ptsB[k] = new PointF(x, (float)yB);
            }

            using (Pen penB = new Pen(Color.FromArgb(140, colorB), 1.3f))
            using (Pen penA = new Pen(colorA, 1.8f))
            {
                if (n >= 2)
                {
                    g.DrawLines(penB, ptsB);
                    g.DrawLines(penA, ptsA);
                }
            }

            // 悬停十字线
            if (hover >= 0 && hover < count)
            {
                float hx = 6f + (float)((w - 12) * (hover / (double)(count - 1)));
                using (Pen penH = new Pen(Color.FromArgb(235, 245, 245, 250), 1f))
                {
                    // 红色实线，直接贯穿图表，方便对准鼠标
                    g.DrawLine(penH, hx, 0, hx, h);
                }
                double yA = h - 14 - ((a[hover] - loA) / (hiA - loA)) * (h - 42);
                double yB = h - 14 - ((b[hover] - loB) / (hiB - loB)) * (h - 42);
                using (SolidBrush dotA = new SolidBrush(colorA))
                using (SolidBrush dotB = new SolidBrush(colorB))
                {
                    g.FillEllipse(dotA, hx - 3.5f, (float)yA - 3.5f, 7f, 7f);
                    g.FillEllipse(dotB, hx - 3f, (float)yB - 3f, 6f, 6f);
                }
            }

            // 最高/最低不再画在图内，改由界面文本行展示
        }
    }
}
