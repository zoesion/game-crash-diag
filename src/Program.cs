using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Forms;

internal static class Program
{
    private static string Root
    {
        get { return Path.GetDirectoryName(Application.ExecutablePath); }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;
        bool selfTest = false;
        int collectSeconds = 0;
        bool uiTest = false;
        bool testDetect = false;
        bool testReport = false;
        bool crashTest = false;
        bool startHidden = false;
        bool diagTest = false;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "-SelfTest") selfTest = true;
            else if (args[i] == "-UiTest") uiTest = true;
            else if (args[i] == "-TestDetect") testDetect = true;
            else if (args[i] == "-TestReport") testReport = true;
            else if (args[i] == "-TestCrashFlow") crashTest = true;
            else if (args[i] == "-Tray") startHidden = true;
            else if (args[i] == "-TestDiagnosis") diagTest = true;
            else if (args[i] == "-Collect" && i + 1 < args.Length) int.TryParse(args[++i], out collectSeconds);
        }

        if (selfTest || collectSeconds > 0) return Headless(selfTest, collectSeconds);
        if (testDetect) return DetectTest();
        if (testReport) return ReportTest();

        // instance identity: a dev copy carries an instance.txt next to the exe
        string tag = "";
        try
        {
            string f = Path.Combine(Root, "instance.txt");
            if (File.Exists(f)) tag = File.ReadAllText(f, Encoding.UTF8).Trim();
        }
        catch { }

        string mutexName = "Local\\GameCrashDiag_v6_" + (tag.Length > 0 ? tag : "main");
        bool created;
        using (var mutex = new Mutex(true, mutexName, out created))
        {
            if (!created) return 0;

            I18n.Load(Path.Combine(Root, "lang"), "zh-CN");
            try { Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false); } catch { }
            try { Native.SetProcessDPIAware(); } catch { }

            if (uiTest)
            {
                using (var f = new MainForm(Root, tag))
                {
                    Console.WriteLine("UI 自检通过");
                    Console.WriteLine("  控件数: " + f.Controls.Count);
                    Console.WriteLine("  标题: " + f.Text);
                }
                return 0;
            }

            if (diagTest)
            {
                using (var f2 = new MainForm(Root, tag))
                {
                    Console.WriteLine(f2.BuildDiagnosisText());
                }
                return 0;
            }

            if (crashTest)
            {
                using (var f = new MainForm(Root, tag))
                {
                    Console.WriteLine(f.RunCrashFlowTest());
                }
                return 0;
            }

            Application.Run(new MainForm(Root, tag, startHidden));
        }
        return 0;
    }

    private static int DetectTest()
    {
        var hit = GameDetect.Find();
        if (hit == null)
        {
            Console.WriteLine("未检测到游戏（符合预期：当前前台只有浏览器/终端）");
        }
        else
        {
            Console.WriteLine(string.Format("检测到: {0} (PID {1}, {2:N0} MB) {3}",
                hit.Name, hit.Pid, hit.Memory / 1048576.0, hit.Path));
        }
        return 0;
    }

    private static int ReportTest()
    {
        var input = new CrashReport.ReportInput();
        input.IsCrash = true;
        input.Reason = "应用错误事件 1000";
        input.GameName = "bf6";
        input.Category = "bf6";
        input.StartTime = DateTime.Now.AddMinutes(-12);
        input.ExitTime = DateTime.Now;
        input.TelemetryFile = "(测试数据)";
        var rnd = new Random(7);
        for (int i = 0; i < 50; i++)
        {
            input.TailRows.Add(string.Format(System.Globalization.CultureInfo.InvariantCulture,
                "04:0{0}:0{1},{2:0.0},{3:0},{4},8001,{5},20,9000,P0,0x1,0,0,0,正常,{6:0.0},3800,30,8,21,45",
                i / 6, i % 6, 60 + rnd.Next(0, 15), 100 + rnd.Next(0, 60), 1800,
                70 + rnd.Next(0, 20), 30 + rnd.Next(0, 40)));
        }
        string path = CrashReport.Write(Root, input);
        Console.WriteLine("报告已生成: " + path);
        foreach (string line in File.ReadAllLines(path)) Console.WriteLine("  " + line);
        return 0;
    }

    private static int Headless(bool selfTest, int collectSeconds)
    {
        bool nv = Nvml.Init();
        Console.WriteLine("NVML: " + (nv ? "OK  " + Nvml.DeviceName : "unavailable - " + Nvml.LastError));
        var cpu = new CpuSampler();
        cpu.Prime();
        Thread.Sleep(600);
        if (!nv) return 2;

        if (selfTest)
        {
            double t, p, mu, mt; int cs, cm, ug, um; string ps; ulong th;
            var watch = System.Diagnostics.Stopwatch.StartNew();
            for (int k = 0; k < 20; k++) Nvml.Read(out t, out p, out cs, out cm, out ug, out um, out mu, out mt, out ps, out th);
            watch.Stop();
            double ms = watch.Elapsed.TotalMilliseconds / 20.0;
            int mhz, load, active, total; double ram;
            cpu.Read(out mhz, out load, out active, out total, out ram);
            Nvml.Read(out t, out p, out cs, out cm, out ug, out um, out mu, out mt, out ps, out th);
            Console.WriteLine(string.Format(System.Globalization.CultureInfo.InvariantCulture,
                "GPU  {0}: {1:N1}C  {2:N1}W  {3}/{4}MHz  占用{5}%  显存{6:N0}/{7:N0}MB  {8}",
                Nvml.DeviceName, t, p, cs, cm, ug, mu, mt, ps));
            Console.WriteLine(string.Format(System.Globalization.CultureInfo.InvariantCulture,
                "CPU  {0}MHz  占用{1}%  活跃{2}/{3}  内存{4}%", mhz, load, active, total, ram));
            Console.WriteLine(string.Format(System.Globalization.CultureInfo.InvariantCulture,
                "单次采样耗时: {0:N2} ms（nvidia-smi 版本约 106 ms）", ms));
            cpu.Dispose(); Nvml.Shutdown();
            return 0;
        }

        string dir = Path.Combine(Root, "logs", "v6test");
        Directory.CreateDirectory(dir);
        string file = Path.Combine(dir, "v6-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".csv");
        File.WriteAllText(file,
            "时间,GPU温度,GPU功耗,GPU核心频率,GPU显存频率,GPU占用,显存占用,显存已用,电源状态,降频掩码,CPU温度,CPU频率,CPU占用,活跃核心,总核心,内存占用" + Environment.NewLine,
            new UTF8Encoding(false));
        int count = 0;
        var end = DateTime.Now.AddSeconds(collectSeconds);
        while (DateTime.Now < end)
        {
            double t, p, mu, mt; int cs, cm, ug, um; string ps; ulong th;
            if (!Nvml.Read(out t, out p, out cs, out cm, out ug, out um, out mu, out mt, out ps, out th)) break;
            int mhz, load, active, total; double ram;
            cpu.Read(out mhz, out load, out active, out total, out ram);
            string line = string.Format(System.Globalization.CultureInfo.InvariantCulture,
                "{0},{1:0.00},{2:0.00},{3},{4},{5},{6},{7},{8},{9:X16},0,{10},{11},{12},{13},{14}",
                DateTime.Now.ToString("HH:mm:ss"), t, p, cs, cm, ug, um, (long)mu, ps, th, mhz, load, active, total, ram);
            File.AppendAllText(file, line + Environment.NewLine, new UTF8Encoding(false));
            count++;
            Thread.Sleep(500);
        }
        Console.WriteLine("写入 " + count + " 行 → " + file);
        cpu.Dispose(); Nvml.Shutdown();
        return 0;
    }
}

internal static class Native
{
    [System.Runtime.InteropServices.DllImport("shcore.dll")]
    private static extern int SetProcessDpiAwareness(int value);

    public static void SetProcessDPIAware()
    {
        try { SetProcessDpiAwareness(1); } catch { }
    }
}
