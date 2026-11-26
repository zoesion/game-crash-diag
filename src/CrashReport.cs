using System;
using System.Collections.Generic;
using System.Diagnostics.Eventing.Reader;
using System.Globalization;
using System.IO;
using System.Text;

// Verdict + report generation, ported from the PowerShell build.
public static class CrashReport
{
    public sealed class Verdict
    {
        public bool IsCrash;
        public string Reason = "无崩溃特征";
    }

    /// <summary>Three signals: fresh crash dump, Application error 1000 for this process, or a
    /// driver error (level 1-3) within 90 s of the exit.</summary>
    public static Verdict Test(DateTime exitTime, string procName)
    {
        DateTime since = exitTime.AddMinutes(-2);
        try
        {
            string docs = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
            string dumpDir = Path.Combine(docs, "Battlefield 6", "CrashDumps");
            if (Directory.Exists(dumpDir))
            {
                foreach (string f in Directory.GetFiles(dumpDir, "*.mdmp"))
                {
                    if (File.GetLastWriteTime(f) >= since)
                    {
                        return new Verdict { IsCrash = true, Reason = "产生崩溃转储 " + Path.GetFileName(f) };
                    }
                }
            }
        }
        catch { }

        string pattern = string.IsNullOrEmpty(procName) ? "bf6" : procName;
        try
        {
            var q = new EventLogQuery("Application", PathType.LogName,
                "*[System[(EventID=1000) and TimeCreated[@SystemTime>='" + XmlTime(since) + "']]]");
            using (var reader = new EventLogReader(q))
            {
                EventRecord rec;
                while ((rec = reader.ReadEvent()) != null)
                {
                    using (rec)
                    {
                        string msg = "";
                        try { msg = rec.FormatDescription() ?? ""; } catch { }
                        if (msg.IndexOf(pattern, StringComparison.OrdinalIgnoreCase) >= 0)
                            return new Verdict { IsCrash = true, Reason = "应用错误事件 1000" };
                    }
                }
            }
        }
        catch { }

        try
        {
            var q2 = new EventLogQuery("System", PathType.LogName,
                "*[System[(Provider[@Name='nvlddmkm']) and (Level<=3) and TimeCreated[@SystemTime>='" +
                XmlTime(exitTime.AddSeconds(-90)) + "']]]");
            using (var reader2 = new EventLogReader(q2))
            {
                EventRecord rec = reader2.ReadEvent();
                if (rec != null) { rec.Dispose(); return new Verdict { IsCrash = true, Reason = "nvlddmkm 驱动错误" }; }
            }
        }
        catch { }

        return new Verdict();
    }

