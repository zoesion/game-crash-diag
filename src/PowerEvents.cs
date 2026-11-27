using System;
using System.Collections.Generic;
using System.Diagnostics.Eventing.Reader;
using System.Text;

// Collects the power / embedded-controller events that explain "the machine just went to sleep"
// reports: ACPI EC timeouts, critical-battery triggers and sleep transitions.
public sealed class PowerEvents
{
    public int EcTimeouts;
    public int AcpiOther;
    public int CriticalBattery;
    public int LowBattery;
    public int SleepCount;
    public int UnexpectedShutdown;
    public int GpuFaults;                 // nvlddmkm id 13/153: GPU 报错次数
    public DateTime LastGpuFault = DateTime.MinValue;
    public string LastGpuFaultText = "";
    public DateTime LastEc = DateTime.MinValue;
    public DateTime LastBattery = DateTime.MinValue;
    public string LastEcDetail = "";

    public bool HasProblem
    {
        get { return EcTimeouts >= 2 || CriticalBattery >= 1 || UnexpectedShutdown >= 1 || GpuFaults >= 50; }
    }

    public static PowerEvents Collect(DateTime since)
    {
        var r = new PowerEvents();
        try
        {
            string from = since.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ");
            var q = new EventLogQuery("System", PathType.LogName,
                "*[System[TimeCreated[@SystemTime>='" + from + "']]]");
            using (var reader = new EventLogReader(q))
            {
                EventRecord rec;
                int guard = 0;
                while ((rec = reader.ReadEvent()) != null && guard++ < 4000)
                {
                    using (rec)
                    {
                        string provider = rec.ProviderName ?? "";
                        int id = rec.Id;
                        DateTime when = rec.TimeCreated.HasValue ? rec.TimeCreated.Value : DateTime.MinValue;

                        if (provider == "ACPI")
                        {
                            if (id == 13)
                            {
                                r.EcTimeouts++;
                                if (when > r.LastEc)
                                {
                                    r.LastEc = when;
                                    try
                                    {
                                        string msg = rec.FormatDescription() ?? "";
                                        r.LastEcDetail = msg.Length > 160 ? msg.Substring(0, 160) : msg;
                                    }
                                    catch { }
                                }
                            }
                            else r.AcpiOther++;
                            continue;
                        }

                        if (provider.IndexOf("nvlddmkm", StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            if (id == 13 || id == 153 || id == 14 || id == 106)
                            {
                                r.GpuFaults++;
                                if (when > r.LastGpuFault)
                                {
                                    r.LastGpuFault = when;
                                    try
                                    {
                                        string msg = rec.FormatDescription() ?? "";
                                        r.LastGpuFaultText = msg.Length > 140 ? msg.Substring(0, 140) : msg;
                                    }
                                    catch { }
                                }
                            }
                            continue;
                        }

                        if (provider.IndexOf("Kernel-Power", StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            if (id == 524) { r.CriticalBattery++; if (when > r.LastBattery) r.LastBattery = when; }
                            else if (id == 525) { r.LowBattery++; if (when > r.LastBattery) r.LastBattery = when; }
                            else if (id == 42 || id == 107) r.SleepCount++;
                            else if (id == 41) r.UnexpectedShutdown++;
                        }
                    }
                }
            }
        }
        catch { }
        return r;
    }

    public string Summary()
    {
        var sb = new StringBuilder();
        sb.AppendLine(string.Format("  EC 通信超时 : {0} 次{1}", EcTimeouts,
            LastEc != DateTime.MinValue ? "（最近 " + LastEc.ToString("HH:mm:ss") + "）" : ""));
        sb.AppendLine(string.Format("  临界电量误报: {0} 次{1}", CriticalBattery,
            LastBattery != DateTime.MinValue ? "（最近 " + LastBattery.ToString("HH:mm:ss") + "）" : ""));
        if (LowBattery > 0) sb.AppendLine(string.Format("  低电量事件  : {0} 次", LowBattery));
        if (SleepCount > 0) sb.AppendLine(string.Format("  睡眠/唤醒   : {0} 次", SleepCount));
        if (UnexpectedShutdown > 0) sb.AppendLine(string.Format("  非正常关机  : {0} 次", UnexpectedShutdown));
        if (GpuFaults > 0) sb.AppendLine(string.Format("  显卡报错    : {0} 次（最近 {1}）", GpuFaults, LastGpuFault.ToString("HH:mm:ss")));
        if (!string.IsNullOrEmpty(LastGpuFaultText)) sb.AppendLine("    最近一条: " + LastGpuFaultText);
        if (AcpiOther > 0) sb.AppendLine(string.Format("  其他 ACPI   : {0} 次", AcpiOther));
        return sb.ToString();
    }

    /// <summary>Short human sentence used for the in-window banner.</summary>
    public string WarnText()
    {
        var parts = new List<string>();
        if (EcTimeouts > 0) parts.Add("EC 通信超时 " + EcTimeouts + " 次");
        if (CriticalBattery > 0) parts.Add("临界电量误报 " + CriticalBattery + " 次");
        if (UnexpectedShutdown > 0) parts.Add("非正常关机 " + UnexpectedShutdown + " 次");
        if (GpuFaults >= 50) parts.Add("显卡驱动报错 " + GpuFaults + " 次（可能是 GPU 不稳定）");
        if (parts.Count == 0) return "";
        return string.Join("，", parts.ToArray()) + "（建议做 EC 复位：关机拔电源，长按电源键 30 秒）";
    }
}
