using System;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;

// Option A updater: ask GitHub for the latest release, compare versions, hand the user a link.
// It never downloads or replaces anything by itself - that keeps it safe and AV friendly.
public static class Updater
{
    public const string ApiUrl = "https://api.github.com/repos/zoesion/game-crash-diag/releases/latest";
    public const string PageUrl = "https://github.com/zoesion/game-crash-diag/releases/latest";

    public sealed class Result
    {
        public bool Ok;
        public string Error = "";
        public string LatestTag = "";
        public string ReleaseName = "";
        public string HtmlUrl = PageUrl;
        public string PublishedAt = "";
        public bool IsNewer;
    }

    public static Result Check(string currentVersion)
    {
        var r = new Result();
        try
        {
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
            using (var wc = new WebClient())
            {
                wc.Headers.Add("User-Agent", "GameCrashDiag");
                wc.Headers.Add("Accept", "application/vnd.github+json");
                wc.Encoding = Encoding.UTF8;
                string json = wc.DownloadString(ApiUrl);

                Match mTag = Regex.Match(json, "\"tag_name\"\\s*:\\s*\"([^\"]+)\"");
                Match mName = Regex.Match(json, "\"name\"\\s*:\\s*\"([^\"]+)\"");
                Match mUrl = Regex.Match(json, "\"html_url\"\\s*:\\s*\"([^\"]+)\"");
                Match mDate = Regex.Match(json, "\"published_at\"\\s*:\\s*\"([^\"]+)\"");

                if (!mTag.Success) { r.Error = "返回内容里没有版本号"; return r; }
                r.LatestTag = mTag.Groups[1].Value.Trim();
                if (mName.Success) r.ReleaseName = Unescape(mName.Groups[1].Value);
                if (mUrl.Success) r.HtmlUrl = Unescape(mUrl.Groups[1].Value);
                if (mDate.Success) r.PublishedAt = mDate.Groups[1].Value;
                r.Ok = true;
                r.IsNewer = CompareVersions(r.LatestTag, currentVersion) > 0;
            }
        }
        catch (WebException wex)
        {
            r.Error = wex.Message;
        }
        catch (Exception ex)
        {
            r.Error = ex.Message;
        }
        return r;
    }

    /// <summary>Compares "v6.02" style tags; returns &gt;0 when a is newer than b.</summary>
    public static int CompareVersions(string a, string b)
    {
        int[] pa = Parse(a), pb = Parse(b);
        int n = Math.Max(pa.Length, pb.Length);
        for (int i = 0; i < n; i++)
        {
            int x = i < pa.Length ? pa[i] : 0;
            int y = i < pb.Length ? pb[i] : 0;
            if (x != y) return x.CompareTo(y);
        }
        return 0;
    }

    private static int[] Parse(string v)
    {
        if (string.IsNullOrEmpty(v)) return new int[0];
        string s = v.Trim().TrimStart('v', 'V');
        int cut = s.IndexOfAny(new[] { '-', '+', ' ' });
        if (cut > 0) s = s.Substring(0, cut);
        string[] parts = s.Split('.');
        var list = new int[parts.Length];
        for (int i = 0; i < parts.Length; i++)
        {
            int n;
            int.TryParse(parts[i], out n);
            list[i] = n;
        }
        return list;
    }

    private static string Unescape(string s)
    {
        return s.Replace("\\u0026", "&").Replace("\\/", "/").Replace("\\\"", "\"");
    }
}
