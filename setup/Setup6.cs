using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

// Installer wizard for the C# build: pick a folder, extract the embedded payload,
// run install6.ps1, then offer desktop shortcut / autostart / launch.
internal static class Setup6
{
    private static string _target = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Programs\GameCrashDiag6");
    private static readonly Color Bg = Color.FromArgb(24, 24, 28);
    private static readonly Color CardColor = Color.FromArgb(34, 34, 40);
    private static readonly Color Fg = Color.FromArgb(228, 228, 236);
    private static readonly Color Dim = Color.FromArgb(140, 140, 155);
    private static readonly Color Accent = Color.FromArgb(86, 214, 178);

    [STAThread]
    private static void Main()
    {
        try { SetProcessDPIAwareP(); } catch { }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new Wizard());
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();
    private static void SetProcessDPIAwareP() { SetProcessDPIAware(); }

    private sealed class Wizard : Form
    {
        private readonly TextBox _dir = new TextBox();
        private readonly ProgressBar _bar = new ProgressBar();
        private readonly Label _status = new Label();
        private readonly CheckBox _chkShortcut = new CheckBox();
        private readonly CheckBox _chkAuto = new CheckBox();
        private readonly CheckBox _chkLaunch = new CheckBox();
        private readonly Button _btnInstall = new Button();
        private readonly Button _btnBrowse = new Button();
        private readonly Panel _finish;

        public Wizard()
        {
            Text = "游戏崩溃诊断器 v6 安装程序";
            ClientSize = new Size(560, 400);
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Bg;
            ForeColor = Fg;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            AutoScaleMode = AutoScaleMode.None;
            Font = new Font("Microsoft YaHei UI", 9.5f);

            var title = new Label();
            title.Text = "游戏崩溃诊断器 v6";
            title.Font = new Font("Microsoft YaHei UI", 18f, FontStyle.Bold);
            title.ForeColor = Accent;
            title.AutoSize = true;
            title.Location = new Point(24, 18);
            Controls.Add(title);

            var sub = new Label();
            sub.Text = "C# 重写版 · 崩溃取证与硬件监控 · 约 100 KB，无需安装运行库";
            sub.ForeColor = Dim;
            sub.AutoSize = true;
            sub.Location = new Point(26, 58);
            Controls.Add(sub);

            var lblDir = new Label();
            lblDir.Text = "安装位置";
            lblDir.ForeColor = Dim;
            lblDir.AutoSize = true;
            lblDir.Location = new Point(26, 100);
            Controls.Add(lblDir);

            _dir.Bounds = new Rectangle(26, 124, 420, 28);
            _dir.BackColor = CardColor;
            _dir.ForeColor = Fg;
            _dir.BorderStyle = BorderStyle.FixedSingle;
            _dir.Text = _target;
            Controls.Add(_dir);

            _btnBrowse.Text = "浏览...";
            _btnBrowse.Bounds = new Rectangle(456, 124, 80, 28);
            Style(_btnBrowse);
            _btnBrowse.Click += (s, e) =>
            {
                using (var dlg = new FolderBrowserDialog())
                {
                    dlg.Description = "选择安装目录";
                    dlg.SelectedPath = _dir.Text;
                    if (dlg.ShowDialog() == DialogResult.OK) _dir.Text = dlg.SelectedPath;
                }
            };
            Controls.Add(_btnBrowse);

            _bar.Bounds = new Rectangle(26, 176, 510, 16);
            _bar.Style = ProgressBarStyle.Continuous;
            Controls.Add(_bar);

            _status.Bounds = new Rectangle(26, 200, 510, 22);
            _status.ForeColor = Dim;
            _status.Text = "准备就绪";
            Controls.Add(_status);

            _chkShortcut.Text = "创建桌面快捷方式";
            _chkShortcut.Checked = true;
            _chkShortcut.ForeColor = Fg;
            _chkShortcut.AutoSize = true;
            _chkShortcut.Location = new Point(26, 240);
            Controls.Add(_chkShortcut);

            _chkAuto.Text = "开机自动启动（进托盘，不弹窗）";
            _chkAuto.Checked = true;
            _chkAuto.ForeColor = Fg;
            _chkAuto.AutoSize = true;
            _chkAuto.Location = new Point(26, 268);
            Controls.Add(_chkAuto);

            _chkLaunch.Text = "安装完成后立即运行";
            _chkLaunch.Checked = true;
            _chkLaunch.ForeColor = Fg;
            _chkLaunch.AutoSize = true;
            _chkLaunch.Location = new Point(26, 296);
            Controls.Add(_chkLaunch);

            _btnInstall.Text = "开始安装";
            _btnInstall.Bounds = new Rectangle(26, 336, 140, 40);
            Style(_btnInstall);
            _btnInstall.BackColor = Color.FromArgb(38, 96, 82);
            _btnInstall.Click += (s, e) => DoInstall();
            Controls.Add(_btnInstall);

            var btnCancel = new Button();
            btnCancel.Text = "取消";
            btnCancel.Bounds = new Rectangle(396, 336, 140, 40);
            Style(btnCancel);
            btnCancel.Click += (s, e) => Close();
            Controls.Add(btnCancel);

            _finish = new Panel();
            _finish.Bounds = new Rectangle(0, 0, 560, 400);
            _finish.BackColor = Bg;
            _finish.Visible = false;
            var ok = new Label();
            ok.Text = "安装完成";
            ok.Font = new Font("Microsoft YaHei UI", 16f, FontStyle.Bold);
            ok.ForeColor = Accent;
            ok.AutoSize = true;
            ok.Location = new Point(24, 24);
            _finish.Controls.Add(ok);
            var hint = new Label();
            hint.Text = "程序已装好。桌面快捷方式、开始菜单都能打开它。";
            hint.ForeColor = Dim;
            hint.AutoSize = true;
            hint.Location = new Point(26, 64);
            _finish.Controls.Add(hint);
            var pathLbl = new Label();
            pathLbl.Text = _target;
            pathLbl.ForeColor = Fg;
            pathLbl.AutoSize = true;
            pathLbl.Location = new Point(26, 96);
            _finish.Controls.Add(pathLbl);
            var btnDone = new Button();
            btnDone.Text = "完成";
            btnDone.Bounds = new Rectangle(396, 336, 140, 40);
            Style(btnDone);
            btnDone.Click += (s, e) => Close();
            _finish.Controls.Add(btnDone);
            Controls.Add(_finish);
        }

