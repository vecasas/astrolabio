using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;

namespace Astrolabio.Core.Services;

public sealed record WeatherHour(DateTime Time, double CloudCover, double LowClouds, double Humidity, double Temperature, double DewPoint, double Wind);

/// <summary>Previsión de Open-Meteo (gratuita, sin clave).</summary>
public static class WeatherService
{
    public static readonly HttpClient Http = CreateHttp();

    private static HttpClient CreateHttp()
    {
        var h = new HttpClient { Timeout = TimeSpan.FromSeconds(45) };
        h.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("Astrolabio", "1.0"));
        return h;
    }

    public static Task<List<WeatherHour>> Forecast(double lat, double lon) =>
        Fetch("https://api.open-meteo.com/v1/forecast", lat, lon, "&forecast_days=3");

    /// <summary>Tiempo pasado: últimos 90 días con la API de previsión y lo anterior con el archivo ERA5.</summary>
    public static Task<List<WeatherHour>> History(double lat, double lon, DateTime fromUtc, DateTime toUtc)
    {
        var recent = fromUtc > DateTime.UtcNow.AddDays(-88);
        return Fetch(recent ? "https://api.open-meteo.com/v1/forecast" : "https://archive-api.open-meteo.com/v1/archive", lat, lon,
            $"&start_date={fromUtc:yyyy-MM-dd}&end_date={toUtc:yyyy-MM-dd}");
    }

    public static WeatherHour? Nearest(DateTime utc, IReadOnlyList<WeatherHour> hours) =>
        hours.Count == 0 ? null : hours.MinBy(h => Math.Abs((h.Time - utc).TotalSeconds)) is { } n && Math.Abs((n.Time - utc).TotalMinutes) < 90 ? n : null;

    private static async Task<List<WeatherHour>> Fetch(string baseUrl, double lat, double lon, string extra)
    {
        var url = string.Create(CultureInfo.InvariantCulture,
            $"{baseUrl}?latitude={lat:F4}&longitude={lon:F4}&hourly=cloud_cover,cloud_cover_low,relative_humidity_2m,temperature_2m,dew_point_2m,wind_speed_10m&timezone=UTC{extra}");
        var root = JsonNode.Parse(await Http.GetStringAsync(url));
        var h = root?["hourly"];
        if (h?["time"] is not JsonArray times) return [];
        double G(string k, int i) => h[k] is JsonArray a && i < a.Count && a[i] is JsonValue v && v.TryGetValue<double>(out var d) ? d : 0;
        var res = new List<WeatherHour>();
        for (var i = 0; i < times.Count; i++)
        {
            if (!DateTime.TryParseExact(times[i]?.GetValue<string>(), "yyyy-MM-dd'T'HH:mm", CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var t)) continue;
            res.Add(new WeatherHour(t, G("cloud_cover", i), G("cloud_cover_low", i), G("relative_humidity_2m", i), G("temperature_2m", i), G("dew_point_2m", i), G("wind_speed_10m", i)));
        }
        return res;
    }

    public static double? CloudCover(DateTime utc, IReadOnlyList<WeatherHour> hours)
    {
        if (hours.Count == 0) return null;
        var best = hours.MinBy(h => Math.Abs((h.Time - utc).TotalSeconds))!;
        return Math.Abs((best.Time - utc).TotalSeconds) < 5400 ? best.CloudCover : null;
    }
}

/// <summary>Busca cualquier objeto por nombre en Sesame/SIMBAD (CDS, Estrasburgo).</summary>
public static class NameResolver
{
    public static async Task<(double Ra, double Dec)?> Resolve(string name)
    {
        var q = name.Trim();
        if (q.Length == 0) return null;
        var text = await WeatherService.Http.GetStringAsync("https://cds.unistra.fr/cgi-bin/nph-sesame/-oI/SNV?" + Uri.EscapeDataString(q));
        foreach (var line in text.Split('\n'))
        {
            if (!line.StartsWith("%J ")) continue;
            var p = line[3..].Split(' ', StringSplitOptions.RemoveEmptyEntries)
                .Select(x => double.TryParse(x, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : double.NaN).Where(v => !double.IsNaN(v)).ToArray();
            if (p.Length >= 2) return (p[0] / 15, p[1]);
        }
        return null;
    }
}

/// <summary>Avisos al móvil con ntfy (sin cuenta ni teléfono).</summary>
public static class PhoneNotifier
{
    public static async Task Send(string server, string topic, string title, string body)
    {
        var t = topic.Trim();
        if (t.Length == 0) return;
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, server.Trim().TrimEnd('/') + "/" + t) { Content = new StringContent(body, Encoding.UTF8) };
            req.Headers.Add("Title", title);
            req.Headers.Add("Tags", "telescope");
            await WeatherService.Http.SendAsync(req);
        }
        catch { }
    }
}

/// <summary>Resumen de Wikipedia en el idioma de la interfaz.</summary>
public static class WikipediaService
{
    private static readonly Dictionary<string, (string Title, string Extract, string? Url)?> Cache = new();

    public static async Task<(string Title, string Extract, string? Url)?> Summary(Astronomy.DeepSkyObject obj)
    {
        var lang = Strings.Language;
        var key = $"{lang}:{obj.Id}";
        if (Cache.TryGetValue(key, out var hit)) return hit;
        var titles = new List<string>();
        if (obj.Id.StartsWith('M') && int.TryParse(obj.Id[1..].Trim(), out var n))
        {
            if (lang == AppLanguage.zh) titles.Add($"梅西耶{n}");
            titles.Add($"Messier {n}"); titles.Add($"M{n}");
        }
        titles.Add(obj.Id);
        if (obj.Name.Length > 0) { titles.Add(obj.Name); titles.Add(obj.LocalizedName); }
        foreach (var title in titles.Distinct())
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, $"https://{lang}.wikipedia.org/api/rest_v1/page/summary/{Uri.EscapeDataString(title.Replace(' ', '_'))}?redirect=true");
                if (lang == AppLanguage.zh) req.Headers.Add("Accept-Language", "zh-cn");
                var resp = await WeatherService.Http.SendAsync(req);
                if (!resp.IsSuccessStatusCode) continue;
                var j = JsonNode.Parse(await resp.Content.ReadAsStringAsync());
                if (j?["type"]?.GetValue<string>() != "standard") continue;
                var extract = j["extract"]?.GetValue<string>() ?? "";
                if (extract.Length < 40) continue;
                var r = (j["title"]?.GetValue<string>() ?? title, extract, j["content_urls"]?["desktop"]?["page"]?.GetValue<string>());
                Cache[key] = r;
                return r;
            }
            catch { }
        }
        Cache[key] = null;
        return null;
    }
}
