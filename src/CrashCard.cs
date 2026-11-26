using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Windows.Forms;

// Small non-modal card shown after a crash: one-line verdict + two buttons.
public sealed class CrashCard : Form
{
    public CrashCard(string title, string verdict, string reportPath, string snapshotPath)
    {
        Text = title;
        ClientSize = new Size(420, 210);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(28, 28, 34);
        ForeColor = Color.FromArgb(230, 230, 238);
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        TopMost = true;
        ShowInTaskbar = true;
        AutoScaleMode = AutoScaleMode.None;

        var lblIcon = new Label();
        lblIcon.Text = "⚠";
        lblIcon.Font = new Font("Segoe UI Symbol", 20f, FontStyle.Bold);
        lblIcon.ForeColor = Color.FromArgb(232, 92, 92);
        lblIcon.AutoSize = true;
        lblIcon.Location = new Point(16, 14);
        Controls.Add(lblIcon);

        var lblHead = new Label();
        lblHead.Text = "检测到游戏崩溃";
        lblHead.Font = new Font("Microsoft YaHei UI", 12f, FontStyle.Bold);
        lblHead.AutoSize = true;
        lblHead.Location = new Point(54, 18);
        Controls.Add(lblHead);

        var lblBody = new Label();
        lblBody.Text = verdict;
        lblBody.Font = new Font("Microsoft YaHei UI", 9.5f);
        lblBody.ForeColor = Color.FromArgb(198, 198, 210);
        lblBody.Bounds = new Rectangle(56, 50, 348, 60);
        Controls.Add(lblBody);

        var lblFile = new Label();
        lblFile.Text = string.IsNullOrEmpty(reportPath) ? "" : Path.GetFileName(reportPath);
        lblFile.Font = new Font("Microsoft YaHei UI", 8.5f);
        lblFile.ForeColor = Color.FromArgb(140, 140, 155);
        lblFile.Bounds = new Rectangle(56, 112, 348, 20);
        Controls.Add(lblFile);

        var btnOpen = new Button();
        btnOpen.Text = "打开报告";
        btnOpen.Bounds = new Rectangle(56, 150, 110, 34);
        btnOpen.FlatStyle = FlatStyle.Flat;
        btnOpen.FlatAppearance.BorderColor = Color.FromArgb(70, 70, 86);
        btnOpen.BackColor = Color.FromArgb(40, 40, 48);
        btnOpen.ForeColor = ForeColor;
        btnOpen.Click += (s, e) =>
        {
            try
            {
                if (!string.IsNullOrEmpty(reportPath) && File.Exists(reportPath))
                    System.Diagnostics.Process.Start("notepad.exe", "\"" + reportPath + "\"");
                else if (!string.IsNullOrEmpty(snapshotPath) && File.Exists(snapshotPath))
                    System.Diagnostics.Process.Start("explorer.exe", "\"" + snapshotPath + "\"");
            }
            catch { }
        };
        Controls.Add(btnOpen);

        var btnClose = new Button();
        btnClose.Text = "关闭";
        btnClose.Bounds = new Rectangle(294, 150, 110, 34);
        btnClose.FlatStyle = FlatStyle.Flat;
        btnClose.FlatAppearance.BorderColor = Color.FromArgb(70, 70, 86);
        btnClose.BackColor = Color.FromArgb(40, 40, 48);
        btnClose.ForeColor = ForeColor;
        btnClose.Click += (s, e) => Close();
        Controls.Add(btnClose);
    }
}
