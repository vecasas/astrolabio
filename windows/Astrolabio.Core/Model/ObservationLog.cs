using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Astrolabio.Core.Astronomy;
using Astrolabio.Core.Protocol;

namespace Astrolabio.Core.Model;

public sealed record WeatherSnapshot(double CloudCover, double Temperature, double DewPoint, double Humidity, double Wind);

/// <summary>Una sesión de apilado. Los campos opcionales se añadieron en la versión 1.1 para los informes.</summary>
public sealed record ObservationRecord(Guid Id, string Target, DateTime Start, DateTime End, int Frames, int ExposureMs)
{
    public double? RaJ2000 { get; init; }
    public double? DecJ2000 { get; init; }
    public int? Gain { get; init; }
    public bool? LpFilter { get; init; }
    public int? Dropped { get; init; }
    public bool? DitherEnabled { get; init; }
    public int? DitherPixels { get; init; }
    public int? DitherInterval { get; init; }
    public int? FocusPosition { get; init; }
    public double? AltitudeStart { get; init; }
    public double? AltitudeEnd { get; init; }
    public int? BatteryStart { get; init; }
    public int? BatteryEnd { get; init; }
    public double? Temperature { get; init; }
    public string? Firmware { get; init; }
    public string? Device { get; init; }
    public string? SiteName { get; init; }
    public double? Latitude { get; init; }
    public double? Longitude { get; init; }
    public WeatherSnapshot? Weather { get; init; }
    public List<string>? Events { get; init; }
    public string? ImageFile { get; init; }
    public string? AlbumThumb { get; init; }
    public bool? Imported { get; init; }

    public double IntegrationMinutes => Frames * ExposureMs / 60_000.0;
    public DateTime NightDate => Start.ToLocalTime().AddHours(-12).Date;
    public ObjectKind? Kind => Catalog.Find(Target)?.Kind;

    public (double Ra, double Dec)? Coordinates =>
        RaJ2000 is double ra && DecJ2000 is double dec ? (ra, dec) : Catalog.Find(Target) is { } o ? (o.RaHours, o.DecDeg) : null;

    public string? ImagePath => ImageFile is null ? null : Path.Combine(ObservationLog.ReportsFolder, ImageFile);
}

/// <summary>Lo que la aplicación aporta a cada sesión: lugar, tiempo y una forma de guardar la imagen apilada.</summary>
public sealed record SessionContext(string SiteName, double Latitude, double Longitude, int Gain, bool? LpFilter,
    bool DitherEnabled, int DitherPixels, int DitherInterval, WeatherSnapshot? Weather, Func<string, bool> SaveImage);

/// <summary>Historial de sesiones de apilado (history.json): base de las estadísticas.</summary>
public sealed partial class ObservationLog : Observable
{
    public List<ObservationRecord> Records { get; private set; } = [];
    public ObservationRecord? Current { get; private set; }
    private readonly string _path;
    private DateTime _lastUpdate = DateTime.MinValue;
    private SeestarClient? _client;
    private Func<int> _exposure = () => 10_000;
    public Func<SessionContext?> ContextProvider { get; set; } = () => null;

    public static string ReportsFolder
    {
        get { var p = Path.Combine(AppPaths.Data, "reports"); Directory.CreateDirectory(p); return p; }
    }

    public ObservationLog(string? path = null)
    {
        _path = path ?? Path.Combine(AppPaths.Data, "history.json");
        try { if (File.Exists(_path)) Records = JsonSerializer.Deserialize<List<ObservationRecord>>(File.ReadAllText(_path)) ?? []; } catch { }
    }

    public IEnumerable<ObservationRecord> All => Current is null ? Records : Records.Append(Current);

    public void Attach(SeestarClient client, Func<int> exposureMs)
    {
        _client = client;
        _exposure = exposureMs;
        client.EventReceived += e => { if (e.Name == "Stack") HandleStack(e); };
        _ = Task.Run(async () =>
        {
            while (true)
            {
                await Task.Delay(60_000);
                if (Current is not null && (DateTime.Now - _lastUpdate).TotalSeconds > 900) CloseCurrent();
            }
        });
    }

    private string TargetName(SeestarEvent e)
    {
        foreach (var c in new[] { e.Data.Str("target_name"), _client?.ViewTarget,
                     _client?.LastEvents.GetValueOrDefault("AutoGoto")?.Data.Str("target_name") })
            if (!string.IsNullOrEmpty(c)) return c;
        return Strings.T("Sin nombre");
    }

    public void HandleStack(SeestarEvent e, DateTime? nowOpt = null)
    {
        var now = nowOpt ?? DateTime.UtcNow;
        if (e.Data.Int("stacked_frame") is int frames)
        {
            var name = TargetName(e);
            var dropped = e.Data.Int("dropped_frame");
            if (Current is { } cur && cur.Target == name && frames >= cur.Frames)
                Current = cur with { Frames = frames, End = now, Dropped = dropped ?? cur.Dropped, BatteryEnd = _client?.Battery ?? cur.BatteryEnd };
            else
            {
                CloseCurrent();
                var exp = _client?.StackExposureMs ?? _exposure();
                Current = Fill(new ObservationRecord(Guid.NewGuid(), name, now.AddSeconds(-frames * exp / 1000.0), now, frames, exp) { Dropped = dropped });
            }
            _lastUpdate = DateTime.Now;
            OnPropertyChanged(nameof(Current));
        }
        if (e.State is "complete" or "cancel" or "fail") CloseCurrent();
    }

