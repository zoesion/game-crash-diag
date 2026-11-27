using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

// Explains DXGI / WHEA / driver error codes using data\error-codes.txt (zh) or error-codes.en.txt.
public static class ErrorCodes
{
    public sealed class Entry
    {
        public string Code = "";
        public string Name = "";
        public string Meaning = "";
        public string Cause = "";
        public string Advice = "";
    }

    private static readonly Dictionary<string, Entry> _map = new Dictionary<string, Entry>(StringComparer.OrdinalIgnoreCase);
    private static string _loadedFor = "";

    public static int Count { get { return _map.Count; } }

    public static void Load(string root, string langCode)
    {
        string want = langCode == "en-US" ? "error-codes.en.txt" : "error-codes.txt";
        if (_loadedFor == want && _map.Count > 0) return;
        _map.Clear();
        string path = Path.Combine(root, "data", want);
        if (!File.Exists(path)) path = Path.Combine(root, "data", "error-codes.txt");
        if (!File.Exists(path)) return;
        try
        {
            foreach (string raw in File.ReadAllLines(path, Encoding.UTF8))
            {
                string line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#")) continue;
                string[] p = line.Split('|');
                if (p.Length < 5) continue;
                var e = new Entry
                {
                    Code = p[0].Trim(),
                    Name = p[1].Trim(),
                    Meaning = p[2].Trim(),
                    Cause = p[3].Trim(),
                    Advice = p[4].Trim()
                };
                _map[e.Code] = e;
            }
            _loadedFor = want;
        }
        catch { }
    }

    /// <summary>Finds every known code mentioned in the text, in table order.</summary>
    public static List<Entry> Find(string text)
    {
        var found = new List<Entry>();
        if (string.IsNullOrEmpty(text) || _map.Count == 0) return found;
        foreach (var kv in _map)
        {
            if (text.IndexOf(kv.Key, StringComparison.OrdinalIgnoreCase) >= 0)
                found.Add(kv.Value);
        }
        found.Sort((a, b) => string.Compare(a.Code, b.Code, StringComparison.OrdinalIgnoreCase));
        return found;
    }

    public static string Explain(string text)
    {
        List<Entry> hits = Find(text);
        var sb = new StringBuilder();
        if (hits.Count == 0)
        {
            sb.AppendLine("  （报告里没有出现已知错误码）");
            return sb.ToString();
        }
        foreach (Entry e in hits)
        {
            sb.AppendLine("  " + e.Code + "  " + e.Name);
            sb.AppendLine("    含义: " + e.Meaning);
            sb.AppendLine("    常见原因: " + e.Cause);
            sb.AppendLine("    建议: " + e.Advice);
            sb.AppendLine();
        }
        return sb.ToString();
    }

    /// <summary>Full table, used by the menu entry so users can look things up.</summary>
    public static string Table()
    {
        var sb = new StringBuilder();
        sb.AppendLine("=== 错误码对照表（" + _map.Count + " 条）===");
        sb.AppendLine();
        foreach (var kv in _map)
        {
            Entry e = kv.Value;
            sb.AppendLine(e.Code + "  " + e.Name);
            sb.AppendLine("  " + e.Meaning);
            sb.AppendLine("  原因: " + e.Cause);
            sb.AppendLine("  建议: " + e.Advice);
            sb.AppendLine();
        }
        return sb.ToString();
    }
}
