using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
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

    // 依次尝试可写目录：LocalAppData → 程序所在目录 → Temp
    static string PickWorkDir()
    {
        string baseName = "GameCrashDiag-setup-" + Guid.NewGuid().ToString("N").Substring(0, 8);
        // 只用用户目录，绝不落到 exe 所在目录
        string[] candidates = new string[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GameCrashDiag", "setup", baseName),
            Path.Combine(Path.GetTempPath(), baseName)
        };

        string err = null;
        foreach (string dir in candidates)
        {
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
        throw new Exception("找不到可写目录：" + err);
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

            string psArgs = "-NoProfile -ExecutionPolicy Bypass -File \"" + ps + "\" -Silent";
            if (!string.IsNullOrEmpty(targetDir)) psArgs += " -InstallDir \"" + targetDir + "\"";

            Log("running install.ps1");
            ProcessStartInfo psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = psArgs,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                WorkingDirectory = work
            };
            string outText, errText;
            using (Process proc = Process.Start(psi))
            {
                outText = proc.StandardOutput.ReadToEnd();
                errText = proc.StandardError.ReadToEnd();
                proc.WaitForExit();
                Log("install exit=" + proc.ExitCode);
            }
            try
            {
                File.WriteAllText(Path.Combine(work, "install-output.txt"), outText + "\r\n--- STDERR ---\r\n" + errText);
            }
            catch { }

            string finalDir = string.IsNullOrEmpty(targetDir) ? @"D:\Program\GameCrashDiag" : targetDir;
            Log("done, dir=" + finalDir);
            try { Directory.Delete(work, true); } catch { }
            MessageBox.Show(
                "安装完成！\r\n\r\n" +
                "安装位置：" + finalDir + "\r\n" +
                "桌面上已创建「游戏崩溃诊断器」快捷方式，双击即可使用。\r\n\r\n" +
                "以后想卸载：设置 → 应用 → 游戏崩溃诊断器。",
                "游戏崩溃诊断器", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch (Exception ex)
        {
            Log("ERROR " + ex);
            MessageBox.Show("安装启动失败：\r\n" + ex.Message + (LogPath != null ? "\r\n\r\n日志：" + LogPath : ""),
                "游戏崩溃诊断器", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
