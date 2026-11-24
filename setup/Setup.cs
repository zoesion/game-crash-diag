using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

static class Setup
{
    static string LogPath;

    static void Log(string msg)
    {
        try
        {
            if (LogPath != null) File.AppendAllText(LogPath, DateTime.Now.ToString("HH:mm:ss") + " " + msg + "\r\n");
        }
        catch { }
    }

    // 依次尝试可写目录。优先 exe 同目录（通常不受 Defender 受控文件夹访问限制）。
    static string PickWorkDir()
    {
        string baseName = "GameCrashDiag-setup-" + Guid.NewGuid().ToString("N").Substring(0, 8);
        string exeDir = null;
        try { exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location); } catch { }

        string[] candidates = new string[]
        {
            exeDir == null ? null : Path.Combine(exeDir, baseName),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GameCrashDiag", "setup", baseName),
            Path.Combine(Path.GetTempPath(), baseName),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "GameCrashDiag-setup", baseName)
        };

        string err = null;
        foreach (string dir in candidates)
        {
            if (string.IsNullOrEmpty(dir)) continue;
            try
            {
                Directory.CreateDirectory(dir);
                string probe = Path.Combine(dir, ".w");
                File.WriteAllText(probe, "ok");
                File.Delete(probe);
                return dir;
            }
            catch (Exception ex) { if (err == null) err = ex.Message; }
        }

        throw new Exception(
            "找不到可写目录。\r\n\r\n" +
            "常见原因：Windows Defender 的「受控文件夹访问」拦截了未签名程序。\r\n" +
            "解决办法（任选其一）：\r\n" +
            "  1. 用同目录下的「安装.cmd」安装（PowerShell 是微软签名程序，不会被拦）\r\n" +
            "  2. 设置 → 隐私和安全性 → Windows 安全中心 → 病毒和威胁防护 →\r\n" +
            "     管理勒索软件防护 → 受控文件夹访问 → 允许应用 → 添加本程序\r\n\r\n" +
            "详细信息：" + err);
    }

    [STAThread]
    static void Main(string[] args)
    {
        try
        {
            string targetDir = null;
            if (args != null && args.Length > 0 && !string.IsNullOrWhiteSpace(args[0]))
                targetDir = args[0].Trim('"');

            string work = PickWorkDir();
            LogPath = Path.Combine(work, "setup.log");
            Log("work=" + work);

            // 1) 解压内嵌文件
            Assembly asm = Assembly.GetExecutingAssembly();
            using (Stream s = asm.GetManifestResourceStream("app.zip"))
            {
                if (s == null) throw new Exception("安装包损坏（缺少内嵌资源）");
                using (ZipArchive zip = new ZipArchive(s, ZipArchiveMode.Read))
                {
                    foreach (ZipArchiveEntry entry in zip.Entries)
                    {
                        string dest = Path.Combine(work, entry.FullName.Replace('/', '\\'));
                        if (entry.FullName.EndsWith("/")) { Directory.CreateDirectory(dest); continue; }
                        Directory.CreateDirectory(Path.GetDirectoryName(dest));
                        entry.ExtractToFile(dest, true);
                    }
                }
            }
            Log("extracted");

            string ps = Path.Combine(work, "install.ps1");
            if (!File.Exists(ps)) throw new Exception("安装脚本缺失");

            // 2) 写一个中转批处理：用 explorer.exe 启动，拿到「中等完整性」令牌。
            //    直接 Process.Start 会继承本程序的低完整性级别，写 D:\Program Files 会被拒绝。
            string outFile = Path.Combine(work, "_out.txt");
            string exitFile = Path.Combine(work, "_exit.txt");

            // 用 UAC 提权启动安装：本程序可能处于低完整性级别，
            // 无法写入 D:\Program Files；提权后由管理员令牌执行才可靠。
            string inner = "powershell -NoProfile -ExecutionPolicy Bypass -File \"" + ps + "\" -Silent";
            if (!string.IsNullOrEmpty(targetDir)) inner += " -InstallDir \"" + targetDir + "\"";
            string cmdLine = "/c \"" + inner + " > \"" + outFile + "\" 2>&1 & echo %ERRORLEVEL%> \"" + exitFile + "\"";

            Log("launching elevated: " + cmdLine);
            ProcessStartInfo rsi = new ProcessStartInfo("cmd.exe", cmdLine);
            rsi.UseShellExecute = true;
            rsi.Verb = "runas";
            rsi.WindowStyle = ProcessWindowStyle.Hidden;
            try
            {
                using (Process rp = Process.Start(rsi)) { rp.WaitForExit(); }
            }
            catch (Exception rex)
            {
                Log("elevation failed: " + rex.Message);
                MessageBox.Show(
                    "需要管理员权限才能安装到 " + (string.IsNullOrEmpty(targetDir) ? @"D:\Program Files\GameCrashDiag" : targetDir) + "。\r\n\r\n" +
                    "已取消提权，或提权被系统拒绝。\r\n" +
                    "可以改用同目录下的「安装.cmd」安装。\r\n\r\n" + rex.Message,
                    "游戏崩溃诊断器", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            // 3) 等待安装完成（最多 3 分钟）
            int waited = 0;
            while (waited < 180000 && !File.Exists(exitFile))
            {
                Thread.Sleep(500);
                waited += 500;
            }

            string outText = File.Exists(outFile) ? File.ReadAllText(outFile, Encoding.GetEncoding(936)) : "";
            int exitCode = -1;
            if (File.Exists(exitFile))
            {
                int.TryParse(File.ReadAllText(exitFile).Trim(), out exitCode);
            }
            Log("install exit=" + exitCode + " waited=" + waited);

            string finalDir = string.IsNullOrEmpty(targetDir) ? @"D:\Program Files\GameCrashDiag" : targetDir;

            if (exitCode != 0)
            {
                MessageBox.Show(
                    "安装失败（退出码 " + exitCode + "）。\r\n\r\n" + Tail(outText, 1200) + "\r\n\r\n" +
                    "可以改用同目录下的「安装.cmd」安装。\r\n日志：" + LogPath,
                    "游戏崩溃诊断器", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            Log("done, dir=" + finalDir);
            try { Directory.Delete(work, true); } catch { }
            MessageBox.Show(
                "安装完成。\r\n\r\n" +
                "安装位置：" + finalDir + "\r\n" +
                "桌面上已创建「游戏崩溃诊断器」快捷方式，双击即可使用。\r\n\r\n" +
                "以后想卸载：设置 → 应用 → 游戏崩溃诊断器。",
                "游戏崩溃诊断器", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch (Exception ex)
        {
            Log("ERROR " + ex);
            MessageBox.Show("安装启动失败：\r\n" + ex.Message,
                "游戏崩溃诊断器", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    static string Tail(string s, int max)
    {
        if (string.IsNullOrEmpty(s)) return "";
        s = s.Trim();
        return s.Length <= max ? s : "..." + s.Substring(s.Length - max);
    }
}
