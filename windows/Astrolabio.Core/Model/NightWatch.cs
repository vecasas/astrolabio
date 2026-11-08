using System.Globalization;
using System.Text.Json.Nodes;
using Astrolabio.Core.Imaging;
using Astrolabio.Core.Services;

namespace Astrolabio.Core.Model;

/// <summary>Nitidez de las estrellas (HFR), igual que NightWatch.swift.</summary>
public static class StarMetrics
{
    public sealed record Result(double Hfr, int Stars);

    public static Result? Measure(float[] lum, int width, int height, int radius = 8, int maxStars = 150, int minStars = 5)
    {
        if (width <= 4 * radius || height <= 4 * radius || lum.Length < width * height) return null;
        var sample = new List<float>(width * height / 49 + 1);
        for (var i = 0; i < width * height; i += 49) sample.Add(lum[i]);
        sample.Sort();
        var bg = sample[sample.Count / 2];
        var dev = sample.Select(v => Math.Abs(v - bg)).OrderBy(v => v).ToList();
        var sigma = Math.Max(1e-5f, dev[dev.Count / 2] * 1.4826f);
        var threshold = bg + 6 * sigma;
        const float saturation = 0.95f;
        var peaks = new List<(int X, int Y, float V)>();
        for (var y = radius; y < height - radius; y++)
        {
            var row = y * width;
            var x = radius;
            while (x < width - radius)
            {
                var v = lum[row + x];
                if (v > threshold && v < saturation)
                {
                    var isMax = true;
                    for (var dy = -2; dy <= 2 && isMax; dy++)
                        for (var dx = -2; dx <= 2; dx++)
                            if ((dx != 0 || dy != 0) && lum[row + dy * width + x + dx] > v) { isMax = false; break; }
                    if (isMax) { peaks.Add((x, y, v)); x += radius; continue; }
                }
                x++;
            }
        }
        if (peaks.Count < minStars) return null;
        peaks.Sort((a, b) => b.V.CompareTo(a.V));
        var hfrs = new List<double>();
        var taken = new List<(int X, int Y)>();
        foreach (var p in peaks)
        {
            if (hfrs.Count >= maxStars) break;
            if (taken.Any(t => Math.Abs(t.X - p.X) < 2 * radius && Math.Abs(t.Y - p.Y) < 2 * radius)) continue;
            double sumF = 0, sumRF = 0, cx = 0, cy = 0;
            for (var dy = -radius; dy <= radius; dy++)
                for (var dx = -radius; dx <= radius; dx++)
                {
                    var f = Math.Max(0, lum[(p.Y + dy) * width + p.X + dx] - bg);
                    sumF += f; cx += f * dx; cy += f * dy;
                }
            if (sumF <= 0) continue;
            cx /= sumF; cy /= sumF;
            for (var dy = -radius; dy <= radius; dy++)
                for (var dx = -radius; dx <= radius; dx++)
                {
                    var f = Math.Max(0, lum[(p.Y + dy) * width + p.X + dx] - bg);
                    sumRF += Math.Sqrt((dx - cx) * (dx - cx) + (dy - cy) * (dy - cy)) * f;
                }
            var hfr = sumRF / sumF;
            if (hfr > 0.3 && hfr < radius * 0.8) { hfrs.Add(hfr); taken.Add((p.X, p.Y)); }
        }
        if (hfrs.Count < minStars) return null;
        hfrs.Sort();
        return new Result(hfrs[hfrs.Count / 2], hfrs.Count);
    }

    public static float[] Luminance(LinearImage img)
    {
        var o = new float[img.Width * img.Height];
        for (var i = 0; i < o.Length; i++) o[i] = 0.2126f * img.R[i] + 0.7152f * img.G[i] + 0.0722f * img.B[i];
        return o;
    }
}

/// <summary>Vigila si las estrellas pierden nitidez durante el apilado.</summary>
public sealed class FocusWatch(double threshold = 0.3)
{
    public abstract record Verdict
    {
        public sealed record Learning : Verdict;
        public sealed record Ok : Verdict;
        public sealed record Softening(int Percent) : Verdict;
    }