    private static string XmlTime(DateTime t)
    {
        return t.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture);
    }

    public sealed class ReportInput
    {
        public bool IsCrash;
        public string Reason = "";
        public string GameName = "";
        public string Category = "";
        public DateTime StartTime = DateTime.Now;
        public DateTime ExitTime = DateTime.Now;
        public string TelemetryFile = "";
        public List<string> TailRows = new List<string>();
    }

    public static string Write(string root, ReportInput input)
    {
        string dir = Path.Combine(root, "reports");
        Directory.CreateDirectory(dir);
        string stamp = input.ExitTime.ToString("yyyyMMdd-HHmmss");
        string path = Path.Combine(dir, (input.IsCrash ? "crash-" : "session-") + stamp + ".txt");

        var sb = new StringBuilder();
        string title = input.IsCrash ? "崩溃报告" : "对局记录";
        sb.AppendLine("==================================================================");
        sb.AppendLine(string.Format("{0} {1}  {2}    [判定依据: {3}]",
            string.IsNullOrEmpty(input.GameName) ? "游戏" : input.GameName,
            title, input.ExitTime.ToString("yyyy-MM-dd HH:mm:ss"),
            string.IsNullOrEmpty(input.Reason) ? "正常退出" : input.Reason));
        sb.AppendLine("==================================================================");
        sb.AppendLine("  游戏开始 : " + input.StartTime.ToString("yyyy-MM-dd HH:mm:ss"));
        sb.AppendLine("  运行时长 : " + Math.Round((input.ExitTime - input.StartTime).TotalMinutes, 1) + " 分钟");
        sb.AppendLine("  记录条数 : " + input.TailRows.Count);
        sb.AppendLine("  遥测文件 : " + input.TelemetryFile);
        sb.AppendLine();
        sb.AppendLine("  --- 最后 40 条遥测 ---");
        int from = Math.Max(0, input.TailRows.Count - 40);
        for (int i = from; i < input.TailRows.Count; i++) sb.AppendLine("  " + input.TailRows[i]);
        sb.AppendLine();

        // simple signal summary so the report is readable on its own
        sb.AppendLine("  --- 数据摘要 ---");
        sb.AppendLine(Summary(input.TailRows));
        sb.AppendLine();
        sb.AppendLine("  --- 建议 ---");
        if (input.IsCrash)
        {
            sb.AppendLine("  1. 先看显卡驱动版本，回滚或升级到官方 WHQL 版本");
            sb.AppendLine("  2. 关掉超频（含显卡厂商标配的 OC 模式），再跑一局");
            sb.AppendLine("  3. 检查散热：GPU 是否撞温度墙、机箱进风是否被堵");
            sb.AppendLine("  4. 若报告里出现 0x887A0006 / 0x887A0005，多为驱动或显存不稳定");
        }
        else
        {
            sb.AppendLine("  本次为正常退出，无需处理。");
        }

        try { File.WriteAllText(path, sb.ToString(), new UTF8Encoding(true)); } catch { }
        return path;
    }

    private static string Summary(List<string> rows)
    {
        if (rows.Count == 0) return "  （无遥测数据）";
        double maxT = -1, minT = 999, maxP = -1, maxCpu = -1;
        foreach (string line in rows)
        {
            string[] p = line.Split(',');
            if (p.Length < 16) continue;
            double v;
            if (double.TryParse(p[1], NumberStyles.Float, CultureInfo.InvariantCulture, out v))
            {
                if (v > maxT) maxT = v;
                if (v < minT) minT = v;
            }
            if (double.TryParse(p[2], NumberStyles.Float, CultureInfo.InvariantCulture, out v) && v > maxP) maxP = v;
            if (double.TryParse(p[14], NumberStyles.Float, CultureInfo.InvariantCulture, out v) && v > maxCpu) maxCpu = v;
        }
        return string.Format(CultureInfo.InvariantCulture,
            "  GPU 温度 {0:0.0} ~ {1:0.0} °C   最高功耗 {2:0} W   CPU 最高 {3:0.0} °C",
            minT, maxT, maxP, maxCpu);
    }

    /// <summary>Saves the two charts into one PNG for the crash card.</summary>
    public static string SaveSnapshot(string root, System.Drawing.Bitmap gpuBmp, System.Drawing.Bitmap cpuBmp)
    {
        try
        {
            string dir = Path.Combine(root, "reports");
            Directory.CreateDirectory(dir);
            string path = Path.Combine(dir, "crash-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".png");
            int w = 900, h = 260;
            using (var bmp = new System.Drawing.Bitmap(w, h))
            using (var g = System.Drawing.Graphics.FromImage(bmp))
            {
                g.Clear(System.Drawing.Color.FromArgb(24, 24, 28));
                if (gpuBmp != null)
                    g.DrawImage(gpuBmp, new System.Drawing.Rectangle(0, 0, w, h / 2 - 4));
                if (cpuBmp != null)
                    g.DrawImage(cpuBmp, new System.Drawing.Rectangle(0, h / 2 + 4, w, h / 2 - 4));
                bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            }
            return path;
        }
        catch { return ""; }
    }
}
