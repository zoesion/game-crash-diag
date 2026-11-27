using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

// Builds the plain-text diagnosis report shown in the dialog and copied to the clipboard.
public static class Diagnosis
{
    public sealed class Input
    {
        public string GpuName = "";
        public string Driver = "";
        public string CpuName = "";
        public int Cores;
        public int Threads;
        public double RamGb;
        public string OsName = "";
        public Sample Now;
        public double MaxTemp = -1, MinTemp = 999, MaxPower = -1, MinClock = 1e9, MaxClock = -1;
        public int Samples;
        public int PowerCapSamples;
        public List<Marker> Markers = new List<Marker>();
        public string Version = "";
        public double IdleGpuTemp, IdleCpuTemp;
    }

    public static string Build(Input d)
    {
        var sb = new StringBuilder();
        string line = new string('=', 62);
        sb.AppendLine(line);
        sb.AppendLine(" 游戏崩溃诊断器 · 诊断报告");
        sb.AppendLine(" 生成时间: " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
        sb.AppendLine(line);
        sb.AppendLine();

        sb.AppendLine("【硬件 / 驱动】");
        sb.AppendLine(" 显卡    : " + Value(d.GpuName));
        sb.AppendLine(" 驱动    : " + Value(d.Driver));
        sb.AppendLine(" 处理器  : " + Value(d.CpuName));
        sb.AppendLine(string.Format(" 核心    : {0} 核 / {1} 线程", d.Cores, d.Threads));
        sb.AppendLine(" 内存    : " + (d.RamGb > 0 ? d.RamGb.ToString("0") + " GB" : "?"));
        sb.AppendLine(" 系统    : " + Value(d.OsName));
        sb.AppendLine(" 程序    : " + d.Version);
        sb.AppendLine();

        sb.AppendLine("【当前状态】");
        sb.AppendLine(string.Format(" GPU : {0}°C  {1}W  {2}MHz  占用 {3}% {4}",
            d.Now.GpuTemp.ToString("0.0"), d.Now.GpuPower.ToString("0"), d.Now.ClockSm, d.Now.UtilGpu, Throttle(d.Now.Throttle)));
        sb.AppendLine(string.Format(" CPU : {0}°C  {1}MHz  占用 {2}%  活跃 {3}/{4}",
            d.Now.CpuTemp > 0 ? d.Now.CpuTemp.ToString("0.0") : "--",
            d.Now.CpuMhz, d.Now.CpuLoad, d.Now.ActiveCores, d.Now.TotalCores));
        sb.AppendLine(string.Format(" 内存: {0}%   显存 {1:N0}/{2:N0} MB", (int)d.Now.RamPct, d.Now.MemUsedMb, d.Now.MemTotalMb));
        sb.AppendLine();

        sb.AppendLine("【本次记录统计】");
        if (d.Samples > 0 && d.MaxTemp > 0)
            sb.AppendLine(string.Format(" 采样 {0:N0} 条   最高温度 {1:0.0}°C   最低温度 {2:0.0}°C   最高功耗 {3:0}W",
                d.Samples, d.MaxTemp, d.MinTemp, d.MaxPower));
        else
            sb.AppendLine(" 采样 0 条（刚启动，还没有统计数据）");
        if (d.MaxClock > 0)
            sb.AppendLine(string.Format(" 核心频率 {0:N0} ~ {1:N0} MHz   撞功耗墙 {2:0.#}% 的采样",
                d.MinClock, d.MaxClock, d.Samples > 0 ? d.PowerCapSamples * 100.0 / d.Samples : 0));
        sb.AppendLine();

        if (d.IdleGpuTemp > 0 && d.Now.GpuTemp > 0)
        {
            sb.AppendLine("【温度基线】");
            sb.AppendLine(string.Format(" 空闲 GPU {0:0.0}°C   CPU {1:0.0}°C   （当前 {2:0.0}°C / {3:0.0}°C）",
                d.IdleGpuTemp, d.IdleCpuTemp, d.Now.GpuTemp, d.Now.CpuTemp));
            sb.AppendLine();
        }

        sb.AppendLine("【崩溃历史】");
        DateTime cut = DateTime.Now.AddDays(-7);
        int crashCount = 0, downCount = 0;
        foreach (var m in d.Markers)
        {
            if (m.Time < cut) continue;
            if (m.Kind == "crash") crashCount++;
            else if (m.Kind == "down") downCount++;
        }
        sb.AppendLine(string.Format(" 最近 7 天: 崩溃 {0} 次，死机/断电 {1} 次", crashCount, downCount));
        int shown = 0;
        for (int i = d.Markers.Count - 1; i >= 0 && shown < 6; i--)
        {
            var m = d.Markers[i];
            if (m.Time < cut) continue;
            sb.AppendLine(string.Format("   · {0}  {1}", m.Time.ToString("MM-dd HH:mm"),
                m.Kind == "crash" ? "游戏崩溃" : (m.Kind == "down" ? "死机 / 断电" : "监控中断")));
            shown++;
        }
        if (shown == 0) sb.AppendLine("   · 没有记录到崩溃");
        sb.AppendLine();

        sb.AppendLine("【建议】");
        foreach (string tip in Advice(d))
            sb.AppendLine(" · " + tip);
        return sb.ToString();
    }

    private static IEnumerable<string> Advice(Input d)
    {
        bool any = false;
        if (d.MaxTemp >= 85)
        {
            any = true;
            yield return string.Format("GPU 最高 {0:0}°C 已接近上限，先查散热（风扇曲线、积灰、硅脂）", d.MaxTemp);
        }
        if (d.Samples > 0 && d.PowerCapSamples * 100.0 / d.Samples > 30)
        {
            any = true;
            yield return "超过三成采样撞到功耗墙，游戏时会降频；笔记本属正常，可考虑限制帧率";
        }
        if (d.MaxClock > 0 && d.MaxClock < 1500)
        {
            any = true;
            yield return "核心频率上不去 1500MHz，检查是否被功耗墙或电源模式限制";
        }
        if (!any)
            yield return "当前数据未发现异常；如果仍然崩溃，请在崩溃后立刻生成一次报告";
        yield return "崩溃判定依据：崩溃转储 / 应用错误事件 1000 / 显卡驱动错误事件";
    }

    private static string Value(string s) { return string.IsNullOrEmpty(s) ? "?" : s; }

    private static string Throttle(ulong mask)
    {
        if ((mask & 0x1UL) != 0) return "降频 功耗墙";
        if ((mask & 0x4UL) != 0) return "降频 温度墙";
        if ((mask & 0x2UL) != 0) return "降频 硬件";
        return "降频 正常";
    }
}
