using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using LibreHardwareMonitor.Hardware;

// Thin wrapper around LibreHardwareMonitorLib.
// Exposes only what GameCrashDiag needs, so the PowerShell side does not have to
// walk the object graph on every tick.
public static class LhmBridge
{
    private static Computer _computer;
    private static IHardware _gpu;
    private static IHardware _cpu;
    private static string _lastError = "";

    public static string LastError { get { return _lastError; } }
    public static bool Ready { get { return _computer != null; } }
    public static string GpuName { get { return _gpu != null ? _gpu.Name : ""; } }
    public static string GpuVendor { get { return _gpu != null ? _gpu.HardwareType.ToString() : ""; } }

    public static bool Init()
    {
        if (_computer != null) return true;
        try
        {
            _computer = new Computer();
            _computer.IsGpuEnabled = true;
            _computer.IsCpuEnabled = true;
            _computer.IsMotherboardEnabled = false;
            _computer.IsControllerEnabled = false;
            _computer.IsMemoryEnabled = false;
            _computer.IsStorageEnabled = false;
            _computer.IsNetworkEnabled = false;
            _computer.Open();

            foreach (IHardware hw in _computer.Hardware)
            {
                if (_gpu == null &&
                    (hw.HardwareType == HardwareType.GpuNvidia ||
                     hw.HardwareType == HardwareType.GpuAmd ||
                     hw.HardwareType == HardwareType.GpuIntel))
                {
                    _gpu = hw;
                }
                if (_cpu == null && hw.HardwareType == HardwareType.Cpu) _cpu = hw;
            }
            return _gpu != null;
        }
        catch (Exception ex)
        {
            _lastError = ex.Message;
            TryClose();
            return false;
        }
    }

    private static void TryClose()
    {
        try { if (_computer != null) _computer.Close(); } catch { }
        _computer = null;
        _gpu = null;
        _cpu = null;
    }

    public static void Close() { TryClose(); }

    private static void Update(IHardware hw)
    {
        if (hw == null) return;
        try
        {
            hw.Update();
            if (hw.SubHardware != null)
                foreach (IHardware sub in hw.SubHardware) sub.Update();
        }
        catch { }
    }

    private static double Sensor(IHardware hw, SensorType type, params string[] names)
    {
        if (hw == null) return double.NaN;
        foreach (string wanted in names)
        {
            foreach (ISensor s in hw.Sensors)
            {
                if (s.SensorType != type) continue;
                if (s.Value == null) continue;
                if (string.Equals(s.Name, wanted, StringComparison.OrdinalIgnoreCase))
                    return s.Value.Value;
            }
        }
        // fallback: first sensor of that type
        foreach (ISensor s in hw.Sensors)
        {
            if (s.SensorType != type) continue;
            if (s.Value == null) continue;
            return s.Value.Value;
        }
        return double.NaN;
    }

    /// <summary>Reads the GPU. Returns NaN for anything unavailable.</summary>
    public static double[] ReadGpu()
    {
        // temp, power, clockCore, clockMem, load, vramUsedMB, vramTotalMB, hotspot
        double[] r = new double[] { double.NaN, double.NaN, double.NaN, double.NaN,
                                    double.NaN, double.NaN, double.NaN, double.NaN };
        if (_gpu == null) return r;
        try
        {
            Update(_gpu);
            r[0] = Sensor(_gpu, SensorType.Temperature, "GPU Core", "GPU Diode");
            r[7] = Sensor(_gpu, SensorType.Temperature, "GPU Hot Spot");
            r[1] = Sensor(_gpu, SensorType.Power, "GPU Package", "GPU Power", "GPU Core");
            r[2] = Sensor(_gpu, SensorType.Clock, "GPU Core");
            r[3] = Sensor(_gpu, SensorType.Clock, "GPU Memory");
            r[4] = Sensor(_gpu, SensorType.Load, "GPU Core", "D3D 3D");
            r[5] = Sensor(_gpu, SensorType.SmallData, "GPU Memory Used", "D3D Dedicated Memory Used");
            r[6] = Sensor(_gpu, SensorType.SmallData, "GPU Memory Total");
        }
        catch { }
        return r;
    }

    /// <summary>CPU package temperature in °C, or NaN.</summary>
    public static double ReadCpuTemp()
    {
        if (_cpu == null) return double.NaN;
        try
        {
            Update(_cpu);
            double v = Sensor(_cpu, SensorType.Temperature, "CPU Package", "Core Average", "Core Max");
            if (!double.IsNaN(v)) return v;
            // average of core temperatures as a last resort
            var cores = _cpu.Sensors.Where(s => s.SensorType == SensorType.Temperature
                                                && s.Value != null
                                                && s.Name.StartsWith("CPU Core", StringComparison.OrdinalIgnoreCase))
                                    .Select(s => s.Value.Value).ToList();
            if (cores.Count > 0) return cores.Average();
            return double.NaN;
        }
        catch { return double.NaN; }
    }

    /// <summary>CPU package power in W, or NaN.</summary>
    public static double ReadCpuPower()
    {
        if (_cpu == null) return double.NaN;
        try
        {
            Update(_cpu);
            return Sensor(_cpu, SensorType.Power, "CPU Package", "Package");
        }
        catch { return double.NaN; }
    }
}
