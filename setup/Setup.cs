using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

static class Setup
{
    const string AppTitle = "游戏崩溃诊断器 安装程序";
    const string DefaultDir = @"D:\Program Files\GameCrashDiag";
    const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string ApprovePath = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";

    static string LogPath;
    static void Log(string m)
    {
        try { if (LogPath != null) File.AppendAllText(LogPath, DateTime.Now.ToString("HH:mm:ss") + " " + m + "\r\n"); }
        catch { }
    }

    static bool IsAdmin()
    {
        try
        {
            using (WindowsIdentity id = WindowsIdentity.GetCurrent())
                return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch { return false; }
    }

    [STAThread]
    static void Main(string[] args)
    {
        bool elevated = args != null && Array.IndexOf(args, "/elevated") >= 0;
        bool noElevate = args != null && Array.IndexOf(args, "/no-elevate") >= 0;

        if (!elevated && !noElevate && !IsAdmin())
        {
            // 需要管理员权限才能写 Program Files：重新以管理员身份启动自己
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(Assembly.GetExecutingAssembly().Location, "/elevated");
                psi.UseShellExecute = true;
                psi.Verb = "runas";
                Process.Start(psi);
            }
            catch
            {
                MessageBox.Show("安装需要管理员权限。\r\n\r\n" +
                    "如果不想提权，也可以双击同目录下的「安装.cmd」安装。",
                    AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            return;
        }

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        string prefill = null;
        if (args != null)
            foreach (string a in args)
                if (a.StartsWith("/dir=", StringComparison.OrdinalIgnoreCase)) prefill = a.Substring(5).Trim('"');

        bool demoFinish = args != null && Array.IndexOf(args, "/demo-finish") >= 0;
        InstallerForm f = new InstallerForm(prefill);
        if (demoFinish) f.Shown += delegate { f.DemoFinish(DefaultDir); };
        Application.Run(f);
    }

    // ================= 安装窗口 =================
    sealed class InstallerForm : Form
    {
        readonly string initDir;
        TextBox txtDir;
        Button btnBrowse, btnInstall, btnCancel;
        ProgressBar bar;
        Label lblStatus;
        Panel finishPanel;
        CheckBox chkDesktop, chkRun, chkAuto;
        bool installing;

        public InstallerForm(string prefillDir)
        {
            initDir = string.IsNullOrEmpty(prefillDir) ? DefaultDir : prefillDir;
            Text = AppTitle;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(560, 260);
            Font = new Font("微软雅黑", 9f);
            try { Icon = Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location); } catch { }

            Label lblTitle = new Label();
            lblTitle.Text = "游戏崩溃诊断器";
            lblTitle.Font = new Font("微软雅黑", 16f, FontStyle.Bold);
            lblTitle.AutoSize = true;
            lblTitle.Location = new Point(24, 20);
            Controls.Add(lblTitle);

            Label lblSub = new Label();
            lblSub.Text = "监控游戏时的显卡 / CPU 温度、功耗、频率，崩溃后自动生成诊断报告。";
            lblSub.ForeColor = Color.FromArgb(90, 90, 96);
            lblSub.AutoSize = true;
            lblSub.Location = new Point(26, 58);
            Controls.Add(lblSub);

            Label lblWhere = new Label();
            lblWhere.Text = "安装位置";
            lblWhere.AutoSize = true;
            lblWhere.Location = new Point(26, 96);
            Controls.Add(lblWhere);

            txtDir = new TextBox();
            txtDir.Text = initDir;
            txtDir.Location = new Point(26, 118);
            txtDir.Size = new Size(410, 26);
            Controls.Add(txtDir);

            btnBrowse = new Button();
            btnBrowse.Text = "浏览...";
            btnBrowse.Location = new Point(446, 117);
            btnBrowse.Size = new Size(88, 28);
            btnBrowse.Click += delegate
            {
                using (FolderBrowserDialog fbd = new FolderBrowserDialog())
                {
                    fbd.Description = "选择安装位置";
                    fbd.SelectedPath = txtDir.Text;
                    if (fbd.ShowDialog(this) == DialogResult.OK) txtDir.Text = fbd.SelectedPath;
                }
            };
            Controls.Add(btnBrowse);

            bar = new ProgressBar();
            bar.Location = new Point(26, 162);
            bar.Size = new Size(508, 18);
            bar.Minimum = 0;
            bar.Maximum = 100;
            Controls.Add(bar);

            lblStatus = new Label();
            lblStatus.Text = "准备就绪，点「开始安装」";
            lblStatus.AutoSize = true;
            lblStatus.Location = new Point(26, 186);
            Controls.Add(lblStatus);

            btnInstall = new Button();
            btnInstall.Text = "开始安装";
            btnInstall.Location = new Point(334, 212);
            btnInstall.Size = new Size(100, 32);
            btnInstall.Click += delegate { StartInstall(); };
            Controls.Add(btnInstall);

            btnCancel = new Button();
            btnCancel.Text = "取消";
            btnCancel.Location = new Point(442, 212);
            btnCancel.Size = new Size(92, 32);
            btnCancel.Click += delegate { Close(); };
            Controls.Add(btnCancel);

            AcceptButton = btnInstall;
            CancelButton = btnCancel;

            // 完成面板（初始隐藏）
            finishPanel = new Panel();
            finishPanel.Location = new Point(0, 90);
            finishPanel.Size = new Size(560, 170);
            finishPanel.Visible = false;
            Controls.Add(finishPanel);

            Label lblDone = new Label();
            lblDone.Text = "安装完成";
            lblDone.Font = new Font("微软雅黑", 13f, FontStyle.Bold);
            lblDone.ForeColor = Color.FromArgb(0, 120, 90);
            lblDone.AutoSize = true;
            lblDone.Location = new Point(26, 8);
            finishPanel.Controls.Add(lblDone);

            chkDesktop = new CheckBox();
            chkDesktop.Text = "创建桌面快捷方式";
            chkDesktop.Checked = true;
            chkDesktop.AutoSize = true;
            chkDesktop.Location = new Point(30, 52);
            finishPanel.Controls.Add(chkDesktop);

            chkRun = new CheckBox();
            chkRun.Text = "安装完成后运行";
            chkRun.Checked = true;
            chkRun.AutoSize = true;
            chkRun.Location = new Point(30, 78);
            finishPanel.Controls.Add(chkRun);

            chkAuto = new CheckBox();
            chkAuto.Text = "开机自动启动（后台记录，不弹窗）";
            chkAuto.Checked = true;
            chkAuto.AutoSize = true;
            chkAuto.Location = new Point(30, 104);
            finishPanel.Controls.Add(chkAuto);

            Button btnFinish = new Button();
            btnFinish.Text = "完成";
            btnFinish.Location = new Point(442, 122);
            btnFinish.Size = new Size(92, 32);
            btnFinish.Click += delegate { Finish(); };
            finishPanel.Controls.Add(btnFinish);
            btnFinish.BringToFront();
            finishPanel.Controls.SetChildIndex(btnFinish, 0);
        }

        void Ui(Action a)
        {
            if (InvokeRequired) BeginInvoke(a); else a();
        }

        void StartInstall()
        {
            if (installing) return;
            string dir = txtDir.Text.Trim().Trim('"');
            if (dir.Length == 0) { MessageBox.Show(this, "请填写安装位置。", AppTitle); return; }

            installing = true;
            btnInstall.Enabled = false;
            btnBrowse.Enabled = false;
            btnCancel.Enabled = false;
            txtDir.Enabled = false;

            ThreadPool.QueueUserWorkItem(delegate
            {
                try
                {
                    DoInstall(dir);
                    Ui(delegate { ShowFinish(dir); });
                }
                catch (Exception ex)
                {
                    Log("ERROR " + ex);
                    Ui(delegate
                    {
                        MessageBox.Show(this, "安装失败：\r\n" + ex.Message + (LogPath != null ? "\r\n\r\n日志：" + LogPath : ""),
                            AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Error);
                        installing = false;
                        btnInstall.Enabled = true;
                        btnBrowse.Enabled = true;
                        btnCancel.Enabled = true;
                        txtDir.Enabled = true;
                        lblStatus.Text = "安装失败";
                    });
                }
            });
        }

        void DoInstall(string targetDir)
        {
            string work = Path.Combine(Path.GetTempPath(), "GameCrashDiag-setup-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            Directory.CreateDirectory(work);
            LogPath = Path.Combine(work, "setup.log");
            Log("work=" + work + " target=" + targetDir);

            Assembly asm = Assembly.GetExecutingAssembly();
            using (Stream s = asm.GetManifestResourceStream("app.zip"))
            {
                if (s == null) throw new Exception("安装包损坏（缺少内嵌资源）");
                using (ZipArchive zip = new ZipArchive(s, ZipArchiveMode.Read))
                {
                    int total = zip.Entries.Count, done = 0;
                    foreach (ZipArchiveEntry entry in zip.Entries)
                    {
                        string dest = Path.Combine(work, entry.FullName.Replace('/', '\\'));
                        if (entry.FullName.EndsWith("/")) Directory.CreateDirectory(dest);
                        else
                        {
                            Directory.CreateDirectory(Path.GetDirectoryName(dest));
                            entry.ExtractToFile(dest, true);
                        }
                        done++;
                        int pct = (int)(done * 40.0 / Math.Max(1, total));
                        Ui(delegate { bar.Value = pct; lblStatus.Text = "解压文件 " + done + " / " + total; });
                    }
                }
            }
            Log("extracted");

            Ui(delegate { bar.Value = 45; lblStatus.Text = "正在复制程序文件..."; });

            string ps = Path.Combine(work, "install.ps1");
            if (!File.Exists(ps)) throw new Exception("安装脚本缺失");
            string psArgs = "-NoProfile -ExecutionPolicy Bypass -File \"" + ps + "\" -Silent -InstallDir \"" + targetDir + "\"";

            ProcessStartInfo psi = new ProcessStartInfo("powershell.exe", psArgs);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.WorkingDirectory = work;

            string outText, errText;
            int code;
            using (Process proc = Process.Start(psi))
            {
                outText = proc.StandardOutput.ReadToEnd();
                errText = proc.StandardError.ReadToEnd();
                proc.WaitForExit();
                code = proc.ExitCode;
            }
            Log("install exit=" + code + " err=" + errText);

            if (code != 0)
                throw new Exception("install.ps1 返回 " + code + "\r\n" + Tail(errText, 600) + "\r\n" + Tail(outText, 600));

            Ui(delegate { bar.Value = 90; lblStatus.Text = "正在收尾..."; });

            try { Directory.Delete(work, true); } catch { }
            Log("done " + targetDir);
        }

        void ShowFinish(string dir)
        {
            bar.Value = 100;
            lblStatus.Text = "安装完成";
            lblStatus.ForeColor = Color.FromArgb(0, 120, 90);
            txtDir.Visible = false;
            btnBrowse.Visible = false;
            Controls.Remove(bar);
            foreach (Control c in Controls)
                if (c is Label && ((Label)c).Text.StartsWith("安装位置")) c.Visible = false;

            btnInstall.Visible = false;
            btnCancel.Visible = false;
            finishPanel.Visible = true;
            finishPanel.BringToFront();
            Tag = dir;
        }

        public void DemoFinish(string dir)
        {
            ShowFinish(dir);
        }

        void Finish()
        {
            string dir = Tag as string ?? txtDir.Text.Trim();
            try
            {
                string desktopLnk = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Desktop), "游戏崩溃诊断器.lnk");
                if (!chkDesktop.Checked) { try { File.Delete(desktopLnk); } catch { } }

                if (chkAuto.Checked)
                {
                    string vbs = Path.Combine(dir, "自启-托盘.vbs");
                    using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKeyPath, true))
                        if (k != null) k.SetValue("GameCrashDiag", "\"" + Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "wscript.exe") + "\" \"" + vbs + "\"", RegistryValueKind.String);
                    using (RegistryKey k = Registry.CurrentUser.OpenSubKey(ApprovePath, true))
                        if (k != null) k.SetValue("GameCrashDiag", new byte[] { 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, RegistryValueKind.Binary);
                }
                else
                {
                    using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKeyPath, true))
                        if (k != null) k.DeleteValue("GameCrashDiag", false);
                }

                if (chkRun.Checked)
                {
                    string launch = Path.Combine(dir, "启动诊断器.vbs");
                    if (File.Exists(launch))
                    {
                        ProcessStartInfo psi = new ProcessStartInfo("wscript.exe", "\"" + launch + "\"");
                        psi.UseShellExecute = true;
                        Process.Start(psi);
                    }
                }
            }
            catch (Exception ex) { Log("finish error " + ex.Message); }
            Close();
        }

        static string Tail(string s, int max)
        {
            if (string.IsNullOrEmpty(s)) return "";
            s = s.Trim();
            return s.Length <= max ? s : "..." + s.Substring(s.Length - max);
        }
    }
}
