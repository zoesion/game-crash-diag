using System;
using System.Diagnostics;
using System.Management;

// CPU sampling via performance counters (same source as the PowerShell version,
// so the numbers stay comparable).
public sealed class CpuSampler : IDisposable
{
    private PerformanceCounter _perf;
    private PerformanceCounter _util;
    private PerformanceCounter _time;
    private PerformanceCounter _mem;
    private PerformanceCounter[] _cores;
    private ulong _totalRamBytes;
    private static readonly object _ramLock = new object();

    public int MaxMHz = 2900;
    public int TotalThreads = 0;

    public CpuSampler()
    {
        try
        {
            var searcher = new ManagementObjectSearcher(
                "SELECT MaxClockSpeed, NumberOfLogicalProcessors, TotalPhysicalMemory FROM Win32_Processor");
            foreach (ManagementObject mo in searcher.Get())
            {
                object mc = mo["MaxClockSpeed"];
                if (mc != null) MaxMHz = Convert.ToInt32(mc);
                object nt = mo["NumberOfLogicalProcessors"];
                if (nt != null) TotalThreads = Convert.ToInt32(nt);
                break;
            }
        }
        catch { }

        // total physical memory: query once, it never changes
        try
        {
            var cs = new ManagementObjectSearcher("SELECT TotalPhysicalMemory FROM Win32_ComputerSystem");
            foreach (ManagementObject mo in cs.Get())
            {
                _totalRamBytes = Convert.ToUInt64(mo["TotalPhysicalMemory"]);
                break;
            }
        }
        catch { }

        _perf = new PerformanceCounter("Processor Information", "% Processor Performance", "_Total");
        _util = new PerformanceCounter("Processor Information", "% Processor Utility", "_Total");
        _time = new PerformanceCounter("Processor Information", "% Processor Time", "_Total");
        _mem = new PerformanceCounter("Memory", "Available MBytes");

        // keep _Total in the list: the PowerShell version counted it too (20 threads -> 21)
        var list = new System.Collections.Generic.List<PerformanceCounter>();
        foreach (var inst in new PerformanceCounterCategory("Processor Information").GetInstanceNames())
        {
            try { list.Add(new PerformanceCounter("Processor Information", "% Processor Time", inst)); } catch { }
        }
        _cores = list.ToArray();
    }

    public void Prime()
    {
        try
        {
            _perf.NextValue(); _util.NextValue(); _time.NextValue(); _mem.NextValue();
            foreach (var c in _cores) c.NextValue();
        }
        catch { }
    }

    public void Read(out int mhz, out int load, out int activeCores, out int totalCores, out double ramPct)
    {
        mhz = 0; load = 0; activeCores = 0; totalCores = 0; ramPct = 0;
        try
        {
            float perf = _perf.NextValue();
            if (perf > 0) mhz = (int)Math.Round(MaxMHz * perf / 100.0);
            float u = _util.NextValue();
            if (u >= 0) load = (int)Math.Min(100, Math.Round(u));
            _time.NextValue();
        }
        catch { }

        int active = 0;
        foreach (var c in _cores)
        {
            try { if (c.NextValue() >= 20) active++; }
            catch { }
        }
        // v5 的口径：线程数 + 1（把 _Total 也计入），保持一致便于对比
        totalCores = Environment.ProcessorCount + 1;   // v5 口径：线程数 + 1
        if (active < 1) active = 1;
        activeCores = active;

        try
        {
            float availMb = _mem.NextValue();
            if (_totalRamBytes > 0 && availMb > 0)
            {
                double usedBytes = (double)_totalRamBytes - (availMb * 1024.0 * 1024.0);
                ramPct = Math.Round(usedBytes / _totalRamBytes * 100.0, 0);
                if (ramPct < 0) ramPct = 0;
                if (ramPct > 100) ramPct = 100;
            }
        }
        catch { }
    }

    public void Dispose()
    {
        try { _perf.Dispose(); _util.Dispose(); _time.Dispose(); _mem.Dispose(); } catch { }
        foreach (var c in _cores) { try { c.Dispose(); } catch { } }
    }
}
