using System.Globalization;
using System.Text.Json.Serialization;
using Astrolabio.Core.Astronomy;

namespace Astrolabio.Core.Model;

/// <summary>Horizonte propio: altura de los obstáculos cada 10° de acimut (igual que Horizon.swift).</summary>
public sealed class Horizon
{
    public const double Step = 10;
    public const int Count = 36;
    public const double MaxAltitude = 70;

    public double[] Altitudes { get; set; } = new double[Count];

    public static Horizon Flat => new();

    public Horizon() { }

    public Horizon(IEnumerable<double> altitudes)
    {
        var a = altitudes.Take(Count).ToList();
        while (a.Count < Count) a.Add(0);
        Altitudes = a.Select(x => double.IsFinite(x) ? Math.Clamp(x, 0, MaxAltitude) : 0).ToArray();
    }

    [JsonIgnore] public bool IsFlat => Altitudes.All(x => x == 0);

    public double AltitudeAt(double az)
    {
        var a = az % 360; if (a < 0) a += 360;
        var i = (int)(a / Step) % Count; var j = (i + 1) % Count;
        var f = (a - i * Step) / Step;
        return Altitudes[i] * (1 - f) + Altitudes[j] * f;
    }

    public bool IsVisible(double altitude, double azimuth, double minAltitude) => altitude >= Math.Max(minAltitude, AltitudeAt(azimuth));

    public void Set(double azimuth, double altitude)
    {
        var a = azimuth % 360; if (a < 0) a += 360;
        Altitudes[(int)Math.Round(a / Step) % Count] = Math.Clamp(altitude, 0, MaxAltitude);
    }

    public string Text() => string.Join("\n", Altitudes.Select((x, i) => $"{(int)(i * Step)} {x.ToString("F0", CultureInfo.InvariantCulture)}"));

    public static Horizon? Parse(string text)
    {
        var pts = new List<(double Az, double Alt)>();
        foreach (var raw in text.Split('\n').Take(2000))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            var f = line.Split([' ', ',', ';', '\t'], StringSplitOptions.RemoveEmptyEntries)
                .Select(x => double.TryParse(x, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : double.NaN).ToArray();
            if (f.Length < 2 || !double.IsFinite(f[0]) || !double.IsFinite(f[1])) continue;
            var az = f[0] % 360; if (az < 0) az += 360;
            pts.Add((az, f[1]));
        }
        if (pts.Count < 2) return null;
        pts.Sort((a, b) => a.Az.CompareTo(b.Az));
        double Interp(double az)
        {
            var after = pts.FirstOrDefault(p => p.Az >= az, pts[0]);
            var before = pts.LastOrDefault(p => p.Az <= az, pts[^1]);
            var span = after.Az - before.Az; if (span <= 0) span += 360;
            if (span == 360) return before.Alt;
            var d = az - before.Az; if (d < 0) d += 360;
            return before.Alt + (after.Alt - before.Alt) * d / span;
        }
        return new Horizon(Enumerable.Range(0, Count).Select(i => Interp(i * Step)));
    }
}

/// <summary>Altura mínima y horizonte propio juntos.</summary>
public sealed record SkyLimit(double MinAltitude, Horizon Horizon)
{
    public bool Clear(double raHours, double decDeg, DateTime utc, double lat, double lon)
    {
        var aa = Astro.AltAz(raHours, decDeg, utc, lat, lon);
        return Horizon.IsVisible(aa.Alt, aa.Az, MinAltitude);
    }

    public Func<DateTime, bool> ClearFixed(double raJ2000, double decJ2000, double lat, double lon)
    {
        var now = Astro.PrecessFromJ2000(raJ2000, decJ2000, DateTime.UtcNow);
        return t => Clear(now.Ra, now.Dec, t, lat, lon);
    }
}
