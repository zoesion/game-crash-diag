using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;

// Stage A of the C# rewrite: headless sampler.
// Modes:
//   -SelfTest            print one snapshot and exit
//   -Collect <seconds>   write CSV for N seconds, print the resulting file
internal static class Program
{
    private static string Root
    {
        get { return Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location); }
    }

    private static int Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;
        int collectSeconds = 0;
        bool selfTest = false;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "-SelfTest") selfTest = true;
            else if (args[i] == "-Collect" && i + 1 < args.Length) int.TryParse(args[++i], out collectSeconds);
        }

        bool nv = Nvml.Init();
        Console.WriteLine("NVML: " + (nv ? "OK  " + Nvml.DeviceName : "unavailable - " + Nvml.LastError));

        var cpu = new CpuSampler();
        cpu.Prime();
        Thread.Sleep(600);

        if (!nv)
        {
            Console.WriteLine("没有 NVML，无法采样 GPU");
            return 2;
        }

        if (selfTest)
        {
            double t, p, mu, mt; int cs, cm, ug, um; string ps; ulong th;
            var watch = System.Diagnostics.Stopwatch.StartNew();
            for (int k = 0; k < 20; k++)
            {
                Nvml.Read(out t, out p, out cs, out cm, out ug, out um, out mu, out mt, out ps, out th);
            }
            watch.Stop();
            double ms = watch.Elapsed.TotalMilliseconds / 20.0;
            int mhz, load, active, total; double ram;
            cpu.Read(out mhz, out load, out active, out total, out ram);
            Nvml.Read(out t, out p, out cs, out cm, out ug, out um, out mu, out mt, out ps, out th);
            Console.WriteLine(string.Format(CultureInfo.InvariantCulture,
                "GPU  {0}: {1:N1}C  {2:N1}W  {3}/{4}MHz  占用{5}%  显存{6:N0}/{7:N0}MB  {8}",
                Nvml.DeviceName, t, p, cs, cm, ug, mu, mt, ps));
            Console.WriteLine(string.Format(CultureInfo.InvariantCulture,
                "CPU  {0}MHz  占用{1}%  活跃{2}/{3}  内存{4}%", mhz, load, active, total, ram));
            Console.WriteLine(string.Format(CultureInfo.InvariantCulture, "单次采样耗时: {0:N2} ms（nvidia-smi 版本约 106 ms）", ms));
            cpu.Dispose();
            Nvml.Shutdown();
            return 0;
        }

        if (collectSeconds > 0)
        {
            string dir = Path.Combine(Root, "logs", "v6test");
            Directory.CreateDirectory(dir);
            string file = Path.Combine(dir, "v6-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".csv");
            var sb = new StringBuilder();
            sb.AppendLine("时间,GPU温度,GPU功耗,GPU核心频率,GPU显存频率,GPU占用,显存占用,显存已用,电源状态,降频掩码,CPU温度,CPU频率,CPU占用,活跃核心,总核心,内存占用");
            File.WriteAllText(file, sb.ToString(), new UTF8Encoding(false));

            int count = 0;
            var end = DateTime.Now.AddSeconds(collectSeconds);
            while (DateTime.Now < end)
            {
                double t, p, mu, mt; int cs, cm, ug, um; string ps; ulong th;
                if (!Nvml.Read(out t, out p, out cs, out cm, out ug, out um, out mu, out mt, out ps, out th)) break;
                int mhz, load, active, total; double ram;
                cpu.Read(out mhz, out load, out active, out total, out ram);
                string line = string.Format(CultureInfo.InvariantCulture,
                    "{0},{1:N2},{2:N2},{3},{4},{5},{6},{7},{8},{9:X16},{10:N1},{11},{12},{13},{14},{15}",
                    DateTime.Now.ToString("HH:mm:ss"), t, p, cs, cm, ug, um, (long)mu, ps, th,
                    0.0, mhz, load, active, total, ram);
                File.AppendAllText(file, line + Environment.NewLine, new UTF8Encoding(false));
                count++;
                Thread.Sleep(500);
            }
            Console.WriteLine("写入 " + count + " 行 → " + file);
            cpu.Dispose();
            Nvml.Shutdown();
            return 0;
        }

        Console.WriteLine("用法: GameCrashDiag6.exe -SelfTest | -Collect <秒>");
        cpu.Dispose();
        Nvml.Shutdown();
        return 1;
    }

    private static long StopwatchSw()
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        return sw.ElapsedMilliseconds;
    }
}
