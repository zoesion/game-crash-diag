using System;
using System.Runtime.InteropServices;
using System.Text;

// Minimal NVML interop: read NVIDIA sensors in-process instead of spawning nvidia-smi
// (nvidia-smi costs ~100 ms per call; direct NVML reads take ~1-2 ms).
public static class Nvml
{
    private const string Dll = "nvml.dll";

    public const int NVML_SUCCESS = 0;

    // nvmlDeviceGetTemperature
    public const int NVML_TEMPERATURE_GPU = 0;

    // clock ids
    public const int NVML_CLOCK_SM = 1;
    public const int NVML_CLOCK_MEM = 2;

    [StructLayout(LayoutKind.Sequential)]
    public struct MemoryInfo
    {
        public ulong Total;
        public ulong Free;
        public ulong Used;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Utilization
    {
        public uint Gpu;
        public uint Memory;
    }

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern int nvmlInit_v2();

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern int nvmlShutdown();

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern int nvmlDeviceGetCount_v2(ref uint count);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern int nvmlDeviceGetHandleByIndex_v2(uint index, ref IntPtr device);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern int nvmlDeviceGetName(IntPtr device, byte[] name, uint length);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern int nvmlDeviceGetTemperature(IntPtr device, int sensorType, ref uint temp);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern int nvmlDeviceGetPowerUsage(IntPtr device, ref uint milliwatts);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern int nvmlDeviceGetClockInfo(IntPtr device, int type, ref uint mhz);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern int nvmlDeviceGetUtilizationRates(IntPtr device, ref Utilization util);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern int nvmlDeviceGetMemoryInfo(IntPtr device, ref MemoryInfo mem);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern int nvmlDeviceGetPerformanceState(IntPtr device, ref int pstate);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern int nvmlDeviceGetCurrentClocksThrottleReasons(IntPtr device, ref ulong reasons);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern int nvmlDeviceGetTotalEnergyConsumption(IntPtr device, ref ulong millijoules);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    private static extern int nvmlSystemGetDriverVersion(byte[] version, uint length);

    private static bool _ready;
    private static IntPtr _dev = IntPtr.Zero;

    public static string DeviceName = "";
    public static string DriverVersion = "";
    public static string LastError = "";

    public static bool IsReady { get { return _ready; } }

    public static bool Init()
    {
        if (_ready) return true;
        try
        {
            if (nvmlInit_v2() != NVML_SUCCESS) { LastError = "nvmlInit failed"; return false; }
            uint count = 0;
            if (nvmlDeviceGetCount_v2(ref count) != NVML_SUCCESS || count == 0)
            {
                LastError = "no devices";
                return false;
            }
            if (nvmlDeviceGetHandleByIndex_v2(0, ref _dev) != NVML_SUCCESS)
            {
                LastError = "handle failed";
                return false;
            }
            byte[] buf = new byte[96];
            if (nvmlDeviceGetName(_dev, buf, (uint)buf.Length) == NVML_SUCCESS)
            {
                int len = Array.IndexOf(buf, (byte)0);
                if (len < 0) len = buf.Length;
                DeviceName = Encoding.UTF8.GetString(buf, 0, len);
            }
            byte[] drv = new byte[80];
            if (nvmlSystemGetDriverVersion(drv, (uint)drv.Length) == NVML_SUCCESS)
            {
                int dl = Array.IndexOf(drv, (byte)0);
                if (dl < 0) dl = drv.Length;
                DriverVersion = Encoding.UTF8.GetString(drv, 0, dl);
            }
            _ready = true;
            return true;
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            return false;
        }
    }

    public static void Shutdown()
    {
        try { if (_ready) nvmlShutdown(); } catch { }
        _ready = false;
    }

    /// <summary>Reads one snapshot. Returns false when NVML is unavailable.</summary>
    public static bool Read(out double temp, out double power, out int clockSm, out int clockMem,
                            out int utilGpu, out int utilMem, out double memUsedMb, out double memTotalMb,
                            out string pstate, out ulong throttle)
    {
        temp = 0; power = 0; clockSm = 0; clockMem = 0; utilGpu = 0; utilMem = 0;
        memUsedMb = 0; memTotalMb = 0; pstate = "-"; throttle = 0;
        if (!_ready) return false;

        uint t = 0, w = 0, c1 = 0, c2 = 0;
        if (nvmlDeviceGetTemperature(_dev, NVML_TEMPERATURE_GPU, ref t) == NVML_SUCCESS) temp = t;
        if (nvmlDeviceGetPowerUsage(_dev, ref w) == NVML_SUCCESS) power = w / 1000.0;
        if (nvmlDeviceGetClockInfo(_dev, NVML_CLOCK_SM, ref c1) == NVML_SUCCESS) clockSm = (int)c1;
        if (nvmlDeviceGetClockInfo(_dev, NVML_CLOCK_MEM, ref c2) == NVML_SUCCESS) clockMem = (int)c2;

        Utilization u = new Utilization();
        if (nvmlDeviceGetUtilizationRates(_dev, ref u) == NVML_SUCCESS) { utilGpu = (int)u.Gpu; utilMem = (int)u.Memory; }

        MemoryInfo mi = new MemoryInfo();
        if (nvmlDeviceGetMemoryInfo(_dev, ref mi) == NVML_SUCCESS)
        {
            memUsedMb = mi.Used / 1048576.0;
            memTotalMb = mi.Total / 1048576.0;
        }

        int ps = 0;
        if (nvmlDeviceGetPerformanceState(_dev, ref ps) == NVML_SUCCESS) pstate = "P" + ps;

        ulong reasons = 0;
        if (nvmlDeviceGetCurrentClocksThrottleReasons(_dev, ref reasons) == NVML_SUCCESS) throttle = reasons;

        return true;
    }
}
