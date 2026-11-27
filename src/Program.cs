using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Forms;

internal static class Program
{
    public static string AwarenessInfo()
    {
        try { return Native.GetAwareness(); } catch { return "?"; }
    }

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
        bool codeTest = false;
        bool updateTest = false;
        string shotPath = "";
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "-SelfTest") selfTest = true;
            else if (args[i] == "-UiTest") uiTest = true;
            else if (args[i] == "-TestDetect") testDetect = true;
            else if (args[i] == "-TestReport") testReport = true;
            else if (args[i] == "-TestCrashFlow") crashTest = true;
            else if (args[i] == "-Tray") startHidden = true;
            else if (args[i] == "-TestDiagnosis") diagTest = true;
            else if (args[i] == "-TestCodes") codeTest = true;
            else if (args[i] == "-TestUpdate") updateTest = true;
            else if (args[i] == "-Shot" && i + 1 < args.Length) shotPath = args[++i];
            else if (args[i] == "-Collect" && i + 1 < args.Length) int.TryParse(args[++i], out collectSeconds);
        }

        if (selfTest || collectSeconds > 0) return Headless(selfTest, collectSeconds);
        if (codeTest) return CodeTest();
        if (updateTest) return UpdateTest();
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

            // DPI awareness must be set before any user32 call, otherwise the window is bitmap-scaled
            try { Native.SetProcessDPIAware(); } catch { }
            if (uiTest) Console.WriteLine("DPI awareness: " + Native.GetAwareness());
            string langCode = "zh-CN";
            try
            {
                string st = Path.Combine(Root, "data", "settings.ini");
                if (File.Exists(st))
                    foreach (string line in File.ReadAllLines(st))
                        if (line.StartsWith("lang=")) langCode = line.Substring(5).Trim();
            }
            catch { }
            I18n.Load(Path.Combine(Root, "lang"), langCode);
            try { Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false); } catch { }

            if (uiTest)
            {
                using (var f = new MainForm(Root, tag))
                {
                    Console.WriteLine("UI 自检通过");
                    Console.WriteLine("  控件数: " + f.Controls.Count);
                    Console.WriteLine("  标题: " + f.Text);
                    Console.WriteLine("  DPI 缩放: " + f.DpiScale);
                    var scr = System.Windows.Forms.Screen.PrimaryScreen.Bounds;
                    Console.WriteLine("  屏幕(逻辑): " + scr.Width + "x" + scr.Height);
                    using (var g2 = System.Drawing.Graphics.FromHwnd(IntPtr.Zero))
                        Console.WriteLine("  桌面 DC DPI: " + g2.DpiX);
                }
                return 0;
            }

            if (!string.IsNullOrEmpty(shotPath))
            {
                using (var f3 = new MainForm(Root, tag))
                {
                    f3.Show();
                    Application.DoEvents();
                    System.Threading.Thread.Sleep(2600);
                    Application.DoEvents();
                    f3.CapturePng(shotPath);
                    f3.Hide();
                }
                Console.WriteLine("saved: " + shotPath);
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

            // 全局兜底：任何未处理异常都写日志，避免进程悄无声息消失
            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
            Application.ThreadException += (s, e) => LogFatal("ThreadException", e.Exception);
            AppDomain.CurrentDomain.UnhandledException += (s, e) => LogFatal("UnhandledException", e.ExceptionObject as Exception);
            Application.Run(new MainForm(Root, tag, startHidden));
        }
        return 0;
    }

    private static int UpdateTest()
    {
        Console.WriteLine("当前版本: " + MainForm.AppVersion);
        var r = Updater.Check(MainForm.AppVersion);
        if (!r.Ok) { Console.WriteLine("检查失败: " + r.Error); return 1; }
        Console.WriteLine("最新版本: " + r.LatestTag + "   " + r.ReleaseName);
        Console.WriteLine("发布时间: " + r.PublishedAt);
        Console.WriteLine("下载页:   " + r.HtmlUrl);
        Console.WriteLine("有新版本: " + r.IsNewer);
        Console.WriteLine("版本比较测试: 6.02 vs 6.0 = " + Updater.CompareVersions("v6.02", "v6.0") +
                          " ; 5.97 vs 6.0 = " + Updater.CompareVersions("v5.97", "v6.0") +
                          " ; 6.10 vs 6.9 = " + Updater.CompareVersions("v6.10", "v6.9"));
        return 0;
    }

    private static int CodeTest()
    {
        ErrorCodes.Load(Root, I18n.Code);
        Console.WriteLine("错误码表: " + ErrorCodes.Count + " 条");
        string sample = "Faulting module dxgi.dll, code 0x887A0006 (DXGI_ERROR_DEVICE_HUNG) at nvlddmkm.sys";
        Console.WriteLine("样本: " + sample);
        Console.WriteLine(ErrorCodes.Explain(sample));
        Console.WriteLine("--- 再试一个 ---");
        Console.WriteLine(ErrorCodes.Explain("WHEA_UNCORRECTABLE_ERROR  0x00000124  bugcheck"));
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
        ErrorCodes.Load(Root, I18n.Code);
        Console.WriteLine("错误码表: " + ErrorCodes.Count + " 条");
        Console.WriteLine("查找测试: " + ErrorCodes.Find("code 0x887A0006").Count + " 条命中");
        var input = new CrashReport.ReportInput();
        input.IsCrash = true;
        input.Reason = "应用错误事件 1000";
        input.GameName = "bf6";
        input.Category = "bf6";
        input.StartTime = DateTime.Now.AddMinutes(-12);
        input.ExitTime = DateTime.Now;
        input.TelemetryFile = "(测试数据)";
        input.IdleGpuTemp = 30.2; input.IdleCpuTemp = 45.0;
        input.GameGpuAvg = 68.4; input.GameGpuMax = 74.0; input.GameCpuAvg = 82.0;
        input.EventText = "Faulting module dxgi.dll, exception code 0x887A0006";
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

    public static void LogFatal(string kind, Exception ex)
    {
        try
        {
            string path = Path.Combine(Path.GetTempPath(), "v6-crash.txt");
            File.AppendAllText(path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + kind + Environment.NewLine +
                (ex != null ? ex.ToString() : "(null)") + Environment.NewLine + Environment.NewLine, Encoding.UTF8);
        }
        catch { }
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
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool SetProcessDPIAwareNative();

    [System.Runtime.InteropServices.DllImport("shcore.dll")]
    private static extern int GetProcessDpiAwareness(IntPtr process, out int value);

    public static void SetProcessDPIAware()
    {
        try { SetProcessDPIAwareNative(); } catch { }
    }

    public static string GetAwareness()
    {
        try
        {
            int v;
            GetProcessDpiAwareness(IntPtr.Zero, out v);
            return v.ToString();
        }
        catch (Exception ex) { return "unknown: " + ex.Message; }
    }
}
