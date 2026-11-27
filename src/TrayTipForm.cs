using System;
using System.Drawing;
using System.Windows.Forms;

// Small borderless window shown next to the tray icon when the mouse hovers over it.
// NotifyIcon tooltips are plain text with no colour, so this draws the values itself:
// white = normal, yellow = warm, red = hot.
public sealed class TrayTipForm : Form
{
    private readonly Label _lblGpu;
    private readonly Label _lblCpu;
    private readonly Timer _hideTimer;
    private Point _anchor;

    private static readonly Color Normal = Color.FromArgb(235, 238, 245);
    private static readonly Color Warm = Color.FromArgb(240, 200, 90);
    private static readonly Color Hot = Color.FromArgb(235, 90, 90);

    public TrayTipForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.FromArgb(24, 24, 28);
        AutoScaleMode = AutoScaleMode.None;
        Font = new Font("Microsoft YaHei UI", 9f);
        Size = new Size(150, 58);
        Padding = new Padding(10, 6, 10, 6);

        _lblGpu = new Label();
        _lblGpu.AutoSize = false;
        _lblGpu.Bounds = new Rectangle(10, 6, 130, 20);
        _lblGpu.Font = new Font("Microsoft YaHei UI", 9.5f);
        _lblGpu.ForeColor = Normal;
        _lblGpu.BackColor = Color.Transparent;
        _lblGpu.Text = "GPU --";

        _lblCpu = new Label();
        _lblCpu.AutoSize = false;
        _lblCpu.Bounds = new Rectangle(10, 28, 130, 20);
        _lblCpu.Font = new Font("Microsoft YaHei UI", 9.5f);
        _lblCpu.ForeColor = Normal;
        _lblCpu.BackColor = Color.Transparent;
        _lblCpu.Text = "CPU --";

        Controls.Add(_lblGpu);
        Controls.Add(_lblCpu);

        _hideTimer = new Timer();
        _hideTimer.Interval = 350;
        _hideTimer.Tick += (s, e) =>
        {
            Point p = Cursor.Position;
            Rectangle r = new Rectangle(Location.X, Location.Y, Width, Height);
            // 鼠标还停在图标上（锚点附近）或已经移到浮窗里，都保持显示
            double dx = p.X - _anchor.X, dy = p.Y - _anchor.Y;
            bool nearAnchor = Math.Abs(dx) <= 60 && Math.Abs(dy) <= 60;
            if (!r.Contains(p) && !nearAnchor) { _hideTimer.Stop(); Hide(); }
        };
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000;   // WS_EX_NOACTIVATE
            cp.ExStyle |= 0x00000080;   // WS_EX_TOOLWINDOW (no taskbar entry)
            return cp;
        }
    }

    private static Color ForGpu(double t)
    {
        if (t <= 0) return Normal;
        if (t >= 85) return Hot;
        if (t >= 76) return Warm;
        return Normal;
    }

    private static Color ForCpu(double t)
    {
        if (t <= 0) return Normal;
        if (t >= 90) return Hot;
        if (t >= 81) return Warm;
        return Normal;
    }

    public void SetValues(double gpuTemp, double gpuPower, double cpuTemp, double cpuFreq)
    {
        _lblGpu.Text = string.Format("GPU {0}°C", gpuTemp > 0 ? gpuTemp.ToString("0") : "--");
        _lblCpu.Text = string.Format("CPU {0}°C", cpuTemp > 0 ? cpuTemp.ToString("0") : "--");
        _lblGpu.ForeColor = ForGpu(gpuTemp);
        _lblCpu.ForeColor = ForCpu(cpuTemp);
    }

    public void ShowAt(Point cursor)
    {
        _anchor = cursor;
        Screen scr = Screen.FromPoint(cursor);
        Rectangle wa = scr.WorkingArea;
        int x = cursor.X - Width / 2;
        int y = cursor.Y - Height - 12;          // above the tray icon
        if (x < wa.Left + 4) x = wa.Left + 4;
        if (x + Width > wa.Right - 4) x = wa.Right - Width - 4;
        if (y < wa.Top + 4) y = cursor.Y + 20;   // fall back to below the cursor
        Location = new Point(x, y);
        if (!Visible) Show();
        BringToFront();
        _hideTimer.Start();
    }
}
