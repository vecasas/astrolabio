using System.Globalization;
using Astrolabio.Core.Astronomy;
using Astrolabio.Core.Services;

namespace Astrolabio.Core.Model;

/// <summary>Una noche de la semana valorada (igual que ObservingLists.swift).</summary>
public sealed record NightOutlook(DateTime Date, double DarkHours, double? Cloud, double MoonIllumination, double MoonUpFraction, int Score);

public static class WeekOutlook
{
    public static List<NightOutlook> Nights(DateTime fromLocal, double lat, double lon, IReadOnlyList<WeatherHour> weather, int days = 7)
    {
        var o = new List<NightOutlook>();
        for (var k = 0; k < days; k++)
        {
            var day = fromLocal.Date.AddDays(k).AddHours(12);
            var n = Astro.NightFor(day, lat, lon);
            if (n.DuskStart is not DateTime s || n.DawnEnd is not DateTime e || e <= s) { o.Add(new(day.Date, 0, null, 0, 0, 0)); continue; }
            var times = new List<DateTime>();
            for (var t = s; t <= e; t = t.AddMinutes(30)) times.Add(t);
            var clouds = times.Select(t => WeatherService.CloudCover(t, weather)).OfType<double>().ToList();
            double? cloud = clouds.Count >= Math.Max(1, times.Count / 2) ? clouds.Average() : null;
            var mid = s + (e - s) / 2;
            var illum = Astro.Moon(mid).Illumination;
            var moonAlt = Ephemeris.MoonAltitude(lat, lon);
            var up = times.Count(t => moonAlt(t) > 0) / (double)Math.Max(1, times.Count);
            var hours = (e - s).TotalHours;
            o.Add(new(day.Date, hours, cloud, illum, up, Score(hours, cloud, illum, up)));
        }
        return o;
    }

    public static int Score(double darkHours, double? cloud, double moon, double moonUp)
    {
        if (darkHours <= 0) return 0;
        var clear = 1 - (cloud ?? 50) / 100;
        var dark = Math.Min(1, darkHours / 9);
        return (int)Math.Round(100 * clear * clear * (0.6 + 0.4 * dark) * (1 - 0.6 * moon * moonUp));
    }

    public static NightOutlook? Best(IEnumerable<NightOutlook> nights) =>
        nights.Where(n => n.Cloud is not null).OrderByDescending(n => n.Score).FirstOrDefault();
}

public enum ObservingList { Messier, Caldwell }

public sealed record ListEntry(string Label, DeepSkyObject? Object);

public enum ListStatus { All, Done, Pending, PendingTonight }

public static class ObservingLists
{
    public static string StatusKey(ListStatus s) => s switch
    {
        ListStatus.All => "Todos", ListStatus.Done => "Hechos", ListStatus.Pending => "Pendientes", _ => "Pendientes y visibles esta noche",
    };

    public static List<ListEntry> Entries(ObservingList l) => l == ObservingList.Messier
        ? Enumerable.Range(1, 110).Select(n => new ListEntry($"M{n}", Catalog.Find($"M{n}"))).ToList()
        : Enumerable.Range(1, 109).Select(n => new ListEntry($"C{n}", Catalog.CaldwellObject(n))).ToList();

    public static HashSet<string> Imaged(IEnumerable<ObservationRecord> records) =>
        records.Select(r => Catalog.Find(r.Target)?.Id).OfType<string>().ToHashSet();

    public static double UsableTonight(DeepSkyObject o, Astro.Night night, double lat, double lon, double minAltitude, Horizon? horizon = null)
    {
        if (night.DuskStart is not DateTime s || night.DawnEnd is not DateTime e || e <= s) return 0;
        var clear = new SkyLimit(minAltitude, horizon ?? Horizon.Flat).ClearFixed(o.RaHours, o.DecDeg, lat, lon);
        double minutes = 0;
        for (var t = s; t <= e; t = t.AddMinutes(15)) if (clear(t)) minutes += 15;
        return minutes;
    }

    public static string Csv(ObservingList l, ISet<string> imaged, IReadOnlyDictionary<string, double> tonight)
    {
        var sb = new System.Text.StringBuilder("lista,numero,objeto,nombre,tipo,magnitud,fotografiado,minutos_esta_noche\n");
        foreach (var e in Entries(l))
        {
            var f = new List<string> { l.ToString(), e.Label };
            if (e.Object is { } o)
                f.AddRange([o.Id, o.LocalizedName, o.Kind.Label(), o.Magnitude.ToString("F1", CultureInfo.InvariantCulture),
                            imaged.Contains(o.Id) ? "sí" : "no", ((int)tonight.GetValueOrDefault(o.Id)).ToString(CultureInfo.InvariantCulture)]);
            else f.AddRange(["", "", "", "", "no", "0"]);
            sb.Append(string.Join(",", f.Select(Model.Csv.Field))).Append('\n');
        }
        return sb.ToString();
    }
}

