using System;
using System.Collections.Generic;
using System.Diagnostics.Eventing.Reader;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

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

    /// <summary>True when Windows logged an unexpected shutdown (41), a bugcheck (1001) or an
    /// unexpected power loss (6008) whose timestamp really matches the moment the app last
    /// sampled - a stale 6008 from an earlier crash must not label later normal restarts.</summary>
    public static bool DetectUncleanShutdown(DateTime around)
    {
        try
        {
            var q = new EventLogQuery("System", PathType.LogName,
                "*[System[(EventID=41 or EventID=1001 or EventID=6008) and TimeCreated[@SystemTime>='" +
                XmlTime(around.AddMinutes(-30)) + "']]]");
            using (var reader = new EventLogReader(q))
            {
                EventRecord rec;
                while ((rec = reader.ReadEvent()) != null)
                {
                    using (rec)
                    {
                        DateTime when = ShutdownTimeOf(rec);
                        LogDetail("event " + rec.Id + " at " + rec.TimeCreated + " -> shutdown " + when.ToString("HH:mm:ss"));
                        if (Math.Abs((when - around).TotalMinutes) <= 2) return true;   // 只认"断点前后 2 分钟内"的死机
                    }
                }
            }
        }
        catch { }
        return false;
    }

    /// <summary>Best guess of when the machine actually died: the 6008 event carries it as data.</summary>
    private static DateTime ShutdownTimeOf(EventRecord rec)
    {
        // Event 6008 stores "23:32:15" and "2026/11/27" as separate data fields (with bidi marks)
        try
        {
            if (rec.Id == 6008)
            {
                var doc = new System.Xml.XmlDocument();
                doc.LoadXml(rec.ToXml());
                var nodes = doc.GetElementsByTagName("Data");
                if (nodes.Count >= 2)
                {
                    string time = CleanDigits(nodes[0].InnerText);
                    string date = CleanDigits(nodes[1].InnerText);
                    Match mt = Regex.Match(time, @"(\d{1,2}):(\d{2}):(\d{2})");
                    Match md = Regex.Match(date, @"(\d{4})/(\d{1,2})/(\d{1,2})");
                    if (mt.Success && md.Success)
                        return new DateTime(int.Parse(md.Groups[1].Value), int.Parse(md.Groups[2].Value),
                                            int.Parse(md.Groups[3].Value), int.Parse(mt.Groups[1].Value),
                                            int.Parse(mt.Groups[2].Value), int.Parse(mt.Groups[3].Value));
                }
            }
        }
        catch { }

        string msg = "";
        try { msg = rec.FormatDescription() ?? ""; } catch { }
        Match m = Regex.Match(msg, @"(\d{1,2}):(\d{2}):(\d{2})\s+on\s+[^\d]*(\d{4})/(\d{1,2})/(\d{1,2})");
        if (m.Success)
        {
            try
            {
                return new DateTime(int.Parse(m.Groups[4].Value), int.Parse(m.Groups[5].Value),
                                    int.Parse(m.Groups[6].Value), int.Parse(m.Groups[1].Value),
                                    int.Parse(m.Groups[2].Value), int.Parse(m.Groups[3].Value));
            }
            catch { }
        }
        // 41 / 1001 are written at boot; fall back to the event time
        return rec.TimeCreated.HasValue ? rec.TimeCreated.Value : DateTime.MinValue;
    }

    private static string CleanDigits(string s)
    {
        var sb = new StringBuilder();
        foreach (char c in s)
            if (char.IsDigit(c) || c == ':' || c == '/') sb.Append(c);
        return sb.ToString();
    }

    public static string LastDetectionLog = "";
    private static void LogDetail(string s) { LastDetectionLog += s + "\r\n"; }

    /// <summary>Gathers recent event-log text so error codes can be explained in the report.</summary>
    public static string CollectEventText(DateTime since, int max = 6)
    {
        var sb = new StringBuilder();
        int taken = 0;
        try
        {
            var q = new EventLogQuery("Application", PathType.LogName,
                "*[System[(EventID=1000 or EventID=1001) and TimeCreated[@SystemTime>='" + XmlTime(since) + "']]]");
            using (var reader = new EventLogReader(q))
            {
                EventRecord rec;
                while (taken < max && (rec = reader.ReadEvent()) != null)
                {
                    using (rec)
                    {
                        string msg = "";
                        try { msg = rec.FormatDescription() ?? ""; } catch { }
                        if (msg.Length > 600) msg = msg.Substring(0, 600);
                        sb.AppendLine(msg);
                        taken++;
                    }
                }
            }
        }
        catch { }
        try
        {
            var q2 = new EventLogQuery("System", PathType.LogName,
                "*[System[(Provider[@Name='nvlddmkm']) and TimeCreated[@SystemTime>='" + XmlTime(since) + "']]]");
            using (var reader2 = new EventLogReader(q2))
            {
                EventRecord rec;
                while (taken < max && (rec = reader2.ReadEvent()) != null)
                {
                    using (rec)
                    {
                        string msg = "";
                        try { msg = rec.FormatDescription() ?? ""; } catch { }
                        if (msg.Length > 400) msg = msg.Substring(0, 400);
                        sb.AppendLine(msg);
                        taken++;
                    }
                }
            }
        }
        catch { }
        return sb.ToString();
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
        public string EventText = "";
        public double IdleGpuTemp, IdleCpuTemp, GameGpuAvg, GameGpuMax, GameCpuAvg;
        public SessionStats Stats;
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
        if (input.IsCrash)
        {
        sb.AppendLine("  --- 最后 40 条遥测 ---");
        int from = Math.Max(0, input.TailRows.Count - 40);
        for (int i = from; i < input.TailRows.Count; i++) sb.AppendLine("  " + input.TailRows[i]);
        sb.AppendLine();

        // simple signal summary so the report is readable on its own
        }

        sb.AppendLine("  --- 数据摘要 ---");
        sb.AppendLine(Summary(input.TailRows));
        sb.AppendLine();
        // 错误码解读：从事件日志 + 遥测尾部里找已知代码
        string evidence = (input.EventText ?? "") + string.Join("\n", input.TailRows.ToArray());
        // 温度基线：空闲 vs 游戏内
        if (input.IdleGpuTemp > 0 && input.GameGpuAvg > 0)
        {
            sb.AppendLine("  --- 温度基线（空闲 vs 游戏内）---");
            sb.AppendLine(string.Format("  GPU : 空闲 {0:0.0}°C  →  游戏平均 {1:0.0}°C  最高 {2:0.0}°C   升幅 {3:+0.0;-0.0}°C",
                input.IdleGpuTemp, input.GameGpuAvg, input.GameGpuMax, input.GameGpuAvg - input.IdleGpuTemp));
            if (input.IdleCpuTemp > 0 && input.GameCpuAvg > 0)
                sb.AppendLine(string.Format("  CPU : 空闲 {0:0.0}°C  →  游戏平均 {1:0.0}°C   升幅 {2:+0.0;-0.0}°C",
                    input.IdleCpuTemp, input.GameCpuAvg, input.GameCpuAvg - input.IdleCpuTemp));
            double rise = input.GameGpuAvg - input.IdleGpuTemp;
            if (rise > 45) sb.AppendLine("  升幅超过 45°C，散热余量偏紧，建议检查风扇曲线和硅脂");
            else if (rise < 20) sb.AppendLine("  升幅较小，散热状态良好");
            sb.AppendLine();
        }

        // 会话统计 + 注意事项：正常对局也有
        if (input.Stats != null)
        {
            TimeSpan dur = input.ExitTime - input.StartTime;
            sb.AppendLine("  --- 会话统计 ---");
            sb.AppendLine("  " + input.Stats.How() + "，时长 " + Math.Round(dur.TotalMinutes, 1) + " 分钟");
            sb.Append(input.Stats.Summary());
            sb.AppendLine();

            sb.AppendLine("  --- 注意事项 ---");
            foreach (string o in input.Stats.Observations(dur)) sb.AppendLine("  · " + o);
            sb.AppendLine();
        }

        sb.AppendLine("  --- 错误码解读 ---");
        sb.Append(ErrorCodes.Explain(evidence));
        sb.AppendLine();

        sb.AppendLine("  --- 建议 ---");
        if (!input.IsCrash && input.Stats != null)
        {
            var extra = input.Stats.Advice();
            if (extra.Count == 0) sb.AppendLine("  1. 本次没有发现异常，保持现在的设置即可");
            else { int n = 1; foreach (string a in extra) sb.AppendLine("  " + (n++) + ". " + a); }
            sb.AppendLine();
        }
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
