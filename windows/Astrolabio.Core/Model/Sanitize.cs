using System.Text;

namespace Astrolabio.Core.Model;

/// <summary>Limpieza de datos externos antes de usarlos en rutas, archivos o enlaces (igual que Sanitize.swift).</summary>
public static class SafeName
{
    public static string FileComponent(string s, string fallback = "Seestar")
    {
        var sb = new StringBuilder(s.Length);
        foreach (var ch in s) sb.Append("/\\:*?\"<>|".Contains(ch) || char.IsControl(ch) ? '-' : ch);
        var o = sb.ToString().Replace("..", "-").Trim().Trim('.', ' ');
        if (o.Length > 100) o = o[..100];
        // Nombres reservados de Windows (CON, NUL, COM1…).
        var stem = o.Split('.')[0].ToUpperInvariant();
        if (stem is "CON" or "PRN" or "AUX" or "NUL" || (stem.Length == 4 && (stem.StartsWith("COM") || stem.StartsWith("LPT")) && char.IsDigit(stem[3]))) o = "_" + o;
        return o.All(c => c is '-' or ' ') ? fallback : o;
    }

    public static bool IsInside(string child, string parent)
    {
        var c = Path.GetFullPath(child);
        var p = Path.GetFullPath(parent).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        return c.StartsWith(p, StringComparison.OrdinalIgnoreCase) || c.Equals(p.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase);
    }
}

public static class Csv
{
    public static string Field(string s)
    {
        var v = s.Replace('\r', ' ').Replace('\n', ' ');
        if (v.Length > 0 && "=+-@\t".Contains(v[0])) v = "'" + v;
        return "\"" + v.Replace("\"", "\"\"") + "\"";
    }
}

public static class NetPolicy
{
    public static Uri? NtfyUrl(string server, string topic)
    {
        var t = topic.Trim();
        if (t.Length == 0 || t.Length > 64 || !t.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_')) return null;
        if (!Uri.TryCreate(server.Trim().TrimEnd('/'), UriKind.Absolute, out var b)) return null;
        if (!(b.Scheme == "https" || (b.Scheme == "http" && IsLocal(b.Host)))) return null;
        return new Uri(b.ToString().TrimEnd('/') + "/" + t);
    }

    public static bool IsLocal(string host)
    {
        var h = host.ToLowerInvariant();
        if (h is "localhost" or "::1" or "[::1]" || h.EndsWith(".local")) return true;
        var p = h.Split('.');
        if (p.Length != 4 || !p.All(x => int.TryParse(x, out var n) && n is >= 0 and <= 255)) return false;
        var a = p.Select(int.Parse).ToArray();
        return a[0] == 10 || a[0] == 127 || (a[0] == 192 && a[1] == 168) || (a[0] == 172 && a[1] is >= 16 and <= 31) || (a[0] == 169 && a[1] == 254);
    }

    public static bool IsWikipedia(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var u) && u.Scheme == "https" &&
        (u.Host.Equals("wikipedia.org", StringComparison.OrdinalIgnoreCase) || u.Host.EndsWith(".wikipedia.org", StringComparison.OrdinalIgnoreCase));

    public static string HeaderValue(string s)
    {
        var v = s.Replace('\r', ' ').Replace('\n', ' ');
        // Las cabeceras HTTP de .NET solo admiten ASCII: el resto se quita.
        v = new string(v.Where(c => c is >= ' ' and <= '~').ToArray());
        return v.Length > 200 ? v[..200] : v;
    }
}
