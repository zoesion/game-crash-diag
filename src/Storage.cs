using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

// One telemetry sample, shared by the UI, the CSV writer and the history store.
public struct Sample
{
    public DateTime Time;
    public double GpuTemp;
    public double GpuPower;
    public int ClockSm;
    public int ClockMem;
    public int UtilGpu;
    public int UtilMem;
    public double MemUsedMb;
    public double MemTotalMb;
    public string PState;
    public ulong Throttle;
    public double CpuTemp;
    public int CpuMhz;
    public int CpuLoad;
    public int ActiveCores;
    public int TotalCores;
    public double RamPct;
}

public sealed class Storage
{
    private readonly string _root;
    public string LogFile = "";

    public Storage(string root) { _root = root; }

    public string LogDir { get { return Path.Combine(_root, "logs"); } }

    public string HistoryDir { get { return Path.Combine(_root, "data", "history"); } }

    // ── CSV logs ────────────────────────────────────────────────
    public string StartLog(string category, int intervalMs)
    {
        string dir = Path.Combine(LogDir, category);
        Directory.CreateDirectory(dir);
        LogFile = Path.Combine(dir, category + "-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".csv");
        string header = "时间,GPU温度(°C),GPU功耗(W),GPU核心频率(MHz),GPU显存频率(MHz),GPU占用(%),显存占用(%),显存已用(MB)," +
                        "电源状态,降频原因码,功耗墙,硬件降频,温度墙,降频说明,CPU温度(°C),CPU频率(MHz),CPU占用(%),活跃核心数,总核心数,内存占用(%)";
        File.WriteAllText(LogFile, header + Environment.NewLine, new UTF8Encoding(true));
        return LogFile;
    }

    public string AppendCsv(Sample s)
    {
        if (string.IsNullOrEmpty(LogFile)) return "";
        // 真实位：0x2 AppClocks, 0x4 SwPowerCap, 0x8 HwSlowdown, 0x20 SwThermal, 0x40 HwThermal, 0x80 HwPowerBrake
        bool powerCap = (s.Throttle & 0x4UL) != 0;
        bool hwSlow = (s.Throttle & 0x8UL) != 0 || (s.Throttle & 0x80UL) != 0;
        bool thermal = (s.Throttle & 0x20UL) != 0 || (s.Throttle & 0x40UL) != 0;
        string text = thermal ? "温度墙" : (powerCap ? "功耗墙" : (hwSlow ? "硬件降频" : "正常"));
        string line = string.Format(CultureInfo.InvariantCulture,
            "{0},{1:0.00},{2:0.00},{3},{4},{5},{6},{7},{8},0x{9:X16},{10},{11},{12},{13},{14:0.0},{15},{16},{17},{18},{19}",
            s.Time.ToString("HH:mm:ss"), s.GpuTemp, s.GpuPower, s.ClockSm, s.ClockMem, s.UtilGpu, s.UtilMem,
            (long)s.MemUsedMb, s.PState, s.Throttle,
            powerCap ? 1 : 0, hwSlow ? 1 : 0, thermal ? 1 : 0, text,
            s.CpuTemp, s.CpuMhz, s.CpuLoad, s.ActiveCores, s.TotalCores, (int)s.RamPct);
        try { File.AppendAllText(LogFile, line + Environment.NewLine, new UTF8Encoding(true)); } catch { }
        return line;
    }

    // ── history store (survives restarts) ───────────────────────
    private string HistoryFile { get { return Path.Combine(HistoryDir, "samples.csv"); } }
    private string MarkerFile { get { return Path.Combine(HistoryDir, "markers.csv"); } }

    private int _historyWrites;

    /// <summary>Keeps the store bounded: when it passes 8 MB, keep only the last 24 hours.</summary>
    private void CompactHistory()
    {
        try
        {
            if (!File.Exists(HistoryFile)) return;
            if (new FileInfo(HistoryFile).Length < 8L * 1024 * 1024) return;
            DateTime cut = DateTime.Now.AddHours(-24);
            var keep = new List<string>();
            using (var fs = new FileStream(HistoryFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (var sr = new StreamReader(fs, Encoding.UTF8))
            {
                string line;
                while ((line = sr.ReadLine()) != null)
                {
                    string[] p = line.Split('|');
                    if (p.Length < 2) continue;
                    DateTime t;
                    if (!DateTime.TryParseExact(p[0], "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture,
                                                DateTimeStyles.None, out t)) continue;
                    if (t >= cut) keep.Add(line);
                }
            }
            File.WriteAllLines(HistoryFile, keep.ToArray(), new UTF8Encoding(false));
        }
        catch { }
    }

    public void AppendHistory(Sample s)
    {
        try
        {
            Directory.CreateDirectory(HistoryDir);
            string line = string.Format(CultureInfo.InvariantCulture,
                "{0:yyyy-MM-dd HH:mm:ss}|{1:0.0}|{2:0.0}|{3}|{4}|{5}|{6}|{7:0.0}|{8}|{9}|{10}|{11}|{12}",
                s.Time, s.GpuTemp, s.GpuPower, s.ClockSm, s.UtilGpu, (long)s.MemUsedMb,
                s.CpuTemp, s.CpuMhz, s.CpuLoad, s.ActiveCores, s.TotalCores, (int)s.RamPct, s.ClockMem);
            File.AppendAllText(HistoryFile, line + Environment.NewLine, new UTF8Encoding(false));
            _historyWrites++;
            if (_historyWrites % 7200 == 0) CompactHistory();   // 1 小时检查一次
        }
        catch { }
    }

    /// <summary>Loads up to maxPoints recent samples (newest last). Returns 0 when nothing usable.</summary>
    public int LoadHistory(double hours, int maxPoints,
                           List<DateTime> times, List<double> gpuTemp, List<double> gpuPower,
                           List<double> cpuTemp, List<double> cpuFreq)
    {
        try
        {
            if (!File.Exists(HistoryFile)) return 0;
            var rows = new List<string[]>();
            DateTime cut = DateTime.Now.AddHours(-hours);
            using (var fs = new FileStream(HistoryFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (var sr = new StreamReader(fs, Encoding.UTF8))
            {
                string line;
                while ((line = sr.ReadLine()) != null)
                {
                    string[] p = line.Split('|');
                    if (p.Length < 12) continue;
                    DateTime t;
                    if (!DateTime.TryParseExact(p[0], "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture,
                                                DateTimeStyles.None, out t)) continue;
                    if (t < cut) continue;
                    rows.Add(p);
                }
            }
            if (rows.Count == 0) return 0;
            int skip = Math.Max(0, rows.Count - maxPoints);
            for (int i = skip; i < rows.Count; i++)
            {
                string[] p = rows[i];
                DateTime t;
                if (!DateTime.TryParseExact(p[0], "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture,
                                            DateTimeStyles.None, out t)) continue;
                times.Add(t);
                gpuTemp.Add(ParseD(p[1]));
                gpuPower.Add(ParseD(p[2]));
                cpuTemp.Add(ParseD(p[6]));
                cpuFreq.Add(ParseD(p[7]));
            }
            return rows.Count - skip;
        }
        catch { return 0; }
    }

    private static double ParseD(string s)
    {
        double v;
        return double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out v) ? v : 0.0;
    }

    // ── markers ─────────────────────────────────────────────────
    public void SaveMarkers(IEnumerable<Marker> markers)
    {
        try
        {
            Directory.CreateDirectory(HistoryDir);
            var sb = new StringBuilder();
            foreach (var m in markers) sb.AppendLine(m.Time.ToString("o") + "|" + m.Kind + "|" + (m.Note ?? ""));
            File.WriteAllText(MarkerFile, sb.ToString(), new UTF8Encoding(false));
        }
        catch { }
    }

    public List<Marker> LoadMarkers()
    {
        var list = new List<Marker>();
        try
        {
            if (!File.Exists(MarkerFile)) return list;
            DateTime cut = DateTime.Now.AddHours(-24);
            foreach (string line in File.ReadAllLines(MarkerFile))
            {
                string[] p = line.Split('|');
                if (p.Length < 2) continue;
                DateTime t;
                if (!DateTime.TryParse(p[0], CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out t)) continue;
                if (t < cut) continue;
                list.Add(new Marker { Time = t, Kind = p[1], Note = p.Length > 2 ? p[2] : "" });
            }
        }
        catch { }
        return list;
    }
}

public struct Marker
{
    public DateTime Time;
    public string Kind;   // crash | down | gap
    public string Note;   // 可选：显示在曲线上的文字（如"隔 2.3 小时"）
}