        private static void Style(Button b)
        {
            b.FlatStyle = FlatStyle.Flat;
            b.FlatAppearance.BorderColor = Color.FromArgb(70, 70, 86);
            b.BackColor = CardColor;
            b.ForeColor = Fg;
        }

        private void Ui(Action a) { if (InvokeRequired) BeginInvoke(a); else a(); }

        private void DoInstall()
        {
            _btnInstall.Enabled = false;
            _btnBrowse.Enabled = false;
            string target = _dir.Text.Trim();
            bool shortcut = _chkShortcut.Checked, auto = _chkAuto.Checked, launch = _chkLaunch.Checked;
            var t = new Thread(() => Install(target, shortcut, auto, launch));
            t.IsBackground = true;
            t.Start();
        }

        private void Install(string target, bool shortcut, bool auto, bool launch)
        {
            string work = Path.Combine(Path.GetTempPath(), "gcd6-setup-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            try
            {
                Ui(delegate { _bar.Value = 8; _status.Text = "正在解压安装包..."; });
                Directory.CreateDirectory(work);
                using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("app6.zip"))
                {
                    if (s == null) throw new Exception("安装包损坏（缺少资源）");
                    string zip = Path.Combine(work, "app6.zip");
                    using (var fs = File.Create(zip)) s.CopyTo(fs);
                    ZipFile.ExtractToDirectory(zip, work);
                }

                Ui(delegate { _bar.Value = 45; _status.Text = "正在复制程序文件..."; });
                string ps = Path.Combine(work, "install6.ps1");
                if (!File.Exists(ps)) throw new Exception("安装脚本缺失");

                string args = "-NoProfile -ExecutionPolicy Bypass -File \"" + ps + "\" -Silent -InstallDir \"" + target + "\"";
                if (shortcut) args += " -Shortcut";
                if (auto) args += " -Autostart";
                if (launch) args += " -Launch";

                var psi = new ProcessStartInfo("powershell.exe", args);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                psi.WorkingDirectory = work;
                using (var p = Process.Start(psi))
                {
                    string outText = p.StandardOutput.ReadToEnd();
                    string errText = p.StandardError.ReadToEnd();
                    p.WaitForExit();
                    if (p.ExitCode != 0)
                        throw new Exception("安装脚本返回 " + p.ExitCode + "\r\n" + Tail(errText, 500) + "\r\n" + Tail(outText, 500));
                }

                _target = target;
                Ui(delegate { _bar.Value = 100; _status.Text = "安装完成"; _finish.Visible = true; _finish.BringToFront(); });
            }
            catch (Exception ex)
            {
                Ui(delegate
                {
                    _bar.Value = 0;
                    _status.Text = "安装失败";
                    MessageBox.Show(this, "安装失败：\r\n\r\n" + ex.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
                    _btnInstall.Enabled = true;
                    _btnBrowse.Enabled = true;
                });
            }
            finally
            {
                try { Directory.Delete(work, true); } catch { }
            }
        }

        private static string Tail(string s, int n)
        {
            if (string.IsNullOrEmpty(s)) return "";
            return s.Length <= n ? s : s.Substring(s.Length - n);
        }
    }
}
