using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Windows.Forms;

// Main window: same layout as the PowerShell build, but compiled C#.
public sealed class MainForm : Form
{
    // ── palette (same as v5) ──
    private static readonly Color CBg = Color.FromArgb(24, 24, 28);
    private static readonly Color CCard = Color.FromArgb(34, 34, 40);
    private static readonly Color CGrid = Color.FromArgb(48, 48, 58);
    private static readonly Color CText = Color.FromArgb(228, 228, 236);
    private static readonly Color CDim = Color.FromArgb(138, 138, 152);
    private static readonly Color CAccent = Color.FromArgb(86, 214, 178);
    private static readonly Color CWarn = Color.FromArgb(232, 176, 74);
    private static readonly Color CBad = Color.FromArgb(232, 92, 92);
    private static readonly Color CPower = Color.FromArgb(90, 155, 220);
    private static readonly Color CFreq = Color.FromArgb(150, 130, 220);

    private readonly float _dpi;
    private readonly string _root;
    private readonly string _tag;
    private readonly Storage _store;
    private readonly CpuSampler _cpu = new CpuSampler();
    private Timer _timer;

    // history buffers
    private readonly List<DateTime> _tTime = new List<DateTime>();
    private readonly List<double> _gTemp = new List<double>();
    private readonly List<double> _gPower = new List<double>();
    private readonly List<DateTime> _cTime = new List<DateTime>();
    private readonly List<double> _cTemp = new List<double>();
    private readonly List<double> _cFreq = new List<double>();
    private readonly List<Marker> _markers = new List<Marker>();

    private int _maxPoints = 43200;
    private int _spanPts = 600;
    private int _shiftPts = 0;
    private bool _followLive = true;

    private double _lastCpuTemp = 0;
    private int _lastCpuFreq = 0;
    private DateTime _cpuTempAt = DateTime.MinValue;
    private bool _lhmReady;

    // controls
    private Label _lblGpuName, _lblStatus, _lblDetail, _lblStats, _lblHint, _lblVer, _lblCpuName, _lblTitle;
    private Label _tip;
    private Label[] _unitLabels;
    private Label _valTemp, _valPower, _valClock, _valUtil;
    private Label _valCpuTemp, _valCpuClock, _valCpuUtil, _valCpuCores;
    private PictureBox _chart, _cpuChart;
    private Panel _barTrack, _barThumb;
    private NotifyIcon _tray;
    private ContextMenuStrip _menu;
    private Bitmap _bmpFront, _bmpBack, _bmpCpuFront, _bmpCpuBack;
    private int _hoverGpu = -1, _hoverCpu = -1;
    private int _lastHoverGpu = -1, _lastHoverCpu = -1;
    private DateTime _lastHoverDraw = DateTime.MinValue;
    private bool _exitFlag;

    // game mode
    private GameDetect.Hit _game;
    private DateTime _gameStart = DateTime.Now;
    private DateTime _scanAt = DateTime.MinValue;
    private readonly List<string> _tail = new List<string>();
    private int _powerCapCount;
    private int _lastClock;
    private int _lastUtil;
    private int _sessionCount;
    private double _ramGb;

    public MainForm(string root, string tag, bool startHidden = false)
    {
        _root = root;
        _tag = tag;
        // 先关掉自动缩放，再设尺寸；否则 WinForms 会按 DPI 反向缩放一次
        AutoScaleMode = AutoScaleMode.None;
        AutoScaleDimensions = new SizeF(96f, 96f);
        // 必须在有窗口句柄/桌面 DC 上取 DPI，控件未创建时拿到的是 96
        using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) _dpi = g.DpiX / 96f;
        if (_dpi < 1f) _dpi = 1f;

        _store = new Storage(root);
        Text = I18n.T("AppTitle", "游戏崩溃诊断器") + (string.IsNullOrEmpty(tag) ? "" : "  [" + tag + "]");
        ClientSize = new Size(S(760), S(620));
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = CBg;
        ForeColor = CText;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        DoubleBuffered = true;
        Font = new Font("Microsoft YaHei UI", 9f);
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

        BuildUi();
        LoadRules();
        ApplyDarkTitleBar();

        _timer = new Timer();
        _timer.Interval = 500;
        _timer.Tick += (s, e) => Tick();