    /// <summary>Completa un registro nuevo con lo que se sabe del telescopio, el lugar y el tiempo.</summary>
    private ObservationRecord Fill(ObservationRecord r)
    {
        var c = _client;
        if (c is not null)
            r = r with
            {
                Gain = c.CurrentGain, FocusPosition = c.FocuserPosition, BatteryStart = c.Battery, BatteryEnd = c.Battery,
                Temperature = c.Temperature, Firmware = c.FirmwareText.Length > 0 ? c.FirmwareText : null,
                Device = c.DeviceName.Length > 0 ? c.DeviceName : null,
            };
        if (Catalog.Find(r.Target) is { } o) r = r with { RaJ2000 = o.RaHours, DecJ2000 = o.DecDeg };
        if (ContextProvider() is { } ctx)
        {
            r = r with
            {
                SiteName = ctx.SiteName, Latitude = ctx.Latitude, Longitude = ctx.Longitude, Gain = r.Gain ?? ctx.Gain,
                LpFilter = ctx.LpFilter ?? r.LpFilter, DitherEnabled = ctx.DitherEnabled, DitherPixels = ctx.DitherPixels,
                DitherInterval = ctx.DitherInterval, Weather = ctx.Weather,
            };
            if (r.Coordinates is { } co) r = r with { AltitudeStart = Altitude(co, r.Start, ctx) };
        }
        return r;
    }

    private static double Altitude((double Ra, double Dec) co, DateTime utc, SessionContext ctx)
    {
        var now = Astro.PrecessFromJ2000(co.Ra, co.Dec, utc);
        return Astro.AltAz(now.Ra, now.Dec, utc, ctx.Latitude, ctx.Longitude).Alt;
    }

    public void CloseCurrent()
    {
        if (Current is not { } cur) return;
        Current = null;
        if (cur.Frames >= 3)
        {
            if (ContextProvider() is { } ctx)
            {
                if (cur.Coordinates is { } co) cur = cur with { AltitudeEnd = Altitude(co, cur.End, ctx) };
                var file = $"{cur.Id}.png";
                try { if (ctx.SaveImage(Path.Combine(ReportsFolder, file))) cur = cur with { ImageFile = file }; } catch { }
            }
            if (_client is { } c)
            {
                var from = cur.Start.ToLocalTime().AddMinutes(-2);
                List<string> events = [];
                try { events = c.Log.ToArray().Where(l => l.Level != LogLevel.Traffic && l.Date >= from)
                    .TakeLast(60).Select(l => $"{l.Date.ToString("t", Strings.Culture)}  {l.Text}").ToList(); } catch { }
                cur = cur with { BatteryEnd = c.Battery ?? cur.BatteryEnd, Events = events };
            }
            Records.Add(cur); Save();
        }
        OnPropertyChanged(nameof(Current));
    }

    public void Delete(IEnumerable<Guid> ids) { var s = ids.ToHashSet(); Records.RemoveAll(r => s.Contains(r.Id)); Save(); }

    [GeneratedRegex(@"Stacked_(\d+)_(?:mosaic_)?(.+?)_(\d+(?:\.\d+)?)s_[A-Za-z0-9]+_(\d{8}-\d{6})")]
    private static partial Regex StackedName();

    /// <summary>Importa las sesiones del álbum del Seestar a partir de los nombres de las imágenes apiladas.</summary>
    public int ImportFromAlbum(JsonObject reply)
    {
        if (reply.At("result.list") is not JsonArray groups) return 0;
        var added = 0;
        foreach (var g in groups.OfType<JsonObject>())
        foreach (var f in (g["files"] as JsonArray ?? []).OfType<JsonObject>())
        {
            var thn = f.Str("thn");
            if (thn is null) continue;
            var m = StackedName().Match(Path.GetFileName(thn));
            if (!m.Success) continue;
            var frames = int.Parse(m.Groups[1].Value);
            var expMs = (int)(double.Parse(m.Groups[3].Value, CultureInfo.InvariantCulture) * 1000);
            var end = DateTime.ParseExact(m.Groups[4].Value, "yyyyMMdd-HHmmss", CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal).ToUniversalTime();
            var target = m.Groups[2].Value;
            if (frames < 1 || Records.Any(r => Catalog.Normalize(r.Target) == Catalog.Normalize(target) && Math.Abs((r.End - end).TotalMinutes) < 30)) continue;
            var host = _client?.Host;
            var o = Catalog.Find(target);
            Records.Add(new ObservationRecord(Guid.NewGuid(), target, end.AddSeconds(-frames * expMs / 1000.0), end, frames, expMs)
            {
                Imported = true, LpFilter = thn.Contains("_LP_"), RaJ2000 = o?.RaHours, DecJ2000 = o?.DecDeg,
                AlbumThumb = string.IsNullOrEmpty(host) ? null : $"http://{host}/{reply.Str("result.path") ?? "MyWorks"}/{thn}",
            });
            added++;
        }
        if (added > 0) { Records.Sort((a, b) => a.Start.CompareTo(b.Start)); Save(); }
        return added;
    }

    private void Save()
    {
        try { File.WriteAllText(_path, JsonSerializer.Serialize(Records, new JsonSerializerOptions { WriteIndented = true })); } catch { }
        OnPropertyChanged(nameof(Records));
    }

    public string Csv()
    {
        var sb = new StringBuilder("objeto,inicio,fin,fotogramas,exposicion_ms,minutos\n");
        foreach (var r in All)
            sb.Append(CultureInfo.InvariantCulture, $"{Csv.Field(r.Target)},{r.Start:O},{r.End:O},{r.Frames},{r.ExposureMs},{r.IntegrationMinutes:F1}\n");
        return sb.ToString();
    }
}
