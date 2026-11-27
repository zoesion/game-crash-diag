using System;
using System.Drawing;
using System.Windows.Forms;

// Read-only text dialog (diagnosis / about). Same visual language as the main window.
public sealed class TextDialog : Form
{
    public TextDialog(string title, string body, bool showFixButton, Action onFix)
    {
        Text = title;
        ClientSize = new Size(700, 620);
        StartPosition = FormStartPosition.CenterParent;
        BackColor = Color.FromArgb(24, 24, 28);
        ForeColor = Color.FromArgb(226, 226, 234);
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        AutoScaleMode = AutoScaleMode.None;
        ShowInTaskbar = false;

        var box = new TextBox();
        box.Multiline = true;
        box.ReadOnly = true;
        box.ScrollBars = ScrollBars.Vertical;
        box.WordWrap = true;
        box.BorderStyle = BorderStyle.None;
        box.BackColor = Color.FromArgb(18, 18, 22);
        box.ForeColor = Color.FromArgb(214, 222, 232);
        box.Font = new Font("Consolas", 9.5f);
        box.Bounds = new Rectangle(10, 10, 680, 540);
        box.Text = body;
        Controls.Add(box);

        var btnCopy = MakeButton("复制报告", 380, 560, 110);
        btnCopy.Click += (s, e) => { try { Clipboard.SetText(box.Text); btnCopy.Text = "已复制"; } catch { } };
        Controls.Add(btnCopy);

        if (showFixButton)
        {
            var btnFix = MakeButton("修复 DirectX", 10, 560, 120);
            btnFix.Click += (s, e) => { if (onFix != null) onFix(); };
            Controls.Add(btnFix);
        }

        var btnClose = MakeButton("关闭", 500, 560, 110);
        btnClose.Click += (s, e) => Close();
        Controls.Add(btnClose);
    }

    private Button MakeButton(string text, int x, int y, int w)
    {
        var b = new Button();
        b.Text = text;
        b.Bounds = new Rectangle(x, y, w, 36);
        b.FlatStyle = FlatStyle.Flat;
        b.FlatAppearance.BorderColor = Color.FromArgb(70, 70, 86);
        b.BackColor = Color.FromArgb(34, 34, 40);
        b.ForeColor = Color.FromArgb(226, 226, 234);
        return b;
    }
}
