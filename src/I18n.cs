using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

// Tiny key=value language loader (the PowerShell build used .psd1 files, which C# cannot read).
public static class I18n
{
    private static readonly Dictionary<string, string> _map = new Dictionary<string, string>(StringComparer.Ordinal);
    public static string Code = "zh-CN";

    public static void Load(string langDir, string code)
    {
        Code = code;
        _map.Clear();
        string path = Path.Combine(langDir, code + ".ini");
        if (!File.Exists(path)) path = Path.Combine(langDir, "zh-CN.ini");
        if (!File.Exists(path)) return;
        foreach (string raw in File.ReadAllLines(path, Encoding.UTF8))
        {
            string line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("#")) continue;
            int eq = line.IndexOf('=');
            if (eq <= 0) continue;
            string key = line.Substring(0, eq).Trim();
            string val = line.Substring(eq + 1).Trim();
            if (val.Length >= 2 && val[0] == '\'' && val[val.Length - 1] == '\'')
                val = val.Substring(1, val.Length - 2);
            val = val.Replace("\\n", "\n");
            _map[key] = val;
        }
    }

    public static string T(string key, string fallback)
    {
        string v;
        return _map.TryGetValue(key, out v) ? v : fallback;
    }

    public static string F(string key, string fallback, params object[] args)
    {
        string v = T(key, fallback);
        try { return string.Format(CultureInfo.CurrentCulture, v, args); }
        catch { return v; }
    }
}