    public double Threshold { get; set; } = threshold;
    public string Target { get; private set; } = "";
    public double? Baseline { get; private set; }
    private readonly List<double> _recent = [];
    private readonly List<double> _warmup = [];

    public Verdict Add(double hfr, string target)
    {
        if (target != Target) Reset(target);
        if (Baseline is null)
        {
            _warmup.Add(hfr);
            if (_warmup.Count >= 3) Baseline = _warmup.OrderBy(x => x).ElementAt(1);
            return new Verdict.Learning();
        }
        _recent.Add(hfr);
        if (_recent.Count > 3) _recent.RemoveAt(0);
        if (_recent.Count < 3) return new Verdict.Ok();
        var now = _recent.OrderBy(x => x).ElementAt(1);
        var b = Baseline.Value;
        return now > b * (1 + Threshold) && now - b >= 0.5 ? new Verdict.Softening((int)((now / b - 1) * 100)) : new Verdict.Ok();
    }

    public void Reset(string target = "") { Target = target; Baseline = null; _recent.Clear(); _warmup.Clear(); }
}

public enum DewRisk { Low, Possible, High }

public static class Dew
{
    public static DewRisk Level(double temperature, double dewPoint)
    {
        var spread = temperature - dewPoint;
        return spread < 2 ? DewRisk.High : spread < 4 ? DewRisk.Possible : DewRisk.Low;
    }
}

/// <summary>Aviso meteorológico oficial (MeteoAlarm).</summary>
public sealed record WeatherWarning(string Area, string Event, string Headline, int Level, int Type, DateTime Onset, DateTime Expires)
{
    public static readonly HashSet<int> DangerousTypes = [1, 2, 3, 10, 12, 13];
    public string Id => $"{Area}|{Event}|{Onset:O}";
    public bool IsActive(DateTime utc) => Onset <= utc && utc <= Expires;
    public bool IsDangerous => Level >= 2 && DangerousTypes.Contains(Type);
}

public static class StormGuard
{
    public static string? Reason(IEnumerable<WeatherWarning> warnings, IEnumerable<WeatherHour> hours, DateTime utc)
    {
        if (warnings.FirstOrDefault(w => w.IsActive(utc) && w.IsDangerous) is { } w)
            return Strings.T("Aviso oficial: %@", w.Headline.Length == 0 ? w.Event : w.Headline);
        var soon = hours.Where(h => h.Time >= utc.AddMinutes(-30) && h.Time <= utc.AddMinutes(90)).ToList();
        if (soon.Any(h => h.WeatherCode is >= 95 and <= 99)) return Strings.T("Se prevén tormentas en la próxima hora.");
        if (soon.FirstOrDefault(h => h.Precipitation >= 0.3) is { } r)
            return Strings.T("Se prevé lluvia (%@ mm/h).", r.Precipitation.ToString("F1", CultureInfo.InvariantCulture));
        if (soon.FirstOrDefault(h => h.Gusts >= 50) is { } g) return Strings.T("Se prevén rachas de viento de %@ km/h.", (int)g.Gusts);
        return null;
    }
}

/// <summary>Avisos oficiales de MeteoAlarm.</summary>
public static class MeteoAlarm
{
    public static readonly string[] Countries =
    [
        "austria", "belgium", "bosnia-herzegovina", "bulgaria", "croatia", "cyprus", "czechia", "denmark",
        "estonia", "finland", "france", "germany", "greece", "hungary", "iceland", "ireland", "israel", "italy",
        "latvia", "lithuania", "luxembourg", "malta", "moldova", "montenegro", "netherlands", "north-macedonia",
        "norway", "poland", "portugal", "romania", "serbia", "slovakia", "slovenia", "spain", "sweden",
        "switzerland", "ukraine", "united-kingdom",
    ];
    public const int MaxBytes = 20 * 1024 * 1024;

    public static async Task<List<WeatherWarning>> Fetch(string country)
    {
        if (!Countries.Contains(country)) return [];
        using var resp = await WeatherService.Http.GetAsync($"https://feeds.meteoalarm.org/api/v1/warnings/feeds-{country}");
        if (!resp.IsSuccessStatusCode || resp.Content.Headers.ContentLength > MaxBytes) return [];
        var bytes = await resp.Content.ReadAsByteArrayAsync();
        return bytes.Length > MaxBytes ? [] : Parse(System.Text.Encoding.UTF8.GetString(bytes));
    }