public sealed record MarathonStep(DeepSkyObject Object, DateTime Time, double Altitude);

/// <summary>Orden del maratón Messier: en cada momento, de los visibles, el que antes deja de verse.</summary>
public static class Marathon
{
    public static (List<MarathonStep> Steps, List<DeepSkyObject> Missed) Plan(Astro.Night night, double lat, double lon, double minAltitude = 10, double minutesPerObject = 4, Horizon? horizon = null)
    {
        var hz = horizon ?? Horizon.Flat;
        var objects = Enumerable.Range(1, 110).Select(n => Catalog.Find($"M{n}")).OfType<DeepSkyObject>().ToList();
        if (night.Sunset is not DateTime sunset || night.Sunrise is not DateTime sunrise) return ([], objects);
        // Crepúsculo náutico (Sol a −12°): los primeros y los últimos objetos están en él.
        var start = sunset; while (start < sunrise && Astro.SunAltitude(start, lat, lon) > -12) start = start.AddMinutes(2);
        var end = sunrise; while (end > start && Astro.SunAltitude(end, lat, lon) > -12) end = end.AddMinutes(-2);
        if (end <= start) return ([], objects);
        var times = new List<DateTime>();
        for (var t = start; t <= end; t = t.AddMinutes(5)) times.Add(t);
        var alts = objects.Select(o =>
        {
            var now = Astro.PrecessFromJ2000(o.RaHours, o.DecDeg, start);
            return times.Select(t => { var aa = Astro.AltAz(now.Ra, now.Dec, t, lat, lon); return aa.Alt >= hz.AltitudeAt(aa.Az) ? aa.Alt : -90; }).ToArray();
        }).ToArray();
        int LastVisible(int i, int k) { var j = k; while (j + 1 < times.Count && alts[i][j + 1] >= minAltitude) j++; return j; }
        var remaining = Enumerable.Range(0, objects.Count).ToHashSet();
        var steps = new List<MarathonStep>();
        var clock = start;
        while (remaining.Count > 0)
        {
            var k = (int)Math.Floor((clock - start).TotalMinutes / 5);
            if (k >= times.Count) break;
            var visible = remaining.Where(i => alts[i][k] >= minAltitude).ToList();
            if (visible.Count == 0) { clock = clock.AddMinutes(5); continue; }
            var next = visible.OrderBy(i => LastVisible(i, k)).ThenBy(i => alts[i][k]).First();
            steps.Add(new MarathonStep(objects[next], clock, alts[next][k]));
            remaining.Remove(next);
            clock = clock.AddMinutes(minutesPerObject);
        }
        return (steps, remaining.Order().Select(i => objects[i]).ToList());
    }
}

/// <summary>Órbitas de cometas del MPC, descargadas una vez al día y guardadas en CometEls.txt.</summary>
public sealed class CometStore : Observable
{
    public static CometStore Shared { get; } = new();
    public const string Source = "https://www.minorplanetcenter.net/iau/MPCORB/CometEls.txt";
    private readonly string _cache;
    private List<CometOrbit> _orbits = []; public List<CometOrbit> Orbits { get => _orbits; private set => Set(ref _orbits, value); }
    public DateTime? Updated { get; private set; }
    private string? _error; public string? Error { get => _error; private set => Set(ref _error, value); }

    public CometStore(string? cache = null)
    {
        _cache = cache ?? Path.Combine(AppPaths.Data, "CometEls.txt");
        try
        {
            var fi = new FileInfo(_cache);
            if (fi.Exists && fi.Length <= Comets.MaxBytes) { Orbits = Comets.Parse(File.ReadAllText(_cache)); Updated = fi.LastWriteTime; }
        }
        catch { }
    }

    public async Task RefreshIfNeeded()
    {
        if (Updated is DateTime u && (DateTime.Now - u).TotalHours < 24 && Orbits.Count > 0) return;
        try
        {
            using var resp = await WeatherService.Http.GetAsync(Source);
            var bytes = resp.IsSuccessStatusCode && resp.Content.Headers.ContentLength is null or <= Comets.MaxBytes ? await resp.Content.ReadAsByteArrayAsync() : [];
            var parsed = bytes.Length is > 0 and <= Comets.MaxBytes ? Comets.Parse(System.Text.Encoding.UTF8.GetString(bytes)) : [];
            if (parsed.Count < 10) { Error = Strings.T("No se pudieron descargar las órbitas de los cometas."); return; }
            File.WriteAllBytes(_cache, bytes);
            Orbits = parsed; Updated = DateTime.Now; Error = null;
        }
        catch { Error = Strings.T("No se pudieron descargar las órbitas de los cometas."); }
    }

    public CometOrbit? Orbit(string name) => Orbits.FirstOrDefault(o => o.Name == name);
}
