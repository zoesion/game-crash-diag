using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

// Ported from the PowerShell build: a process counts as a game when it owns a
// near-fullscreen visible window, is not on the blocklist, and uses at least 400 MB.
public static class GameDetect
{
    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    private static readonly HashSet<string> Blocked = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "explorer","dwm","powershell","pwsh","windowsterminal","cmd","conhost","gamecrashdiag","gamecrashdiag6",
        "chrome","msedge","firefox","iexplore","opera","brave","vivaldi",
        "discord","teams","slack","code","devenv","notepad","notepad++","winword","excel","powerpnt",
        "taskmgr","applicationframehost","searchhost","startmenuexperiencehost","textinputhost",
        "systemsettings","shellexperiencehost","lockapp","phoneexperiencehost","snippingtool","screensketch",
        "nvidia overlay","nvidia share","nvidia app","nvsphelper64","nvcontainer","nvsmartmax",
        "gameoverlayui","gameoverlayui64","steamwebhelper","steam",
        "rtss","rttshooksloader64","msiafterburner","rivatuner statistics server",
        "wallpaper64","wallpaper32","razerappengine","rzsdkserver","rzchromastreamserver",
        "syserroroverlay","translucenttb","rainmeter","nexus",
        "ollama","ollama app","ollama_llama_server","qqmusic","qqmusicmini","cloudmusic",
        "neteasecloudmusic","kugou","potplayermini64","vlc","mpc-hc64","mpv","obs64","obs64.exe","obs",
        "zoom","wechat","wechatappex","qq","photos","photosapp","mspaint","acrobat","acrord32","sumatrapdf",
        "baidunetdisk","thunder","idman","pixso","figma","photoshop","illustrator","afterfx",
        "obsidian","notion","typora","wmplayer","musicbee","foobar2000",
        "epicgameslauncher","battle.net","origin","ea desktop","eaapp","ubisoftconnect","galaxyclient",
        "riotclientservices","wegame","dockerd","docker desktop"
    };

    private static readonly string[] BlockedPaths =
    {
        @"\Windows\", @"\NVIDIA Corporation\", @"\Steam\bin\", @"\Razer\",
        @"\ProgramData\Microsoft\Windows Defender\", @"\Program Files\WindowsApps\",
        @"\AppData\Local\Programs\ollama\", @"\AppData\Local\Ollama\",
        @"ms-playwright", @"\AppData\Local\Google\Chrome\"
    };

    public sealed class Hit
    {
        public int Pid;
        public string Name = "";
        public string Path = "";
        public long Memory;
        public DateTime StartTime;
    }


    /// <summary>Looks at the loaded modules of the running game to see which upscaling /
    /// frame generation features are active. Useful when crashes only happen with DLSS on.</summary>
    public static string DetectFeatures(int pid)
    {
        var found = new List<string>();
        try
        {
            using (var p = System.Diagnostics.Process.GetProcessById(pid))
            {
                foreach (System.Diagnostics.ProcessModule m in p.Modules)
                {
                    string n = m.ModuleName.ToLowerInvariant();
                    if (n.Contains("nvngx_dlssg")) AddOnce(found, "DLSS 帧生成");
                    else if (n.Contains("nvngx_dlssd")) AddOnce(found, "DLSS 光线重建");
                    else if (n.Contains("nvngx_dlss")) AddOnce(found, "DLSS 超分辨率");
                    else if (n.Contains("nvngx")) AddOnce(found, "DLSS");
                    else if (n.Contains("sl.reflex") || n.Contains("nvreflex")) AddOnce(found, "Reflex");
                }
            }
        }
        catch { }
        return string.Join(", ", found.ToArray());
    }

    private static void AddOnce(List<string> list, string item)
    {
        if (!list.Contains(item)) list.Add(item);
    }
    public static Hit Find()
    {
        System.Drawing.Rectangle screen = System.Windows.Forms.Screen.PrimaryScreen.Bounds;
        double minW = screen.Width * 0.88;
        double minH = screen.Height * 0.88;

        var candidates = new List<Hit>();
        foreach (Process p in Process.GetProcesses())
        {
            try
            {
                if (p.Id == Process.GetCurrentProcess().Id) continue;
                string name = p.ProcessName;
                if (Blocked.Contains(name)) continue;
                IntPtr hwnd = p.MainWindowHandle;
                if (hwnd == IntPtr.Zero || !IsWindowVisible(hwnd)) continue;

                RECT r;
                if (!GetWindowRect(hwnd, out r)) continue;
                if (r.Right - r.Left < minW || r.Bottom - r.Top < minH) continue;

                string exe = "";
                try { exe = p.MainModule.FileName; } catch { }
                if (exe.Length > 0)
                {
                    bool skip = false;
                    foreach (string frag in BlockedPaths)
                        if (exe.IndexOf(frag, StringComparison.OrdinalIgnoreCase) >= 0) { skip = true; break; }
                    if (skip) continue;
                }

                long mem = p.WorkingSet64;
                if (mem < 400L * 1024 * 1024) continue;

                candidates.Add(new Hit
                {
                    Pid = p.Id,
                    Name = name,
                    Path = exe,
                    Memory = mem,
                    StartTime = SafeStart(p)
                });
            }
            catch { }
        }
        if (candidates.Count == 0) return null;
        candidates.Sort((a, b) => b.Memory.CompareTo(a.Memory));
        return candidates[0];
    }

    private static DateTime SafeStart(Process p)
    {
        try { return p.StartTime; } catch { return DateTime.Now; }
    }
}