    public static List<WeatherWarning> Parse(string json)
    {
        var o = new List<WeatherWarning>();
        JsonNode? root;
        try { root = JsonNode.Parse(json); } catch { return o; }
        if (root?["warnings"] is not JsonArray list) return o;
        var seen = new HashSet<string>();
        static DateTime? D(JsonNode? n) =>
            n is JsonValue v && v.TryGetValue<string>(out var s) && DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var d) ? d.UtcDateTime : null;
        foreach (var w in list.OfType<JsonObject>())
        {
            if (w["alert"]?["info"] is not JsonArray infos || infos.FirstOrDefault() is not JsonObject info) continue;
            int level = 0, type = 0;
            foreach (var p in (info["parameter"] as JsonArray ?? []).OfType<JsonObject>())
            {
                var name = p["valueName"]?.GetValue<string>();
                var value = p["value"]?.GetValue<string>() ?? "";
                int.TryParse(value.Split(';')[0].Trim(), out var n);
                if (name == "awareness_level") level = n;
                if (name == "awareness_type") type = n;
            }
            if ((D(info["onset"]) ?? D(info["effective"])) is not DateTime onset || D(info["expires"]) is not DateTime expires) continue;
            var ev = info["event"]?.GetValue<string>() ?? "";
            var headline = info["headline"]?.GetValue<string>() ?? ev;
            foreach (var a in (info["area"] as JsonArray ?? []).OfType<JsonObject>())
            {
                var area = a["areaDesc"]?.GetValue<string>();
                if (string.IsNullOrEmpty(area)) continue;
                var warning = new WeatherWarning(area, ev, headline, level, type, onset, expires);
                if (seen.Add(warning.Id)) o.Add(warning);
            }
        }
        return o;
    }

    public static List<string> Areas(IEnumerable<WeatherWarning> w) =>
        w.Select(x => x.Area).Distinct().OrderBy(x => x, StringComparer.Create(CultureInfo.GetCultureInfo("es"), true)).ToList();
}

/// <summary>Radar de lluvia de RainViewer.</summary>
public static class RainRadar
{
    public sealed record Frame(DateTime Time, string Path);

    public static async Task<(string Host, List<Frame> Frames)> Frames() =>
        Parse(await WeatherService.Http.GetStringAsync("https://api.rainviewer.com/public/weather-maps.json"));

    public static (string Host, List<Frame> Frames) Parse(string json)
    {
        try
        {
            var root = JsonNode.Parse(json);
            var host = root?["host"]?.GetValue<string>() ?? "";
            if (!host.StartsWith("https://")) return ("", []);
            var frames = (root?["radar"]?["past"] as JsonArray ?? []).OfType<JsonObject>()
                .Select(f => (T: f["time"]?.GetValue<double>(), P: f["path"]?.GetValue<string>()))
                .Where(f => f.T is not null && f.P is string p && p.StartsWith('/') && !p.Contains(".."))
                .Select(f => new Frame(DateTime.UnixEpoch.AddSeconds(f.T!.Value), f.P!)).ToList();
            return (host, frames);
        }
        catch { return ("", []); }
    }

    public static (int X, int Y, double Fx, double Fy) Tile(double lat, double lon, int zoom)
    {
        var n = (double)(1 << zoom);
        var x = (lon + 180) / 360 * n;
        var latR = Math.Clamp(lat, -85.0511, 85.0511) * Math.PI / 180;
        var y = (1 - Math.Log(Math.Tan(latR) + 1 / Math.Cos(latR)) / Math.PI) / 2 * n;
        return ((int)x, (int)y, x - Math.Floor(x), y - Math.Floor(y));
    }

    public static string RadarUrl(string host, Frame f, int z, int x, int y) => $"{host}{f.Path}/256/{z}/{x}/{y}/2/1_1.png";
    public static string BaseUrl(int z, int x, int y) => $"https://tile.openstreetmap.org/{z}/{x}/{y}.png";
}
