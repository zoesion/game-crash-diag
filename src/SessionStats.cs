using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

// Builds the "what should I watch out for" part of a report, for normal sessions as much as crashes.
public sealed class SessionStats
{
    // filled in by MainForm while a game is being tracked
    public int Samples;
    public double GpuTempSum, GpuTempMax = double.MinValue, CpuTempSum, CpuTempMax = double.MinValue, CpuTempMin = double.MaxValue;
    public double PowerSum, PowerMax;
    public double ClockSum, ClockMin = double.MaxValue, ClockMax;
    public double UtilSum, UtilMax;
    public double VramMax;
    public double CpuUtilSum, CpuUtilMax;
    public double CpuFreqSum, CpuFreqMin = double.MaxValue, CpuFreqMax;
    public int TempWallSamples, PowerWallSamples, HotCpuSamples, HotCpu90Samples, HotGpuSamples, VramTightSamples;
    public int ActiveCoresMax;

    public void Reset()
    {
        Samples = 0;
        GpuTempSum = CpuTempSum = PowerSum = ClockSum = UtilSum = CpuUtilSum = CpuFreqSum = 0;
        GpuTempMax = CpuTempMax = PowerMax = ClockMax = UtilMax = VramMax = CpuUtilMax = CpuFreqMax = 0;
        CpuTempMin = double.MaxValue; ClockMin = double.MaxValue; CpuFreqMin = double.MaxValue;
        TempWallSamples = PowerWallSamples = HotCpuSamples = HotCpu90Samples = HotGpuSamples = VramTightSamples = 0;
        ActiveCoresMax = 0;
    }

    public void Add(double gpuTemp, double power, double clock, double util, double vramMb,
                    double cpuTemp, double cpuUtil, double cpuFreq, int activeCores, ulong throttle)
    {
        Samples++;
        if (gpuTemp > 0)
        {
            GpuTempSum += gpuTemp;
            if (gpuTemp > GpuTempMax) GpuTempMax = gpuTemp;
            if (gpuTemp >= 85) HotGpuSamples++;
        }
        if (power > 0) { PowerSum += power; if (power > PowerMax) PowerMax = power; }
        if (clock > 0)
        {
            ClockSum += clock;
            if (clock > ClockMax) ClockMax = clock;
            if (clock < ClockMin) ClockMin = clock;
        }
        if (util >= 0) { UtilSum += util; if (util > UtilMax) UtilMax = util; }
        if (vramMb > VramMax) VramMax = vramMb;
        if (vramMb >= 15000) VramTightSamples++;
        if (cpuTemp > 0)
        {
            CpuTempSum += cpuTemp;
            if (cpuTemp > CpuTempMax) CpuTempMax = cpuTemp;
            if (cpuTemp < CpuTempMin) CpuTempMin = cpuTemp;
            if (cpuTemp >= 95) HotCpuSamples++;
            if (cpuTemp >= 90) HotCpu90Samples++;
        }
        if (cpuUtil >= 0) { CpuUtilSum += cpuUtil; if (cpuUtil > CpuUtilMax) CpuUtilMax = cpuUtil; }
        if (cpuFreq > 0)
        {
            CpuFreqSum += cpuFreq;
            if (cpuFreq > CpuFreqMax) CpuFreqMax = cpuFreq;
            if (cpuFreq < CpuFreqMin) CpuFreqMin = cpuFreq;
        }
        if (activeCores > ActiveCoresMax) ActiveCoresMax = activeCores;
        if ((throttle & 0x4UL) != 0) TempWallSamples++;
        if ((throttle & 0x1UL) != 0) PowerWallSamples++;
    }

    public double GpuTempAvg { get { return Samples > 0 ? GpuTempSum / Samples : 0; } }
    public double CpuTempAvg { get { return Samples > 0 ? CpuTempSum / Samples : 0; } }
    public double PowerAvg { get { return Samples > 0 ? PowerSum / Samples : 0; } }
    public double ClockAvg { get { return Samples > 0 ? ClockSum / Samples : 0; } }
    public double UtilAvg { get { return Samples > 0 ? UtilSum / Samples : 0; } }
    public double CpuUtilAvg { get { return Samples > 0 ? CpuUtilSum / Samples : 0; } }
    public double CpuFreqAvg { get { return Samples > 0 ? CpuFreqSum / Samples : 0; } }

    public string How() { return Samples > 0 ? "游戏内采样 " + Samples + " 次（每 0.5 秒）" : "没有采集到游戏内数据"; }

