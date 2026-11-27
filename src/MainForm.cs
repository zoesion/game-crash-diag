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

    public const string AppVersion = "v6.0";

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
    private string _cpuTempSource = "";
    private double _cpuPower;
    private bool _tsRunning = true;
    private DateTime _tsChecked = DateTime.MinValue;
    private int _lastCpuFreq = 0;
    private DateTime _cpuTempAt = DateTime.MinValue;
    private bool _lhmReady;

    // controls
    private Label _lblGpuName, _lblStatus, _lblDetail, _lblStats, _lblHint, _lblVer, _lblCpuName, _lblTitle;
    private Label _tip;
    private ToolStripItem _miStart;
    private Label[] _unitLabels;
    private Label _valTemp, _valPower, _valClock, _valUtil;
    private Label _valCpuTemp, _valCpuClock, _valCpuUtil, _valCpuCores;
    private PictureBox _chart, _cpuChart;
    private Panel _barTrack, _barThumb;
    private NotifyIcon _tray;
    private ContextMenuStrip _trayMenu;
    private ContextMenuStrip _menu;
    private Bitmap _bmpFront, _bmpBack, _bmpCpuFront, _bmpCpuBack;
    private int _hoverGpu = -1, _hoverCpu = -1;
    private int _lastHoverGpu = -1, _lastHoverCpu = -1;
    private DateTime _lastHoverDraw = DateTime.MinValue;
    // 滚动条拖动
    private bool _barDrag;
    private int _barDragX;
    private int _barDragLeft;
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
    // 温度基线：不打游戏时累积，游戏内对比
    private readonly SessionStats _stats = new SessionStats();
    private double _idleGpuSum, _idleCpuSum;
    private int _idleCount;
    private double _gameGpuSum, _gameCpuSum, _gameGpuMax;
    private int _gameCount;

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

        ErrorCodes.Load(_root, I18n.Code);
        BuildUi();
        LoadRules();
        LoadLastSessionBanner();
        ApplyDarkTitleBar();

        // 启动 4 秒后把托盘图标设为"固定显示"，否则 Windows 11 会把它塞进隐藏区
        var promote = new Timer();
        promote.Interval = 4000;
        promote.Tick += (s, e) => { promote.Stop(); promote.Dispose(); PromoteTrayIcon(); };
        promote.Start();

        _timer = new Timer();
        _timer.Interval = 500;
        _timer.Tick += (s, e) => Tick();


        LogLine("form load, tag=" + _tag);
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

        _lblTitle = MakeLabel(I18n.T("AppTitle", "游戏崩溃诊断器"), new Point(S(52), S(2)), 17f, CDim, true);
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
        _barTrack.BackColor = Color.FromArgb(68, 68, 82);
        _barTrack.Bounds = new Rectangle(S(6), S(450), S(748), S(12));
        _barThumb = new Panel();
        _barThumb.BackColor = Color.FromArgb(152, 152, 172);
        _barThumb.Bounds = new Rectangle(0, S(2), S(120), S(8));
        _barTrack.Controls.Add(_barThumb);
        Controls.Add(_barTrack);

        // 拖动手柄
        _barThumb.Cursor = Cursors.Hand;
        _barThumb.MouseDown += (s, e) =>
        {
            _barDrag = true;
            _barDragX = Cursor.Position.X;
            _barDragLeft = _barThumb.Left;
            _barThumb.BackColor = Color.FromArgb(190, 190, 210);
        };
        _barThumb.MouseMove += (s, e) =>
        {
            if (!_barDrag) return;
            int travel = Math.Max(1, _barTrack.Width - _barThumb.Width);
            int dx = Cursor.Position.X - _barDragX;
            int left = _barDragLeft + dx;
            if (left < 0) left = 0;
            if (left > travel) left = travel;
            _barThumb.Left = left;
            SetShiftFromThumb();
        };
        _barThumb.MouseUp += (s, e) =>
        {
            if (!_barDrag) return;
            _barDrag = false;
            _barThumb.BackColor = Color.FromArgb(152, 152, 172);
            Draw();
        };

        // 点击轨道空白处直接跳转
        _barTrack.MouseDown += (s, e) =>
        {
            int travel = Math.Max(1, _barTrack.Width - _barThumb.Width);
            int left = e.X - _barThumb.Width / 2;
            if (left < 0) left = 0;
            if (left > travel) left = travel;
            _barThumb.Left = left;
            SetShiftFromThumb();
            Draw();
        };

        // 鼠标滚轮在图上左右翻
        _chart.MouseWheel += (s, e) => ShiftView(e.Delta > 0 ? 1 : -1);
        _cpuChart.MouseWheel += (s, e) => ShiftView(e.Delta > 0 ? 1 : -1);

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
        _miStart = _menu.Items.Add(I18n.T("MenuStart", "开始记录"));
        _miStart.Click += (s, e) => ToggleLogging();
        var miLog = _menu.Items.Add(I18n.T("MenuLogs", "打开数据目录"));
        miLog.Click += (s, e) => OpenPath(_store.LogDir);
        var miLast = _menu.Items.Add(I18n.T("MenuLastReport", "打开最近一份报告"));
        miLast.Click += (s, e) => OpenLatestReport();
        var miRep = _menu.Items.Add(I18n.T("MenuReports", "打开报告目录（崩溃 / 对局）"));
        miRep.Click += (s, e) => OpenPath(Path.Combine(_root, "reports"));
        var miDiag = _menu.Items.Add(I18n.T("MenuDiag", "诊断报告"));
        miDiag.Click += (s, e) => ShowDiagnosis();
        _menu.Items.Add(new ToolStripSeparator());
        var miClear = new ToolStripMenuItem(I18n.T("MenuClear", "清空数据"));
        _menu.Items.Add(miClear);
        var miClearChart = miClear.DropDown.Items.Add(I18n.T("ClearChart", "清空曲线（只清屏幕上的）"));
        miClearChart.Click += (s, e) =>
        {
            _tTime.Clear(); _gTemp.Clear(); _gPower.Clear();
            _cTime.Clear(); _cTemp.Clear(); _cFreq.Clear();
            _sessionCount = 0;
            Draw();
        };
        var miClearAll = miClear.DropDown.Items.Add(I18n.T("ClearAll", "清空全部历史（删 logs / reports）"));
        miClearAll.Click += (s, e) => ClearAllData();
        _menu.Items.Add(new ToolStripSeparator());
        var miDx = _menu.Items.Add(I18n.T("MenuDx", "DirectX 检查"));
        miDx.Click += (s, e) => ShowDirectX();
        var miAuto = _menu.Items.Add(I18n.T("MenuAuto", "开机自动启动"));
        miAuto.Click += (s, e) => ToggleAutoStart(miAuto);
        var miLang = new ToolStripMenuItem(I18n.T("MenuLang", "语言 / Language"));
        _menu.Items.Add(miLang);
        var miZh = miLang.DropDown.Items.Add("简体中文");
        miZh.Click += (s, e) => SwitchLanguage("zh-CN");
        var miEn = miLang.DropDown.Items.Add("English");
        miEn.Click += (s, e) => SwitchLanguage("en-US");
        _menu.Items.Add(new ToolStripSeparator());
        var miCodes = _menu.Items.Add(I18n.T("MenuCodes", "错误码对照表"));
        miCodes.Click += (s, e) =>
        {
            var dlgCodes = new TextDialog("错误码对照表", ErrorCodes.Table(), false, null);
            dlgCodes.ShowDialog(this);
        };
        var miUpdate = _menu.Items.Add(I18n.T("MenuUpdate", "检查更新"));
        miUpdate.Click += (s, e) => CheckUpdates();
        var miElev = _menu.Items.Add(I18n.T("MenuElevate", "以管理员身份重启（可读 CPU 封装温度/功耗）"));
        miElev.Click += (s, e) => RestartElevated();
        if (IsElevated()) miElev.Text = I18n.T("MenuElevated", "已是管理员权限");
        var miUninst = _menu.Items.Add(I18n.T("MenuUninst", "卸载本程序"));
        miUninst.Click += (s, e) => RunUninstaller();
        var miAbout = _menu.Items.Add(I18n.T("MenuAbout", "关于"));
        miAbout.Click += (s, e) => ShowAbout();
        var miExit = _menu.Items.Add(I18n.T("TrayExit", "退出"));
        miExit.Click += (s, e) => { _exitFlag = true; Close(); };

        btnMenu.Click += (s, e) => _menu.Show(btnMenu, new Point(0, btnMenu.Height));

        _tray = new NotifyIcon();
        try
        {
            string icoFile = Path.Combine(_root, "app.ico");
            if (File.Exists(icoFile)) _tray.Icon = new Icon(icoFile);
        }
        catch { }
        if (_tray.Icon == null)
        {
            try { _tray.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        }
        if (_tray.Icon == null)
        {
            _tray.Icon = SystemIcons.Application;
            LogLine("tray icon fallback to system icon");
        }
        LogLine("tray initialised, icon=" + (_tray.Icon != null ? _tray.Icon.Width + "x" + _tray.Icon.Height : "null"));
        _tray.Text = Text;
        _tray.Visible = true;
        _tray.DoubleClick += (s, e) => ShowFromTray();
        _tray.MouseClick += (s, e) =>
        {
            if (e.Button == MouseButtons.Left) ShowFromTray();   // 右键菜单由 ContextMenuStrip 自动处理
        };
        var trayMenu = new ContextMenuStrip();
        trayMenu.Items.Add(I18n.T("TrayShow", "显示")).Click += (s, e) => ShowFromTray();
        trayMenu.Items.Add(I18n.T("TrayExit", "退出")).Click += (s, e) => { _exitFlag = true; Close(); };
        trayMenu.ShowImageMargin = false;
        _trayMenu = trayMenu;

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

    private static readonly object _logLock = new object();
    private DateTime _lastBeat = DateTime.MinValue;

    private void LogLine(string msg)
    {
        try
        {
            lock (_logLock)
            {
                string dir = Path.Combine(_root, "data");
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "session.log"),
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + msg + Environment.NewLine,
                    new System.Text.UTF8Encoding(false));
            }
        }
        catch { }
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

        if (_game == null)
        {
            if (s.GpuTemp > 0) { _idleGpuSum += s.GpuTemp; _idleCount++; }
            if (s.CpuTemp > 0) _idleCpuSum += s.CpuTemp;
        }
        else
        {
            if (s.GpuTemp > 0) { _gameGpuSum += s.GpuTemp; if (s.GpuTemp > _gameGpuMax) _gameGpuMax = s.GpuTemp; _gameCount++; }
            if (s.CpuTemp > 0) _gameCpuSum += s.CpuTemp;
            _stats.Add(s.GpuTemp, s.GpuPower, s.ClockSm, s.UtilGpu, s.MemUsedMb,
                       s.CpuTemp, s.CpuLoad, s.CpuMhz, s.ActiveCores, s.Throttle);
        }

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
        if (_cpuPower > 0)
            _lblDetail.Text += string.Format("   ·   CPU 功耗 {0:0}W", _cpuPower);
        if (!_tsRunning)
            _lblDetail.Text += I18n.T("TsMissing", "   ·   ⚠ ThrottleStop 未运行（功耗墙 200W，高温可能关机）");
        if (_cpuTempSource == "ACPI")
            _lblDetail.Text += I18n.T("TempAcpiHint", "   ·   温度源 ACPI");

        _lblStats.Text = string.Format("{0} {1:N0}{2}    {3} 0    {4} {5}",
            I18n.T("RowLogCount", "已记录"), _sessionCount, I18n.T("StatsThis", "（本次）"),
            I18n.T("RowReports", "报告"), I18n.T("RowFile", "文件"), Path.GetFileName(_store.LogFile));

        // 状态栏每帧刷新：游戏中提示游戏名和目录，否则提示系统监控
        if (_game != null)
        {
            double mins = Math.Max(0, (DateTime.Now - _gameStart).TotalMinutes);
            _lblStatus.Text = "● " + I18n.T("StatusGame", "游戏记录中");
            _lblStatus.ForeColor = CAccent;
            _lblHint.Text = string.Format(
                I18n.T("HintGameRun", "已记录 {0} 分钟 · {1} → logs\\{2}\\ · 退出游戏后自动生成会话报告"),
                (int)mins, _game.Name, SafeName(_game.Name));
            _lblHint.ForeColor = CAccent;
        }
        else
        {
            _lblStatus.Text = "● " + I18n.T("StatusRec", "记录中");
            _lblStatus.ForeColor = CAccent;
            _lblHint.Text = I18n.T("HintNoGame", "未检测到游戏，正在做系统监控（logs\\system\\）");
            _lblHint.ForeColor = CDim;
        }

        if ((DateTime.Now - _tsChecked).TotalSeconds >= 15)
        {
            _tsChecked = DateTime.Now;
            try
            {
                bool running = Process.GetProcessesByName("ThrottleStop").Length > 0;
                if (running != _tsRunning)
                {
                    _tsRunning = running;
                    LogLine("ThrottleStop running=" + running);
                }
            }
            catch { }
        }

        if ((DateTime.Now - _lastBeat).TotalSeconds >= 60)
        {
            _lastBeat = DateTime.Now;
            LogLine("alive samples=" + _sessionCount + " mem=" + (Environment.WorkingSet / 1048576) + "MB");
        }

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
            _gameGpuSum = 0; _gameCpuSum = 0; _gameGpuMax = 0; _gameCount = 0;
            _stats.Reset();
            ClearReportBanner();
            _tail.Clear();
            _store.StartLog(SafeName(hit.Name), 500);
            _lblHint.Text = string.Format(I18n.T("HintGame", "已检测到游戏 {0}，正在记录到 logs\\{1}\\"),
                hit.Name, SafeName(hit.Name));
            _lblHint.ForeColor = CAccent;
            LogLine("game start: " + hit.Name + " -> logs\\" + SafeName(hit.Name));
        }
        else if (hit == null && _game != null)
        {
            var closed = _game;
            _game = null;
            DateTime exitTime = DateTime.Now;
            LogLine("game end: " + closed.Name + " after " + Math.Round((exitTime - _gameStart).TotalMinutes, 1) + " min");

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
                TailRows = new List<string>(_tail),
                EventText = CrashReport.CollectEventText(exitTime.AddMinutes(-2)),
                IdleGpuTemp = _idleCount > 0 ? _idleGpuSum / _idleCount : 0,
                IdleCpuTemp = _idleCount > 0 ? _idleCpuSum / _idleCount : 0,
                GameGpuAvg = _gameCount > 0 ? _gameGpuSum / _gameCount : 0,
                GameGpuMax = _gameGpuMax,
                GameCpuAvg = _gameCount > 0 ? _gameCpuSum / _gameCount : 0,
                Stats = _stats
            };
            string report = CrashReport.Write(Path.Combine(Path.GetTempPath(), "gcd-test-reports"), input);
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
                    LogLine("crash card shown: " + Path.GetFileName(report));
                }
                catch { }
            }
            else
            {
                string tip = "";
                try
                {
                    var obs = _stats.Observations(exitTime - _gameStart);
                    if (obs.Count > 0) tip = "  注意：" + obs[0];
                }
                catch { }
                _lblHint.Text = "游戏正常退出，报告已生成: " + Path.GetFileName(report) + tip;
                _lblHint.ForeColor = CDim;
                try
                {
                    SaveLastSession(closed.Name, (exitTime - _gameStart).TotalMinutes,
                        _stats.CpuTempMax, _stats.GpuTempMax, _stats.VramMax, report);
                    ShowReportBanner(string.Format("✓ 对局结束 · {0} · {1} 分钟 · 报告 {2}（点此打开）",
                        closed.Name, Math.Round((exitTime - _gameStart).TotalMinutes),
                        Path.GetFileName(report)), report);
                    LogLine("session banner shown: " + Path.GetFileName(report));
                }
                catch { }
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
        string report = CrashReport.Write(Path.Combine(Path.GetTempPath(), "gcd-test-reports"), input);
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
            _cpuTempSource = (double.IsNaN(t) || t <= 0) ? "ACPI" : "封装";
            if (double.IsNaN(t) || t <= 0) t = ReadAcpiTemp();
            try
            {
                double cp = LhmBridge.ReadCpuPower();
                _cpuPower = double.IsNaN(cp) ? 0 : cp;
            }
            catch { _cpuPower = 0; }
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
        {
            LogLine("restored " + n + " points, last=" + _tTime[_tTime.Count - 1].ToString("yyyy-MM-dd HH:mm:ss") +
                    ", gapMin=" + Math.Round((DateTime.Now - _tTime[_tTime.Count - 1]).TotalMinutes, 1));
            _lblHint.Text = I18n.T("HintNoGame", "未检测到游戏，正在做系统监控") +
                            string.Format(I18n.T("RestoredHint", "（接上次 {0} 点）"), n);
            DateTime last = _tTime[_tTime.Count - 1];
            double mins = (DateTime.Now - last).TotalMinutes;
            // 每次接续都画一条分界线（哪怕只断了 10 秒），这样"上一次会话到今天"看得见
            bool dead = false;
            try { dead = CrashReport.DetectUncleanShutdown(last); } catch { }
            if (dead) LogLine("unclean shutdown detected around " + last.ToString("HH:mm:ss"));
            string note = dead ? "宕机"
                : (mins >= 60 ? "隔 " + Math.Round(mins / 60.0, 1) + " 小时"
                : (mins >= 2 ? "隔 " + (int)mins + " 分钟" : "续接"));
            _markers.Add(new Marker { Time = last, Kind = dead ? "down" : "gap", Note = note });
            LogLine("marker added: kind=" + (dead ? "down" : "gap") + " note=" + note + " gapMin=" + Math.Round(mins, 1));
            try { _store.SaveMarkers(_markers); } catch { }
            FixGapMarkersAfterUncleanShutdown();
        }
    }

    private void FixGapMarkersAfterUncleanShutdown()
    {
        try
        {
            bool changed = false;
            for (int i = 0; i < _markers.Count; i++)
            {
                Marker mk = _markers[i];
                if (mk.Kind != "gap") continue;
                if ((DateTime.Now - mk.Time).TotalMinutes > 60) continue;   // 只看最近一小时
                if (!CrashReport.DetectUncleanShutdown(mk.Time)) continue;
                mk.Kind = "down";
                mk.Note = "宕机";
                _markers[i] = mk;
                changed = true;
                LogLine("marker upgraded to down at " + mk.Time.ToString("HH:mm:ss"));
            }
            if (changed) _store.SaveMarkers(_markers);
        }
        catch { }
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
        ChartRenderer.MinSpanA = 10.0;    // 温度至少 10°C 跨度
        ChartRenderer.MinSpanB = 40.0;    // 功耗至少 40W 跨度
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
            ChartRenderer.MinSpanA = 10.0;   // 温度至少 10°C
            ChartRenderer.MinSpanB = 300.0;  // 频率至少 300MHz
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
                var labelRows = new List<Tuple<float, float, float>>();
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
                    string txt = !string.IsNullOrEmpty(m.Note) ? m.Note
                               : m.Kind == "crash" ? I18n.T("MarkerCrash", "崩溃")
                               : m.Kind == "down" ? I18n.T("MarkerDown", "宕机")
                               : I18n.T("MarkerGap", "中断");
                    using (var brush = new SolidBrush(col))
                    {
                        SizeF sz = g.MeasureString(txt, font);
                        float tx = x - sz.Width - 4;
                        if (tx < 2) tx = x + 4;
                        // 标签避让：挨得近的标记往上错开一行，避免文字叠在一起
                        float ty = bmp.Height - 18;
                        for (int row = 0; row < 4; row++)
                        {
                            bool clash = false;
                            foreach (var used in labelRows)
                            {
                                if (Math.Abs(used.Item2 - ty) < 1 && tx < used.Item3 && tx + sz.Width > used.Item1) { clash = true; break; }
                            }
                            if (!clash) break;
                            ty -= 13;
                        }
                        labelRows.Add(new Tuple<float, float, float>(tx, ty, tx + sz.Width));
                        g.DrawString(txt, font, brush, tx, ty);
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
        int tw = Math.Max(S(60), (int)Math.Round(w * (span / (double)total)));
        if (tw > w) tw = w;
        if (_barThumb.Width != tw) _barThumb.Width = tw;
        int travel = Math.Max(0, w - tw);
        int scrollable = Math.Max(1, total - span);
        int pos = (int)Math.Round(travel * (1 - Math.Min(1.0, _shiftPts / (double)scrollable)));
        _barThumb.Left = pos;
        _barTrack.BringToFront();
    }

    /// <summary>Thumb position -> view offset. Called while dragging or after a track click.</summary>
    private void SetShiftFromThumb()
    {
        int total = _tTime.Count;
        int span = Math.Min(_spanPts, Math.Max(1, total));
        int scrollable = Math.Max(0, total - span);
        int travel = Math.Max(1, _barTrack.Width - _barThumb.Width);
        double ratio = Math.Min(1.0, Math.Max(0.0, _barThumb.Left / (double)travel));
        _shiftPts = (int)Math.Round((1 - ratio) * scrollable);
        if (_shiftPts < 0) _shiftPts = 0;
        if (_shiftPts > scrollable) _shiftPts = scrollable;
        _followLive = (_shiftPts <= 0);
        if (!_followLive)
        {
            _lblHint.Text = I18n.T("HintPaused", "回看中：拖回最右侧恢复跟随（45 秒不动也会自动恢复）");
            _lblHint.ForeColor = CDim;
        }
        Draw();
    }

    /// <summary>Mouse wheel paging: positive delta goes further back in time.</summary>
    private void ShiftView(int dir)
    {
        int total = _tTime.Count;
        int span = Math.Min(_spanPts, Math.Max(1, total));
        int scrollable = Math.Max(0, total - span);
        if (scrollable <= 0) return;
        int step = Math.Max(1, span / 4);
        _shiftPts += dir * step;
        if (_shiftPts < 0) _shiftPts = 0;
        if (_shiftPts > scrollable) _shiftPts = scrollable;
        _followLive = (_shiftPts <= 0);
        Draw();
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
        // P8/P5 待机时 NVIDIA 也会置位，这时显示"待机"更有意义
        if (_lastClock < 600 && _lastUtil < 5) return I18n.T("ThrottleIdle", "待机");
        // nvmlClocksEventReasons 的真实位定义：
        //   0x1  GpuIdle            0x2  ApplicationsClocks
        //   0x4  SwPowerCap         0x8  HwSlowdown
        //   0x10 SyncBoost          0x20 SwThermalSlowdown
        //   0x40 HwThermalSlowdown  0x80 HwPowerBrake
        if ((mask & 0x40UL) != 0 || (mask & 0x20UL) != 0) return I18n.T("ThrottleThermal", "温度墙");
        if ((mask & 0x4UL) != 0) return I18n.T("ThrottlePower", "功耗墙");
        if ((mask & 0x8UL) != 0 || (mask & 0x80UL) != 0) return I18n.T("ThrottleHw", "硬件降频");
        if ((mask & 0x2UL) != 0) return I18n.T("ThrottleApp", "应用限频");
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

    // ── menu actions ────────────────────────────────────────────
    private bool _logging = true;

    private void ToggleLogging()
    {
        if (_logging)
        {
            _timer.Stop();
            _logging = false;
            _lblStatus.Text = "◼ " + I18n.T("StatusIdle", "已停止");
            _lblStatus.ForeColor = CDim;
            _miStart.Text = I18n.T("MenuStart", "开始记录");
        }
        else
        {
            _store.StartLog(_game != null ? SafeName(_game.Name) : "system", 500);
            _tail.Clear();
            _timer.Start();
            _logging = true;
            _lblStatus.Text = "● " + I18n.T("StatusRec", "记录中");
            _lblStatus.ForeColor = CAccent;
            _miStart.Text = I18n.T("MenuStop", "停止记录");
        }
    }

    private void ClearAllData()
    {
        var ans = MessageBox.Show(I18n.T("ClearAsk", "确定清空全部历史数据？会删除 logs 和 reports 里的所有文件，不可恢复。"),
            Text, MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2);
        if (ans != DialogResult.Yes) return;
        _timer.Stop();
        try
        {
            foreach (string sub in new[] { "logs", "reports" })
            {
                string dir = Path.Combine(_root, sub);
                if (Directory.Exists(dir))
                    foreach (string f in Directory.GetFiles(dir, "*", SearchOption.AllDirectories))
                    { try { File.Delete(f); } catch { } }
            }
            _tTime.Clear(); _gTemp.Clear(); _gPower.Clear();
            _cTime.Clear(); _cTemp.Clear(); _cFreq.Clear();
            _markers.Clear();
            _store.SaveMarkers(_markers);
            _sessionCount = 0;
            _store.StartLog(_game != null ? SafeName(_game.Name) : "system", 500);
            _lblHint.Text = I18n.T("ClearDone", "已清空全部历史");
        }
        catch { }
        _logging = true;
        _timer.Start();
        Draw();
    }

    private void ShowAbout()
    {
        string body =
            I18n.T("AppTitle", "游戏崩溃诊断器") + "   GameCrashDiag  v6.0\n\n" +
            "【它是什么】\n一个轻量的本地监控与崩溃取证工具：游戏运行时自动记录显卡和 CPU 的温度、功耗、频率、占用，\n" +
            "游戏闪退后自动生成一份能直接看懂的诊断报告。\n\n" +
            "【为什么会有它】\n最早是为了排查《战地 6》的 DXGI_ERROR_DEVICE_HUNG 闪退写的。\n" +
            "在翻了几百个崩溃转储之后，发现绝大多数问题都集中在三个地方：散热、驱动、超频。\n\n" +
            "【能做什么】\n" +
            " · 实时监控 GPU / CPU 共 12 项指标，双曲线走势，鼠标悬停看具体数值\n" +
            " · 自动识别全屏游戏，按游戏名分目录记录\n" +
            " · 崩溃后自动判定并生成报告，带崩溃前 40 条遥测\n" +
            " · 诊断报告：硬件 / 驱动 / 当前状态 / 本次统计 / 崩溃历史 / 建议\n\n" +
            "【技术】\n" +
            "C# + WinForms，零安装依赖；GPU 走 NVML 直连（0.09ms/次），CPU 走性能计数器，\n" +
            "AMD / Intel 显卡通过内置的 LibreHardwareMonitor 读取。\n\n" +
            "版本: v6.0 (C#)\n数据目录: " + _root;
        var dlg = new TextDialog(I18n.T("AboutTitle", "关于 游戏崩溃诊断器"), body, false, null);
        dlg.ShowDialog(this);
    }

    private void ShowDirectX()
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("=== DirectX 检查 ===");
        sb.AppendLine();
        try
        {
            using (var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(
                @"SOFTWARE\Microsoft\DirectX"))
            {
                object v = key != null ? key.GetValue("Version") : null;
                sb.AppendLine("DirectX 版本: " + (v != null ? v.ToString() : "未检测到"));
            }
        }
        catch { sb.AppendLine("DirectX 版本: 读取失败"); }

        sb.AppendLine();
        sb.AppendLine("核心组件:");
        string sys = Environment.GetFolderPath(Environment.SpecialFolder.System);
        foreach (string name in new[] { "d3d11.dll", "d3d12.dll", "dxgi.dll", "d3dcompiler_47.dll", "dxdiagn.dll", "d3dx9_43.dll" })
        {
            string p = Path.Combine(sys, name);
            string where = File.Exists(p) ? "OK   " + p : "缺失";
            sb.AppendLine("  " + name.PadRight(20) + where);
        }

        sb.AppendLine();
        sb.AppendLine("DirectX 运行时（DXSETUP）:");
        bool dxsetup = false;
        foreach (string dir in new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "D3DCompiler_47.dll"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32")
        })
        {
            if (File.Exists(dir)) { dxsetup = true; break; }
        }
        sb.AppendLine(dxsetup ? "  已安装或系统自带，通常无需修复" : "  未找到，可点下方按钮运行微软官方修复");
        sb.AppendLine();
        sb.AppendLine("如果游戏报 0x887A0006 / 0x887A0005，多半是显卡驱动或显存问题，建议先更新/回滚驱动。");

        var dlg = new TextDialog("DirectX 检查 - 游戏崩溃诊断器", sb.ToString(), true, RunDxRepair);
        dlg.ShowDialog(this);
    }

    private void RunDxRepair()
    {
        var ans = MessageBox.Show(
            "将用管理员权限运行系统文件检查：\n\nDISM /Online /Cleanup-Image /RestoreHealth\n\n这可能需要几分钟，确定继续？",
            Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question);
        if (ans != DialogResult.Yes) return;
        try
        {
            var psi = new ProcessStartInfo("cmd.exe",
                "/c echo 正在修复 DirectX 组件... & DISM /Online /Cleanup-Image /RestoreHealth & pause")
            { Verb = "runas", UseShellExecute = true };
            Process.Start(psi);
        }
        catch (Exception ex) { MessageBox.Show("启动失败: " + ex.Message, Text); }
    }

    private void CheckUpdates()
    {
        _lblHint.Text = "正在检查更新...";
        _lblHint.ForeColor = CDim;
        var worker = new System.ComponentModel.BackgroundWorker();
        worker.DoWork += (s, e) => { e.Result = Updater.Check(AppVersion); };
        worker.RunWorkerCompleted += (s, e) =>
        {
            var r = e.Result as Updater.Result;
            if (r == null || !r.Ok)
            {
                _lblHint.Text = "检查更新失败：" + (r != null ? r.Error : "未知错误");
                _lblHint.ForeColor = CWarn;
                MessageBox.Show("检查更新失败：\r\n\r\n" + (r != null ? r.Error : "未知错误") +
                    "\r\n\r\n可以手动打开下载页：\r\n" + Updater.PageUrl, Text);
                return;
            }
            _lblHint.Text = "已检查更新：最新 " + r.LatestTag + "，当前 " + AppVersion;
            _lblHint.ForeColor = CDim;
            if (!r.IsNewer)
            {
                MessageBox.Show("已经是最新版本。\r\n\r\n当前：" + AppVersion + "\r\n最新：" + r.LatestTag, Text,
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            string msg = "发现新版本 " + r.LatestTag + "\r\n\r\n当前：" + AppVersion +
                         "\r\n最新：" + r.LatestTag + "\r\n发布：" + r.PublishedAt + "\r\n\r\n要打开下载页吗？";
            if (MessageBox.Show(msg, Text, MessageBoxButtons.YesNo, MessageBoxIcon.Information) == DialogResult.Yes)
            {
                try { Process.Start(r.HtmlUrl); } catch { }
            }
        };
        worker.RunWorkerAsync();
    }

    private void RunUninstaller()
    {
        string script = Path.Combine(_root, "uninstall6.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("找不到卸载脚本 uninstall6.ps1，请从安装目录手动删除。", Text);
            return;
        }
        var ans = MessageBox.Show("确定要卸载本程序吗？日志和崩溃报告会保留。", Text,
            MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2);
        if (ans != DialogResult.Yes) return;
        try
        {
            var psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"")
            { UseShellExecute = true };
            Process.Start(psi);
            _exitFlag = true;
            Close();
        }
        catch (Exception ex) { MessageBox.Show("启动卸载程序失败: " + ex.Message, Text); }
    }

    private void SwitchLanguage(string code)
    {
        try
        {
            string dir = Path.Combine(_root, "data");
            Directory.CreateDirectory(dir);
            File.WriteAllText(Path.Combine(dir, "settings.ini"), "lang=" + code, new System.Text.UTF8Encoding(false));
            var ans = MessageBox.Show(
                code == "en-US" ? "Language will be applied after restart. Restart now?" : "语言将在重启后生效，现在就重启吗？",
                Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (ans != DialogResult.Yes) return;
            var psi = new ProcessStartInfo(Application.ExecutablePath);
            Process.Start(psi);
            _exitFlag = true;
            Close();
        }
        catch { }
    }

    // ── diagnosis dialog ────────────────────────────────────────
    private void ShowDiagnosis()
    {
        var dlg = new TextDialog("诊断报告 - 游戏崩溃诊断器", BuildDiagnosisText(), false, null);
        dlg.ShowDialog(this);
    }

    /// <summary>Shows the report banner with the newest report and renders the window.</summary>
    public string RunBannerTest(string shotPath)
    {
        string dir = Path.Combine(_root, "reports");
        string newest = "";
        try
        {
            var files = new DirectoryInfo(dir).GetFiles("*.txt");
            if (files.Length > 0)
            {
                Array.Sort(files, delegate (FileInfo a, FileInfo b) { return b.LastWriteTime.CompareTo(a.LastWriteTime); });
                newest = files[0].FullName;
            }
        }
        catch { }
        ShowReportBanner("✓ 对局结束 · bf6 · 35 分钟 · CPU 最高 96°C · GPU 最高 57°C · 显存峰值 8,075 MB · 报告 " +
                         (newest != "" ? Path.GetFileName(newest) : "（无）") + "（点此打开）", newest);
        Show();
        Application.DoEvents();
        System.Threading.Thread.Sleep(400);
        Draw();
        Application.DoEvents();
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("横幅可见: " + (_lblBanner != null && _lblBanner.Visible));
        sb.AppendLine("横幅文字: " + (_lblBanner != null ? _lblBanner.Text : ""));
        if (!string.IsNullOrEmpty(shotPath))
        {
            try
            {
                using (var bmp = new Bitmap(Width, Height))
                {
                    DrawToBitmap(bmp, new Rectangle(0, 0, Width, Height));
                    bmp.Save(shotPath, System.Drawing.Imaging.ImageFormat.Png);
                }
            }
            catch { }
        }
        Hide();
        return sb.ToString();
    }

    /// <summary>Hide to tray, then restore, reporting whether the window really came back.</summary>
    public string RunTrayTest(string shotPath)
    {
        var sb = new System.Text.StringBuilder();
        HideToTray();
        Application.DoEvents();
        System.Threading.Thread.Sleep(600);
        sb.AppendLine("隐藏后 Visible=" + Visible);

        ShowFromTray();
        Application.DoEvents();
        System.Threading.Thread.Sleep(900);

        sb.AppendLine("显示后 Visible=" + Visible + "  WindowState=" + WindowState);
        var fg = GetForegroundWindow();
        sb.AppendLine("前台窗口 == 本窗口: " + (fg == Handle) + "  (前台=" + fg + ", 本窗口=" + Handle + ")");
        if (!string.IsNullOrEmpty(shotPath))
        {
            try
            {
                using (var bmp = new Bitmap(Width, Height))
                {
                    DrawToBitmap(bmp, new Rectangle(0, 0, Width, Height));
                    bmp.Save(shotPath, System.Drawing.Imaging.ImageFormat.Png);
                }
                sb.AppendLine("截图: " + shotPath);
            }
            catch (Exception ex) { sb.AppendLine("截图失败: " + ex.Message); }
        }
        return sb.ToString();
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    /// <summary>Injects the three marker kinds and renders, so the separators can be verified.</summary>
    public string RunMarkerTest(string shotPath = "")
    {
        _tTime.Clear(); _gTemp.Clear(); _gPower.Clear(); _cTime.Clear(); _cTemp.Clear(); _cFreq.Clear();
        _markers.Clear();
        DateTime t0 = DateTime.Now.AddMinutes(-20);
        for (int i = 0; i < 2400; i++)
        {
            DateTime t = t0.AddMilliseconds(500 * i);
            _tTime.Add(t); _cTime.Add(t);
            _gTemp.Add(45 + (i % 12)); _gPower.Add(120 + (i % 40));
            _cTemp.Add(62 + (i % 10)); _cFreq.Add(3900 + (i % 200));
        }
        _markers.Add(new Marker { Time = t0.AddMinutes(4), Kind = "gap", Note = "隔 2.3 小时" });
        _markers.Add(new Marker { Time = t0.AddMinutes(9), Kind = "crash", Note = "崩溃" });
        _markers.Add(new Marker { Time = t0.AddMinutes(14), Kind = "down", Note = "宕机" });
        _markers.Add(new Marker { Time = t0.AddMinutes(17), Kind = "crash", Note = "崩溃" });
        Show();
        Application.DoEvents();
        Draw();
        Application.DoEvents();
        if (!string.IsNullOrEmpty(shotPath))
        {
            try
            {
                using (var bmp = new Bitmap(Width, Height))
                {
                    DrawToBitmap(bmp, new Rectangle(0, 0, Width, Height));
                    bmp.Save(shotPath, System.Drawing.Imaging.ImageFormat.Png);
                }
            }
            catch { }
        }
        Hide();
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("标记数: " + _markers.Count);
        foreach (var m in _markers) sb.AppendLine("  " + m.Time.ToString("HH:mm:ss") + "  " + m.Kind + "  " + m.Note);
        return sb.ToString();
    }

    /// <summary>Headless check of the scrollbar maths (no mouse needed).</summary>
    public string RunScrollTest()
    {
        var sb = new System.Text.StringBuilder();
        _tTime.Clear(); _gTemp.Clear(); _gPower.Clear(); _cTime.Clear(); _cTemp.Clear(); _cFreq.Clear();
        DateTime t0 = DateTime.Now.AddMinutes(-25);
        for (int i = 0; i < 3000; i++)
        {
            DateTime t = t0.AddMilliseconds(500 * i);
            _tTime.Add(t); _cTime.Add(t);
            _gTemp.Add(40 + (i % 20)); _gPower.Add(100 + (i % 50));
            _cTemp.Add(60 + (i % 15)); _cFreq.Add(3800 + (i % 300));
        }
        Show();
        Application.DoEvents();
        Draw();
        Application.DoEvents();
        sb.AppendLine("点数: " + _tTime.Count + "  窗口跨度: " + _spanPts + "  滚动条可见: " + _barTrack.Visible);
        int travel = Math.Max(1, _barTrack.Width - _barThumb.Width);
        sb.AppendLine("轨道宽 " + _barTrack.Width + "  手柄宽 " + _barThumb.Width + "  可移动 " + travel);
        foreach (double frac in new[] { 1.0, 0.75, 0.5, 0.25, 0.0 })
        {
            _barThumb.Left = (int)Math.Round(travel * frac);
            SetShiftFromThumb();
            sb.AppendLine(string.Format("手柄 {0,4:P0} → 偏移 {1,6} 点，跟随最新={2}，窗口 {3} ~ {4}",
                frac, _shiftPts, _followLive,
                _tTime[Math.Max(0, _tTime.Count - _shiftPts - Math.Min(_spanPts, _tTime.Count))].ToString("HH:mm:ss"),
                _tTime[Math.Max(0, _tTime.Count - _shiftPts - 1)].ToString("HH:mm:ss")));
        }
        Hide();
        return sb.ToString();
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

    public string LastSessionPath = "";

    public string BuildDiagnosisText()
    {
        var head = new System.Text.StringBuilder();
        try
        {
            if (File.Exists(LastSessionFile))
            {
                string[] lp = File.ReadAllText(LastSessionFile, System.Text.Encoding.UTF8).Split('|');
                if (lp.Length >= 7 && File.Exists(lp[6]))
                {
                    DateTime wt;
                    string when = DateTime.TryParse(lp[0], out wt) ? wt.ToString("MM-dd HH:mm") : lp[0];
                    head.AppendLine("【上一次对局】");
                    head.AppendLine(string.Format("  {0}  {1}  {2} 分钟   CPU 最高 {3}°C   GPU 最高 {4}°C   显存峰值 {5} MB",
                        when, lp[1], lp[2], lp[3], lp[4], lp[5]));
                    head.AppendLine("  报告: " + lp[6]);
                    head.AppendLine();
                    LastSessionPath = lp[6];
                }
            }
        }
        catch { }
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
        d.IdleGpuTemp = _idleCount > 0 ? _idleGpuSum / _idleCount : 0;
        d.IdleCpuTemp = _idleCount > 0 ? _idleCpuSum / _idleCount : 0;

        string text = Diagnosis.Build(d);
        return text + Environment.NewLine + head.ToString();
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

    private void PromoteTrayIcon()
    {
        try
        {
            using (var baseKey = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Control Panel\NotifyIconSettings", true))
            {
                if (baseKey == null) return;
                foreach (string name in baseKey.GetSubKeyNames())
                {
                    using (var sub = baseKey.OpenSubKey(name, true))
                    {
                        if (sub == null) continue;
                        string exe = sub.GetValue("ExecutablePath") as string;
                        if (exe == null) continue;
                        if (!string.Equals(exe, Application.ExecutablePath, StringComparison.OrdinalIgnoreCase)) continue;
                        object cur = sub.GetValue("IsPromoted");
                        if (cur == null || Convert.ToInt32(cur) == 0)
                        {
                            sub.SetValue("IsPromoted", 1, Microsoft.Win32.RegistryValueKind.DWord);
                            LogLine("tray promoted (key " + name + ")");
                        }
                    }
                }
            }
        }
        catch (Exception ex) { LogLine("tray promote failed: " + ex.Message); }
    }

    private void HideToTray()
    {
        Hide();
        _tray.BalloonTipTitle = Text;
        _tray.BalloonTipText = I18n.T("TrayBalloon", "已缩到托盘，仍在后台记录");
        try { _tray.ShowBalloonTip(1200); } catch { }
    }

    private Label _lblBanner;
    private string _bannerReport = "";
    private DateTime _bannerShown = DateTime.MinValue;

    private void ShowReportBanner(string text, string reportPath)
    {
        if (_lblBanner == null)
        {
            _lblBanner = MakeLabel("", new Point(S(6), S(544)), 8.5f, CAccent, false);
            _lblBanner.AutoSize = false;
            _lblBanner.Size = new Size(S(748), S(20));
            _lblBanner.Cursor = Cursors.Hand;
            _lblBanner.Click += (s, e) => OpenReportFile(_bannerReport);
            Controls.Add(_lblBanner);
        }
        _bannerReport = reportPath;
        _bannerShown = DateTime.Now;
        _lblBanner.Text = text;
        _lblBanner.Visible = true;
        _lblBanner.BringToFront();
    }

    private string LastSessionFile { get { return Path.Combine(_root, "data", "last-session.txt"); } }

    private void SaveLastSession(string game, double minutes, double cpuMax, double gpuMax, double vramMax, string report)
    {
        try
        {
            Directory.CreateDirectory(Path.Combine(_root, "data"));
            File.WriteAllText(LastSessionFile,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "|" + game + "|" + Math.Round(minutes) + "|" +
                Math.Round(cpuMax) + "|" + Math.Round(gpuMax) + "|" + Math.Round(vramMax) + "|" + report,
                new System.Text.UTF8Encoding(false));
        }
        catch { }
    }

    private void LoadLastSessionBanner()
    {
        try
        {
            if (!File.Exists(LastSessionFile)) return;
            string[] p = File.ReadAllText(LastSessionFile, System.Text.Encoding.UTF8).Split('|');
            if (p.Length < 7) return;
            string when = p[0], game = p[1], report = p[6];
            if (!File.Exists(report)) return;
            DateTime tt;
            string clock = DateTime.TryParse(when, out tt) ? tt.ToString("MM-dd HH:mm") : when;
            ShowReportBanner(string.Format("上一次对局 · {0} · {1} · {2} 分钟 · 报告 {3}（点此打开）",
                clock, game, p[2], Path.GetFileName(report)), report);
        }
        catch { }
    }
    private void OpenReportFile(string path)
    {
        try
        {
            if (!string.IsNullOrEmpty(path) && File.Exists(path)) Process.Start("notepad.exe", "\"" + path + "\"");
        }
        catch (Exception ex) { MessageBox.Show("打开失败: " + ex.Message, Text); }
    }

    private void ClearReportBanner()
    {
        if (_lblBanner != null) _lblBanner.Visible = false;
        _bannerReport = "";
    }

    private static bool IsElevated()
    {
        try
        {
            var id = System.Security.Principal.WindowsIdentity.GetCurrent();
            var p = new System.Security.Principal.WindowsPrincipal(id);
            return p.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
        }
        catch { return false; }
    }

    private void RestartElevated()
    {
        if (IsElevated())
        {
            MessageBox.Show("当前已经是管理员权限，可以直接读取 CPU 封装温度。", Text);
            return;
        }
        try
        {
            var psi = new ProcessStartInfo(Application.ExecutablePath, "-Tray");
            psi.Verb = "runas";
            psi.UseShellExecute = true;
            Process.Start(psi);
            LogLine("restart elevated");
            _exitFlag = true;
            Close();
        }
        catch (Exception ex)
        {
            MessageBox.Show("提权失败（可能点了取消）：" + ex.Message, Text);
        }
    }

    private void OpenLatestReport()
    {
        try
        {
            string dir = Path.Combine(_root, "reports");
            if (!Directory.Exists(dir)) { MessageBox.Show("还没有任何报告。", Text); return; }
            var files = new DirectoryInfo(dir).GetFiles("*.txt");
            if (files.Length == 0) { MessageBox.Show("还没有任何报告。", Text); return; }
            Array.Sort(files, delegate (FileInfo a, FileInfo b) { return b.LastWriteTime.CompareTo(a.LastWriteTime); });
            Process.Start("notepad.exe", "\"" + files[0].FullName + "\"");
        }
        catch (Exception ex) { MessageBox.Show("打开失败: " + ex.Message, Text); }
    }

    private void ShowTrayMenu()
    {
        try
        {
            if (_trayMenu != null) _trayMenu.Show(Cursor.Position);
        }
        catch { }
    }

    private void ShowFromTray()
    {
        try
        {
            ShowInTaskbar = true;
            if (!Visible) Show();
            if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
            ShowWindow(Handle, SW_RESTORE);

            // 从后台进程抢前台需要一点技巧：短暂置顶再恢复，配合 SetForegroundWindow
            bool wasTop = TopMost;
            TopMost = true;
            TopMost = wasTop;
            Activate();
            SetForegroundWindow(Handle);
            BringToFront();
            LogLine("show from tray");
        }
        catch (Exception ex) { LogLine("show from tray failed: " + ex.Message); }
    }

    private const int SW_RESTORE = 9;

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    private void OnClosing(object sender, FormClosingEventArgs e)
    {
        if (!_exitFlag && e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            HideToTray();
            return;
        }
        LogLine("closing, reason=" + e.CloseReason + " exitFlag=" + _exitFlag);
        _timer.Stop();
        _store.SaveMarkers(_markers);
        if (_tray != null) { _tray.Visible = false; _tray.Dispose(); }
        try { LhmBridge.Close(); } catch { }
        try { Nvml.Shutdown(); } catch { }
        _cpu.Dispose();
    }
}