        Load += (s, e) =>
        {
            // 句柄创建后 WinForms 会按 DPI 再缩放一次，这里强制回到设计尺寸
            if (ClientSize.Width != S(760)) ClientSize = new Size(S(760), S(620));
            if (startHidden) BeginInvoke(new Action(HideToTray));
            _cpu.Prime();
            RestoreHistory();
            _store.StartLog("system", 500);
            _timer.Start();
        };
        FormClosing += OnClosing;
        Resize += (s, e) => { if (WindowState == FormWindowState.Minimized) HideToTray(); };
    }

    public float DpiScale { get { return _dpi; } }

    private int S(float v) { return (int)Math.Round(v * _dpi); }

    // ── layout ──────────────────────────────────────────────────
    private void BuildUi()
    {
        var btnMenu = new Button();
        btnMenu.Text = "☰";
        btnMenu.Font = new Font("Segoe UI Symbol", 13f);
        btnMenu.FlatStyle = FlatStyle.Flat;
        btnMenu.FlatAppearance.BorderSize = 0;
        btnMenu.ForeColor = CText;
        btnMenu.BackColor = CCard;
        btnMenu.Bounds = new Rectangle(S(6), S(8), S(38), S(34));
        Controls.Add(btnMenu);

        _lblTitle = MakeLabel(I18n.T("AppTitle", "游戏崩溃诊断器"), new Point(S(52), S(2)), 17f, CText, true);
        _lblGpuName = MakeLabel("GPU", new Point(S(8), S(38)), 9.5f, CDim, false);
        _lblStatus = MakeLabel("● --", new Point(S(620), S(12)), 9f, CAccent, false);
        _lblStatus.AutoSize = false;
        _lblStatus.Size = new Size(S(134), S(22));
        _lblStatus.TextAlign = ContentAlignment.MiddleRight;

        _lblCpuName = MakeLabel("CPU", new Point(S(8), S(250)), 10f, CDim, false);

        // GPU cards
        var cardTemp = MakeCard(S(6), S(66));
        var cardPower = MakeCard(S(196), S(66));
        var cardClock = MakeCard(S(386), S(66));
        var cardUtil = MakeCard(S(576), S(66));
        var cardCpuTemp = MakeCard(S(6), S(270));
        var cardCpuClock = MakeCard(S(196), S(270));
        var cardCpuUtil = MakeCard(S(386), S(270));
        var cardCores = MakeCard(S(576), S(270));

        _valTemp = MakeBigValue(cardTemp);
        _valPower = MakeBigValue(cardPower);
        _valClock = MakeBigValue(cardClock);
        _valUtil = MakeBigValue(cardUtil);
        _valCpuTemp = MakeBigValue(cardCpuTemp);
        _valCpuClock = MakeBigValue(cardCpuClock);
        _valCpuUtil = MakeBigValue(cardCpuUtil);
        _valCpuCores = MakeBigValue(cardCores);

        AddCardText(cardTemp, I18n.T("CardTemp", "温度"), "°C", 146);
        AddCardText(cardPower, I18n.T("CardPower", "功耗"), "W", 146);
        AddCardText(cardClock, I18n.T("CardClock", "核心频率"), "MHz", 140);
        AddCardText(cardUtil, I18n.T("CardUtil", "GPU 占用"), "%", 150);
        AddCardText(cardCpuTemp, I18n.T("CardCpuTemp", "CPU 温度"), "°C", 146);
        AddCardText(cardCpuClock, I18n.T("CardCpuClock", "CPU 频率"), "MHz", 136);
        AddCardText(cardCpuUtil, I18n.T("CardCpuUtil", "CPU 占用"), "%", 150);
        AddCardText(cardCores, I18n.T("CardCores", "活跃核心"), "", 150);

        _chart = MakeChart(S(6), S(146), true);
        _cpuChart = MakeChart(S(6), S(350), false);

        // scrollbar
        _barTrack = new Panel();
        _barTrack.BackColor = Color.FromArgb(46, 46, 56);
        _barTrack.Bounds = new Rectangle(S(6), S(452), S(748), S(10));
        _barThumb = new Panel();
        _barThumb.BackColor = Color.FromArgb(112, 112, 126);
        _barThumb.Bounds = new Rectangle(0, S(2), S(120), S(6));
        _barTrack.Controls.Add(_barThumb);
        Controls.Add(_barTrack);

        _lblDetail = MakeLabel("", new Point(S(6), S(470)), 9f, CDim, false);
        _lblStats = MakeLabel("", new Point(S(6), S(494)), 9f, CDim, false);
        _lblHint = MakeLabel("", new Point(S(6), S(518)), 9f, CDim, false);
        _lblVer = MakeLabel("", new Point(S(6), S(586)), 8f, Color.FromArgb(96, 96, 108), false);

        _tip = new Label();
        _tip.AutoSize = true;
        _tip.Visible = false;
        _tip.BackColor = Color.FromArgb(44, 44, 52);
        _tip.ForeColor = Color.FromArgb(226, 226, 234);
        _tip.Font = new Font("Microsoft YaHei UI", 9f);
        _tip.Padding = new Padding(S(6), S(3), S(6), S(3));
        _tip.BorderStyle = BorderStyle.FixedSingle;
        Controls.Add(_tip);

        _menu = new ContextMenuStrip();
        var miLog = _menu.Items.Add(I18n.T("MenuLogs", "打开数据目录"));
        miLog.Click += (s, e) => OpenPath(_store.LogDir);
        var miRep = _menu.Items.Add(I18n.T("MenuReports", "打开崩溃报告"));
        miRep.Click += (s, e) => OpenPath(Path.Combine(_root, "reports"));
        _menu.Items.Add(new ToolStripSeparator());
        var miClear = _menu.Items.Add(I18n.T("ClearChart", "清空曲线（只清屏幕上的）"));
        miClear.Click += (s, e) => { _tTime.Clear(); _gTemp.Clear(); _gPower.Clear(); _cTime.Clear(); _cTemp.Clear(); _cFreq.Clear(); Draw(); };
        var miDiag = _menu.Items.Add(I18n.T("MenuDiag", "诊断报告"));
        miDiag.Click += (s, e) => ShowDiagnosis();
        var miAuto = _menu.Items.Add(I18n.T("MenuAuto", "开机自动启动"));
        miAuto.Click += (s, e) => ToggleAutoStart(miAuto);
        _menu.Items.Add(new ToolStripSeparator());
        var miExit = _menu.Items.Add(I18n.T("TrayExit", "退出"));
        miExit.Click += (s, e) => { _exitFlag = true; Close(); };

        btnMenu.Click += (s, e) => _menu.Show(btnMenu, new Point(0, btnMenu.Height));

        _tray = new NotifyIcon();
        try { _tray.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        _tray.Text = Text;
        _tray.Visible = true;
        _tray.DoubleClick += (s, e) => ShowFromTray();
        var trayMenu = new ContextMenuStrip();
        trayMenu.Items.Add(I18n.T("TrayShow", "显示")).Click += (s, e) => ShowFromTray();
        trayMenu.Items.Add(I18n.T("TrayExit", "退出")).Click += (s, e) => { _exitFlag = true; Close(); };
        _tray.ContextMenuStrip = trayMenu;

        _timer = new Timer();
        _timer.Interval = 500;
    }

    private Label MakeLabel(string text, Point pos, float size, Color color, bool bold)
    {
        var l = new Label();
        l.Text = text;
        l.AutoSize = true;
        l.Location = pos;
        l.ForeColor = color;
        l.BackColor = Color.Transparent;
        l.Font = new Font("Microsoft YaHei UI", size, bold ? FontStyle.Bold : FontStyle.Regular);
        Controls.Add(l);
        return l;
    }

    private Panel MakeCard(int x, int y)
    {
        var p = new Panel();
        p.Bounds = new Rectangle(x, y, S(178), S(74));
        p.BackColor = CCard;
        Controls.Add(p);
        return p;
    }

    private Label MakeBigValue(Panel card)
    {
        var l = new Label();
        l.Text = "--";
        l.AutoSize = true;
        l.Location = new Point(S(8), S(20));
        l.ForeColor = CAccent;
        l.BackColor = Color.Transparent;
        l.Font = new Font("Microsoft YaHei UI", 22f, FontStyle.Bold);
        card.Controls.Add(l);
        return l;
    }

    private void AddCardText(Panel card, string title, string unit, int unitX)
    {
        var t = new Label();
        t.Text = title;
        t.AutoSize = true;
        t.Location = new Point(S(10), S(5));
        t.ForeColor = CDim;
        t.BackColor = Color.Transparent;
        t.Font = new Font("Microsoft YaHei UI", 8.5f);
        card.Controls.Add(t);
        if (!string.IsNullOrEmpty(unit))
        {
            var u = new Label();
            u.Text = unit;
            u.AutoSize = true;
            u.Location = new Point(S(unitX), S(11));
            u.ForeColor = CDim;
            u.BackColor = Color.Transparent;
            u.Font = new Font("Microsoft YaHei UI", 8.5f);
            card.Controls.Add(u);
        }
    }

    private PictureBox MakeChart(int x, int y, bool isGpu)
    {
        var p = new PictureBox();
        p.Bounds = new Rectangle(x, y, S(748), S(96));
        p.BackColor = CCard;
        p.SizeMode = PictureBoxSizeMode.Normal;
        p.MouseMove += (s, e) => OnChartHover(p, e, isGpu);
        p.MouseLeave += (s, e) => { _hoverGpu = -1; _hoverCpu = -1; if (_tip != null) _tip.Visible = false; Draw(); };
        Controls.Add(p);
        return p;
    }

    // ── data loop ───────────────────────────────────────────────
    private void Tick()
    {
        try { TickCore(); }
        catch (Exception ex)
        {
            try { File.WriteAllText(Path.Combine(Path.GetTempPath(), "v6-tick-error.txt"), DateTime.Now.ToString("HH:mm:ss") + " " + ex); } catch { }
        }
    }

    private void TickCore()
    {
        var s = TakeSample();
        if (s.GpuTemp <= 0 && s.CpuMhz <= 0) { _lblStatus.Text = "✕ 读取失败"; _lblStatus.ForeColor = CBad; return; }

        int keep = _maxPoints + 600;
        _tTime.Add(s.Time); _gTemp.Add(s.GpuTemp); _gPower.Add(s.GpuPower);
        _cTime.Add(s.Time); _cTemp.Add(s.CpuTemp); _cFreq.Add(s.CpuMhz);
        if (_tTime.Count > keep)
        {
            int drop = _tTime.Count - _maxPoints;
            _tTime.RemoveRange(0, drop); _gTemp.RemoveRange(0, drop); _gPower.RemoveRange(0, drop);
            _cTime.RemoveRange(0, drop); _cTemp.RemoveRange(0, drop); _cFreq.RemoveRange(0, drop);
        }

        _store.AppendHistory(s);
        _sessionCount++;
        if ((s.Throttle & 0x1UL) != 0) _powerCapCount++;
        try
        {
            string csvLine = _store.AppendCsv(s);
            if (!string.IsNullOrEmpty(csvLine))
            {
                _tail.Add(csvLine);
                if (_tail.Count > 200) _tail.RemoveRange(0, _tail.Count - 200);
            }
        }
        catch { }
        CheckGame();

        _lastClock = s.ClockSm;
        _lastUtil = s.UtilGpu;
        _valTemp.Text = Fmt(s.GpuTemp, "0.0");
        _valPower.Text = Fmt(s.GpuPower, "0");
        _valClock.Text = s.ClockSm.ToString("N0");
        _valUtil.Text = s.UtilGpu.ToString();
        _valTemp.ForeColor = s.GpuTemp >= 85 ? CBad : (s.GpuTemp >= 75 ? CWarn : CAccent);

        _valCpuTemp.Text = s.CpuTemp > 0 ? Fmt(s.CpuTemp, "0") : "--";
        _valCpuClock.Text = s.CpuMhz.ToString("N0");
        _valCpuUtil.Text = s.CpuLoad.ToString();
        _valCpuCores.Text = s.ActiveCores + "/" + s.TotalCores;
        _valCpuTemp.ForeColor = s.CpuTemp >= 95 ? CBad : (s.CpuTemp >= 85 ? CWarn : CAccent);
        _valCpuUtil.ForeColor = s.CpuLoad >= 90 ? CBad : (s.CpuLoad >= 70 ? CWarn : CAccent);

        if (_ramGb <= 0) _ramGb = TotalRamGb();
        _lblDetail.Text = string.Format("显存 {0:N0} / {1} MB     系统内存 {2}%  {3}G/{4}G      GPU降频 {5}      性能档 {6}",
            s.MemUsedMb, s.MemTotalMb > 0 ? s.MemTotalMb.ToString("N0") : "--", (int)s.RamPct,
            Math.Round(s.RamPct / 100.0 * _ramGb, 1), _ramGb,
            ThrottleText(s.Throttle), PStateText(s.PState));

        _lblStats.Text = string.Format("{0} {1:N0}{2}    {3} 0    {4} {5}",
            I18n.T("RowLogCount", "已记录"), _sessionCount, I18n.T("StatsThis", "（本次）"),
            I18n.T("RowReports", "报告"), I18n.T("RowFile", "文件"), Path.GetFileName(_store.LogFile));

        _lblStatus.Text = "● " + I18n.T("StatusRec", "记录中");
        _lblStatus.ForeColor = CAccent;
        _lblHint.Text = I18n.T("HintNoGame", "未检测到游戏，正在做系统监控（logs\\system\\）");

        if (_followLive) _shiftPts = 0;
        Draw();
    }

    private void ApplyDarkTitleBar()
    {
        try
        {
            int on = 1;
            // 20 = DWMWA_USE_IMMERSIVE_DARK_MODE (Windows 10 2004+), 19 = older builds
            if (DwmSetWindowAttribute(Handle, 20, ref on, sizeof(int)) != 0)
                DwmSetWindowAttribute(Handle, 19, ref on, sizeof(int));
        }
        catch { }
    }

    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    private double ReadAcpiTemp()
    {
        try
        {
            var q = new System.Management.ManagementObjectSearcher(
                "SELECT HighPrecisionTemperature FROM Win32_PerfFormattedData_Counters_ThermalZoneInformation");
            double best = double.NaN;
            foreach (System.Management.ManagementObject mo in q.Get())
            {
                object v = mo["HighPrecisionTemperature"];
                if (v == null) continue;
                double raw = Convert.ToDouble(v);
                if (raw <= 2732) continue;
                double c = Math.Round(raw / 10.0 - 273.15, 1);
                if (double.IsNaN(best) || c > best) best = c;
            }
            return best;
        }
        catch { return double.NaN; }
    }

    private int PhysicalCores()
    {
        try
        {
            var q = new System.Management.ManagementObjectSearcher("SELECT NumberOfCores FROM Win32_Processor");
            foreach (System.Management.ManagementObject mo in q.Get())
            {
                object v = mo["NumberOfCores"];
                if (v != null) return Convert.ToInt32(v);
            }
        }
        catch { }
        return Math.Max(1, Environment.ProcessorCount / 2);
    }

    // ── game detection ──────────────────────────────────────────
    private void CheckGame()
    {
        if ((DateTime.Now - _scanAt).TotalSeconds < 1) return;
        _scanAt = DateTime.Now;

        GameDetect.Hit hit;
        try { hit = GameDetect.Find(); } catch { hit = null; }

        if (hit != null && _game == null)
        {
            _game = hit;
            _gameStart = hit.StartTime > DateTime.Now.AddDays(-1) ? hit.StartTime : DateTime.Now;
            _tail.Clear();
            _store.StartLog(SafeName(hit.Name), 500);
            _lblHint.Text = string.Format(I18n.T("HintGame", "已检测到游戏 {0}，正在记录到 logs\\{1}\\"),
                hit.Name, SafeName(hit.Name));
            _lblHint.ForeColor = CAccent;
        }
        else if (hit == null && _game != null)
        {
            var closed = _game;
            _game = null;
            DateTime exitTime = DateTime.Now;

            var verdict = CrashReport.Test(exitTime, closed.Name);
            var input = new CrashReport.ReportInput
            {
                IsCrash = verdict.IsCrash,
                Reason = verdict.Reason,
                GameName = closed.Name,
                Category = SafeName(closed.Name),
                StartTime = _gameStart,
                ExitTime = exitTime,
                TelemetryFile = _store.LogFile,
                TailRows = new List<string>(_tail)
            };
            string report = CrashReport.Write(_root, input);
            string snap = verdict.IsCrash
                ? CrashReport.SaveSnapshot(_root, _bmpFront, _bmpCpuFront)
                : "";

            _markers.Add(new Marker { Time = exitTime, Kind = verdict.IsCrash ? "crash" : "gap" });
            _store.SaveMarkers(_markers);

            _store.StartLog("system", 500);
            _tail.Clear();

            if (verdict.IsCrash)
            {
                _lblHint.Text = string.Format("⚠ 判定为崩溃（{0}），报告: {1}  已切回系统监控",
                    verdict.Reason, Path.GetFileName(report));
                _lblHint.ForeColor = CBad;
                try
                {
                    var card = new CrashCard("游戏崩溃诊断器",
                        string.Format("{0}  (依据: {1})", closed.Name, verdict.Reason), report, snap);
                    card.Show();
                }
                catch { }
            }
            else
            {
                _lblHint.Text = "游戏正常退出，记录已保存: " + Path.GetFileName(report) + "  已切回系统监控";
                _lblHint.ForeColor = CDim;
            }
        }
    }

    // ── crash flow self test (no real game needed) ──────────────
    public string RunCrashFlowTest()
    {
        var sb = new System.Text.StringBuilder();
        var fake = new GameDetect.Hit { Pid = 9999, Name = "testgame", Memory = 3L * 1024 * 1024 * 1024, StartTime = DateTime.Now };
        _game = fake;
        _gameStart = DateTime.Now.AddMinutes(-5);
        _tail.Clear();
        _store.StartLog("testgame", 500);
        sb.AppendLine("开始记录: " + Path.GetFileName(_store.LogFile));
        for (int i = 0; i < 8; i++)
        {
            var s = TakeSample();
            s.Time = DateTime.Now;
            string line = _store.AppendCsv(s);
            if (!string.IsNullOrEmpty(line)) _tail.Add(line);
            System.Threading.Thread.Sleep(200);
        }
        sb.AppendLine("已采集 " + _tail.Count + " 条");

        var verdict = CrashReport.Test(DateTime.Now, "testgame");
        var input = new CrashReport.ReportInput
        {
            IsCrash = verdict.IsCrash,
            Reason = verdict.Reason,
            GameName = fake.Name,
            Category = "testgame",
            StartTime = _gameStart,
            ExitTime = DateTime.Now,
            TelemetryFile = _store.LogFile,
            TailRows = new List<string>(_tail)
        };
        string report = CrashReport.Write(_root, input);
        sb.AppendLine("判定: " + (verdict.IsCrash ? "崩溃" : "正常退出") + "  依据: " + verdict.Reason);
        sb.AppendLine("报告: " + report);
        _markers.Add(new Marker { Time = DateTime.Now, Kind = verdict.IsCrash ? "crash" : "gap" });
        _store.SaveMarkers(_markers);
        sb.AppendLine("标记数: " + _markers.Count);
        _store.StartLog("system", 500);
        sb.AppendLine("已切回: " + Path.GetFileName(_store.LogFile));
        _game = null;
        return sb.ToString();
    }

    private static string SafeName(string name)
    {
        if (string.IsNullOrEmpty(name)) return "game";
        foreach (char c in Path.GetInvalidFileNameChars()) name = name.Replace(c, '_');
        return name.Trim();
    }

    private double TotalRamGb()
    {
        try
        {
            var searcher = new System.Management.ManagementObjectSearcher("SELECT TotalPhysicalMemory FROM Win32_ComputerSystem");
            foreach (System.Management.ManagementObject mo in searcher.Get())
                return Math.Round(Convert.ToUInt64(mo["TotalPhysicalMemory"]) / 1073741824.0, 0);
        }
        catch { }
        return 0;
    }

    private Sample TakeSample()
    {
        var s = new Sample();
        s.Time = DateTime.Now;
        _cpu.Read(out s.CpuMhz, out s.CpuLoad, out s.ActiveCores, out s.TotalCores, out s.RamPct);

        // CPU temperature from LibreHardwareMonitor, cached 5 s (it costs ~20 ms)
        if ((s.Time - _cpuTempAt).TotalSeconds >= 5)
        {
            double t = double.NaN;
            if (_lhmReady)
            {
                try { t = LhmBridge.ReadCpuTemp(); } catch { }
            }
            if (double.IsNaN(t) || t <= 0) t = ReadAcpiTemp();
            if (!double.IsNaN(t) && t > 0) _lastCpuTemp = Math.Round(t, 1);
            _cpuTempAt = s.Time;
        }
        s.CpuTemp = _lastCpuTemp;

        double gt, gp, mu, mt; int cs, cm, ug, um; string ps; ulong th;
        if (_nvmlReady && Nvml.Read(out gt, out gp, out cs, out cm, out ug, out um, out mu, out mt, out ps, out th))
        {
            s.GpuTemp = Math.Round(gt, 1); s.GpuPower = Math.Round(gp, 1);
            s.ClockSm = cs; s.ClockMem = cm; s.UtilGpu = ug; s.UtilMem = um;
            s.MemUsedMb = mu; s.MemTotalMb = mt; s.PState = ps; s.Throttle = th;
        }
        else if (_lhmReady)
        {
            try
            {
                double[] g = LhmBridge.ReadGpu();
                if (g != null && g.Length >= 8)
                {
                    if (!double.IsNaN(g[0])) s.GpuTemp = Math.Round(g[0], 1);
                    if (!double.IsNaN(g[1])) s.GpuPower = Math.Round(g[1], 1);
                    if (!double.IsNaN(g[2])) s.ClockSm = (int)g[2];
                    if (!double.IsNaN(g[3])) s.ClockMem = (int)g[3];
                    if (!double.IsNaN(g[4])) s.UtilGpu = (int)g[4];
                    if (!double.IsNaN(g[5])) s.MemUsedMb = g[5];
                    if (!double.IsNaN(g[6])) s.MemTotalMb = g[6];
                    s.PState = "-";
                }
            }
            catch { }
        }
        return s;
    }

    private bool _nvmlReady;

    private void RestoreHistory()
    {
        _markers.AddRange(_store.LoadMarkers());
        int n = _store.LoadHistory(6.0, _maxPoints, _tTime, _gTemp, _gPower, _cTemp, _cFreq);
        for (int i = 0; i < n; i++) _cTime.Add(_tTime[_tTime.Count - n + i]);
        if (n > 0)
            _lblHint.Text = I18n.T("HintNoGame", "未检测到游戏，正在做系统监控") +
                            string.Format(I18n.T("RestoredHint", "（接上次 {0} 点）"), n);
    }

    private void LoadRules()
    {
        _lblVer.Text = "v6.0  " + I18n.T("DataDir", "数据目录") + ": " + _root;
        _lblGpuName.Text = "GPU · " + (Nvml.Init() ? Nvml.DeviceName + "    驱动 " + Nvml.DriverVersion : "未检测到 NVIDIA 显卡");
        _nvmlReady = Nvml.IsReady;
        try
        {
            string lhmDir = Path.Combine(_root, "thirdparty", "lhm");
            string lhmDll = Path.Combine(lhmDir, "LibreHardwareMonitorLib.dll");
            string hidDll = Path.Combine(lhmDir, "HidSharp.dll");
            if (File.Exists(lhmDll) && File.Exists(hidDll))
            {
                System.Reflection.Assembly.LoadFrom(hidDll);
                System.Reflection.Assembly.LoadFrom(lhmDll);
                _lhmReady = LhmBridge.Init();
            }
        }
        catch { }
        _lblCpuName.Text = string.Format("CPU · {0}   {1} 核 / {2} 线程",
            CpuName(), PhysicalCores(), Environment.ProcessorCount);
    }

    private string CpuName()
    {
        try
        {
            var q = new System.Management.ManagementObjectSearcher("SELECT Name FROM Win32_Processor");
            foreach (System.Management.ManagementObject mo in q.Get()) return (mo["Name"] as string ?? "CPU").Trim();
        }
        catch { }
        return "CPU";
    }

    // ── drawing ─────────────────────────────────────────────────
    private void Draw()
    {
        int total = _tTime.Count;
        if (total < 1) return;
        int span = _spanPts;
        if (span > total) span = total;
        int maxShift = Math.Max(0, total - span);
        if (_shiftPts > maxShift) _shiftPts = maxShift;
        if (_shiftPts < 0) _shiftPts = 0;
        int to = total - _shiftPts;
        int from = Math.Max(0, to - span);
        int count = to - from;
        if (count < 2) return;

        double[] a = Slice(_gTemp, from, count);
        double[] b = Slice(_gPower, from, count);
        int n = Math.Min(a.Length, b.Length);
        if (n < 2) return;

        string info = string.Format("{0} · {1} · {2}",
            I18n.F("ChartPerPoint", "每 {0} 秒 1 点", 0.5),
            I18n.F("ChartPoints", "{0} 点", n),
            I18n.F("ChartMinutes", "{0} 分钟", Math.Round(n * 0.5 / 60.0, 1)));
        if (_shiftPts > 0)
            info = I18n.F("ChartPaused", "{0} ~ {1} · {2} 点（回看中）",
                _tTime[from].ToString("HH:mm:ss"), _tTime[to - 1].ToString("HH:mm:ss"), n);

        double mnA = Min(a), mxA = Max(a), mnB = Min(b), mxB = Max(b);
        string labA = string.Format("{0}   最高 {1:N0}  最低 {2:N0}", I18n.T("LegendGpuTemp", "GPU 温度 °C"), mxA, mnA);
        string labB = string.Format("{0}   最高 {1:N0}  最低 {2:N0}", I18n.T("LegendPower", "功耗 W"), mxB, mnB);

        EnsureBitmaps();
        if (_bmpBack == null) return;
        int hov = -1;
        if (_hoverGpu >= 0 && _hoverGpu < n) hov = _hoverGpu;
        ChartRenderer.Render(_bmpBack, a, b, n, CCard, CGrid, CAccent, CPower, CDim, info, labA, labB, "°C", "W", hov);
        DrawMarkers(_bmpBack, from, n);
        var tmp = _bmpFront; _bmpFront = _bmpBack; _bmpBack = tmp;
        _chart.Image = _bmpFront;

        // CPU chart
        double[] ca = Slice(_cTemp, from, count);
        double[] cb = Slice(_cFreq, from, count);
        int cn = Math.Min(ca.Length, cb.Length);
        if (cn >= 2)
        {
            string cinfo = string.Format("{0} · {1} · {2}",
                I18n.F("ChartPerPoint", "每 {0} 秒 1 点", 0.5),
                I18n.F("ChartPoints", "{0} 点", cn),
                I18n.F("ChartMinutes", "{0} 分钟", Math.Round(cn * 0.5 / 60.0, 1)));
            if (_shiftPts > 0)
                cinfo = I18n.F("ChartPaused", "{0} ~ {1} · {2} 点（回看中）",
                    _cTime[from].ToString("HH:mm:ss"), _cTime[to - 1].ToString("HH:mm:ss"), cn);
            string clabA = string.Format("{0}   最高 {1:N0}  最低 {2:N0}", I18n.T("LegendCpuTemp", "CPU 温度 °C"), Max(ca), Min(ca));
            string clabB = string.Format("{0}   最高 {1:N0}  最低 {2:N0}", I18n.T("LegendFreq", "频率 MHz"), Max(cb), Min(cb));
            int chov = (_hoverCpu >= 0 && _hoverCpu < cn) ? _hoverCpu : -1;
            ChartRenderer.Render(_bmpCpuBack, ca, cb, cn, CCard, CGrid, CAccent, CFreq, CDim, cinfo, clabA, clabB, "°C", "MHz", chov);
            DrawMarkers(_bmpCpuBack, from, cn);
            var tmp2 = _bmpCpuFront; _bmpCpuFront = _bmpCpuBack; _bmpCpuBack = tmp2;
            _cpuChart.Image = _bmpCpuFront;
        }

        UpdateScrollbar(total, span);
    }

    private void EnsureBitmaps()
    {
        if (_bmpFront == null || _bmpFront.Width != _chart.Width || _bmpFront.Height != _chart.Height)
        {
            if (_bmpFront != null) _bmpFront.Dispose();
            if (_bmpBack != null) _bmpBack.Dispose();
            _bmpFront = new Bitmap(_chart.Width, _chart.Height);
            _bmpBack = new Bitmap(_chart.Width, _chart.Height);
        }
        if (_bmpCpuFront == null || _bmpCpuFront.Width != _cpuChart.Width || _bmpCpuFront.Height != _cpuChart.Height)
        {
            if (_bmpCpuFront != null) _bmpCpuFront.Dispose();
            if (_bmpCpuBack != null) _bmpCpuBack.Dispose();
            _bmpCpuFront = new Bitmap(_cpuChart.Width, _cpuChart.Height);
            _bmpCpuBack = new Bitmap(_cpuChart.Width, _cpuChart.Height);
        }
    }

    private void DrawMarkers(Bitmap bmp, int from, int count)
    {
        if (_markers.Count == 0 || count < 2) return;
        try
        {
            using (var g = Graphics.FromImage(bmp))
            {
                var font = new Font("Microsoft YaHei UI", 7f);
                foreach (var m in _markers)
                {
                    DateTime t0 = _tTime[from];
                    DateTime t1 = _tTime[from + count - 1];
                    if (m.Time < t0 || m.Time > t1) continue;
                    int idx = -1;
                    for (int q = from; q < from + count; q++) { if (_tTime[q] >= m.Time) { idx = q; break; } }
                    if (idx < 0) continue;
                    float frac = (idx - from) / (float)(count - 1);
                    float x = 6f + frac * (bmp.Width - 12);
                    Color col = m.Kind == "crash" ? Color.FromArgb(220, 235, 90, 90)
                              : m.Kind == "down" ? Color.FromArgb(220, 232, 150, 70)
                              : Color.FromArgb(120, 150, 150, 172);
                    using (var pen = new Pen(col, m.Kind == "gap" ? 1f : 1.6f))
                    {
                        if (m.Kind == "gap") pen.DashStyle = DashStyle.Dash;
                        g.DrawLine(pen, x, 4, x, bmp.Height - 4);
                    }
                    string txt = m.Kind == "crash" ? I18n.T("MarkerCrash", "崩溃")
                               : m.Kind == "down" ? I18n.T("MarkerDown", "宕机")
                               : I18n.T("MarkerGap", "中断");
                    using (var brush = new SolidBrush(col))
                    {
                        SizeF sz = g.MeasureString(txt, font);
                        float tx = x - sz.Width - 4;
                        if (tx < 2) tx = x + 4;
                        g.DrawString(txt, font, brush, tx, bmp.Height - 18);
                    }
                }
                font.Dispose();
            }
        }
        catch { }
    }

    private void UpdateScrollbar(int total, int span)
    {
        if (total <= span) { _barTrack.Visible = false; return; }
        _barTrack.Visible = true;
        int w = _barTrack.Width;
        int tw = Math.Max(S(28), (int)Math.Round(w * (span / (double)total)));
        if (tw > w) tw = w;
        if (_barThumb.Width != tw) _barThumb.Width = tw;
        int travel = Math.Max(0, w - tw);
        int scrollable = Math.Max(1, total - span);
        int pos = (int)Math.Round(travel * (1 - Math.Min(1.0, _shiftPts / (double)scrollable)));
        _barThumb.Left = pos;
        _barTrack.BringToFront();
    }

    private void OnChartHover(PictureBox box, MouseEventArgs e, bool isGpu)
    {
        int total = _tTime.Count;
        if (total < 2) return;
        int span = Math.Min(_spanPts, total);
        int to = total - _shiftPts;
        int from = Math.Max(0, to - span);
        int count = to - from;
        if (count < 2) return;
        double usable = box.Width - 12.0;
        double frac = (e.X - 6.0) / usable;
        if (frac < 0) frac = 0; if (frac > 1) frac = 1;
        int idx = (int)Math.Round(frac * (count - 1));
        if (isGpu) _hoverGpu = idx; else _hoverCpu = idx;

        // 提示框：贴着鼠标显示该点的数值与时刻
        int abs = from + idx;
        string txt;
        if (isGpu)
        {
            double t = abs < _gTemp.Count ? _gTemp[abs] : 0;
            double pw = abs < _gPower.Count ? _gPower[abs] : 0;
            string when = abs < _tTime.Count ? _tTime[abs].ToString("HH:mm:ss") : "";
            txt = string.Format("温度 {0:0.0}°C   功耗 {1:0}W   {2}", t, pw, when);
        }
        else
        {
            double t = abs < _cTemp.Count ? _cTemp[abs] : 0;
            double f2 = abs < _cFreq.Count ? _cFreq[abs] : 0;
            string when = abs < _cTime.Count ? _cTime[abs].ToString("HH:mm:ss") : "";
            txt = string.Format("温度 {0:0}°C   频率 {1:0}MHz   {2}", t, f2, when);
        }
        _tip.Text = txt;
        Size sz = TextRenderer.MeasureText(txt, _tip.Font);
        int tipW = sz.Width + S(14);
        int tipH = sz.Height + S(8);
        int tipX = box.Left + e.X + S(14);
        if (tipX + tipW > ClientSize.Width - S(4)) tipX = box.Left + e.X - tipW - S(10);
        if (tipX < S(2)) tipX = S(2);
        int tipY = box.Top + e.Y - tipH - S(6);
        if (tipY < S(2)) tipY = box.Top + e.Y + S(18);
        _tip.Bounds = new Rectangle(tipX, tipY, tipW, tipH);
        _tip.Visible = true;
        _tip.BringToFront();

        // 只在悬停位置真的变了、且距上次重画超过 50ms 时才重画，避免鼠标一动就卡
        bool moved = (isGpu ? _lastHoverGpu : _lastHoverCpu) != idx;
        _lastHoverGpu = isGpu ? idx : _lastHoverGpu;
        _lastHoverCpu = isGpu ? _lastHoverCpu : idx;
        if (moved && (DateTime.Now - _lastHoverDraw).TotalMilliseconds >= 50)
        {
            _lastHoverDraw = DateTime.Now;
            Draw();
        }
    }

    // ── helpers ─────────────────────────────────────────────────
    private static string Fmt(double v, string f) { return v.ToString(f, CultureInfo.InvariantCulture); }
    private static double[] Slice(List<double> src, int from, int count)
    {
        var arr = new double[count];
        for (int i = 0; i < count; i++) arr[i] = src[from + i];
        return arr;
    }
    private static double Min(double[] a) { double m = a[0]; for (int i = 1; i < a.Length; i++) if (a[i] < m) m = a[i]; return m; }
    private static double Max(double[] a) { double m = a[0]; for (int i = 1; i < a.Length; i++) if (a[i] > m) m = a[i]; return m; }

    private string ThrottleText(ulong mask)
    {
        // P8/P5 待机时 NVIDIA 也会置功耗墙标志位，这时显示"待机"更有意义
        if (_lastClock < 600 && _lastUtil < 5) return I18n.T("ThrottleIdle", "待机");
        if ((mask & 0x1UL) != 0) return I18n.T("ThrottlePower", "功耗墙");
        if ((mask & 0x4UL) != 0) return I18n.T("ThrottleThermal", "温度墙");
        if ((mask & 0x2UL) != 0) return I18n.T("ThrottleHw", "硬件降频");
        return I18n.T("ThrottleNone", "正常");
    }

    private string PStateText(string ps)
    {
        if (ps == "P0") return I18n.T("PStateFull", "P0 满速");
        if (ps == "-" || string.IsNullOrEmpty(ps)) return "-";
        return ps;
    }

    private void OpenPath(string path)
    {
        try { Directory.CreateDirectory(path); Process.Start("explorer.exe", "\"" + path + "\""); } catch { }
    }

    // ── diagnosis dialog ────────────────────────────────────────
    private void ShowDiagnosis()
    {
        var dlg = new TextDialog("诊断报告 - 游戏崩溃诊断器", BuildDiagnosisText(), false, null);
        dlg.ShowDialog(this);
    }

    /// <summary>Renders the whole window to a PNG (used by -Shot for verification).</summary>
    public void CapturePng(string path)
    {
        try
        {
            CreateControl();
            foreach (Control c in Controls) c.CreateControl();
            using (var bmp = new Bitmap(Width, Height))
            {
                DrawToBitmap(bmp, new Rectangle(0, 0, Width, Height));
                bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            }
        }
        catch { }
    }

    public string BuildDiagnosisText()
    {
        _cpu.Prime();
        System.Threading.Thread.Sleep(350);
        var d = new Diagnosis.Input();
        d.GpuName = Nvml.IsReady ? Nvml.DeviceName : "未检测到 NVIDIA 显卡";
        d.Driver = !string.IsNullOrEmpty(Nvml.DriverVersion) ? Nvml.DriverVersion : DriverVersion();
        d.CpuName = CpuName();
        d.Cores = PhysicalCores();
        d.Threads = Environment.ProcessorCount;
        d.RamGb = _ramGb > 0 ? _ramGb : TotalRamGb();
        d.OsName = OsName();
        d.Version = "v6.0 (C#)";
        d.Now = TakeSample();
        d.Samples = _tTime.Count;
        foreach (double v in _gTemp)
        {
            if (v > d.MaxTemp) d.MaxTemp = v;
            if (v < d.MinTemp) d.MinTemp = v;
        }
        foreach (double v in _gPower) if (v > d.MaxPower) d.MaxPower = v;
        foreach (double v in new List<double>()) { }
        d.Markers = new List<Marker>(_markers);
        d.PowerCapSamples = _powerCapCount;

        string text = Diagnosis.Build(d);
        return text;
    }

    private string DriverVersion()
    {
        try
        {
            var q = new System.Management.ManagementObjectSearcher(
                "SELECT DriverVersion FROM Win32_VideoController WHERE Name LIKE '%NVIDIA%'");
            foreach (System.Management.ManagementObject mo in q.Get())
            {
                object v = mo["DriverVersion"];
                if (v != null) return v.ToString();
            }
        }
        catch { }
        return "?";
    }

    private string OsName()
    {
        try
        {
            var q = new System.Management.ManagementObjectSearcher("SELECT Caption, Version FROM Win32_OperatingSystem");
            foreach (System.Management.ManagementObject mo in q.Get())
            {
                string cap = (mo["Caption"] as string ?? "").Trim();
                string ver = mo["Version"] as string ?? "";
                return cap + "  " + ver;
            }
        }
        catch { }
        return "?";
    }

    // ── autostart ───────────────────────────────────────────────
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunName = "GameCrashDiag6";

    private void ToggleAutoStart(ToolStripItem item)
    {
        if (!string.IsNullOrEmpty(_tag))
        {
            MessageBox.Show("测试副本不注册开机自启，避免顶掉正式版。", Text);
            return;
        }
        try
        {
            using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey, true))
            {
                if (key == null) return;
                if (key.GetValue(RunName) != null)
                {
                    key.DeleteValue(RunName, false);
                    MessageBox.Show("已关闭开机自动启动。", Text);
                }
                else
                {
                    key.SetValue(RunName, "\"" + Application.ExecutablePath + "\" -Tray");
                    MessageBox.Show("已开启开机自动启动（启动后进托盘）。", Text);
                }
            }
        }
        catch (Exception ex) { MessageBox.Show("修改失败: " + ex.Message, Text); }
    }

    private void HideToTray()
    {
        Hide();
        _tray.BalloonTipTitle = Text;
        _tray.BalloonTipText = I18n.T("TrayBalloon", "已缩到托盘，仍在后台记录");
        try { _tray.ShowBalloonTip(1200); } catch { }
    }

    private void ShowFromTray()
    {
        Show();
        WindowState = FormWindowState.Normal;
        Activate();
    }

    private void OnClosing(object sender, FormClosingEventArgs e)
    {
        if (!_exitFlag && e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            HideToTray();
            return;
        }
        _timer.Stop();
        _store.SaveMarkers(_markers);
        if (_tray != null) { _tray.Visible = false; _tray.Dispose(); }
        try { LhmBridge.Close(); } catch { }
        try { Nvml.Shutdown(); } catch { }
        _cpu.Dispose();
    }
}