    /// <summary>Human readable observations, worst first.</summary>
    public List<string> Observations(TimeSpan duration)
    {
        var list = new List<string>();
        if (Samples == 0) { list.Add("本次会话没有采到数据（可能游戏一闪而过）"); return list; }

        double pctHotCpu = HotCpuSamples * 100.0 / Samples;
        double pctHotCpu90 = HotCpu90Samples * 100.0 / Samples;
        double pctHotGpu = HotGpuSamples * 100.0 / Samples;
        double pctTempWall = TempWallSamples * 100.0 / Samples;

        if (pctHotCpu90 >= 40 && pctHotCpu < 30)
            list.Add(string.Format("CPU 有 {0:0}% 的时间在 90°C 以上（最高 {1:0}°C），属于偏高，但还没到降频区", pctHotCpu90, CpuTempMax));
        if (pctHotCpu >= 30)
            list.Add(string.Format("CPU 有 {0:0}% 的时间在 95°C 以上（最高 {1:0}°C），长时间高温会触发降频", pctHotCpu, CpuTempMax));
        else if (CpuTempMax >= 95)
            list.Add(string.Format("CPU 最高到过 {0:0}°C，属于该型号的正常上限附近，注意散热", CpuTempMax));
        if (pctTempWall >= 10)
            list.Add(string.Format("GPU 有 {0:0}% 的时间撞到温度墙而降频（{1} / {2} 次采样），可能出现掉帧", pctTempWall, TempWallSamples, Samples));
        else if (pctHotGpu >= 20)
            list.Add(string.Format("GPU 有 {0:0}% 的时间在 85°C 以上（最高 {1:0}°C）", pctHotGpu, GpuTempMax));
        if (VramMax >= 15500)
            list.Add(string.Format("显存峰值 {0:N0} MB，非常接近 16 GB 上限，贴图设最高容易爆显存", VramMax));
        else if (VramTightSamples > Samples * 0.2)
            list.Add(string.Format("显存有 {0:0}% 的时间在 15 GB 以上（峰值 {1:N0} MB）", VramTightSamples * 100.0 / Samples, VramMax));

        if (pctHotCpu < 30 && pctHotGpu < 20 && VramMax < 15500 && pctTempWall < 10)
            list.Add("温度和显存都在安全范围，没有观察到降频或爆显存");

        if (duration.TotalMinutes < 3)
            list.Add("本局时间很短（" + Math.Round(duration.TotalMinutes) + " 分钟），统计意义有限");

        return list;
    }

    /// <summary>One or two concrete suggestions derived from the observations.</summary>
    public List<string> Advice()
    {
        var list = new List<string>();
        if (Samples == 0) return list;
        double pctHotCpu = HotCpuSamples * 100.0 / Samples;
        if (pctHotCpu >= 30 || CpuTempMax >= 97)
        {
            list.Add("CPU 温度偏高：垫高机身或加散热底座，电源模式改「平衡」，考虑用 ThrottleStop 降压 -100mV");
        }
        if (TempWallSamples > Samples * 0.1)
        {
            list.Add("GPU 常撞温度墙：清理风扇灰尘，或用 MSI Afterburner 把功耗墙下调 5~10%，换取更稳的频率");
        }
        if (VramMax >= 15500)
            list.Add("显存接近上限：把材质质量降一档，关闭高分辨率贴图，避免爆显存导致的卡顿或崩溃");
        if (ClockMin > 0 && ClockMin < 800 && ClockMax > 1500)
            list.Add("核心频率波动较大（" + (int)ClockMin + " ~ " + (int)ClockMax + " MHz），若同时掉帧可尝试锁频");
        return list;
    }

    public string Summary()
    {
        var sb = new StringBuilder();
        if (Samples == 0) return "  （无数据）\r\n";
        sb.AppendLine(string.Format("  采样次数 : {0}", Samples));
        sb.AppendLine(string.Format("  GPU 温度 : 平均 {0:0.0}°C  最高 {1:0.0}°C", GpuTempAvg, GpuTempMax));
        sb.AppendLine(string.Format("  GPU 功耗 : 平均 {0:0}W  最高 {1:0}W", PowerAvg, PowerMax));
        sb.AppendLine(string.Format("  GPU 频率 : 平均 {0:0} MHz  范围 {1:0} ~ {2:0} MHz", ClockAvg, ClockMin == double.MaxValue ? 0 : ClockMin, ClockMax));
        sb.AppendLine(string.Format("  GPU 占用 : 平均 {0:0}%  最高 {1:0}%", UtilAvg, UtilMax));
        sb.AppendLine(string.Format("  显存峰值 : {0:N0} MB", VramMax));
        sb.AppendLine(string.Format("  CPU 温度 : 平均 {0:0.0}°C  最高 {1:0.0}°C  最低 {2:0.0}°C", CpuTempAvg, CpuTempMax, CpuTempMin == double.MaxValue ? 0 : CpuTempMin));
        sb.AppendLine(string.Format("  CPU 频率 : 平均 {0:0} MHz  最高 {1:0} MHz", CpuFreqAvg, CpuFreqMax));
        sb.AppendLine(string.Format("  CPU 占用 : 平均 {0:0}%  最高 {1:0}%  活跃核心最多 {2}", CpuUtilAvg, CpuUtilMax, ActiveCoresMax));
        sb.AppendLine(string.Format("  降频情况 : 温度墙 {0} 次  功耗墙 {1} 次", TempWallSamples, PowerWallSamples));
        return sb.ToString();
    }
}
